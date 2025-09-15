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
  # the sha file contains the filename without the path
  sha_value=$(cut -d' ' -f1 "${HELM_ARCHIVE}.sha256")
  echo "${sha_value}  ${HELM_ARCHIVE}" | sha256sum --check --status
else
  log "warning: unable to verify helm checksum"
fi
tar -xzf "${HELM_ARCHIVE}" -C "${TMPDIR}"
export PATH="${TMPDIR}/linux-amd64:${PATH}"

NAMESPACE="${ORIGIN_DRA_NFD_NAMESPACE:-node-feature-discovery}"
RELEASE_NAME="${ORIGIN_DRA_NFD_RELEASE_NAME:-node-feature-discovery}"
CHART_URL="${ORIGIN_DRA_NFD_CHART_URL:-https://github.com/kubernetes-sigs/node-feature-discovery/releases/download/v0.17.3/node-feature-discovery-chart-0.17.3.tgz}"
CHART_VERSION="${ORIGIN_DRA_NFD_CHART_VERSION:-v0.17.3}"
VALUES_FILE="${TMPDIR}/values.yaml"

cat > "${VALUES_FILE}" <<'VALUES'
worker:
  createCRDs: true
  config:
    sources:
      pci:
        deviceLabelFields:
        - vendor
      custom:
      - name: nvidia-gpu-testing
        labels:
          nvidia.com: "true"
        matchFeatures:
        - feature: pci.device
          matchExpressions:
            class:
              op: In
              value:
              - "0302"
            vendor:
              op: In
              value:
              - "10de"
VALUES

log "Ensuring namespace ${NAMESPACE} exists"
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"
oc label namespace "${NAMESPACE}" "pod-security.kubernetes.io/enforce=privileged" --overwrite

log "Installing Node Feature Discovery chart"
helm upgrade --install "${RELEASE_NAME}" "${CHART_URL}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  --values "${VALUES_FILE}" \
  --wait=false

log "Granting privileged SCC to the worker service account"
oc adm policy add-scc-to-user privileged -z "${RELEASE_NAME}-worker" -n "${NAMESPACE}" || true

log "Waiting for NFD worker daemonset to become available"
oc rollout status daemonset/"${RELEASE_NAME}-worker" -n "${NAMESPACE}" --timeout=10m

log "Waiting for NFD master deployment to become available"
oc rollout status deployment/"${RELEASE_NAME}-master" -n "${NAMESPACE}" --timeout=10m || true

log "NFD installation completed"
