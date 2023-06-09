#!/bin/bash

# shellcheck shell=bash

set -xe pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
KIND_CLUSTER_PREFIX="submariner-cluster-"
export CLUSTERADM_BIN="${BIN_DIR}/clusteradm"
export ISTIOCTL_BIN="${BIN_DIR}/istioctl"

source "${LOCAL_SETUP_DIR}"/.ocmUtils

KIND="${BIN_DIR}/kind"
KUSTOMIZE="${BIN_DIR}/kustomize"
HELM="${BIN_DIR}/helm"

METALLB_KUSTOMIZATION_DIR=${LOCAL_SETUP_DIR}/config/metallb
SUBMARINER_RESOURCES_DIR=${LOCAL_SETUP_DIR}/config/submariner
INGRESS_NGINX_KUSTOMIZATION_DIR=${LOCAL_SETUP_DIR}/config/ingress-nginx
EXAMPLES_DIR=${LOCAL_SETUP_DIR}/config/examples
ISTIO_KUSTOMIZATION_DIR=${LOCAL_SETUP_DIR}/config/istio/istio-operator.yaml
GATEWAY_API_KUSTOMIZATION_DIR=${LOCAL_SETUP_DIR}/config/gateway-api

kind_fixup_config() {
  local master_ip
  TMP_KUBECONFIG=./tmp/kubeconfigs/${cluster}.kubeconfig
  master_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cluster}-control-plane" | head -n 1)
  yq -i ".clusters[0].cluster.server = \"https://${master_ip}:6443\"" "${TMP_KUBECONFIG}"
  yq -i "(.. | select(. == \"kind-${cluster}\")) = \"${cluster}\"" "${TMP_KUBECONFIG}"
  chmod a+r "${TMP_KUBECONFIG}"
}

kindCreateCluster() {
  local cluster=$1;
  local port80=$2;
  local port443=$3;
  local idx=$4
  local pod_cidr="10.24${idx}.0.0/16"
  local service_cidr="100.9${idx}.0.0/16"
  local dns_domain="${cluster}.local"
  cat <<EOF | ${KIND} create cluster --name ${cluster} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
kubeadmConfigPatches:
- |
  apiVersion: kubeadm.k8s.io/v1beta2
  kind: ClusterConfiguration
  metadata:
    name: config
  networking:
    podSubnet: ${pod_cidr}
    serviceSubnet: ${service_cidr}
    dnsDomain: ${dns_domain}
nodes:
- role: control-plane
  image: kindest/node:v1.26.0

EOF
  ${KIND} get kubeconfig --name ${cluster} > ./tmp/kubeconfigs/${cluster}.kubeconfig
  ${KIND} export kubeconfig --name ${cluster} --kubeconfig ./tmp/kubeconfigs/internal/${cluster}.kubeconfig --internal
  kind_fixup_config
}

deployMetalLB () {
  clusterName=${1}
  metalLBSubnet=${2}

  kubectl config use-context kind-${clusterName}
  echo "Deploying MetalLB to ${clusterName}"
  ${KUSTOMIZE} build ${METALLB_KUSTOMIZATION_DIR} | kubectl apply -f -
  while (test $(kubectl -n metallb-system get pod --selector=app=metallb -o name | wc -l) -le 1)
  do
    echo "Waiting for metallb pods to exist"
    sleep 3
  done
  echo "Waiting for deployments to be ready ..."
  kubectl -n metallb-system wait --for=condition=ready pod --selector=app=metallb --timeout=90s
  echo "Creating MetalLB AddressPool"
  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
  - 172.18.${metalLBSubnet}.0/24
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF
}

cleanClusters() {
	# Delete existing kind clusters
	clusterCount=$(${KIND} get clusters | grep ${KIND_CLUSTER_PREFIX} | wc -l)
	if ! [[ $clusterCount =~ "0" ]] ; then
		echo "Deleting previous kind clusters."
		${KIND} get clusters | grep ${KIND_CLUSTER_PREFIX} | xargs ${KIND} delete clusters
	fi
  rm -rf ./tmp/kubeconfigs/*
}


deployIngressController() {
  clusterName=${1}
  kubectl config use-context kind-${clusterName}
  echo "Deploying Ingress controller to ${clusterName}"
  ${KUSTOMIZE} build ${INGRESS_NGINX_KUSTOMIZATION_DIR} --enable-helm --helm-command ${HELM} | kubectl apply -f -
  echo "Waiting for deployments to be ready ..."
  kubectl -n ingress-nginx wait --timeout=300s --for=condition=Available deployments --all
}

deployIstio() {
  clusterName=${1}
  echo "Deploying Istio to (${clusterName})"

  kubectl config use-context kind-${clusterName}
  ${ISTIOCTL_BIN} operator init
	kubectl apply -f  ${ISTIO_KUSTOMIZATION_DIR}
}

installGatewayAPI() {
  clusterName=${1}
  kubectl config use-context kind-${clusterName}
  echo "Installing Gateway API in ${clusterName}"

  ${KUSTOMIZE} build ${GATEWAY_API_KUSTOMIZATION_DIR} | kubectl apply -f -
}

port80=9090
port443=8445
metalLBSubnetStart=200

cleanClusters

for ((i = 1; i <= 2; i++)); do
  export KUBECONFIG=$(pwd)/tmp/kubeconfigs/base.config
  kindCreateCluster ${KIND_CLUSTER_PREFIX}${i} $((${port80} + ${i} - 1)) $((${port443} + ${i} - 1)) ${i}
  # deployIstio ${KIND_CLUSTER_PREFIX}${i}
  # installGatewayAPI ${KIND_CLUSTER_PREFIX}${i}
  #deployMetalLB ${KIND_CLUSTER_PREFIX}${i} $((${metalLBSubnetStart} + ${i} - 1))
  # deployIngressController ${KIND_CLUSTER_PREFIX}${i}


  # if [[ "$i" -eq 1 ]]
  # then
  #   # OCM Hub goes on first cluster
  #   ocmInitHub ${KIND_CLUSTER_PREFIX}${i}
  # else
  #   # Register all other clusters with the OCM Hub
  #   ocmAddCluster ${KIND_CLUSTER_PREFIX}1 ${KIND_CLUSTER_PREFIX}${i}
  # fi
done;

# Deploy the submariner broker to cluster 1
subctl deploy-broker --kubeconfig ./tmp/kubeconfigs/submariner-cluster-1.kubeconfig

# Join cluster 1 & 2 to the broker
subctl join --kubeconfig ./tmp/kubeconfigs/submariner-cluster-1.kubeconfig broker-info.subm --clusterid submariner-cluster-1 --natt=false --check-broker-certificate=false
subctl join --kubeconfig ./tmp/kubeconfigs/submariner-cluster-2.kubeconfig broker-info.subm --clusterid submariner-cluster-2 --natt=false --check-broker-certificate=false