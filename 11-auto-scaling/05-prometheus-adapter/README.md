## What This Lab Adds

| Topic | Prior demos | `05-prometheus-adapter` |
|---|---|---|
| Prometheus Adapter role and relationship to Prometheus | Theory in `02-hpa-advanced` §9 | ✅ full hands-on |
| kube-prometheus-stack installation | `04-keda-adapter` Step 3 note (assumed installed) | ✅ full install |
| Prometheus Adapter installation (Helm) | GAP | ✅ |
| ConfigMap rule structure — seriesQuery, resources, name, metricsQuery | GAP | ✅ with worked examples |
| Verifying `custom.metrics.k8s.io` with `kubectl get --raw` | GAP | ✅ |
| `type: Pods` HPA — hands-on with real metric | Theory only in `02-hpa-advanced` Step 4 | ✅ Steps 3–4 |
| `type: Object` HPA — hands-on with Ingress request rate | Theory only in `02-hpa-advanced` Step 4 | ✅ Steps 5–6 |
| `Value` vs `AverageValue` for Object type — hands-on verification | Theory in `02-hpa-advanced` API Reference §13.2 | ✅ Step 6 |
| Adapter troubleshooting — rule mismatch, metric not found | GAP | ✅ Break-Fix |

---

## Lab Overview

`02-hpa-advanced` explained that `type: Pods` and `type: Object` HPA metrics require a metrics adapter — a component that implements `custom.metrics.k8s.io` and bridges an application metrics backend (Prometheus) to the HPA controller. That demo covered the theory; this lab covers the hands-on.

The Prometheus Adapter sits between Prometheus and the HPA controller. Prometheus scrapes application metrics in its own format; the HPA controller speaks the Kubernetes Custom Metrics API. The Prometheus Adapter is the translator — it takes HPA's metric request, runs a PromQL query against Prometheus, and returns the result in the format HPA expects. The key insight is that Prometheus itself needs no changes; all translation configuration lives in the Prometheus Adapter's ConfigMap.

**Real-world scenario:** A web application exposes `http_requests_total` in Prometheus format. The team wants HPA to scale the Deployment based on requests-per-second per pod — not CPU, which is a lagging indicator. CPU rises after the application is already under stress; requests-per-second rises the moment traffic increases. The Prometheus Adapter makes this possible by exposing the `http_requests_per_second` metric to HPA via the Custom Metrics API.

**What this lab covers:**
- Installing kube-prometheus-stack (Prometheus + Grafana) on minikube `3node`
- Installing Prometheus Adapter and pointing it at the Prometheus service
- The Prometheus Adapter ConfigMap — rule structure, PromQL templates, label-to-resource mapping
- Verifying `custom.metrics.k8s.io` is serving metrics using `kubectl get --raw`
- HPA `type: Pods` — scaling based on a per-pod custom metric (http_requests_per_second)
- HPA `type: Object` — scaling based on a single Kubernetes object metric (Ingress request rate)
- `Value` vs `AverageValue` for Object type — hands-on demonstration of the difference
- Adapter troubleshooting — metric not found, rule mismatch, APIService not ready

> **Scope note:** All steps in this lab run on minikube `3node`. No cloud infrastructure is required. AWS-specific sources (SQS, ALB, CloudWatch) are covered in `aws-eks-demos`. KEDA-based scaling is covered in `04-keda-adapter`.

> **Verification status:** Steps expected outputs are written from documented Prometheus Adapter behaviour. They have not yet been run against this lab's manifests on a live cluster — run through the steps and report back any differences.

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — same cluster as all prior autoscaling demos
- kubectl installed and configured
- Helm v3 (used for kube-prometheus-stack and Prometheus Adapter)
- metrics-server enabled (already done in `01-hpa-basic`)

**Verify before starting:**
```bash
kubectl get pods -n kube-system | grep metrics-server
helm version --short
kubectl top nodes
# All must succeed before proceeding
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-hpa-basic` — HPA pipeline, metric types overview
- **REQUIRED:** Completion of `02-hpa-advanced` — Custom Metrics API theory, Pods/Object metric types, Prometheus Adapter architecture (Steps 4–5 and API Reference §9)
- **RECOMMENDED:** Completion of `04-keda-adapter` — useful for understanding how Prometheus Adapter and KEDA differ as adapter implementations

---

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Install kube-prometheus-stack and verify Prometheus is scraping cluster metrics
2. ✅ Install Prometheus Adapter and connect it to the Prometheus service
3. ✅ Explain the Prometheus Adapter ConfigMap rule structure — all four fields
4. ✅ Write a ConfigMap rule that maps a Prometheus metric to a `custom.metrics.k8s.io` name
5. ✅ Verify that `custom.metrics.k8s.io` is serving a metric using `kubectl get --raw`
6. ✅ Create an HPA with `type: Pods` targeting a custom per-pod metric and observe scaling
7. ✅ Create an HPA with `type: Object` targeting an Ingress request rate and observe the `Value` vs `AverageValue` difference
8. ✅ Diagnose a broken Adapter rule from `kubectl describe hpa` output
9. ✅ Uninstall the Prometheus Adapter and kube-prometheus-stack cleanly

---

## Directory Structure

```
11-auto-scaling/05-prometheus-adapter/
├── README.md                                     # this file
├── 05-prometheus-adapter-anki.csv                # Anki flashcard deck
├── 05-prometheus-adapter-quiz.md                 # standalone quiz
└── src/
    ├── sample-app-deploy.yaml                    # sample app exposing /metrics
    ├── ingress.yaml                              # Ingress for Object metric demo
    ├── prometheus-adapter-values.yaml            # Helm values for Prometheus Adapter
    ├── hpa-pods-metric.yaml                      # HPA type: Pods
    ├── hpa-object-metric-value.yaml              # HPA type: Object, target.type: Value
    ├── hpa-object-metric-avgvalue.yaml           # HPA type: Object, target.type: AverageValue
    └── break-fix/
        ├── 01-adapter-rule-wrong-resource.yaml         # broken: resource label mismatch
        ├── 02-hpa-metric-name-mismatch.yaml            # broken: HPA metric name ≠ adapter name
        └── 03-adapter-missing-metricsquery.yaml        # broken: rule missing metricsQuery
```

---

## Recall Check — 04-keda-adapter

Answer from memory before continuing — these are scenario questions from `04-keda-adapter`.

1. You create a ScaledObject with `minReplicaCount: 0` and `cooldownPeriod: 60`. The Redis queue empties. After 5 minutes, `kubectl get pods -l app=worker` still shows 1 running pod. What is the most likely cause, and how would you diagnose it?
2. `kubectl get scaledobject` shows `READY=False` for your ScaledObject. The target Deployment exists and is running. What are the two most likely causes, and what command do you run to confirm?
3. You want to store Redis credentials for a KEDA scaler without putting the password in the ScaledObject YAML. What KEDA resource do you create, and how does the ScaledObject reference it?

<details>
<summary>Answers</summary>

1. Most likely cause: KEDA Operator pod is not running, or the ScaledObject is showing `READY=False` (not successfully querying the scaler). Another cause: `cooldownPeriod` restarts on every non-zero event — if a stray test message arrived in the last 60 seconds, the cooldown reset. Diagnose with: `kubectl get scaledobject worker-redis-scaler` (check ACTIVE and READY); `kubectl describe scaledobject worker-redis-scaler` (check Conditions); `kubectl get pods -n keda` (verify KEDA Operator is running); `kubectl logs -n keda -l app=keda-operator | tail -20`.

2. Two most likely causes: (a) `scaleTargetRef.name` typo — Deployment name in ScaledObject does not match the actual Deployment name; (b) the scaler cannot reach the event source (wrong address, port, or missing/wrong credentials). Command: `kubectl describe scaledobject <name> | grep -A10 "Conditions:"` — the Conditions block shows the specific error message including the mismatched name or connection error.

3. Create a `TriggerAuthentication` object that references a Kubernetes Secret containing the Redis password (`secretTargetRef` mapping `parameter: password` to the Secret key). The ScaledObject references it via `triggers[].authenticationRef.name: <trigger-auth-name>`. The password never appears in the ScaledObject spec — only the TriggerAuthentication name is referenced.

</details>

---

## Concepts

### The Prometheus Adapter — Role and Architecture

