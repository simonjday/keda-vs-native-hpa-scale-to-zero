#!/usr/bin/env bash
# =============================================================================
# add-grafana.sh — Add Grafana to already-running lab clusters
#
# Run this if your clusters were created before Grafana was added to cluster.sh.
# Safe to run multiple times (helm upgrade --install is idempotent).
#
# Usage: ./add-grafana.sh [native|keda|both]  (default: both)
# =============================================================================
set -euo pipefail

TARGET="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

upgrade_grafana() {
  local ctx="$1"
  local grafana_port="$2"

  info "[$ctx] Upgrading kube-prometheus-stack to enable Grafana…"

  helm upgrade prometheus prometheus-community/kube-prometheus-stack \
    --kube-context "$ctx" \
    --namespace monitoring \
    --reuse-values \
    --set grafana.enabled=true \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort="${grafana_port}" \
    --set grafana.adminPassword=admin \
    --set grafana.defaultDashboardsTimezone=browser \
    --set grafana.sidecar.dashboards.enabled=true \
    --wait --timeout 5m

  info "[$ctx] Applying scale-to-zero dashboard…"
  kubectl --context "$ctx" apply \
    -f "${LAB_DIR}/manifests/grafana/dashboard-configmap.yaml"

  success "[$ctx] Grafana ready at http://localhost:${grafana_port}  (admin / admin)"
  echo "         Dashboards → Scale-to-Zero Lab"
}

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

[[ "$TARGET" == "native" || "$TARGET" == "both" ]] && \
  upgrade_grafana "kind-native-hpa-lab" 30081

[[ "$TARGET" == "keda" || "$TARGET" == "both" ]] && \
  upgrade_grafana "kind-keda-lab" 30082

echo
success "Done. Both clusters now have Grafana."
echo "  native-hpa-lab Grafana: http://localhost:30081"
echo "  keda-lab Grafana:       http://localhost:30082"
echo "  Login: admin / admin"
