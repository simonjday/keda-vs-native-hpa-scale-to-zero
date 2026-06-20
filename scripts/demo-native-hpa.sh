#!/usr/bin/env bash
# =============================================================================
# demo-native-hpa.sh — Native HPA scale-to-zero demo walkthrough
#
# Cluster:  kind-native-hpa-lab
# Stack:    Prometheus + Prometheus Adapter (no KEDA)
#
# Chain:
#   fake-metrics pod → /metrics (queue_depth_total gauge)
#   Prometheus scrapes every 15s
#   Prometheus Adapter translates PromQL → external.metrics.k8s.io
#   autoscaling/v2 HPA (minReplicas:0) reads external metric
#   ScaledToZero condition (KEP-2021) tracks intentional-zero vs manual-zero
#
# Verified behaviour (from actual lab run):
#   Scale-to-zero:  10→5→0 stepped (scaleDown policy 10 pods/15s) in ~30s
#   Wake-from-zero: 0→1 in ~30s (Prometheus scrape lag + pod startup)
#   ScaledToZero=True written immediately when HPA drives to 0
#   ScaledToZero=False (NotScaledToZero) as soon as metric > 0 and HPA acts
#
# Prerequisites: ./cluster.sh up native
# =============================================================================
set -euo pipefail

CLUSTER="kind-native-hpa-lab"
NS="demo-native"
WORKLOAD="worker-app"
LOCAL_PF_PORT=18081
PF_PID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

header()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }
step()    { echo -e "${CYAN}▸${NC} $*"; }
info()    { echo -e "  ${GREEN}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
pause()   { echo -e "\n${YELLOW}[Press ENTER to continue]${NC}"; read -r; }

# ── Port-forward to fake-metrics /set endpoint ────────────────────────────────
# kubectl exec + wget inside the pod has IPv6 binding issues on macOS.
# Port-forward with --address 127.0.0.1 is explicit and reliable.
start_port_forward() {
  local pod
  pod=$(kubectl --context "$CLUSTER" get pod -n "$NS" -l app=fake-metrics \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "$pod" ]] && { warn "fake-metrics pod not found"; return 1; }
  stop_port_forward 2>/dev/null || true
  kubectl --context "$CLUSTER" port-forward \
    -n "$NS" "pod/${pod}" "${LOCAL_PF_PORT}:8080" \
    --address 127.0.0.1 &>/dev/null &
  PF_PID=$!
  local i=0
  until curl -sf "http://127.0.0.1:${LOCAL_PF_PORT}/health" &>/dev/null; do
    sleep 0.5; i=$((i+1))
    [[ $i -gt 20 ]] && { warn "Port-forward timed out"; return 1; }
  done
  info "Port-forward ready: 127.0.0.1:${LOCAL_PF_PORT} → ${pod}:8080"
}

stop_port_forward() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null && PF_PID=""
  lsof -ti "tcp:${LOCAL_PF_PORT}" 2>/dev/null | xargs kill -9 2>/dev/null || true
}

trap stop_port_forward EXIT INT TERM

inject_queue_depth() {
  local value="$1"
  step "Setting queue_depth_total = ${value}"
  curl -sf "http://127.0.0.1:${LOCAL_PF_PORT}/health" &>/dev/null || start_port_forward
  curl -sf "http://127.0.0.1:${LOCAL_PF_PORT}/set?queue_depth=${value}" >/dev/null
  info "Queue depth set to ${value}. Prometheus will scrape within ~15s."
}

show_hpa() {
  kubectl --context "$CLUSTER" get hpa "${WORKLOAD}-hpa" -n "$NS" -o wide 2>/dev/null || true
}