The Prometheus Adapter is a Kubernetes Deployment that implements two Kubernetes metrics APIs:
- `custom.metrics.k8s.io` — for HPA `type: Pods` and `type: Object` metrics
- `external.metrics.k8s.io` — for HPA `type: External` metrics (less common via Prometheus Adapter; KEDA is preferred for external sources)

It is maintained by the Kubernetes community under `kubernetes-sigs` (official SIG). It is NOT a Prometheus plugin or Prometheus component — it is a separate piece of software that happens to query Prometheus using the standard Prometheus HTTP API (the same API Grafana uses).

**Why Prometheus alone is not enough:**

```
HPA controller speaks:  Kubernetes Custom Metrics API (custom.metrics.k8s.io)
Prometheus speaks:      Prometheus HTTP API + PromQL

These are two different protocols.
HPA cannot query Prometheus directly.
Prometheus cannot push metrics to HPA.

The Prometheus Adapter bridges them:
  HPA asks:   "what is http_requests_per_second for pod nginx-xxx?"
              via GET /apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/nginx-xxx/http_requests_per_second
  Adapter:    translates to PromQL: sum(rate(http_requests_total{pod="nginx-xxx"}[2m]))
              runs the query against Prometheus HTTP API
              returns the result in Custom Metrics API format
  HPA:        receives the value, calculates desiredReplicas
```

**Full component stack:**

```
Application pods
  expose /metrics endpoint (Prometheus exposition format)
  e.g. http_requests_total{method="GET", status="200"} 1234
        │
        │  Prometheus scrapes /metrics every 15s
        ▼
Prometheus (kube-prometheus-stack)
  stores time-series data
  exposes PromQL HTTP query API at :9090
        │
        │  PromQL queries (same API Grafana uses)
        ▼
Prometheus Adapter
  registered as APIService for custom.metrics.k8s.io
  ConfigMap rules define: which Prometheus series → which Custom Metrics API name
        │
        │  Custom Metrics API (proxied via kube-apiserver)
        ▼
HPA Controller
  queries custom.metrics.k8s.io for metric values
  calculates desiredReplicas
  updates Deployment scale subresource
```

**What Prometheus needs to support this:** Nothing. Prometheus only needs to be scraping the relevant application metrics. All configuration lives in the Prometheus Adapter's ConfigMap — Prometheus has no awareness of HPA or the Custom Metrics API.

---

### Prometheus Adapter ConfigMap — Rule Structure

The ConfigMap is where you define which Prometheus metrics are exposed to HPA and under what name. Each rule has four required fields:

```yaml
rules:
  - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
    #
    # seriesQuery: which Prometheus metric series this rule matches
    # Think of it as a filter — which time series in Prometheus does this rule apply to?
    # Must include label selectors that ensure namespace and pod are present
    # (so the adapter can link the metric to a Kubernetes resource)
    #
    resources:
      overrides:
        namespace: {resource: "namespace"}
        pod:       {resource: "pod"}
    #
    # resources.overrides: maps Prometheus label names to Kubernetes resource names
    # This is how the adapter knows WHICH Kubernetes object the metric belongs to.
    # "namespace" label in Prometheus -> Kubernetes "namespace" resource
    # "pod" label in Prometheus -> Kubernetes "pod" resource
    # Without this mapping, the adapter cannot route the metric to the correct pod.
    #
    name:
      matches: "^(.*)_total$"
      as: "${1}_per_second"
    #
    # name: transforms the Prometheus metric name into the Custom Metrics API name
    # matches: regex that captures part of the Prometheus metric name
    # as: the resulting Custom Metrics API name (what HPA references in metric.name)
    # Example: "http_requests_total" -> matches "http_requests" -> "http_requests_per_second"
    # This is the name you put in the HPA YAML: metric.name: http_requests_per_second
    #
    metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
    #
    # metricsQuery: the PromQL template executed when HPA requests this metric
    # Template variables (filled in by the adapter per request):
    #   <<.Series>>        -> replaced with the matched Prometheus series name
    #                         (e.g. "http_requests_total")
    #   <<.LabelMatchers>> -> replaced with label selectors to scope to the specific
    #                         pod/namespace the HPA is asking about
    #                         (e.g. pod="nginx-xxx",namespace="default")
    #   <<.GroupBy>>       -> replaced with the grouping label (usually "pod" for Pods type)
    #
    # The result of this query is what the adapter returns to HPA as the metric value.
    # rate(...[2m]) computes per-second rate over the last 2 minutes.
    # sum(...) by (pod) aggregates across all time series for each pod.
```

**What each field does — in plain terms:**

```
seriesQuery:    "find these Prometheus metrics"
resources:      "this Prometheus label means this Kubernetes resource"
name:           "call this metric <name> when HPA asks for it"
metricsQuery:   "when HPA asks, run this PromQL to get the value"
```

**For Object type metrics (Ingress example):**

```yaml
rules:
  - seriesQuery: 'nginx_ingress_controller_requests_total{namespace!="",ingress!=""}'
    resources:
      overrides:
        namespace: {resource: "namespace"}
        ingress: {group: "networking.k8s.io", resource: "ingresses"}
    #   ↑ "ingress" label in Prometheus → Kubernetes Ingress object
    #   Must specify the API group for non-core resources
    name:
      matches: "^nginx_ingress_controller_(.*)_total$"
      as: "nginx_ingress_${1}_per_second"
    metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
    # For Object type, <<.GroupBy>> is "ingress" — groups by Ingress name
```

---

### How HPA Requests Flow Through the Adapter

Understanding the request path explains why the ConfigMap fields must be consistent with the HPA YAML:

```
HPA YAML specifies:
  type: Pods
  pods:
    metric:
      name: http_requests_per_second   <- must match the "as:" field in the rule
    target:
      type: AverageValue
      averageValue: "100"

HPA controller sends GET:
  /apis/custom.metrics.k8s.io/v1beta1/
    namespaces/default/pods/*/http_requests_per_second

Adapter receives this request:
  1. Finds the rule where name.as = "http_requests_per_second"
  2. Identifies the seriesQuery: http_requests_total{namespace!="",pod!=""}
  3. Builds LabelMatchers from the requested pod names and namespace
  4. Executes metricsQuery with the template variables filled in:
     sum(rate(http_requests_total{pod=~"nginx-xxx|nginx-yyy",namespace="default"}[2m]))
     by (pod)
  5. Gets per-pod values: nginx-xxx=120/s, nginx-yyy=95/s
  6. Returns to HPA in Custom Metrics API format

HPA calculates:
  average = (120 + 95) / 2 = 107.5 req/s
  target = 100 req/s per pod
  desiredReplicas = ceil[2 × (107.5/100)] = ceil[2.15] = 3
```

---

### `Value` vs `AverageValue` for `type: Object` — Hands-on Impact

This distinction matters critically for Object type and was flagged in `02-hpa-advanced` API Reference §13.2:

```
type: Object, target.type: Value
  -> HPA compares the raw Ingress total directly to target.value
  -> Adding more backend pods does NOT reduce the Ingress total
  -> Traffic keeps arriving at the same total rate regardless of pod count
  -> Result: HPA keeps scaling up until maxReplicas, never stabilises
  -> Use case: scale up to a fixed cap when total load exceeds a threshold
               (not a per-pod calculation — just a trigger)

type: Object, target.type: AverageValue
  -> HPA divides the Ingress total by the current pod count
  -> Adding a pod reduces the per-pod share of the total
  -> Result: HPA stabilises when (total / pods) == averageValue
  -> Use case: scale to handle N requests per pod (load balancing semantics)
  -> This makes Object type behave like Pods type for the scaling math

Example:
  Ingress receiving 1200 req/s total
  Backend pods: 3
  Per-pod share: 1200 / 3 = 400 req/s

  With target.type: Value, value: "1000":
    1200 > 1000 -> scale up -> 4 pods
    1200 > 1000 -> still scale up -> 5 pods (Ingress total does not change!)
    -> keeps scaling to maxReplicas

  With target.type: AverageValue, averageValue: "400":
    1200 / 3 = 400 = target -> no scaling needed (stable at 3 pods)
    If traffic grows to 1600: 1600 / 3 = 533 > 400 -> scale to 4
    1600 / 4 = 400 = target -> stable at 4 pods
```

---

## Lab Step-by-Step Guide

---

### Step 1 — Install kube-prometheus-stack

