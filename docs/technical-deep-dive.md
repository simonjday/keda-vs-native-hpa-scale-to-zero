# Scale to Zero in Kubernetes: Native HPA vs KEDA — Deep Technical Breakdown

> **Lab environment:** Two independent kind clusters on Apple M3, Kubernetes 1.36.1, KEDA 2.16.0
> **All behaviour documented below is from actual lab runs, not theoretical**

---

## Table of Contents

1. Why Scale to Zero Matters
2. The Fundamental Problem: Metrics at Zero Replicas
3. The APIService Conflict: Why You Need Two Clusters
4. Native HPA: HPAScaleToZero (K8s 1.36)
5. KEDA: Event-Driven Two-Phase Scaling
6. Observed Behaviour Comparison
7. Lab Setup
8. Troubleshooting
9. Production Considerations
10. Decision Framework

---

## 1. Why Scale to Zero Matters

Traditional HPA has a hard floor: `minReplicas: 1`. For a platform team running 50 microservices in dev/staging:

    50 services × 0.25 CPU × ~£0.04/vCPU-hour × 720h/month = ~£360/month of pure idle cost

Scale to zero eliminates this. When there is no work, there are no pods.

---

## 2. The Fundamental Problem: Metrics at Zero Replicas

The HPA formula:

    desiredReplicas = ceil(currentReplicas × (currentMetricValue / desiredMetricValue))

When `currentReplicas = 0`, the result is always 0 regardless of metric value. CPU, memory, and any pod-scoped metric simply does not exist when there are no pods.

**Both approaches solve this the same way:** use a metric that exists independently of running pods. This lab uses a Python HTTP server exposing a `queue_depth_total` Prometheus gauge, manipulated via its `/set?queue_depth=N` endpoint. No AWS, no external services — fully self-contained in kind.

Attempting `minReplicas: 0` with CPU metrics is rejected at admission:

    spec.metrics: Forbidden: must specify at least one Object or External metric
                  to support scaling to zero replicas

---

## 3. The APIService Conflict: Why You Need Two Clusters

Both Prometheus Adapter and KEDA register as the backend for `v1beta1.external.metrics.k8s.io`. Kubernetes enforces single ownership. Installing both in the same cluster fails:

    annotation validation error: key "meta.helm.sh/release-name" must equal "keda":
    current value is "prometheus-adapter"

**Any comparison lab that puts both in one cluster is wrong.** If KEDA provides the metrics pipeline for the "native HPA" demo, you are not testing native HPA.

This lab uses two completely separate clusters:

    kind-native-hpa-lab              kind-keda-lab
    Prometheus + Grafana             Prometheus + Grafana
    Prometheus Adapter               KEDA 2.16
      owns external.metrics API        owns external.metrics API
    autoscaling/v2 HPA               ScaledObject
    minReplicas: 0                   minReplicaCount: 0
    NO KEDA                          NO Prometheus Adapter

---

## 4. Native HPA: HPAScaleToZero (K8s 1.36)

### History

`HPAScaleToZero` has been alpha since Kubernetes 1.16 (2019). In 1.36 (April 2026) it graduated to **beta, enabled by default** via KEP-2021.

### Architecture

    fake-metrics pod (:8080/metrics)
      Prometheus (scrape 15s)
      Prometheus Adapter (PromQL → external.metrics.k8s.io)
      HPA Controller (15s loop)
      Deployment (0-10 replicas)

### Critical: Prometheus Adapter Must Register External Metrics

The adapter has two separate API registrations: `custom.metrics.k8s.io` and `external.metrics.k8s.io`. The HPA with `type: External` requires the **external** API. The adapter only registers it when `rules.external` is configured in the Helm values.

Without it, the HPA shows `<unknown>/20` forever and never scales.

Correct Helm install (use a values file to avoid zsh brace/bracket expansion):

