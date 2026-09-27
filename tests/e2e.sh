#!/usr/bin/env bash
# End-to-end tests against a running cluster bootstrapped from this repo.
#
#   1. GitOps     every Argo CD application is Synced and Healthy
#   2. Admission  Kyverno rejects insecure, unpinned, foreign, unsigned and wrongly signed images,
#                 and admits the pipeline-signed image; Pod Security blocks privileged pods
#   3. Network    default-deny holds: other namespaces cannot reach demo-api, demo-api cannot
#                 reach the internet, and the allowed load-generator path works
#   4. RBAC       developers can read their namespace and nothing else
#   5. Metrics    Prometheus scrapes demo-api and has its alert rules loaded
#   6. Canary     a good release passes its Prometheus analysis and is promoted to 100%
#   7. Bad release a release with 50% errors fires DemoApiHighErrorRate (Prometheus and
#                 Alertmanager), fails its canary analysis and is rolled back automatically;
#                 the stable pods never run it
#   8. Self-heal  Argo CD reverts manual drift and recreates deleted resources
#
# Usage: tests/e2e.sh            (uses the current kubectl context)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/fixtures.env
source tests/fixtures.env

TEST_NS=policy-test
# Results go to a file, not shell variables: many checks run on the receiving end of a pipe,
# i.e. in a subshell, where incrementing a counter would be lost.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

pass() { echo "PASS $1" >>"$RESULTS"; printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { echo "FAIL $1" >>"$RESULTS"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Poll a command until it succeeds or the timeout (seconds) passes.
eventually() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $end ] && return 1
    sleep 5
  done
}

# Query Prometheus / Alertmanager through the API server's service proxy (no port-forward needed).
prom_query() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"
}
prom_value() { prom_query "$1" | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")'; }
alert_firing_in_prometheus() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/alerts" |
    python3 -c 'import sys,json;a=json.load(sys.stdin)["data"]["alerts"];sys.exit(0 if any(x["labels"]["alertname"]==sys.argv[1] and x["state"]=="firing" for x in a) else 1)' "$1"
}
alert_in_alertmanager() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts" |
    python3 -c 'import sys,json;a=json.load(sys.stdin);sys.exit(0 if any(x["labels"]["alertname"]==sys.argv[1] for x in a) else 1)' "$1"
}

# A pod spec that satisfies every policy; tests change one thing at a time.
pod_json() { # name image [namespace] [args-json]
  python3 - "$@" <<'EOF'
import json, sys
name, image = sys.argv[1], sys.argv[2]
ns = sys.argv[3] if len(sys.argv) > 3 else "policy-test"
args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
c = {"name": "c", "image": image,
     "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "64Mi"}},
     "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                         "capabilities": {"drop": ["ALL"]}}}
if args:
    c["args"] = args
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "namespace": ns},
  "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False,
           "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                               "seccompProfile": {"type": "RuntimeDefault"}},
           "containers": [c]}}))
EOF
}
mutate() { python3 -c "import sys,json;d=json.load(sys.stdin);$1;print(json.dumps(d))"; }

expect_denied() { # description expected-message-fragment  (manifest on stdin)
  local out
  if out=$(kubectl apply --dry-run=server -f - 2>&1); then
    fail "$1" "was admitted: $out"
  elif grep -q -- "$2" <<<"$out"; then
    pass "$1"
  else
    fail "$1" "rejected for a different reason: $(head -c 300 <<<"$out")"
  fi
}
expect_allowed() {
  local out
  if out=$(kubectl apply --dry-run=server -f - 2>&1); then pass "$1"; else fail "$1" "$(head -c 300 <<<"$out")"; fi
}

SIGNED_IMAGE="ghcr.io/prhoguns/demo-api@$(grep -oE 'sha256:[a-f0-9]{64}' workloads/demo-api/kustomization.yaml)"