kube-prometheus-stack installs Prometheus, Alertmanager, Grafana, and a set of ServiceMonitors that scrape cluster-level metrics out of the box.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi
```

> **Why disable Grafana and Alertmanager?** Reduces resource usage on minikube `3node`. Grafana and Alertmanager are not needed for HPA — only Prometheus is required. Re-enable for production deployments.

Wait for Prometheus to be running:
```bash
kubectl get pods -n monitoring -w
```

**Expected output (ready state):**
```
NAME                                                   READY   STATUS
kube-prom-kube-promethe-prometheus-0                   2/2     Running
kube-prom-kube-state-metrics-xxxxxxxxx-xxxxx           1/1     Running
kube-prom-prometheus-node-exporter-xxxxx               1/1     Running
kube-prom-prometheus-node-exporter-yyyyy               1/1     Running
```

Verify Prometheus is serving metrics:
```bash
kubectl port-forward -n monitoring svc/kube-prom-kube-promethe-prometheus 9090:9090 &
PF_PID=$!
sleep 2

# Query a known metric to confirm Prometheus is working
curl -s "http://localhost:9090/api/v1/query?query=up" | python3 -m json.tool | head -10
```

**Expected output:**
```json
{
    "status": "success",
    "data": {
        "resultType": "vector",
        "result": [...]
    }
}
```

```bash
kill $PF_PID 2>/dev/null
```

Note the Prometheus service name — you will need it for the Prometheus Adapter:
```bash
kubectl get svc -n monitoring | grep prometheus
```

**Expected output:**
```
NAME                                        TYPE        PORT(S)
kube-prom-kube-promethe-prometheus          ClusterIP   9090/TCP
```

```
# Observation: the Prometheus service is kube-prom-kube-promethe-prometheus
#              in namespace monitoring, port 9090.
#              This is the address the Prometheus Adapter will query.
#              The exact name depends on your Helm release name (kube-prom here).
```

---

### Step 2 — Install Prometheus Adapter

**`src/prometheus-adapter-values.yaml`:**
```yaml
prometheus:
  url: http://kube-prom-kube-promethe-prometheus.monitoring.svc
  port: 9090
  # Adjust "kube-prom" to match your Helm release name from Step 1

rules:
  default: false            # disable default rules — we write our own in Steps 3-5
  custom:
    # Rule 1: http_requests_per_second for Pods type HPA
    - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod:       {resource: "pod"}
      name:
        matches: "^(.*)_total$"
        as: "${1}_per_second"
      metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'

    # Rule 2: nginx_ingress_requests_per_second for Object type HPA
    - seriesQuery: 'nginx_ingress_controller_requests_total{namespace!="",ingress!=""}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          ingress: {group: "networking.k8s.io", resource: "ingresses"}
      name:
        matches: "^nginx_ingress_controller_(.*)_total$"
        as: "nginx_ingress_${1}_per_second"
      metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
```

```bash
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  -f src/prometheus-adapter-values.yaml
```

**Expected output:**
```
NAME: prometheus-adapter
NAMESPACE: monitoring
STATUS: deployed
```

Wait for the Adapter to be running:
```bash
kubectl get pods -n monitoring | grep adapter
```

**Expected output:**
```
NAME                                    READY   STATUS
prometheus-adapter-xxxxxxxxx-xxxxx      1/1     Running
```

Verify the Adapter registered itself as an APIService for `custom.metrics.k8s.io`:
```bash
kubectl get apiservices | grep custom.metrics
```

**Expected output:**
```
v1beta1.custom.metrics.k8s.io   monitoring/prometheus-adapter   True   2m
```

```
# Observation: True = Prometheus Adapter is reachable and serving the Custom Metrics API
#              False or Missing = adapter pod not running or registration failed
#              If False: check adapter pod logs:
#              kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter
```

---

### Step 3 — Deploy Sample Application

This application exposes a `/metrics` endpoint in Prometheus format with an `http_requests_total` counter. Prometheus will scrape it, and the Prometheus Adapter will expose it as `http_requests_per_second` to HPA.

**`src/sample-app-deploy.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  labels:
    app: sample-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
      annotations:
        prometheus.io/scrape: "true"    # tells Prometheus to scrape this pod
        prometheus.io/port: "8080"      # port where /metrics is exposed
        prometheus.io/path: "/metrics"  # path of the metrics endpoint
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: app
          image: prom/prometheus-example-app:latest
          # prom/prometheus-example-app exposes:
          #   http_requests_total{method, path, status} counter
          #   version_info gauge
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app-svc
  labels:
    app: sample-app
spec:
  type: ClusterIP
  selector:
    app: sample-app
  ports:
    - port: 8080
      targetPort: 8080
```

```bash
cd 11-auto-scaling/05-prometheus-adapter/src

kubectl apply -f sample-app-deploy.yaml
kubectl rollout status deployment/sample-app
kubectl get pods -l app=sample-app
```

**Expected output:**
```
NAME                          READY   STATUS
sample-app-xxxxxxxxx-xxxxx    1/1     Running
```

Verify the application exposes metrics:
```bash
kubectl port-forward svc/sample-app-svc 8080:8080 &
APP_PF=$!
sleep 2
curl -s http://localhost:8080/metrics | grep http_requests_total
kill $APP_PF 2>/dev/null
```

**Expected output:**
```
# HELP http_requests_total Count of all HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="get",status="200"} 1
```

Generate some traffic to create a non-zero rate:
```bash
kubectl run traffic-gen --image=busybox:1.36 --restart=Never \
  --command -- sh -c \
  "while true; do wget -q -O- http://sample-app-svc:8080; sleep 0.1; done"
```

Wait ~2 minutes for Prometheus to scrape the metric and for the Adapter to expose it:
```bash
# Verify the metric appears in Prometheus
kubectl port-forward -n monitoring svc/kube-prom-kube-promethe-prometheus 9090:9090 &
PROM_PF=$!
sleep 2

curl -s "http://localhost:9090/api/v1/query?query=http_requests_total" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    [print(r['metric'].get('pod',''), r['value'][1]) for r in d['data']['result']]"
kill $PROM_PF 2>/dev/null
```

**Expected output:**
```
sample-app-xxxxxxxxx-xxxxx   142
```

```
# Observation: Prometheus has scraped http_requests_total from the sample-app pod.
#              The adapter can now expose this as http_requests_per_second
#              via the Custom Metrics API.
```

---

### Step 4 — Verify Custom Metrics API and Create HPA (Pods Type)

Verify the Prometheus Adapter is exposing the metric via Custom Metrics API:
```bash
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second" \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "kind": "MetricValueList",
    "apiVersion": "custom.metrics.k8s.io/v1beta1",
    "metadata": {},
    "items": [
        {
            "describedObject": {
                "kind": "Pod",
                "namespace": "default",
                "name": "sample-app-xxxxxxxxx-xxxxx"
            },
            "metricName": "http_requests_per_second",
            "value": "10200m"
        }
    ]
}
```

```
# Observation: "10200m" = 10.2 requests per second (m = milli, so 10200m = 10.2)
#              The adapter ran the PromQL rate() query and returned the result.
#              If this returns 404 or empty items:
#              -> either the metric has not been scraped yet (wait 2 more minutes)
#              -> or the adapter rule's seriesQuery does not match any Prometheus series
```

**`src/hpa-pods-metric.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sample-app-hpa-pods
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second    # must match adapter rule name.as
        target:
          type: AverageValue
          averageValue: "5"                 # target: 5 req/s per pod
```

```bash
kubectl apply -f hpa-pods-metric.yaml
kubectl get hpa sample-app-hpa-pods -w
```

**Expected output:**
```
NAME                   REFERENCE                TARGETS         MINPODS  MAXPODS  REPLICAS
sample-app-hpa-pods    Deployment/sample-app    <unknown>/5     1        5        1
sample-app-hpa-pods    Deployment/sample-app    10200m/5        1        5        1
sample-app-hpa-pods    Deployment/sample-app    10200m/5        1        5        2
```

```
# Observation: <unknown>/5 -> adapter not yet returning value (wait 30-60s)
#              10200m/5    -> 10.2 req/s current, 5 req/s target
#                             desiredReplicas = ceil[1 x (10.2/5)] = ceil[2.04] = 2
#              REPLICAS: 2 -> HPA scaled out using the custom metric ✅
```

Check that traffic-gen load drives further scaling:
```bash
kubectl describe hpa sample-app-hpa-pods | grep -A5 "Metrics:"
```

**Expected output:**
```
Metrics:                                               ( current / target )
  "http_requests_per_second" on pods/sample-app-hpa-pods:  10200m / 5