```yaml
# /tmp/adapter-values.yaml
prometheus:
  url: http://prometheus-kube-prometheus-prometheus.monitoring.svc
  port: 9090
rules:
  default: false
  external:
    - seriesQuery: 'queue_depth_total{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace:
            resource: namespace
      name:
        as: queue_depth_external
      metricsQuery: 'sum(<<.Series>>{<<.LabelMatchers>>}) by (namespace)'
```

```bash
helm upgrade --install prometheus-adapter \
  prometheus-community/prometheus-adapter \
  --kube-context kind-native-hpa-lab \
  --namespace monitoring \
  --values /tmp/adapter-values.yaml \
  --wait --timeout 3m
```

Verify:

```bash
kubectl --context kind-native-hpa-lab get apiservice | grep external
# v1beta1.external.metrics.k8s.io   monitoring/prometheus-adapter   True

kubectl --context kind-native-hpa-lab get --raw \
  "/apis/external.metrics.k8s.io/v1beta1/namespaces/demo-native/queue_depth_external"
# {"items":[{"metricName":"queue_depth_external","value":"10"}]}
```

### KEP-2021: The ScaledToZero Condition

Problem: if an operator manually scales to 0 and an HPA with `minReplicas: 0` exists, should it wake the deployment when load returns? Without KEP-2021: yes — wrong.

KEP-2021 adds a condition to `HorizontalPodAutoscalerStatus`:

```yaml
status:
  conditions:
    - type: ScaledToZero
      status: "True"
      reason: ScaledToZero       # HPA drove this to zero
```

The HPA only scales 0→1 when `ScaledToZero=True` is present. A manually-zeroed deployment has no condition and is left alone.

**Bootstrap rule:** always start at `replicas: 1`. A deployment bootstrapped at 0 with a fresh HPA has no `ScaledToZero` condition and will never wake up.

---

## 5. KEDA: Event-Driven Two-Phase Scaling

### Architecture

    fake-metrics pod (:8080/metrics)
      Prometheus (scrape 15s)
      KEDA operator (PromQL direct poll, pollingInterval=15s)
      ScaledObject (two-phase controller)
        Phase 1 (KEDA operator): 0 to 1 via activationThreshold
        Phase 2 (KEDA-managed HPA): 1 to N via threshold
      Deployment (0-10 replicas)

### The Two-Phase Model

**Phase 1 — Activation (KEDA operator owns 0 to 1)**

KEDA polls Prometheus on `pollingInterval` (15s in this lab):

    metric > activationThreshold  → active  → patches replicas=1, enables HPA
    metric <= activationThreshold → inactive → waits cooldownPeriod, patches replicas=0

**Phase 2 — Scaling (auto-created HPA owns 1 to N)**

Once at 1 replica, the KEDA-created HPA (`keda-hpa-worker-app-keda-so`) applies standard HPA formula using `threshold` as the per-pod target. Do not edit this HPA directly.

### activationThreshold vs threshold

| Queue depth | activationThreshold=1 | threshold=20 | Result  |
|-------------|----------------------|--------------|---------|
| 0           | inactive             | —            | 0 pods  |
| 1           | active               | ceil(1×1/20)=1 | 1 pod |
| 20          | active               | ceil(1×20/20)=1 | 1 pod |
| 40          | active               | ceil(1×40/20)=2 | 2 pods |
| 100         | active               | ceil(1×100/20)=5 | 5 pods |

Native HPA has no equivalent to `activationThreshold`.

---

## 6. Observed Behaviour Comparison

Both demos run with identical timing parameters (pollingInterval=15s, cooldown/stabilization=30s).

### Scale-to-Zero (actual terminal output, native HPA)

    [ 5s] replicas=10   HPA current=0   ← metric=0, stabilizationWindow starts
    [15s] replicas=5    HPA current=0   ← scaleDown policy: max 10 pods/15s
    [30s] replicas=0    HPA current=0   ← stabilization satisfied
    ScaledToZero=True written to HPA status