########################################################################################
section "1. GitOps: Argo CD applications"
apps_ready() {
  kubectl -n argocd get applications -o json | python3 -c '
import sys, json
apps = json.load(sys.stdin)["items"]
names = {a["metadata"]["name"] for a in apps}
need = {"root", "kyverno", "policies", "monitoring", "argo-rollouts", "platform-config", "demo-api"}
ok = need <= names and all(a["status"].get("sync", {}).get("status") == "Synced" and
                           a["status"].get("health", {}).get("status") == "Healthy" for a in apps)
sys.exit(0 if ok else 1)'
}
if eventually 1200 apps_ready; then
  pass "all 7 applications Synced and Healthy"
else
  fail "all 7 applications Synced and Healthy" "$(kubectl -n argocd get applications 2>&1)"
fi
rollout_phase() { kubectl -n demo get rollout demo-api -o jsonpath='{.status.phase}'; }
rollout_healthy() { [ "$(rollout_phase)" = Healthy ]; }
eventually 600 rollout_healthy &&
  pass "demo-api rollout Healthy ($(kubectl -n demo get rollout demo-api -o jsonpath='{.status.availableReplicas}') replicas available)" ||
  fail "demo-api rollout Healthy" "phase: $(rollout_phase)"
spread=$(kubectl -n demo get pods -l app.kubernetes.io/name=demo-api -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)
[ "$spread" -ge 2 ] && pass "demo-api replicas spread across $spread nodes" || fail "demo-api replicas spread across nodes" "on $spread node(s)"

########################################################################################
section "2. Admission control (Kyverno + Pod Security)"
kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
pod_json ok "$SIGNED_IMAGE" | expect_allowed "admits the pipeline-signed image, pinned by digest"
pod_json p "$SIGNED_IMAGE" | mutate 'd["spec"]["securityContext"]["runAsNonRoot"]=False' |
  expect_denied "rejects a container allowed to run as root" "runAsNonRoot"
pod_json p "$SIGNED_IMAGE" | mutate 'd["spec"]["containers"][0]["securityContext"]["allowPrivilegeEscalation"]=True' |
  expect_denied "rejects privilege escalation" "allowPrivilegeEscalation"
pod_json p "$SIGNED_IMAGE" | mutate 'd["spec"]["containers"][0]["securityContext"]["capabilities"]={"add":["NET_ADMIN"]}' |
  expect_denied "rejects a container that keeps Linux capabilities" "drop ALL"
pod_json p "$SIGNED_IMAGE" | mutate 'd["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"]=False' |
  expect_denied "rejects a writable root filesystem" "readOnlyRootFilesystem"
pod_json p "$SIGNED_IMAGE" | mutate 'del d["spec"]["containers"][0]["resources"]' |
  expect_denied "rejects a container without resource requests" "resources.requests"
pod_json p "nginx:1.29" | expect_denied "rejects an image from Docker Hub" "must come from ghcr.io/prhoguns/"
pod_json p "ghcr.io/prhoguns/demo-api:main" | expect_denied "rejects an image referenced by tag" "pinned by digest"
pod_json p "$UNSIGNED_IMAGE" | expect_denied "rejects an unsigned image from our own registry" "not signed by the devsecops-supply-chain pipeline"
pod_json p "$WRONG_IDENTITY_IMAGE" | expect_denied "rejects an image signed by a different workflow" "not signed by the devsecops-supply-chain pipeline"
pod_json p "nginx:1.29" | python3 -c '
import sys, json
pod = json.load(sys.stdin)
print(json.dumps({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "d", "namespace": "policy-test"},
  "spec": {"selector": {"matchLabels": {"a": "b"}},
           "template": {"metadata": {"labels": {"a": "b"}}, "spec": pod["spec"] | {"restartPolicy": "Always"}}}}))' |
  expect_denied "rejects a bad Deployment at apply time, not only its pods" "must come from ghcr.io/prhoguns/"