```

```
# Observation: the metric name appears exactly as defined in name.as ("http_requests_per_second")
#              and the type label confirms this is a Pods-type metric
```

```bash
kubectl delete -f hpa-pods-metric.yaml
```

---

### Step 5 — Deploy nginx-ingress-controller for Object Type Demo

The Object type demo uses the nginx-ingress-controller, which exposes per-Ingress request metrics that Prometheus can scrape.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=true \
  --set controller.metrics.serviceMonitor.namespace=monitoring
```

**Expected output:**
```
NAME: ingress-nginx
NAMESPACE: ingress-nginx
STATUS: deployed
```

Wait for the Ingress controller to be running:
```bash
kubectl get pods -n ingress-nginx -w
```

**Expected output:**
```
NAME                                       READY   STATUS
ingress-nginx-controller-xxxxxxxxx-xxxxx   1/1     Running
```

Create an Ingress for the sample app:

**`src/ingress.yaml`:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sample-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: sample-app.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: sample-app-svc
                port:
                  number: 8080
```

```bash
kubectl apply -f ingress.yaml
kubectl get ingress
```

**Expected output:**
```
NAME                  CLASS   HOSTS               ADDRESS      PORTS
sample-app-ingress    nginx   sample-app.local    <node-ip>    80
```

Send traffic through the Ingress (so the nginx controller records request metrics):
```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# If minikube doesn't assign an IP automatically, use minikube tunnel
minikube tunnel -p 3node &
TUNNEL_PID=$!
sleep 3

INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

kubectl run ingress-traffic --image=busybox:1.36 --restart=Never \
  --command -- sh -c \
  "while true; do wget -q -O- --header='Host: sample-app.local' \
   http://${INGRESS_IP}/; sleep 0.1; done"
```

Wait ~2 minutes for Prometheus to scrape the nginx-ingress-controller metrics, then verify:
```bash
kubectl port-forward -n monitoring svc/kube-prom-kube-promethe-prometheus 9090:9090 &
PROM_PF=$!
sleep 2

curl -s "http://localhost:9090/api/v1/query?query=nginx_ingress_controller_requests_total" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    [print(r['metric'].get('ingress',''), r['value'][1]) \
     for r in d['data']['result'][:3]]"
kill $PROM_PF 2>/dev/null
```

**Expected output:**
```
sample-app-ingress   528
```

```
# Observation: Prometheus has scraped the nginx_ingress_controller_requests_total metric
#              with an "ingress" label matching our Ingress name.
#              This is what the adapter rule for Object type will expose.
```

---

### Step 6 — HPA Object Type: `Value` vs `AverageValue`

First verify the Ingress metric is available via Custom Metrics API:
```bash
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/ingresses.networking.k8s.io/sample-app-ingress/nginx_ingress_requests_per_second" \
  | python3 -m json.tool
```

**Expected output:**
```json
{
    "kind": "MetricValueList",
    "apiVersion": "custom.metrics.k8s.io/v1beta1",
    "items": [
        {
            "describedObject": {
                "kind": "Ingress",
                "namespace": "default",
                "name": "sample-app-ingress"
            },
            "metricName": "nginx_ingress_requests_per_second",
            "value": "8500m"
        }
    ]
}
```

```
# Observation: ONE value for the Ingress object (not per-pod).
#              8500m = 8.5 req/s total across all backend pods.
#              This is the "single aggregate value from one Kubernetes object"
#              that defines the Object metric type.
```

**Test 1 — Object type with `target.type: Value`:**

**`src/hpa-object-metric-value.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sample-app-hpa-object-value
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Object
      object:
        metric:
          name: nginx_ingress_requests_per_second
        describedObject:
          apiVersion: networking.k8s.io/v1
          kind: Ingress
          name: sample-app-ingress
        target:
          type: Value                # compare RAW TOTAL directly to this value
          value: "5"                 # scale when total Ingress req/s > 5
```

```bash
kubectl apply -f hpa-object-metric-value.yaml
kubectl get hpa sample-app-hpa-object-value -w
```

**Expected output:**
```
NAME                         REFERENCE                TARGETS        MINPODS  MAXPODS  REPLICAS
sample-app-hpa-object-value  Deployment/sample-app    8500m/5        1        5        1
sample-app-hpa-object-value  Deployment/sample-app    8500m/5        1        5        2
sample-app-hpa-object-value  Deployment/sample-app    8500m/5        1        5        3
sample-app-hpa-object-value  Deployment/sample-app    8500m/5        1        5        4
sample-app-hpa-object-value  Deployment/sample-app    8500m/5        1        5        5  <- maxReplicas hit
```

```
# Observation: TARGETS stays at 8500m/5 (8.5 req/s > 5 target) even as replicas grow.
#              Adding more backend pods does NOT reduce the Ingress total —
#              traffic still arrives at the same 8.5 req/s regardless of pod count.
#              HPA keeps scaling until maxReplicas=5. This is the Value behaviour.
#              In production this would loop until maxReplicas — use AverageValue instead.
```

```bash
kubectl delete -f hpa-object-metric-value.yaml
```

**Test 2 — Object type with `target.type: AverageValue`:**

**`src/hpa-object-metric-avgvalue.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sample-app-hpa-object-avgvalue
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Object
      object:
        metric:
          name: nginx_ingress_requests_per_second
        describedObject:
          apiVersion: networking.k8s.io/v1
          kind: Ingress
          name: sample-app-ingress
        target:
          type: AverageValue         # divide total by pod count before comparing
          averageValue: "5"          # target: 5 req/s PER BACKEND POD
```

```bash
kubectl apply -f hpa-object-metric-avgvalue.yaml
kubectl get hpa sample-app-hpa-object-avgvalue -w
```

**Expected output:**
```
NAME                            REFERENCE                TARGETS         MINPODS  MAXPODS  REPLICAS
sample-app-hpa-object-avgvalue  Deployment/sample-app    8500m/5         1        5        1
sample-app-hpa-object-avgvalue  Deployment/sample-app    4250m/5         1        5        2   <- stabilised
```

```
# Observation: HPA calculates: 8.5 total / 2 pods = 4.25 req/s per pod
#              4.25 is within the 10% tolerance of the 5 req/s target
#              -> HPA stabilises at 2 replicas
#              With AverageValue, adding a pod reduces the per-pod share -> stabilisation ✅
#
# Compare with Value result above:
#   Value:        never stabilises -> keeps scaling to maxReplicas
#   AverageValue: stabilises when (total / pods) ≈ target
```

```bash
kubectl delete -f hpa-object-metric-avgvalue.yaml
```

---

### Step 7 — Cleanup

```bash
kubectl delete -f sample-app-deploy.yaml --ignore-not-found
kubectl delete -f ingress.yaml --ignore-not-found
kubectl delete -f hpa-pods-metric.yaml --ignore-not-found
kubectl delete -f hpa-object-metric-value.yaml --ignore-not-found
kubectl delete -f hpa-object-metric-avgvalue.yaml --ignore-not-found
kubectl delete pod traffic-gen --ignore-not-found --grace-period=0
kubectl delete pod ingress-traffic --ignore-not-found --grace-period=0

kubectl get hpa
kubectl get pods
```

**Expected output:**
```
No resources found in default namespace.
No resources found in default namespace.
```

Uninstall Prometheus Adapter, nginx-ingress, and kube-prometheus-stack:
```bash
helm uninstall prometheus-adapter -n monitoring
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall kube-prom -n monitoring

kubectl delete namespace monitoring
kubectl delete namespace ingress-nginx