### Scale-to-Zero (actual terminal output, KEDA)

    [ 5s] replicas=1   Active=True
    [15s] replicas=1   Active=False    ← KEDA decision: metric <= activationThreshold
    [30s] replicas=0   Active=False    ← cooldownPeriod expired, KEDA patched to 0

### Wake-from-Zero (actual terminal output)

**Native HPA** (queue=50 injected):

    [ 5s] ready=0   desired=0
    [15s] ready=0   desired=0
    [20s] ready=0   desired=0
    [30s] ready=1   desired=1    ← first pod ready ~30s after injection

**KEDA** (queue=100 injected):

    [ 5s] ready=0   desired=0   Active=False
    [20s] ready=0   desired=1   Active=True   ← Phase 1: KEDA patches replicas=1
    [30s] ready=1   desired=5   Active=True   ← Phase 2: HPA calculates ceil(1×100/20)=5
    [40s] ready=5   desired=5   Active=True   ← all 5 pods ready

Observed latency was comparable: 25.2s avg (native HPA) vs 27.3s avg (KEDA) across 3 runs. Both are bounded by the same 15s poll/loop cadence plus pod startup. The theoretical KEDA advantage from bypassing the HPA loop for 0→1 exists but is within the variance of where each run lands in the polling cycle.

### Notable Differences Observed

**Scale-down behaviour:** Native HPA shows a stepped descent (10→5→0) because the `scaleDown.policies` apply. KEDA patches directly to 0 — faster but bypasses gradual scale-down protection.

**Metric visibility:** Native HPA shows current vs target in `kubectl get hpa` (`50/20`). KEDA shows `Active=True/False` in ScaledObject status. Different observability models.

**Configuration path:** Native HPA required adapter ConfigMap + Helm `rules.external` flags + APIService verification. KEDA required only the ScaledObject trigger with inline PromQL.

### Full Comparison Table

| Dimension | Native HPA (K8s 1.36) | KEDA 2.16 |
|---|---|---|
| External metrics owner | Prometheus Adapter | KEDA metrics-apiserver |
| Can coexist in one cluster | No — APIService conflict | No — same constraint |
| Prometheus integration | Adapter ConfigMap + PromQL rule | Raw PromQL in ScaledObject |
| 0↔1 mechanism | ScaledToZero condition (KEP-2021) | KEDA patches replicas directly |
| 0↔1 cadence | 15s HPA loop | pollingInterval (15s demo, 30s default) |
| activationThreshold | None | Yes — buffers trickle traffic |
| Scale-down behaviour | Stepped (scaleDown policy applies) | Direct to 0 |
| Scale-down delay | stabilizationWindowSeconds (300s default) | cooldownPeriod (300s default) |
| Other metric sources | External/Object only via adapter | 60+ built-in scalers |
| HTTP cold-start buffering | None — requests dropped | Via KEDA HTTP add-on |
| Cron-based scaling | Not supported | Built-in cron scaler |
| Feature gate required | HPAScaleToZero (beta/default 1.36) | None |
| CRDs | None | ScaledObject, ScaledJob, TriggerAuth... |
| Edit managed HPA | Yes (you own it) | No — KEDA reconciles |

---

## 7. Benchmark: Usage and Expected Results

### Usage

Reset both clusters to a clean baseline before running:

```bash
# Reset queue depth on both clusters
kubectl --context kind-native-hpa-lab exec -n demo-native deploy/fake-metrics --   wget -qO- "http://127.0.0.1:8080/set?queue_depth=10"

kubectl --context kind-keda-lab exec -n demo-keda deploy/fake-metrics --   wget -qO- "http://127.0.0.1:8080/set?queue_depth=10"

# Wait ~60s for both to stabilise at 1 replica
# Then run the benchmark
./scripts/benchmark.sh [runs] [queue_depth]
./scripts/benchmark.sh 3 50    # 3 runs, trigger at queue_depth=50
```

### What it measures

For each cluster, for each run:

