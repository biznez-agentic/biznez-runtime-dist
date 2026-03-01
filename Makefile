RUNTIME_DIR ?= ../biznez-agentic-runtime
CHART_DIR   := helm/biznez-runtime
RELEASE     := test

.PHONY: lint template kubeconform conftest kind-install smoke-test all \
       shellcheck test-cli test-cli-integration-fast test-cli-integration-full \
       cli-bundle build-release verify-images test-release-integration

lint:
	helm lint $(CHART_DIR)/

template:
	helm template $(RELEASE) $(CHART_DIR)/

kubeconform:
	helm template $(RELEASE) $(CHART_DIR)/ | kubeconform -strict -summary -

conftest:
	helm template $(RELEASE) $(CHART_DIR)/ | conftest test - --policy policies/

kind-install:
	dev/kind-install.sh

smoke-test:
	tests/smoke-test.sh

shellcheck:
	shellcheck -s bash -e SC1091 cli/biznez-cli
	shellcheck -s bash -e SC1091,SC2317,SC2329 cli/lib/images.sh

test-cli:
	bash tests/test-cli.sh

test-cli-integration-fast:
	bash tests/smoke-test.sh

test-cli-integration-full:
	bash tests/smoke-test.sh --full

cli-bundle:  ## Bundle CLI + lib into single distributable file
	bash release/bundle-cli.sh cli/biznez-cli cli/lib/images.sh > cli/biznez-cli-bundle
	chmod +x cli/biznez-cli-bundle

build-release:  ## Run full release build pipeline
	release/build-release.sh $(VERSION)

verify-images:  ## Verify image signatures and tag→digest match
	cli/biznez-cli verify-images --manifest helm/biznez-runtime/images.lock \
		--registry $(REGISTRY) --key $(COSIGN_KEY)

test-release-integration:  ## Integration test with local registry
	bash tests/test-release-integration.sh

all: lint template kubeconform conftest