# Verify apiservices are cleaned up
kubectl get apiservices | grep custom.metrics
# No output expected — custom.metrics.k8s.io is removed
```

```
# Observation: metrics-server stays enabled — still needed for later demos.
#              custom.metrics.k8s.io is removed along with the Prometheus Adapter.
```

---

## What You Learned

In this lab, you:
- ✅ Installed kube-prometheus-stack and verified Prometheus is scraping application metrics
- ✅ Installed Prometheus Adapter and connected it to Prometheus via the service URL
- ✅ Explained the four ConfigMap rule fields — `seriesQuery`, `resources`, `name`, `metricsQuery` — and what each does
- ✅ Wrote ConfigMap rules for both Pods and Object metric types
- ✅ Verified `custom.metrics.k8s.io` is serving metrics using `kubectl get --raw`
- ✅ Created an HPA with `type: Pods` targeting `http_requests_per_second` and observed scaling
- ✅ Created an HPA with `type: Object` and observed the `Value` vs `AverageValue` difference hands-on
- ✅ Confirmed that `Value` on Object type causes unbounded scale-out; `AverageValue` stabilises correctly

**Key Takeaway:** The Prometheus Adapter is a translator — Prometheus stores metrics, the HPA controller speaks the Custom Metrics API, and the Adapter converts between them using PromQL rules defined in its ConfigMap. Prometheus itself needs no changes. The most common mistake is using `target.type: Value` for Object metrics when `AverageValue` is intended — `Value` compares the Ingress total directly to the target, and since the total does not decrease as pods scale, HPA keeps scaling to `maxReplicas`. Always use `AverageValue` for Object metrics unless you specifically want a threshold trigger regardless of pod count.

---

## Break-Fix

Three broken manifests below. For each: apply it, read the symptom, diagnose, then reveal the answer.

---

### Error-1

**`src/break-fix/01-adapter-rule-wrong-resource.yaml`:**
```yaml
# This is a Prometheus Adapter ConfigMap with a broken rule.
# Apply it by upgrading the Helm release:
# helm upgrade prometheus-adapter prometheus-community/prometheus-adapter \
#   --namespace monitoring -f break-fix/01-adapter-rule-wrong-resource.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-adapter
  namespace: monitoring
data:
  config.yaml: |
    rules:
      - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
        resources:
          overrides:
            namespace: {resource: "namespace"}
            container: {resource: "pod"}   # BUG: "container" label does not exist
                                            # in http_requests_total; should be "pod"
        name:
          matches: "^(.*)_total$"
          as: "${1}_per_second"
        metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
```

After applying this rule and waiting 2 minutes:
```bash
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second"
kubectl describe hpa sample-app-hpa-pods | grep -A3 "Metrics:"
```

What do you see, and why?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get --raw ...: {"kind":"MetricValueList","items":[]}
# Empty items — no metrics returned

kubectl describe hpa:
  Metrics:
    "http_requests_per_second" on pods/sample-app:  <unknown> / 5
```

**Cause:** The `resources.overrides` block maps the Prometheus label `container` to the Kubernetes `pod` resource. But the `http_requests_total` metric does not have a `container` label — it has a `pod` label. The adapter cannot link the metric to any Kubernetes pod (the mapping produces no matches), so it returns an empty result set. HPA shows `<unknown>` because the Custom Metrics API returns no values for the pods it asks about.

**Fix:** Change `container: {resource: "pod"}` to `pod: {resource: "pod"}` — the left side must be the actual Prometheus label name, not a Kubernetes resource name. The right side names the Kubernetes resource type.

**Cascade:** Any HPA using `type: Pods` with this metric stays at `<unknown>` and holds the current replica count. No scaling occurs and no error is thrown — the metric just silently returns empty.

</details>

---

### Error-2

**`src/break-fix/02-hpa-metric-name-mismatch.yaml`:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sample-app-hpa-broken-name
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_total     # BUG: this is the raw Prometheus metric name
                                         # the adapter exposes it as "http_requests_per_second"
                                         # (the "name.as" field in the ConfigMap rule)
        target:
          type: AverageValue
          averageValue: "5"
```

```bash
kubectl apply -f break-fix/02-hpa-metric-name-mismatch.yaml
# Wait 60s
kubectl describe hpa sample-app-hpa-broken-name | grep -A5 "Metrics:\|Conditions:"
```

What does the HPA show, and how do you identify the correct metric name to use?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
Metrics:
  "http_requests_total" on pods/sample-app:   <unknown> / 5

Conditions:
  ScalingActive: False   FailedGetPodsMetric
    "unable to get metric http_requests_total: no metrics returned from custom metrics API"
```

**Cause:** The HPA references `http_requests_total` — the raw Prometheus counter name. The Prometheus Adapter's rule transforms this to `http_requests_per_second` via the `name.as` field. The Custom Metrics API does not expose `http_requests_total`; it only exposes `http_requests_per_second`. The HPA asks for a name the adapter has never registered.

**Fix:** Change `name: http_requests_total` to `name: http_requests_per_second` — the Custom Metrics API name as defined in the adapter rule's `name.as` field.

**How to find the correct name:**
```bash
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/ | python3 -m json.tool | grep '"name"'
# Lists all metric names currently registered by the adapter
```

**Cascade:** HPA shows `<unknown>` indefinitely. No scaling occurs. The error message in Conditions names the metric the adapter could not find — use that to trace back to the adapter rule.

</details>

---

### Error-3

**`src/break-fix/03-adapter-missing-metricsquery.yaml`:**
```yaml
# Prometheus Adapter ConfigMap with missing metricsQuery
rules:
  - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
    resources:
      overrides:
        namespace: {resource: "namespace"}
        pod:       {resource: "pod"}
    name:
      matches: "^(.*)_total$"
      as: "${1}_per_second"
    # BUG: metricsQuery field is missing entirely
    # The adapter has no PromQL template to execute when HPA asks for this metric
```

After applying this broken ConfigMap and restarting the adapter:
```bash
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second"
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter | tail -10
```

What do you observe and what is the fix?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

```
kubectl get --raw ...:
  Error: the server could not find the requested resource

kubectl logs:
  error loading config: error parsing rules: rule 0 has no metrics query defined
```

**Cause:** The `metricsQuery` field is required in every adapter rule. Without it, the adapter cannot construct a PromQL query when HPA requests the metric. The adapter fails to start (or rejects the rule), and the metric is never registered with the Custom Metrics API. The `kubectl get --raw` returns a 404 because `custom.metrics.k8s.io` does not know about this metric at all.

**Fix:** Add the `metricsQuery` field with the appropriate PromQL template:
```yaml
metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
```

**Cascade:** The adapter pod may crash-loop (if it rejects invalid configs at startup) or skip the invalid rule (depending on adapter version). Either way, the metric is never available and any HPA using it shows `<unknown>`. Check adapter logs first whenever `custom.metrics.k8s.io` returns 404 for an expected metric.

</details>

---

## Interview Prep

**Q1. Explain the role of the Prometheus Adapter. Why can HPA not query Prometheus directly?**

HPA controller speaks the Kubernetes Custom Metrics API (`custom.metrics.k8s.io`), which is an API group with a specific request/response format defined by the Kubernetes API aggregation layer. Prometheus speaks its own HTTP API with PromQL as the query language — an entirely different protocol with no concept of Kubernetes resource namespacing or the Custom Metrics API shape. The Prometheus Adapter bridges these: it registers as the `custom.metrics.k8s.io` APIService, receives HPA's metric requests, translates them into PromQL queries (using the ConfigMap rule's `metricsQuery` template), executes those queries against Prometheus, and returns results in the Custom Metrics API format HPA expects. No configuration change is needed in Prometheus itself — only the adapter's ConfigMap changes.

**Q2. Walk through the four fields of a Prometheus Adapter ConfigMap rule and what each does.**

`seriesQuery` is a Prometheus label selector that identifies which metric series in Prometheus this rule applies to — it must include label selectors that ensure namespace and pod (or other Kubernetes resource) labels are present. `resources.overrides` maps Prometheus label names to Kubernetes resource names — this is how the adapter knows which Kubernetes object a metric belongs to; for example, `pod: {resource: "pod"}` maps the Prometheus `pod` label to the Kubernetes pod resource. `name` transforms the Prometheus metric name into the Custom Metrics API name the HPA will reference — `matches` is a regex, `as` is the output name. `metricsQuery` is the PromQL template executed when HPA requests the metric, with `<<.Series>>`, `<<.LabelMatchers>>`, and `<<.GroupBy>>` as template variables filled in by the adapter per request.

**Q3. An HPA with `type: Object` and `target.type: Value` keeps scaling to `maxReplicas` even with no load increase. What is the root cause, and how do you fix it?**

`target.type: Value` compares the raw metric value from the Ingress object directly to the target. The Ingress total request rate is determined by incoming traffic — it does not decrease when backend pods are added. So as HPA adds pods, the metric stays the same, the comparison stays above the target, and HPA keeps scaling. The fix is `target.type: AverageValue` — this divides the Ingress total by the current pod count before comparing. Adding a pod reduces the per-pod share, which eventually brings the per-pod metric to the target value and stabilises scaling.

**Q4. `kubectl describe hpa` shows `<unknown>` for a custom metric. Describe your troubleshooting sequence.**

