#!/usr/bin/env bash
# =============================================================================
# demo-keda.sh — KEDA scale-to-zero demo walkthrough
#
# Cluster:  kind-keda-lab
# Stack:    Prometheus + KEDA 2.16 (no Prometheus Adapter)
#
# Chain:
#   fake-metrics pod → /metrics (queue_depth_total gauge)
#   Prometheus scrapes every 15s
#   KEDA operator polls Prometheus directly via PromQL (pollingInterval=15s)
#   ScaledObject drives two-phase scaling:
#     Phase 1 (KEDA operator):  0 ↔ 1  via activationThreshold
#     Phase 2 (KEDA-managed HPA): 1 ↔ N  via threshold
#
# Verified behaviour (from actual lab run):
#   Scale-to-zero:  Active=False at ~15s, replicas=0 at ~30s (cooldownPeriod)
#   Wake from zero: Active=True at ~20s, desired=1 → desired=5 at ~30s, ready=5 at ~40s
#   Two-phase visible: KEDA patches replicas before HPA calculates scale-out
#   Partial drain:  queue=20 → HPA stabilises at 1 pod, Active stays True
#
# Prerequisites: ./cluster.sh up keda
# =============================================================================
set -euo pipefail

CLUSTER="kind-keda-lab"
NS="demo-keda"
WORKLOAD="worker-app-keda"
SO="${WORKLOAD}-so"
LOCAL_PF_PORT=18080
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
# Uses 127.0.0.1 explicitly to avoid macOS IPv6 binding issues.
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
  info "Port-forward ready: localhost:${LOCAL_PF_PORT} → ${pod}:8080"
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
  info "Queue depth set to ${value}"
}

