RUNTIME_DIR ?= ../biznez-agentic-runtime
CHART_DIR   := helm/biznez-runtime
RELEASE     := test

.PHONY: lint template kubeconform conftest kind-install smoke-test all \
       shellcheck test-cli test-cli-integration-fast test-cli-integration-full

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

test-cli:
	bash tests/test-cli.sh

test-cli-integration-fast:
	bash tests/smoke-test.sh

test-cli-integration-full:
	bash tests/smoke-test.sh --full

all: lint template kubeconform conftest