First, check whether the Custom Metrics API is registered: `kubectl get apiservices | grep custom.metrics` — if False or absent, the adapter pod is not running or failed to register. Second, check the adapter pod logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter` — look for rule parse errors, missing fields, or connection failures. Third, verify the metric exists in Prometheus: port-forward to Prometheus and run a PromQL query matching the adapter's `seriesQuery`. Fourth, verify the metric is exposed by the adapter: `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/` to list all registered metrics — confirm the expected name appears. If it does not, the `seriesQuery` matched no Prometheus series. Fifth, check the HPA metric name matches the adapter rule's `name.as` field exactly — this is case-sensitive.

**Q5. What is the difference between the Prometheus Adapter and KEDA for custom metrics scaling?**

The Prometheus Adapter is a lean adapter that implements `custom.metrics.k8s.io` (and `external.metrics.k8s.io`) using Prometheus as the backend, via PromQL rules in a ConfigMap. HPA creates and manages its own scaling; the adapter only serves metric values. KEDA is a full event-driven autoscaling framework that creates and manages HPA objects on your behalf, bundles 50+ built-in scalers (not just Prometheus — also Kafka, Redis, SQS, cron, HTTP, etc.), and adds scale-to-zero capability that native HPA cannot provide. Use the Prometheus Adapter when you already have Prometheus and want HPA to use application metrics with full HPA semantics (`behavior`, `minReplicas`, etc.). Use KEDA when you need scale-to-zero, multiple event sources without installing separate adapters, or event-driven (not metric-driven) scaling semantics.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| Prometheus Adapter — implements `custom.metrics.k8s.io` | Workloads & Scheduling (15%) | Application Deployment (20%) | metrics-server never serves `custom.metrics.k8s.io` — single most common misconception on either exam |
| ConfigMap rule structure — four required fields | Workloads & Scheduling (15%) | Application Deployment (20%) | `seriesQuery`, `resources`, `name`, `metricsQuery` all required |
| `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/...` | Troubleshooting (30%) | Application Observability and Maintenance (15%) | Primary diagnostic command for confirming adapter health and registered metric names |
| `type: Pods` HPA with a custom per-pod metric | Workloads & Scheduling (15%) | Application Deployment (20%) | Only `AverageValue` is a valid target type for `Pods` |
| `type: Object` HPA targeting an Ingress metric | Services & Networking (20%) | Services and Networking (20%) | Object type ties scaling to a non-target Kubernetes object (here, an Ingress) |
| `Value` vs `AverageValue` for Object type | Workloads & Scheduling (15%) | Application Deployment (20%) | `Value` never stabilises as pods scale; `AverageValue` does |
| Adapter troubleshooting — rule mismatch, metric not found | Troubleshooting (30%) | Application Observability and Maintenance (15%) | Check order: APIService status → adapter logs → Prometheus series → name match |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| Task expects an HPA with `type: Pods` targeting a custom metric to work as soon as metrics-server is confirmed healthy | Recognize metrics-server never serves `custom.metrics.k8s.io` — a separate adapter must be installed with a matching ConfigMap rule before any custom metric is available | Troubleshooting metrics-server health/logs when the actual gap is a missing or misconfigured Custom Metrics adapter |
| Task's HPA references `metric.name: http_requests_total` (the raw Prometheus counter name) and stays `<unknown>` even though the metric is clearly present in Prometheus | Trace the adapter ConfigMap's `name.as` field — the Custom Metrics API only exposes the transformed name (e.g. `http_requests_per_second`), and the HPA must reference that exact name | Re-checking Prometheus scrape configuration when the mismatch is actually between the HPA spec and the adapter's name-transform rule |
| Task creates an HPA with `type: Object` and `target.type: Value` against an Ingress, and expects it to stabilise as replicas increase | Recognize `Value` compares the raw object total directly to the target — Ingress request rate doesn't drop as backend pods increase — so it scales to `maxReplicas` and stays there; switch to `AverageValue` | Repeatedly raising `maxReplicas` to "give it more room," instead of changing the target type |
| Task's `resources.overrides` block maps a label name that doesn't actually exist on the Prometheus series being queried | Confirm the left-hand label name in `resources.overrides` matches an actual label present on the target Prometheus series — a mismatch produces empty results with no explicit error | Assuming the empty Custom Metrics API response means the metric hasn't been scraped yet, and waiting rather than checking the rule's label mapping |

---

## Key Takeaways

| Concept | Detail |
|---|---|
| Prometheus Adapter role | Implements `custom.metrics.k8s.io`; translates HPA metric requests to PromQL queries against Prometheus; returns results in Custom Metrics API format |
| Prometheus needs no changes | All configuration lives in the Prometheus Adapter ConfigMap; Prometheus only needs to scrape the relevant metrics |
| ConfigMap rule — seriesQuery | Prometheus label selector identifying which series this rule applies to; must include namespace and pod (or other K8s resource) labels |
| ConfigMap rule — resources.overrides | Maps Prometheus label names to Kubernetes resource names; left side = Prometheus label, right side = Kubernetes resource type |
| ConfigMap rule — name.as | The Custom Metrics API name exposed to HPA; NOT the raw Prometheus metric name; must match exactly what HPA references in `metric.name` |
| ConfigMap rule — metricsQuery | PromQL template with `<<.Series>>`, `<<.LabelMatchers>>`, `<<.GroupBy>>` variables; executed per HPA request; required field |
| Verifying adapter | `kubectl get apiservices | grep custom.metrics` (True = adapter registered); `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/` (lists all exposed metrics) |
| Object type — Value | Compares raw Ingress/object total directly to target; does NOT decrease as pods scale; causes unbounded scale-out to maxReplicas |
| Object type — AverageValue | Divides total by pod count before comparing; adding a pod reduces per-pod share; stabilises when (total / pods) ≈ target |
| Pods type — AverageValue only | `type: Pods` only supports `AverageValue` (not `Value` or `Utilization`); averaged across all pods of the target |
| `<unknown>` custom metric — check order | (1) APIService True? (2) adapter pod running? (3) adapter logs (rule errors)? (4) metric in Prometheus? (5) name matches rule.as? |
| Prometheus Adapter vs KEDA | Adapter: lean, requires Prometheus, HPA manages its own scaling. KEDA: full framework, 50+ scalers, scale-to-zero, creates/manages HPA objects |
| metrics-server scope | metrics-server NEVER serves custom.metrics.k8s.io — only metrics.k8s.io (CPU/memory) |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get apiservices \| grep custom.metrics` | Verify Prometheus Adapter registered `custom.metrics.k8s.io` (must be True) |
| `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/` | List all metric names exposed by the adapter |
| `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/\<metric-name\>"` | Get current value of a Pods-type metric |
| `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/ingresses.networking.k8s.io/\<ingress-name\>/\<metric-name\>"` | Get current value of an Object-type Ingress metric |
| `kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter` | Prometheus Adapter logs — rule errors and query failures |
| `kubectl get hpa <name> -w` | Watch HPA scaling with custom metrics |
| `kubectl describe hpa <name> \| grep -A5 "Metrics:\|Conditions:"` | Current metric value and any scaling errors |
| `helm upgrade prometheus-adapter prometheus-community/prometheus-adapter -n monitoring -f values.yaml` | Update adapter ConfigMap rules |

---

## Troubleshooting

**`kubectl get apiservices | grep custom.metrics` shows False:**
```bash
kubectl get pods -n monitoring | grep adapter
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-adapter | tail -20
# Adapter pod not running, or failed to connect to Prometheus
# Verify serverAddress in Helm values matches the Prometheus service name:
kubectl get svc -n monitoring | grep prometheus
```

**`kubectl get --raw` returns 404 for expected metric:**
```bash
# Metric not registered — adapter rule problem
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/ | python3 -m json.tool | grep name
# If metric name not listed: seriesQuery in ConfigMap matches no Prometheus series
# Port-forward to Prometheus and verify the series exists:
# curl 'http://localhost:9090/api/v1/series?match[]=http_requests_total'
```

**HPA shows `<unknown>` for custom metric:**
```bash
kubectl describe hpa <name> | grep -A5 "Conditions:"
# FailedGetPodsMetric: "no metrics returned" -> adapter rule matches no series
# FailedGetPodsMetric: "unable to get metric <name>" -> metric name in HPA
#   does not match rule name.as — check exact spelling (case-sensitive)
```