show_state() {
  echo
  step "ScaledObject:"
  kubectl --context "$CLUSTER" get scaledobject -n "$NS" -o wide 2>/dev/null || true
  echo
  step "KEDA-managed HPA (do not edit directly):"
  kubectl --context "$CLUSTER" get hpa -n "$NS" -o wide 2>/dev/null || true
  echo
  step "Deployment:"
  kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='  {.metadata.name}: ready={.status.readyReplicas} desired={.status.replicas}{"\n"}' \
    2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────
header "DEMO: KEDA Scale-to-Zero (KEDA 2.16, kind-keda-lab)"

kubectl --context "$CLUSTER" cluster-info &>/dev/null || {
  echo "Cluster '$CLUSTER' not reachable. Run: ./cluster.sh up keda"
  exit 1
}

kubectl --context "$CLUSTER" get pod -n "$NS" -l app=fake-metrics \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running || {
  warn "fake-metrics pod not Running"
  kubectl --context "$CLUSTER" get pods -n "$NS"
  exit 1
}

step "Opening port-forward to fake-metrics (127.0.0.1:${LOCAL_PF_PORT})…"
start_port_forward

echo
echo "KEDA's two-phase scaling model:"
echo
echo "  Phase 1 — Activation (KEDA operator owns 0 ↔ 1):"
echo "    • Polls Prometheus every pollingInterval=15s"
echo "    • metric ≤ activationThreshold=1 → Active=False → scale to 0"
echo "    • metric > activationThreshold=1 → Active=True → scale to 1"
echo "    • cooldownPeriod=30s before acting on inactivity"
echo
echo "  Phase 2 — Scaling (KEDA-managed HPA owns 1 ↔ N):"
echo "    • Standard HPA formula: ceil(replicas × metric / threshold)"
echo "    • threshold=20 → 1 pod per 20 queue items"
echo "    • HPA name: keda-hpa-${SO} (do not edit directly)"
echo
echo "Key difference from native HPA:"
echo "  • No Prometheus Adapter — raw PromQL in ScaledObject trigger"
echo "  • activationThreshold separates 'should I exist?' from 'how many?'"
echo "  • KEDA patches replicas directly for 0↔1; HPA handles 1↔N"
echo "  • APIService owner is KEDA, not prometheus-adapter"
echo
echo "Grafana: http://localhost:30082  (admin / admin)"
echo "         Dashboards → Scale-to-Zero Lab"
pause

# ── Step 1: Inspect object model ──────────────────────────────────────────────
header "STEP 1 — ScaledObject and auto-generated HPA"

step "ScaledObject spec (raw PromQL inline — no adapter config needed):"
kubectl --context "$CLUSTER" get scaledobject "$SO" -n "$NS" -o yaml 2>/dev/null \
  | grep -A 40 "^spec:" | head -45 \
  || { warn "ScaledObject not found"; exit 1; }
echo
step "KEDA auto-created HPA:"
kubectl --context "$CLUSTER" get hpa -n "$NS" -o wide 2>/dev/null || true
echo
step "APIService owner (should be 'keda', not 'prometheus-adapter'):"
kubectl --context "$CLUSTER" get apiservice v1beta1.external.metrics.k8s.io \
  -o jsonpath='  owner: {.metadata.annotations.meta\.helm\.sh/release-name}{"\n"}' 2>/dev/null || true
pause

# ── Step 2: Drain queue → scale to zero ──────────────────────────────────────
header "STEP 2 — Drain the queue (activation phase → zero)"

inject_queue_depth 0
echo
info "KEDA polls Prometheus every 15s."
info "metric (0) ≤ activationThreshold (1) → Active=False after next poll."
info "cooldownPeriod=30s → replicas patched to 0, HPA paused."
info "Observed: Active=False at ~15s, replicas=0 at ~30s."
echo
step "Watching scale-down:"
echo

for i in $(seq 1 24); do
  replicas=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
  active=$(kubectl --context "$CLUSTER" get scaledobject "$SO" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "?")
  printf "  [%3ds] replicas=%-3s  ScaledObject.Active=%s\n" \
    $((i*5)) "${replicas:-0}" "$active"
  if [[ "${replicas:-1}" == "0" ]]; then
    echo
    success "Scaled to ZERO"
    break
  fi
  sleep 5
done

echo
step "ScaledObject conditions:"
kubectl --context "$CLUSTER" get scaledobject "$SO" -n "$NS" \
  -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
pause

# ── Step 3: Inject 100 → two-phase wake-up ───────────────────────────────────
header "STEP 3 — Inject load=100 (two-phase wake-up)"

inject_queue_depth 100
echo
info "Phase 1 (KEDA): metric (100) > activationThreshold (1)"
info "  → KEDA patches replicas=1, re-enables HPA"
info "Phase 2 (HPA):  ceil(1 × 100/20) = 5 pods desired"
info "Observed: Active=True at ~20s, desired=5 at ~30s, ready=5 at ~40s"
echo
step "Watching two-phase scale-up:"
echo

for i in $(seq 1 24); do
  ready=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  desired=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  active=$(kubectl --context "$CLUSTER" get scaledobject "$SO" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "?")
  printf "  [%3ds] ready=%-3s desired=%-3s  Active=%s\n" \
    $((i*5)) "${ready:-0}" "${desired:-0}" "$active"
  if [[ "${ready:-0}" -ge 5 ]]; then
    echo
    success "5 pods ready (queue=100, threshold=20/pod)"
    break
  fi
  sleep 5
done

echo
step "Final state:"
show_state
pause

# ── Step 4: Partial drain ─────────────────────────────────────────────────────
header "STEP 4 — Partial drain (queue=20, observe HPA-only scale-down)"

inject_queue_depth 20
echo
info "queue=20, threshold=20/pod → HPA: ceil(5 × 20/20) = 1 pod"
info "activationThreshold=1 → still Active (metric > 0)"
info "KEDA stays out of it — HPA handles 5→1. Observed in ~60s."
echo
info "Waiting 60s for stabilization…"
sleep 60

step "State after 60s:"
show_state
pause

# ── Step 5: Scale to zero from 1 pod ─────────────────────────────────────────
header "STEP 5 — Scale to zero from single pod"

inject_queue_depth 0
echo
info "cooldownPeriod=30s from single pod. Observed: replicas=0 at ~35s."
echo

for i in $(seq 1 18); do
  replicas=$(kubectl --context "$CLUSTER" get deployment "$WORKLOAD" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
  printf "  [%3ds] replicas=%s\n" $((i*5)) "${replicas:-0}"
  [[ "${replicas:-1}" == "0" ]] && { echo; success "Back to zero"; break; }
  sleep 5
done
pause

# ── Summary ───────────────────────────────────────────────────────────────────
header "DEMO COMPLETE — KEDA Scale-to-Zero"

cat <<'EOF'
Observed behaviour:
  Scale-to-zero:   Active=False ~15s, replicas=0 ~30s (cooldownPeriod)
  Wake from zero:  Active=True ~20s, desired=5 ~30s, ready=5 ~40s
  Two-phase split: KEDA patches 0→1 before HPA calculates 1→5
  Partial drain:   HPA handles N→1 independently; KEDA stays Active

Key advantages over native HPA:
  • No Prometheus Adapter — raw PromQL directly in ScaledObject
  • activationThreshold buffers trickle traffic (no 0/1 flapping)
  • 60+ built-in scalers (Kafka, SQS, Redis, HTTP, cron...)
  • HTTP add-on can buffer requests during cold-start
  • No feature gate dependency (works on any K8s version)

EOF
echo "Compare:   ./scripts/demo-native-hpa.sh"
echo "Benchmark: ./scripts/benchmark.sh 3 50"
echo "Grafana:   http://localhost:30082  (admin / admin)"
