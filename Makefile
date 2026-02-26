RUNTIME_DIR ?= ../biznez-agentic-runtime
CHART_DIR   := helm/biznez-runtime
RELEASE     := test

.PHONY: lint template kubeconform conftest kind-install smoke-test all

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

all: lint template kubeconform conftest
