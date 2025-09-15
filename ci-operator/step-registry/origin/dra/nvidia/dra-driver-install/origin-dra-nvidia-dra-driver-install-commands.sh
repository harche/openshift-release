#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

function log() {
  echo "[$(date --iso-8601=seconds)] $*"
}

TMPDIR=$(mktemp -d)
function cleanup() {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${SHARED_DIR:-}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  else
    log "KUBECONFIG is not set and ${SHARED_DIR:-}/kubeconfig not found"
    exit 1
  fi
fi

HELM_VERSION="${ORIGIN_DRA_HELM_VERSION:-v3.15.4}"
HELM_TARBALL="helm-${HELM_VERSION}-linux-amd64.tar.gz"
HELM_URL="https://get.helm.sh/${HELM_TARBALL}"
HELM_ARCHIVE="${TMPDIR}/${HELM_TARBALL}"

log "Downloading helm ${HELM_VERSION}"
curl -fsSL "${HELM_URL}" -o "${HELM_ARCHIVE}"
curl -fsSL "${HELM_URL}.sha256" -o "${HELM_ARCHIVE}.sha256"
if [[ -s "${HELM_ARCHIVE}.sha256" ]]; then
  sha_value=$(cut -d' ' -f1 "${HELM_ARCHIVE}.sha256")
  echo "${sha_value}  ${HELM_ARCHIVE}" | sha256sum --check --status
else
  log "warning: unable to verify helm checksum"
fi
tar -xzf "${HELM_ARCHIVE}" -C "${TMPDIR}"
export PATH="${TMPDIR}/linux-amd64:${PATH}"

NAMESPACE="${ORIGIN_DRA_DRIVER_NAMESPACE:-nvidia-dra-driver-gpu}"
RELEASE_NAME="${ORIGIN_DRA_DRIVER_RELEASE_NAME:-nvidia-dra-driver-gpu}"
CHART_URL="${ORIGIN_DRA_DRIVER_CHART_URL:-https://helm.ngc.nvidia.com/nvidia/charts/nvidia-dra-driver-gpu-25.3.1.tgz}"
CHART_VERSION="${ORIGIN_DRA_DRIVER_CHART_VERSION:-25.3.1}"
VALUES_FILE="${TMPDIR}/values.yaml"

cat > "${VALUES_FILE}" <<'VALUES'
nvidiaDriverRoot: /run/nvidia/driver
gpuResourcesEnabledOverride: true
controller:
  tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/master
            operator: Exists
VALUES

log "Ensuring namespace ${NAMESPACE} exists"
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"
oc label namespace "${NAMESPACE}" "pod-security.kubernetes.io/enforce=privileged" --overwrite

log "Installing NVIDIA DRA driver chart"
helm upgrade --install "${RELEASE_NAME}" "${CHART_URL}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait=false

log "Granting privileged SCC to the default service account"
oc adm policy add-scc-to-user privileged -z default -n "${NAMESPACE}" || true

function wait_for_daemonset() {
  local name=$1
  if oc get daemonset "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log "Waiting for daemonset ${name}"
    oc rollout status daemonset/"${name}" -n "${NAMESPACE}" --timeout=20m
  else
    log "Daemonset ${name} not found, skipping wait"
  fi
}

function wait_for_deployment() {
  local name=$1
  if oc get deployment "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log "Waiting for deployment ${name}"
    oc rollout status deployment/"${name}" -n "${NAMESPACE}" --timeout=20m
  else
    log "Deployment ${name} not found, skipping wait"
  fi
}

wait_for_daemonset "${RELEASE_NAME}-kubelet-plugin"
wait_for_deployment "${RELEASE_NAME}-controller"

log "NVIDIA DRA driver installation completed"