pod_json p "$SIGNED_IMAGE" demo | mutate 'd["spec"]["hostNetwork"]=True' |
  expect_denied "Pod Security 'restricted' blocks host networking in the demo namespace" "violates PodSecurity"

########################################################################################
section "3. Network policy"
# On a fresh cluster Prometheus may still be discovering targets here, and rate() needs two scrapes,
# so allow up to 5 minutes before calling the traffic path broken.
work_rate() { prom_value 'sum(rate(http_requests_total{job="demo-api",path="/api/work"}[1m]))' | cut -d. -f1; }
traffic_flowing() { local r; r=$(work_rate); [ -n "$r" ] && [ "$r" -ge 1 ]; }
eventually 300 traffic_flowing &&
  pass "allowed path: load generator reaches demo-api (>= 1 req/s in Prometheus)" ||
  fail "allowed path: load generator reaches demo-api"

probe_args='["-c","import urllib.request,sys\ntry:\n  urllib.request.urlopen(\"http://demo-api.demo.svc/healthz\",timeout=3)\n  print(\"REACHED\")\nexcept Exception as e:\n  print(\"BLOCKED\",type(e).__name__)"]'
kubectl -n "$TEST_NS" delete pod netprobe --ignore-not-found >/dev/null
pod_json netprobe "$SIGNED_IMAGE" "$TEST_NS" "$probe_args" | kubectl apply -f - >/dev/null
eventually 90 test "$(kubectl -n $TEST_NS get pod netprobe -o jsonpath='{.status.phase}')" = Succeeded
result=$(kubectl -n "$TEST_NS" logs netprobe 2>&1)
grep -q BLOCKED <<<"$result" && pass "another namespace cannot reach demo-api ($result)" || fail "another namespace cannot reach demo-api" "$result"

pod=$(kubectl -n demo get pods -l app.kubernetes.io/name=demo-api -o jsonpath='{.items[0].metadata.name}')
egress=$(kubectl -n demo exec "$pod" -- python -c '
import urllib.request
try:
    urllib.request.urlopen("https://github.com", timeout=3); print("REACHED")
except Exception as e:
    print("BLOCKED", type(e).__name__)' 2>&1)
grep -q BLOCKED <<<"$egress" && pass "demo-api has no internet egress ($egress)" || fail "demo-api has no internet egress" "$egress"

########################################################################################
section "4. RBAC"
can() { kubectl auth can-i "$@" --as=jane --as-group=demo-developers 2>/dev/null; }
[ "$(can list pods -n demo)" = yes ] && pass "developer can list pods in demo" || fail "developer can list pods in demo"
[ "$(can get pods --subresource=log -n demo)" = yes ] && pass "developer can read logs in demo" || fail "developer can read logs in demo"
[ "$(can get secrets -n demo)" = no ] && pass "developer cannot read secrets" || fail "developer cannot read secrets"
[ "$(can create pods --subresource=exec -n demo)" = no ] && pass "developer cannot exec into pods" || fail "developer cannot exec into pods"
[ "$(can patch deployments -n demo)" = no ] && pass "developer cannot change deployments (changes go through Git)" || fail "developer cannot change deployments"
[ "$(can list pods -n kube-system)" = no ] && pass "developer cannot see other namespaces" || fail "developer cannot see other namespaces"

########################################################################################
section "5. Metrics"
up=$(prom_value 'count(up{job="demo-api"} == 1)')
[ "${up:-0}" -ge 4 ] && pass "Prometheus scrapes all 4 demo-api replicas" || fail "Prometheus scrapes all 4 demo-api replicas" "up count: ${up:-none}"
rules=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/rules" | grep -o 'DemoApi[A-Za-z]*' | sort -u | tr '\n' ' ')
[ "$(wc -w <<<"$rules")" -eq 3 ] && pass "alert rules loaded: $rules" || fail "alert rules loaded" "$rules"

########################################################################################
section "6. Canary release: a good version is analysed and promoted"
# Pause GitOps reconciliation for demo-api so the test's releases are not reverted mid-rollout.
kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
kubectl -n argocd patch application demo-api --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
stable_before=$(kubectl -n demo get rollout demo-api -o jsonpath='{.status.stableRS}')
kubectl -n demo patch rollout demo-api --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"e2e/release\":\"good-$(date +%s)\"}}}}}" >/dev/null
latest_analysis_phase() {
  kubectl -n demo get analysisruns -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.status.phase}{"\n"}{end}' | sort | tail -1 | cut -d' ' -f2
}
promoted() { rollout_healthy && [ "$(kubectl -n demo get rollout demo-api -o jsonpath='{.status.stableRS}')" != "$stable_before" ]; }
eventually 600 promoted &&
  pass "good release promoted to 100% (canary analysis: $(latest_analysis_phase))" ||
  fail "good release promoted to 100%" "phase: $(rollout_phase), analysis: $(latest_analysis_phase)"