**HPA with Object type scales to maxReplicas and stays there:**
```bash
kubectl describe hpa <name> | grep -A5 "Metrics:"
# If using target.type: Value: change to AverageValue
# Value compares raw Ingress total (doesn't decrease with more pods)
# AverageValue divides by pod count and stabilises
```

**Prometheus not scraping application pods:**
```bash
# Check pod annotations
kubectl describe pod -l app=sample-app | grep prometheus
# Must have: prometheus.io/scrape=true, prometheus.io/port, prometheus.io/path
# Verify in Prometheus UI: Status -> Targets -> look for the pod
```

---

## Appendix — Anki Cards

**`05-prometheus-adapter-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::05-prometheus-adapter
#separator:Comma
#columns:Front,Back,Tags
"What does the Prometheus Adapter do, and why can HPA not query Prometheus directly?","Prometheus Adapter implements custom.metrics.k8s.io. It translates HPA's Custom Metrics API requests into PromQL queries against Prometheus and returns results in Custom Metrics API format. HPA speaks the Kubernetes Custom Metrics API protocol; Prometheus speaks its own HTTP/PromQL API — they are incompatible. The adapter bridges them. Prometheus itself needs no configuration changes.","05-prometheus-adapter,architecture"
"Name the four required fields in a Prometheus Adapter ConfigMap rule and what each does.","seriesQuery: Prometheus label selector — identifies which series this rule applies to. resources.overrides: maps Prometheus label names to Kubernetes resource names (left=Prometheus label, right=K8s resource type). name.as: the Custom Metrics API name exposed to HPA (NOT the raw Prometheus metric name). metricsQuery: PromQL template with <<.Series>>, <<.LabelMatchers>>, <<.GroupBy>> variables — executed per HPA request.","05-prometheus-adapter,configmap-rules"
"An HPA references metric.name: http_requests_per_second but the Prometheus metric is http_requests_total. How does the adapter bridge this?","The adapter ConfigMap rule's name field transforms Prometheus metric names to Custom Metrics API names. name.matches: captures the base name from http_requests_total; name.as: outputs http_requests_per_second. The HPA references the name.as value; the adapter internally knows to query http_requests_total via the rule's metricsQuery. The two names do not need to match.","05-prometheus-adapter,configmap-rules,naming"
"How do you verify that custom.metrics.k8s.io is registered and serving a specific metric?","Two commands: (1) kubectl get apiservices | grep custom.metrics — must show True. (2) kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second — returns MetricValueList with current values if the adapter is serving the metric. Empty items or 404 means the adapter rule matches no Prometheus series.","05-prometheus-adapter,troubleshooting,commands"
"An HPA with type: Object and target.type: Value keeps scaling to maxReplicas despite no load increase. Why, and how do you fix it?","Value compares the raw Ingress total directly to the target. Adding backend pods does not reduce the Ingress total — traffic still arrives at the same total rate. HPA sees the metric always above the target and keeps scaling. Fix: change to target.type: AverageValue — this divides the total by current pod count before comparing. Adding a pod reduces the per-pod share, which eventually equals the target and stabilises scaling.","05-prometheus-adapter,object-type,value-vs-avgvalue"
"What is the difference between type: Pods and type: Object HPA metrics, given both use the Custom Metrics API?","Pods: per-pod metric; adapter returns one value per pod of the target; HPA averages them; only AverageValue target type valid. Object: single metric from one named Kubernetes object (via describedObject); adapter returns one aggregate value; Value or AverageValue target types valid. Pods metric is owned by the pod; Object metric is owned by a different object (e.g. Ingress) that may not be the thing being scaled.","05-prometheus-adapter,pods-type,object-type"
"Does metrics-server serve custom.metrics.k8s.io?","No. metrics-server only serves metrics.k8s.io — CPU and memory via the Resource Metrics API. custom.metrics.k8s.io requires a separate adapter (Prometheus Adapter, KEDA, Datadog Cluster Agent, etc.). This is the most common misconception in HPA custom metrics questions.","05-prometheus-adapter,metrics-server,common-mistake"
"kubectl describe hpa shows FailedGetPodsMetric: no metrics returned from custom metrics API. What are the three most likely causes?","(1) Prometheus adapter rule seriesQuery matches no series in Prometheus — the metric has not been scraped or the label selectors are wrong. (2) HPA metric.name does not match the adapter rule name.as — names must match exactly (case-sensitive). (3) The adapter ConfigMap rule has a missing or invalid field (e.g. no metricsQuery) causing the adapter to skip the rule.","05-prometheus-adapter,troubleshooting,unknown-metric"
"What does resources.overrides do in the Prometheus Adapter ConfigMap rule?","Maps Prometheus label names to Kubernetes resource types. This tells the adapter which Kubernetes object each metric belongs to. For example: pod: {resource: pod} maps the Prometheus 'pod' label to Kubernetes pod resources. For non-core resources like Ingress: ingress: {group: networking.k8s.io, resource: ingresses}. Without this mapping, the adapter cannot link the metric to a Kubernetes object and returns empty results.","05-prometheus-adapter,configmap-rules,resources-overrides"
"What Prometheus configuration is needed to support HPA via Prometheus Adapter?","Nothing. Prometheus only needs to already be scraping the relevant application metrics. All HPA integration configuration lives in the Prometheus Adapter ConfigMap. Prometheus has no awareness of HPA, the Custom Metrics API, or the adapter.","05-prometheus-adapter,prometheus-config"
"How do the Prometheus Adapter and KEDA differ for custom metric HPA scaling?","Prometheus Adapter: implements custom.metrics.k8s.io only via Prometheus backend; HPA creates and manages its own scaling objects; no scale-to-zero. KEDA: full event-driven framework; bundles 50+ scalers (Prometheus, Redis, Kafka, SQS, cron, etc.); creates and manages HPA objects on your behalf; supports scale-to-zero. Use Adapter when you only need Prometheus metrics with standard HPA semantics. Use KEDA for scale-to-zero, multiple event sources, or event-driven workloads.","05-prometheus-adapter,keda,comparison"
"(CKA/CKAD) An HPA with type: Pods shows <unknown> for http_requests_per_second. kubectl get apiservices shows custom.metrics.k8s.io=True. kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/ shows the metric is listed. What should you check next?","The metric name in the HPA spec (metric.name) may not exactly match the name listed in the Custom Metrics API. Check kubectl describe hpa for the exact error message. Verify: (1) spelling and case match the adapter rule name.as exactly; (2) the metric is listed under the correct namespace and resource type; (3) the Prometheus time series has recent data (rate() returns 0 if series is stale).","05-prometheus-adapter,cka-troubleshooting,ckad-observability-maintenance,troubleshooting"
```

---

## Appendix — Quiz

````markdown
# Quiz — 11-auto-scaling/05-prometheus-adapter: HPA with Custom Metrics via Prometheus Adapter

> One correct answer per question unless stated otherwise.
> Target: 10/12 or above before moving to 06-cluster-autoscaler.

**Q1. HPA cannot query Prometheus directly. What component bridges them?**

A. metrics-server
B. kube-apiserver
C. Prometheus Adapter
D. kube-prometheus-stack

<details>
<summary>Answer</summary>

**C** — The Prometheus Adapter implements `custom.metrics.k8s.io`, translates HPA's metric requests to PromQL, queries Prometheus, and returns results in Custom Metrics API format.

Trap A: metrics-server serves `metrics.k8s.io` (CPU/memory only) — not custom metrics. Trap B: kube-apiserver proxies requests to the adapter but does not implement the metrics logic. Trap D: kube-prometheus-stack installs Prometheus; it does not bridge to HPA.

</details>

---

**Q2. Which field in the Prometheus Adapter ConfigMap rule defines the Custom Metrics API name that HPA references?**

A. `seriesQuery`
B. `metricsQuery`
C. `name.as`
D. `resources.overrides`

<details>
<summary>Answer</summary>

**C** — `name.as` defines the Custom Metrics API name exposed to HPA. The HPA YAML's `metric.name` must match this value exactly.

Trap A: `seriesQuery` identifies which Prometheus series the rule applies to. Trap B: `metricsQuery` is the PromQL template executed when HPA requests the metric. Trap D: `resources.overrides` maps Prometheus labels to Kubernetes resource types.

</details>

---

**Q3. What does `resources.overrides: {pod: {resource: "pod"}}` do in an adapter rule?**

A. Filters the Prometheus query to only include metrics with a "pod" label
B. Maps the Prometheus "pod" label to the Kubernetes pod resource, so the adapter can link the metric to the correct pod
C. Sets the target type for the HPA metric to "pod" level
D. Restricts the metric to only work with type: Pods HPAs