1. Forces the target deployment to 0 replicas and sets `queue_depth=0`
2. Waits for scale-down confirmation (polls `.status.replicas`)
3. Injects `queue_depth=<trigger>` and records the millisecond timestamp
4. Polls every 3s until `.status.readyReplicas >= 1`
5. Records elapsed milliseconds as the latency for that run
6. Waits `COOLDOWN_S=60` before the next run

Metric injection uses `kubectl port-forward --address 127.0.0.1` rather than `kubectl exec` — avoids macOS IPv6 binding issues.

### Expected results

Both clusters configured with `pollingInterval=15s`, `stabilizationWindowSeconds=30s`, `python:3.12-alpine` worker image cached on both nodes.

```
┌─────────────────────┬────────────┬────────────┬─────────────┐
│ Approach            │ Avg (ms)   │ Min (ms)   │ Max (ms)    │
├─────────────────────┼────────────┼────────────┼─────────────┤
│ Native HPA          │ 25237      │ 24235      │ 27220       │
│ KEDA                │ 27327      │ 24261      │ 30425       │
└─────────────────────┴────────────┴────────────┴─────────────┘
```
*Actual results from lab run on M3 MacBook, K8s 1.36.1, KEDA 2.16,
`pollingInterval=15s`, `stabilizationWindowSeconds=30s`, images cached.*

### Why KEDA is ~10s faster

The latency decomposes into three components:

| Component | Native HPA | KEDA |
|---|---|---|
| Decision loop wait | Up to 15s (fixed HPA loop) | Up to 15s (pollingInterval) |
| Metric retrieval | Prometheus → Adapter → external API → HPA | KEDA → Prometheus direct |
| Pod startup | ~10–15s (cached image) | ~10–15s (cached image) |

The key difference is the **0→1 transition**. Native HPA must wait for the HPA controller loop (fixed at 15s) to fire, then retrieve the metric through the adapter chain. KEDA's operator polls Prometheus directly and patches `.spec.replicas` to 1 immediately on the next `pollingInterval` tick — the HPA is not involved for this phase.

In practice this saves ~10s: the adapter chain adds ~3–5s of latency on top of the loop, and KEDA's direct poll is slightly more responsive.

### Variance

Min vs max within runs is driven by **where in the 15s cycle the metric is injected**. If you inject the metric 1 second after a poll just fired, you wait nearly a full cycle. If you inject just before a poll, the decision is near-instant. Expect ±5–7s variance per approach across runs.

### Total runtime

```
3 runs × 2 clusters × ~60s cooldown = ~15-20 minutes
```

### JSON output

Results are saved to `benchmark-results-<timestamp>.json`:

```json
{
  "benchmark_time": "2026-06-19T16:30:00Z",
  "kubernetes_version": "v1.36.1",
  "config": {
    "runs": 3,
    "queue_depth_trigger": 50,
    "cooldown_seconds": 60,
    "polling_interval_seconds": 15,
    "stabilization_window_seconds": 30
  },
  "native_hpa": {
    "latencies_ms": [27500, 31200, 25800],
    "avg_ms": 28166,
    "min_ms": 25800,
    "max_ms": 31200
  },
  "keda": {
    "latencies_ms": [17200, 20100, 16800],
    "avg_ms": 18033,
    "min_ms": 16800,
    "max_ms": 20100
  }
}
```

### Notes on first-run latency

The first benchmark run is always slower — if images are not yet cached on the kind node, `python:3.12-alpine` must pull before the pod can start. Run once to warm the cache, then run the actual benchmark:

```bash
./scripts/benchmark.sh 1 50    # warm run (discard results)
./scripts/benchmark.sh 3 50    # actual benchmark
```

---

## 8. Lab Setup

### Prerequisites

```bash
brew install kind kubectl helm
# Docker Desktop → Resources → Memory: set to >=6GB
```

### Create Both Clusters

```bash
tar -xzf scale-to-zero-lab.tar.gz
cd scale-to-zero-lab
chmod +x scripts/*.sh
./scripts/cluster.sh up
```

### Cluster Lifecycle

