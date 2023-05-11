#!/bin/bash


##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

# detect OS and ARCH
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/')

## Tool Binaries
KIND ?= $(LOCALBIN)/kind
KUSTOMIZE ?= $(LOCALBIN)/kustomize
HELM ?= $(LOCALBIN)/helm
CLUSTERADM ?= $(LOCALBIN)/clusteradm
ISTIOCTL ?= $(LOCALBIN)/istioctl

## Tool Versions
KIND_VERSION ?= v0.17.0
KUSTOMIZE_VERSION ?= v4.5.4
HELM_VERSION ?= v3.10.0
CLUSTERADM_VERSION ?= v0.4.1
ISTIOVERSION ?= 1.17.0

.PHONY: kind
kind: $(KIND) ## Download kind locally if necessary.
$(KIND):
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/kind@$(KIND_VERSION)

HELM_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
.PHONY: helm
helm: $(HELM)
$(HELM):
	curl -s $(HELM_INSTALL_SCRIPT) | HELM_INSTALL_DIR=$(LOCALBIN) PATH=$$PATH:$$HELM_INSTALL_DIR bash -s -- --no-sudo --version $(HELM_VERSION)

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || { curl -Ss $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }

CLUSTERADM_DOWNLOAD_URL ?= https://github.com/open-cluster-management-io/clusteradm/releases/download/$(CLUSTERADM_VERSION)/clusteradm_$(OS)_$(ARCH).tar.gz
CLUSTERADM_TAR ?= /tmp/clusteradm.tar.gz
.PHONY: clusteradm
clusteradm: $(CLUSTERADM)
$(CLUSTERADM): $(LOCALBIN)
	test -s $(LOCALBIN)/clusteradm || \
		{ curl -SsL $(CLUSTERADM_DOWNLOAD_URL) -o $(CLUSTERADM_TAR) && tar -C $(LOCALBIN) -xvf $(CLUSTERADM_TAR) --exclude=LICENSE && chmod +x $(CLUSTERADM); }

.PHONY: istioctl
istioctl: $(ISTIOCTL)
$(ISTIOCTL):
	$(eval ISTIO_TMP := $(shell mktemp -d))
	cd $(ISTIO_TMP); curl -sSL https://istio.io/downloadIstio | ISTIO_VERSION=$(ISTIOVERSION) sh -
	cp $(ISTIO_TMP)/istio-$(ISTIOVERSION)/bin/istioctl ${ISTIOCTL}
	-rm -rf $(TMP)

.PHONY: local-setup
local-setup: kind kustomize helm clusteradm istioctl
	./local-setup.sh