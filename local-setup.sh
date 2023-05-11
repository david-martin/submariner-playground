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

kindCreateCluster() {
  local cluster=$1;
  local port80=$2;
  local port443=$3;
  cat <<EOF | ${KIND} create cluster --name ${cluster} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.26.0
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: ${port80}
    protocol: TCP
  - containerPort: 443
    hostPort: ${port443}
    protocol: TCP
EOF
mkdir -p ./tmp/kubeconfigs
${KIND} get kubeconfig --name ${cluster} > ./tmp/kubeconfigs/${cluster}.kubeconfig
${KIND} export kubeconfig --name ${cluster} --kubeconfig ./tmp/kubeconfigs/internal/${cluster}.kubeconfig --internal
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
  kindCreateCluster ${KIND_CLUSTER_PREFIX}${i} $((${port80} + ${i} - 1)) $((${port443} + ${i} - 1))
  deployIstio ${KIND_CLUSTER_PREFIX}${i}
  installGatewayAPI ${KIND_CLUSTER_PREFIX}${i}
  deployMetalLB ${KIND_CLUSTER_PREFIX}${i} $((${metalLBSubnetStart} + ${i} - 1))
  deployIngressController ${KIND_CLUSTER_PREFIX}${i}

  # OCM Hub goes on first cluster
  if [[ "$i" -eq 1 ]]
  then
    ocmInitHub ${KIND_CLUSTER_PREFIX}${i}
  fi
  # Register all clusters, even the hub cluster, with the OCM Hub
  ocmAddCluster ${KIND_CLUSTER_PREFIX}1 ${KIND_CLUSTER_PREFIX}${i}
done;