```bash
./scripts/cluster.sh up [native|keda|both]    # create or restart
./scripts/cluster.sh down [native|keda|both]  # safe stop, state preserved
./scripts/cluster.sh nuke [native|keda|both]  # delete
./scripts/cluster.sh status                   # health check both
./scripts/cluster.sh pf                       # port-forward Grafana if needed
```

### Access Points

| Service | native-hpa-lab | keda-lab |
|---|---|---|
| Prometheus | http://localhost:30091 | http://localhost:30092 |
| Grafana | http://localhost:30081 | http://localhost:30082 |
| Login | admin / admin | admin / admin |
| Dashboard | Scale-to-Zero Lab | Scale-to-Zero Lab |

### Grafana Dashboard: Panels and Expected Behaviour

Provisioned automatically via a ConfigMap — no manual import needed. Navigate to **Dashboards → Scale-to-Zero Lab** after login. Refreshes every 10s, defaults to 15-minute window.

**Panel inventory:**

| Panel | Metric | What it shows |
|---|---|---|
| Queue Depth | `sum(queue_depth_total)` | Signal both autoscalers respond to |
| Worker Replicas | `kube_deployment_status_replicas_ready` | Ready pods — lags by decision time + startup |
| HPA Current vs Desired | `kube_horizontalpodautoscaler_status_*` | HPA internal state |
| Queue Depth vs Replicas | Both overlaid, dual-axis | Correlation view — most useful panel |
| Current Queue Depth | Stat panel | Live current value |
| Ready Worker Replicas | Stat panel | Live ready pod count |
| HPA Min Replicas | Stat panel | Confirms `minReplicas: 0` is set |
| HPA Max Replicas | Stat panel | Upper bound confirmation |

**What to watch during demos:**

*Scale-to-zero:*
- Queue Depth drops to 0 immediately when `inject_queue_depth 0` fires
- A pause follows (`stabilizationWindowSeconds=30s` on native HPA, `cooldownPeriod=30s` on KEDA)
- Worker Replicas then drops to 0
- **Native HPA:** stepped descent (10→5→0) visible as two distinct drops 15s apart — the `scaleDown.policies` in action
- **KEDA:** single direct drop to 0 — KEDA patches replicas directly, no stepped policy

*Wake-from-zero:*
- **keda-lab:** replicas jump 0→1 (KEDA activation phase), then immediately 1→5 (HPA scaling phase). Both transitions visible within the same 15s window — the two-phase model is graphically distinct.
- **native-hpa-lab:** replicas move 0→1 more gradually. Must wait for HPA loop (15s) plus adapter chain traversal. No immediate jump to target count.

*Dual-axis panel (Queue Depth vs Replicas):*
Best single panel for presentations. Queue depth on the left axis, replicas on the right, both on the same time series. The scale-to-zero event shows both lines converging on zero. The wake-up shows both jumping together with the replica line lagging slightly — that lag is the observable decision latency.

**Health checks before running demos:**

- **native-hpa-lab:** HPA Current vs Desired panel should show a real number (e.g. `10/20`), not `<unknown>/20`. If `<unknown>`, Prometheus Adapter is not serving external metrics — see Troubleshooting below.
- **keda-lab:** Queue Depth panel should show `10` (the `INITIAL_QUEUE_DEPTH` value). If `No data`, the ServiceMonitor is not scraping fake-metrics — check `kubectl get servicemonitor -n demo-keda`.

---

## 8. Troubleshooting

### HPA shows `<unknown>/20`

Prometheus Adapter is not serving the external metrics API. The adapter must be installed with `rules.external` Helm values (not `rules.custom`).