########################################################################################
section "7. Bad release: alert fires, canary analysis fails, automatic rollback"
stable_rs=$(kubectl -n demo get rollout demo-api -o jsonpath='{.status.stableRS}')
kubectl -n demo patch rollout demo-api --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0","value":{"name":"ERROR_RATE","value":"0.5"}}]' >/dev/null
canary_running() { [ "$(kubectl -n demo get pods -l app.kubernetes.io/name=demo-api -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash}{"\n"}{end}' | grep -vcx "$stable_rs")" -ge 1 ]; }
eventually 180 canary_running && pass "bad release started as a canary (1 of 4 pods)" || fail "bad release started as a canary"
eventually 300 alert_firing_in_prometheus DemoApiHighErrorRate &&
  pass "DemoApiHighErrorRate firing in Prometheus while the canary runs" ||
  fail "DemoApiHighErrorRate firing in Prometheus"
eventually 120 alert_in_alertmanager DemoApiHighErrorRate &&
  pass "alert delivered to Alertmanager" || fail "alert delivered to Alertmanager"
aborted() { [ "$(kubectl -n demo get rollout demo-api -o jsonpath='{.status.abort}')" = true ]; }
eventually 300 aborted &&
  pass "canary analysis failed and the rollout aborted itself (analysis: $(latest_analysis_phase))" ||
  fail "rollout aborted automatically" "phase: $(rollout_phase), analysis: $(latest_analysis_phase)"
back_on_stable() {
  [ "$(kubectl -n demo get rollout demo-api -o jsonpath='{.status.stableRS}')" = "$stable_rs" ] &&
    ! canary_running &&
    [ "$(kubectl -n demo get pods -l "rollouts-pod-template-hash=$stable_rs" --field-selector=status.phase=Running -o name | wc -l)" -ge 4 ]
}
eventually 180 back_on_stable &&
  pass "all traffic back on the stable version; stable pods never ran the bad release" ||
  fail "all traffic back on the stable version"

########################################################################################
section "8. Self-healing"
# Resume reconciliation: the root app restores demo-api's sync policy, which reverts the drift.
kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
error_rate_reverted() { [ "$(kubectl -n demo get rollout demo-api -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ERROR_RATE")].value}')" = "0" ]; }
eventually 300 error_rate_reverted && pass "manual change (ERROR_RATE=0.5) reverted to the value in Git" || fail "manual change reverted to Git"
kubectl -n demo delete service demo-api >/dev/null
eventually 180 kubectl -n demo get service demo-api && pass "deleted Service recreated by Argo CD" || fail "deleted Service recreated by Argo CD"
eventually 900 apps_ready && pass "all applications back to Synced and Healthy" || fail "all applications back to Synced and Healthy"

kubectl delete namespace "$TEST_NS" --wait=false >/dev/null

PASS=$(grep -c '^PASS' "$RESULTS")
FAIL=$(grep -c '^FAIL' "$RESULTS")
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
grep '^FAIL' "$RESULTS" | sed 's/^FAIL /  - /'
[ "$FAIL" -eq 0 ]