<details>
<summary>Answer</summary>

**B** — `resources.overrides` maps Prometheus label names (left) to Kubernetes resource types (right). Without this, the adapter cannot determine which Kubernetes pod owns each metric value and returns empty results.

Trap A: `seriesQuery` handles filtering. Trap C: target type is set in the HPA spec, not the adapter ConfigMap. Trap D: the resource mapping enables the adapter to group results per K8s resource, regardless of HPA type.

</details>

---

**Q4. Does Prometheus need any configuration changes to support HPA via the Prometheus Adapter?**

A. Yes — you must enable the Remote Write API
B. Yes — you must add a scrape job for the HPA controller
C. No — Prometheus only needs to scrape the application metrics; all integration config is in the adapter ConfigMap
D. Yes — you must install the Prometheus Federation plugin

<details>
<summary>Answer</summary>

**C** — Prometheus needs no changes. It only needs to already be scraping the relevant metrics. All HPA integration configuration lives in the Prometheus Adapter ConfigMap.

Traps A, B, D: none of these are required or relevant for the Prometheus Adapter integration.

</details>

---

**Q5. An HPA with `type: Object` and `target.type: Value, value: "100"` targets an Ingress receiving 500 req/s. The Deployment currently has 3 pods. How many replicas will HPA target?**

A. 5 — ceil[3 × (500/100)]
B. 3 — stable (500 / 3 = 167 per pod, divide by target)
C. 15 — ceil[3 × (500/100)] = 15
D. 10 (maxReplicas capped)

<details>
<summary>Answer</summary>

**C** — `target.type: Value` compares the raw total (500) to the target (100): `desiredReplicas = ceil[3 × (500/100)] = ceil[15] = 15`. This will hit maxReplicas (whatever it is set to). Note: adding pods will NOT reduce the 500 req/s total — this will scale to maxReplicas and stay there. Answer D is correct if maxReplicas=10, but the formula gives 15.

Trap A: correct formula but wrong arithmetic. Trap B: that calculation applies to AverageValue, not Value.

</details>

---

**Q6. Same scenario but `target.type: AverageValue, averageValue: "167"`. 3 pods, Ingress receiving 500 req/s. What does HPA do?**

A. Scales to 15 pods
B. Stays at 3 pods — 500 / 3 = 167 per pod = target
C. Scales to 5 pods — ceil[3 × (500/167)]
D. Scales to 1 pod

<details>
<summary>Answer</summary>

**B** — `AverageValue` divides the total by pod count: 500 / 3 = 167 req/s per pod = target (167). Within 10% tolerance: no scaling needed. The Deployment stabilises at 3 pods.

Trap A: that is Value behaviour. Trap C: 500/167 = 2.99 → ceil = 3, not 5. Trap D: scaling down would only occur if per-pod metric < target × (1 - tolerance).

</details>

---

**Q7. `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second` returns an empty `items: []`. The adapter pod is running and APIService shows True. What is the most likely cause?**

A. The HPA has not been created yet
B. The adapter's seriesQuery matches no series in Prometheus — the metric has not been scraped or labels do not match
C. The metric name is wrong in the kubectl command
D. The Prometheus Adapter does not support the pods resource

<details>
<summary>Answer</summary>

**B** — Empty `items` with the adapter running and APIService True means the adapter found no Prometheus series matching the rule's `seriesQuery`. Either the metric has not been scraped yet, the pod label does not exist on the series, or the namespace selector is too restrictive.

Trap A: HPA creation is unrelated to the adapter serving metrics via `kubectl get --raw`. Trap C: if the name were wrong, the result would be 404, not empty items. Trap D: the pods resource is fully supported.

</details>

---

**Q8. What is the correct HPA metric type and target type for scaling a Deployment based on messages-per-second per pod, where each pod exposes its own counter?**

A. `type: Object`, `target.type: Value`
B. `type: Pods`, `target.type: AverageValue`
C. `type: External`, `target.type: AverageValue`
D. `type: Resource`, `target.type: Utilization`

<details>
<summary>Answer</summary>

**B** — `type: Pods` is for per-pod metrics (each pod exposes its own value, averaged across pods). `AverageValue` is the only valid target type for Pods — it averages the per-pod values and compares to the target.

Trap A: Object is for a single metric on one Kubernetes object, not per-pod. Trap C: External is for metrics with no Kubernetes object association (SQS, etc.). Trap D: Resource is for CPU/memory from metrics-server, not custom application metrics.

</details>

---

**Q9. `kubectl describe hpa` shows `FailedGetPodsMetric: unable to get metric http_requests_total`. The adapter is running and the metric exists in Prometheus. What is wrong?**

A. The HPA is referencing the raw Prometheus metric name instead of the adapter's name.as value
B. The adapter cannot connect to Prometheus
C. type: Pods requires the metric to be named with the pod name
D. http_requests_total is a counter and cannot be used with HPA

<details>
<summary>Answer</summary>

**A** — The adapter transforms `http_requests_total` to `http_requests_per_second` (or similar) via `name.as`. The Custom Metrics API only knows the transformed name. The HPA must reference `http_requests_per_second` (the `name.as` value), not `http_requests_total` (the raw Prometheus name).

Trap B: if the adapter couldn't connect to Prometheus, APIService would show False. Trap C: no such naming requirement exists. Trap D: counters are the most common metric type for rate-based HPA scaling via rate().

</details>

---

**Q10. Which of these is NOT a valid target.type for `type: Pods` metrics?**

A. AverageValue
B. Value
C. Utilization

<details>
<summary>Answer</summary>

Both **B and C** are invalid for Pods type — but since the question asks for NOT valid (singular), the answer most likely intended is **C (Utilization)**. To be precise: `type: Pods` only supports `AverageValue`. Neither `Value` nor `Utilization` is valid for Pods type. `Value` is valid for Object and External. `Utilization` is only valid for Resource and ContainerResource.

</details>

---

**Q11. (CKA/CKAD-style) You installed the Prometheus Adapter and `kubectl get apiservices` shows `v1beta1.custom.metrics.k8s.io=True`. But `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/` returns an empty list. What does this tell you?**

A. The adapter is not running
B. The adapter is running and registered, but no ConfigMap rules matched any Prometheus series — no metrics are being exposed
C. kube-apiserver is not proxying to the adapter
D. Prometheus is not running

<details>
<summary>Answer</summary>

**B** — APIService `True` confirms the adapter is registered and reachable. An empty metrics list means the adapter has no rules that matched any Prometheus series — either the ConfigMap has no rules, the `seriesQuery` labels match nothing in Prometheus, or Prometheus has not yet scraped the relevant metrics.

Trap A: if the adapter were not running, APIService would show False. Trap C: if kube-apiserver could not proxy, APIService would show False or the command would error. Trap D: Prometheus being down would not affect APIService registration (adapter registers at startup).

</details>

---

**Q12. (CKA/CKAD-style) After applying an Ingress and configuring a Prometheus Adapter Object-type rule, you notice the nginx_ingress_requests_per_second metric appears in `/apis/custom.metrics.k8s.io/v1beta1/` but the HPA shows `<unknown>`. The HPA spec shows `describedObject.kind: Ingress, name: my-ingress`. What should you check?**

A. Whether the Ingress exists in the same namespace as the HPA
B. Whether metrics-server is running
C. Whether the Deployment has resource requests set
D. Whether the Prometheus Adapter is installed in kube-system

<details>
<summary>Answer</summary>

**A** — The HPA, scaleTargetRef, and `describedObject` must all be in the same namespace. If the Ingress is in a different namespace than the HPA, the adapter cannot find it and returns `<unknown>`. Check: `kubectl get ingress -A` to confirm the namespace, and ensure the HPA is created in the same namespace.

Trap B: metrics-server serves `metrics.k8s.io`, not custom metrics — irrelevant here. Trap C: resource requests affect Resource/ContainerResource HPA, not custom Object metrics. Trap D: the adapter namespace (monitoring) is independent of whether it serves cross-namespace metrics — the HPA/object namespace match is what matters.

</details>

---

| Score | Action |
|---|---|
| 12/12 | Import Anki cards, move to next Demo |
| 11/12 | Review the wrong answer, then proceed |
| 10/12 | Re-read the relevant Concepts section, retry those questions |
| Below 10/12 | Re-read the full lab and redo the walkthrough before proceeding |
````