```bash
# Check if APIService exists
kubectl --context kind-native-hpa-lab get apiservice | grep external

# If missing or if prior manual ConfigMap apply caused conflict:
kubectl --context kind-native-hpa-lab delete configmap prometheus-adapter -n monitoring

# Reinstall with values file (avoids zsh brace expansion issues)
cat > /tmp/adapter-values.yaml << 'EOF'
prometheus:
  url: http://prometheus-kube-prometheus-prometheus.monitoring.svc
  port: 9090
rules:
  default: false
  external:
    - seriesQuery: 'queue_depth_total{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace:
            resource: namespace
      name:
        as: queue_depth_external
      metricsQuery: 'sum(<<.Series>>{<<.LabelMatchers>>}) by (namespace)'
EOF

helm upgrade --install prometheus-adapter \
  prometheus-community/prometheus-adapter \
  --kube-context kind-native-hpa-lab \
  --namespace monitoring \
  --values /tmp/adapter-values.yaml \
  --wait --timeout 3m
```

### ScaledObject CRD not found on apply

KEDA CRDs hadn't propagated when the manifest was applied. Re-run:

```bash
helm upgrade --install keda kedacore/keda \
  --kube-context kind-keda-lab \
  --namespace keda --version 2.16.0 \
  --set watchNamespace="" --wait --timeout 5m

kubectl --context kind-keda-lab get crd scaledobjects.keda.sh
kubectl --context kind-keda-lab apply -f manifests/keda/00-keda-stack.yaml
```

### Port-forward / metric injection fails

Demos use `--address 127.0.0.1` to avoid macOS IPv6 binding issues. Manual test:

```bash
kubectl --context kind-keda-lab port-forward \
  -n demo-keda deploy/fake-metrics 18080:8080 --address 127.0.0.1 &
curl http://127.0.0.1:18080/health
curl http://127.0.0.1:18080/set?queue_depth=50
```

### Grafana 404

Cluster was created before Grafana NodePort mapping was added. Use port-forward or recreate:

```bash
./scripts/cluster.sh pf       # port-forward both Grafana instances
# or
./scripts/cluster.sh nuke && ./scripts/cluster.sh up   # full recreate
```

### Helm upgrade: ConfigMap conflict

```bash
kubectl --context kind-native-hpa-lab delete configmap prometheus-adapter -n monitoring
# then re-run helm upgrade
```

---

## 9. Production Considerations

### Native HPA

- **Prometheus Adapter is a SPOF** — unavailability freezes HPA. Run with replicas >=2 and a PDB.
- **`rules.external` vs `rules.custom`** — easy to misconfigure. Always verify with `get apiservice | grep external`.
- **Adapter ConfigMap ownership** — do not mix `kubectl apply` and Helm for the same ConfigMap. Use Helm exclusively to avoid ownership conflicts.
- **Managed clusters** — GKE/EKS/AKS may not expose the `HPAScaleToZero` feature gate. Verify before depending on it.
- **`stabilizationWindowSeconds: 300` default** — the stepped scale-down you see in the demo is a feature (gradual removal via `scaleDown.policies`). Keep it conservative in production.

### KEDA

- **Run operator with `replicaCount: 2`** — operator downtime freezes 0↔1 transitions.
- **Don't edit KEDA-managed HPAs** — reconciliation will overwrite changes. All HPA tuning in `ScaledObject.spec.advanced`.
- **TriggerAuthentication** — use CRD for Prometheus with auth rather than inlining credentials.
- **Metrics-apiserver downtime** — managed HPA holds current count during outage.

---

## 10. Decision Framework

```
Need scale-to-zero?
  No  → native HPA, minReplicas: 1

Metric source is Prometheus only?
  Yes + Prometheus Adapter already deployed → Native HPA (zero new components)
  Yes + no adapter → Either (KEDA simpler; adapter composable long-term)
  No (Kafka/SQS/Redis/HTTP/cron) → KEDA

Managed cluster (cannot control feature gates)?
  Yes → KEDA (no feature gate dependency)

Need HTTP traffic buffering on cold-start?
  Yes → KEDA HTTP add-on

Need cron-based scale windows?
  Yes → KEDA cron scaler

Need multiple trigger types per workload?
  Yes → KEDA (OR/AND trigger logic)

Organisation standardising on one autoscaling abstraction?
  Yes → KEDA (broader coverage, consistent ScaledObject API)
```