show_hpa_conditions() {
  kubectl --context "$CLUSTER" get hpa "${WORKLOAD}-hpa" -n "$NS" \
    -o jsonpath='{.status.conditions}' 2>/dev/null \
    | python3 -m json.tool 2>/dev/null \
    | grep -A3 "ScaledToZero\|AbleToScale\|ScalingActive" || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────
header "DEMO: Native HPA Scale-to-Zero (K8s 1.36 / HPAScaleToZero=true)"

kubectl --context "$CLUSTER" cluster-info &>/dev/null || {
  echo "Cluster '$CLUSTER' not reachable. Run: ./cluster.sh up native"
  exit 1
}

# Verify external metrics API is available — common failure point
if ! kubectl --context "$CLUSTER" get apiservice \
    v1beta1.external.metrics.k8s.io &>/dev/null; then
  warn "v1beta1.external.metrics.k8s.io APIService not found."
  warn "Prometheus Adapter may not have registered the external metrics API."
  warn "Run: helm upgrade prometheus-adapter ... --values /tmp/adapter-values.yaml"
  warn "See docs/technical-deep-dive.md § Troubleshooting"
  exit 1
fi

step "Opening port-forward to fake-metrics (127.0.0.1:${LOCAL_PF_PORT})…"
start_port_forward

echo
echo "This demo exercises the native Kubernetes HPA using:"
echo "  • HPAScaleToZero feature gate (beta/default in 1.36)"
echo "  • External metric via Prometheus Adapter → external.metrics.k8s.io"
echo "  • ScaledToZero condition (KEP-2021) — distinguishes intentional zero"
echo "    from manually-zeroed deployments"
echo "  • minReplicas: 0 in autoscaling/v2 HPA spec"
echo
echo "Key constraint: CPU/memory metrics CANNOT drive scale-from-zero."
echo "The HPA needs a metric source that exists even at 0 replicas."
echo "Prometheus Adapter bridges PromQL → external.metrics.k8s.io to provide this."
echo
echo "Grafana: http://localhost:30081  (admin / admin)"
echo "         Dashboards → Scale-to-Zero Lab"
pause

# ── Step 1: Initial state ─────────────────────────────────────────────────────
header "STEP 1 — Initial state"

step "Deployment:"
kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" -o wide
echo
step "HPA (expect actual value in TARGETS, not <unknown>):"
show_hpa
echo
step "HPA conditions (ScaledToZero=False, ScalingActive=True):"
show_hpa_conditions
echo
step "External metric value via Prometheus Adapter:"
kubectl --context "$CLUSTER" get --raw \
  "/apis/external.metrics.k8s.io/v1beta1/namespaces/${NS}/queue_depth_external" \
  2>/dev/null | python3 -m json.tool 2>/dev/null \
  || warn "Metric not yet registered — wait 30s and retry"
echo
step "APIService owner (confirms no KEDA in this cluster):"
kubectl --context "$CLUSTER" get apiservice v1beta1.external.metrics.k8s.io \
  -o jsonpath='  owner: {.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}' 2>/dev/null
pause

# ── Step 2: Drain queue → scale to zero ──────────────────────────────────────
header "STEP 2 — Drain the queue (scale to zero)"

inject_queue_depth 0
echo
info "HPA stabilizationWindowSeconds=30 (demo). Production default: 300s."
info "scaleDown policy: max 10 pods per 15s → stepped descent (observed: 10→5→0)."
info "HPA controller loop: 15s. Expected time to zero: ~30-45s."
echo
step "Watching scale-down:"
echo

for i in $(seq 1 24); do
  replicas=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
  hpa_line=$(kubectl --context "$CLUSTER" get hpa "${WORKLOAD}-hpa" -n "$NS" \
    --no-headers 2>/dev/null | awk '{print $4, $5, $6}' || echo "n/a")
  printf "  [%3ds] replicas=%-3s  HPA(current/min/max)=%s\n" \
    $((i*5)) "${replicas:-0}" "$hpa_line"
  if [[ "${replicas:-1}" == "0" ]]; then
    echo
    success "Scaled to ZERO"
    break
  fi
  sleep 5
done

echo
step "HPA conditions (ScaledToZero=True confirms HPA drove the scale-down):"
show_hpa_conditions
echo
info "ScaledToZero=True is the KEP-2021 condition. It means:"
info "  • The HPA intentionally scaled this to 0 (not an operator/manual action)"
info "  • The HPA will wake this deployment when metric > 0"
info "  • A manually-zeroed deployment has no ScaledToZero condition — HPA ignores it"
pause

# ── Step 3: Re-inject load → wake from zero ───────────────────────────────────
header "STEP 3 — Re-inject load (wake from zero)"

inject_queue_depth 50
echo
info "HPA sees metric > 0 + ScaledToZero=True → scales 0→1 immediately."
info "No stabilization window on scale-up (stabilizationWindowSeconds=0)."
info "scaleUp policy: max 5 pods per 15s. At queue=50, target=20 → ceil(1×50/20)=3 pods."
echo
info "Watching wake-up (expect ~15-30s to first ready pod):"
echo

for i in $(seq 1 18); do
  ready=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  desired=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  printf "  [%3ds] ready=%-3s desired=%s\n" $((i*5)) "${ready:-0}" "${desired:-0}"
  if [[ "${ready:-0}" -ge 1 ]]; then
    echo
    success "Woken from zero — first pod ready in ~$((i*5))s"
    break
  fi
  sleep 5
done

echo
step "Final HPA state:"
show_hpa
echo
step "Final conditions (ScaledToZero=False, reason=NotScaledToZero):"
show_hpa_conditions

# ── Summary ───────────────────────────────────────────────────────────────────
header "DEMO COMPLETE — Native HPA Scale-to-Zero"

cat <<'EOF'
Observed behaviour:
  Scale-down: stepped 10→5→0 (scaleDown policy: 10 pods/15s, window=30s)
  Scale-up:   0→1 in ~30s (Prometheus scrape interval + pod startup)
  ScaledToZero condition: True when HPA drives to 0, False when metric > 0

Key constraints:
  1. minReplicas: 0 only works with External or Object metric types
  2. Prometheus Adapter required — HPA cannot query Prometheus directly
  3. Adapter owns external.metrics.k8s.io — cannot coexist with KEDA
  4. No traffic buffering on cold-start — first request dropped
  5. ScaledToZero (KEP-2021) prevents accidental wake of manually-zeroed workloads

EOF
echo "Compare:   ./scripts/demo-keda.sh"
echo "Benchmark: ./scripts/benchmark.sh 3 50"
echo "Grafana:   http://localhost:30081  (admin / admin)"
