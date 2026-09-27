.PHONY: up test down ui lint

up:    ## Create the kind cluster and bootstrap Argo CD (REVISION=main by default)
	scripts/up.sh

test:  ## Run the end-to-end suite against the current cluster
	tests/e2e.sh

ui:    ## Port-forward Argo CD and Grafana
	scripts/ui.sh

down:  ## Delete the cluster
	scripts/down.sh

lint:  ## Static checks that CI also runs
	terraform fmt -check -recursive infra
	helm lint argocd/apps
	kubectl kustomize policies >/dev/null
	kubectl kustomize platform/config >/dev/null
	kubectl kustomize workloads/demo-api >/dev/null
