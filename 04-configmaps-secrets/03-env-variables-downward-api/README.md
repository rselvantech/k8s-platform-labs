# Demo: 04-configmaps-secrets/03-env-variables-downward-api — Environment Variables & Downward API

## Lab Overview

This demo covers topics deliberately **not** included in
`01-core-concepts/03-pod-container-basics`'s pod/container basics
coverage: how `envFrom` and explicit `env` entries resolve key
collisions, the exact scope rules (and one genuine blind spot) of
`$(VAR_NAME)` substitution, the full Downward API field catalogue beyond
the single example shown earlier in this series, and — critically — the
one real reason to prefer Downward API **volumes** over Downward API
**env vars**: live updates for labels and annotations that change on a
running pod.

**What this lab covers:**
- `envFrom` + explicit `env` precedence rules when keys collide
- `$(VAR_NAME)` substitution scope — chain substitution and the `envFrom` blind spot
- The full Downward API field catalogue — every `fieldRef` and `resourceFieldRef` path
- Downward API via volume files — the only way to expose *all* labels, and the only way that updates live
- `projected` volumes — deliberately deferred to `04-volume-mounts`

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `02-secrets` (this demo assumes you already understand `envFrom`/`valueFrom` mechanics and the symlink-chain update mechanism from `01-configmaps`/`02-secrets` — neither is re-explained here)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the exact precedence order when `envFrom` sources and explicit `env` entries share a key
2. ✅ Explain `$(VAR_NAME)` substitution's scope rules, including the `envFrom` blind spot and the left-to-right resolution order
3. ✅ Use the full Downward API field catalogue — `fieldRef` and `resourceFieldRef` — as environment variables
4. ✅ Use Downward API as volume-mounted files, and explain exactly why that's required for live label/annotation updates
5. ✅ Explain what `resourceFieldRef`'s `divisor` field actually controls

## Directory Structure

```
04-configmaps-secrets/03-env-variables-downward-api/
├── README.md
└── src/
    ├── 01-pod-envfrom-combined.yaml      # envFrom ConfigMap + Secret, precedence demo
    ├── 02-pod-var-substitution.yaml      # $(VAR_NAME) substitution and scope
    ├── 03-pod-downward-api-env.yaml      # Full fieldRef + resourceFieldRef as env vars
    ├── 04-pod-downward-api-volume.yaml   # Downward API as volume files (live updates)
    └── break-fix/
        ├── 01-forward-reference-substitution.yaml   # Embedded inline in README — not generated on disk
        └── 02-resourcefieldref-container-typo.yaml  # Embedded inline in README — not generated on disk
```

---

## Recall Check — 02-secrets

Answer from memory before continuing — no peeking at the previous demo.

1. Is base64 encoding a meaningful security control on its own?
2. What's the one genuinely different thing about how Secret volumes are delivered compared to ConfigMap volumes?
3. Does an `Opaque` Secret enforce any required keys the way `kubernetes.io/tls` does?

<details>
<summary>Answers</summary>

1. No — it's trivially reversible; RBAC and etcd encryption at rest are the real controls.
2. `tmpfs` (RAM-backed) vs ConfigMaps' regular node-disk storage — everything else about the delivery mechanism is identical.
3. No — `Opaque` accepts anything, including nothing; required-key validation is specific to typed Secrets.

</details>

---

## Concepts

This lab covers topics not included in `01-core-concepts/03-pod-container-basics`:

- `envFrom` combining ConfigMaps and Secrets — precedence rules when keys collide
- `$(VAR_NAME)` substitution in `env[].value` — scope rules and the `envFrom` blind spot
- The full Downward API field catalogue — `fieldRef` and `resourceFieldRef`
- Downward API via **volume files** — required for live label/annotation updates
- `projected` volumes — deliberately deferred to `04-volume-mounts`

----

### Environment variable precedence

When a pod mixes `envFrom` sources and explicit `env` entries, key collisions are resolved in this order (highest to lowest):

```
explicit env[].value / env[].valueFrom   ← always wins
      ↓
envFrom[0] (first listed source)
      ↓
envFrom[1] (second listed source)
      ↓
...
```

If `envFrom` sources share a key, the **first listed source wins**. An explicit `env` entry always overrides any `envFrom` source with the same key name.

----

### `$(VAR_NAME)` substitution — scope and the envFrom blind spot

Kubernetes supports `$(VAR_NAME)` in `env[].value` to compose values from other env vars defined **in the same `env[]` list**. Resolution is left-to-right — a variable can only reference one defined before it. This demo's Break-Fix Error-1 shows exactly what happens when that ordering rule is violated.

```yaml
env:
- name: BASE_URL
  value: "https://api.example.com"
- name: HEALTH_URL
  value: "$(BASE_URL)/health"   # ✅ works — BASE_URL defined above in same env[]
```

**The envFrom blind spot:** Variables loaded via `envFrom` are NOT available for `$(VAR_NAME)` substitution in `env[].value`. Only variables explicitly defined in the same `env[]` list are in scope.

```yaml
env:
- name: GREETING
  value: "Hello from $(APP_ENV)"   # ❌ APP_ENV comes from envFrom — NOT substituted
envFrom:
- configMapRef:
    name: my-config   # APP_ENV loaded here — but NOT in scope for env[] substitution
```

If a referenced variable is not in scope, Kubernetes leaves the literal `$(APP_ENV)` string unchanged — no error, no warning.

----

### Downward API — full field catalogue

**All supported `fieldRef` paths:**

| fieldRef path                   | What it returns                |
| ------------------------------- | ------------------------------- |
| `metadata.name`                 | Pod name                       |
| `metadata.namespace`            | Pod namespace                  |
| `metadata.uid`                  | Pod UID                        |
| `metadata.labels['<KEY>']`      | Value of a specific label      |
| `metadata.annotations['<KEY>']` | Value of a specific annotation |
| `spec.nodeName`                 | Node the pod is scheduled to   |
| `spec.serviceAccountName`       | Pod's ServiceAccount name      |
| `spec.hostIP`                   | Node's primary IP              |
| `status.podIP`                  | Pod's IP address               |
| `status.podIPs`                 | All pod IPs (dual-stack)       |

**All supported `resourceFieldRef` fields:**

| resourceFieldRef resource   | What it returns          |
| ---------------------------- | ------------------------- |
| `requests.cpu`               | Container CPU request    |
| `requests.memory`            | Container memory request |
| `limits.cpu`                 | Container CPU limit      |
| `limits.memory`              | Container memory limit   |
| `requests.hugepages-<size>`  | Hugepage requests        |
| `limits.hugepages-<size>`    | Hugepage limits          |

`resourceFieldRef` requires `containerName` (which container — a typo or nonexistent container name here is exactly this demo's Break-Fix Error-2) and `divisor` (output unit: `"1m"` for millicores, `"1Mi"` for mebibytes, `"1"` for raw bytes or cores).

----

### Volume vs env var — when to use which

| Method                   | Updates live?                  | Can expose ALL labels?   | Best for                                                  |
| ------------------------ | -------------------------------- | -------------------------- | ----------------------------------------------------------- |
| `env.valueFrom.fieldRef` | ❌ No — baked at pod start      | No — one label at a time | Scalar values that don't change                           |
| `downwardAPI` volume     | ✅ Yes — same sync as ConfigMap | Yes — entire labels file  | Labels, annotations, any value that may change at runtime |

**Critical:** Labels and annotations can be updated on a running pod (`kubectl label`, `kubectl annotate`). An env var captures the value at pod start and never updates. A `downwardAPI` volume file updates automatically via the same kubelet sync mechanism as ConfigMaps (`syncFrequency`, default 1 min effective, full mechanism in `01-configmaps`). **For labels and annotations, always use the volume method if live updates matter.**

---

## Lab Step-by-Step Guide

### Step 1 — Setup, then envFrom with multiple sources and precedence

```bash
# Create the ConfigMap and Secret used throughout this demo
kubectl create configmap shared-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=OVERRIDE_ME=from-configmap

kubectl create secret generic shared-secret \
  --from-literal=API_KEY=secret-key-value \
  --from-literal=OVERRIDE_ME=from-secret

kubectl get configmap shared-config
kubectl get secret shared-secret
```
```
NAME            DATA   AGE
shared-config   3      2s
NAME            TYPE     DATA   AGE
shared-secret   Opaque   2      1s
```

This pod loads from two envFrom sources (a ConfigMap and a Secret) that share the key `OVERRIDE_ME`. The result demonstrates the first-source-wins rule and the absolute priority of explicit `env[]` entries.

**01-pod-envfrom-combined.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-envfrom-combined
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    envFrom:
    # Source 0 — ConfigMap: contributes APP_ENV, LOG_LEVEL, OVERRIDE_ME=from-configmap
    - configMapRef:
        name: shared-config
    # Source 1 — Secret: contributes API_KEY, OVERRIDE_ME=from-secret
    # OVERRIDE_ME from Secret LOSES — source 0 (ConfigMap) wins the collision
    - secretRef:
        name: shared-secret
    env:
    # Explicit env entry — wins over ALL envFrom sources, regardless of order
    - name: EXPLICIT_OVERRIDE
      value: "set-directly-in-env"
    # Uncomment to prove explicit env wins over envFrom OVERRIDE_ME:
    # - name: OVERRIDE_ME
    #   value: "explicit-wins"
  restartPolicy: Never
```

```bash
kubectl apply -f src/01-pod-envfrom-combined.yaml
kubectl wait --for=condition=Ready pod/pod-envfrom-combined --timeout=30s
```

**Verify using `printenv`:**
```bash
# Check the collision key — which source won?
kubectl exec pod-envfrom-combined -- printenv OVERRIDE_ME
```
```
from-configmap
```
**Observation:** ConfigMap value wins — it was listed first in `envFrom`. The Secret's `OVERRIDE_ME=from-secret` was silently discarded.

```bash
kubectl exec pod-envfrom-combined -- printenv APP_ENV LOG_LEVEL API_KEY
```
```
APP_ENV=production
LOG_LEVEL=info
API_KEY=secret-key-value
```

```bash
kubectl exec pod-envfrom-combined -- printenv EXPLICIT_OVERRIDE
```
```
set-directly-in-env
```
**Observation:** the explicit `env[]` value is present exactly as specified — it would win even if `envFrom` sources also had `EXPLICIT_OVERRIDE` as a key.

---

### Step 2 — Variable substitution with `$(VAR_NAME)`

This pod demonstrates `$(VAR_NAME)` substitution in `env[].value` — including chain substitution, cross-type references (from `valueFrom`-sourced vars), and the `envFrom` blind spot.

**02-pod-var-substitution.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-var-subst
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    env:
    # env[] list is resolved left-to-right — each entry can reference any above it
    - name: PROTOCOL
      value: "https"
    - name: HOST
      value: "api.example.com"
    - name: PORT
      value: "8443"
    - name: BASE_URL
      value: "$(PROTOCOL)://$(HOST):$(PORT)"   # chain: references 3 vars above
    - name: HEALTH_URL
      value: "$(BASE_URL)/health"              # chain: references the composed var above
    - name: DB_HOST
      valueFrom:
        configMapKeyRef:
          name: shared-config
          key: APP_ENV    # valueFrom-sourced var — available for substitution below
    - name: DB_URL
      value: "postgres://$(DB_HOST):5432/appdb"  # references valueFrom-sourced var ✅
    - name: GREETING
      # APP_ENV comes from envFrom below — NOT available for $(VAR_NAME) substitution
      value: "Hello from $(APP_ENV)"   # APP_ENV not in env[] — literal string in output
    envFrom:
    - configMapRef:
        name: shared-config   # APP_ENV loaded here — but NOT in scope for env[] substitution
  restartPolicy: Never
```

```bash
kubectl apply -f src/02-pod-var-substitution.yaml
kubectl wait --for=condition=Ready pod/pod-var-subst --timeout=30s
```

**Verify each substitution result:**
```bash
kubectl exec pod-var-subst -- printenv BASE_URL HEALTH_URL DB_URL GREETING
```
```
BASE_URL=https://api.example.com:8443
HEALTH_URL=https://api.example.com:8443/health
DB_URL=postgres://production:5432/appdb
GREETING=Hello from $(APP_ENV)
```
```
BASE_URL   — composed correctly from PROTOCOL, HOST, PORT (all in env[] list)
HEALTH_URL — chain substitution works — BASE_URL was defined above in env[]
DB_URL     — valueFrom-sourced var (DB_HOST=production from ConfigMap) IS in scope
GREETING   — $(APP_ENV) was NOT substituted — APP_ENV came from envFrom, not env[]
             The literal string "$(APP_ENV)" is the value — Kubernetes leaves it unchanged
```

```bash
# Confirm APP_ENV is present as an env var (from envFrom), just not available for substitution
kubectl exec pod-var-subst -- printenv APP_ENV
```
```
production
```
**Observation:** `APP_ENV` exists in the container but was NOT available for `$(VAR_NAME)` substitution in `env[].value` — demonstrating the `envFrom` blind spot.

---

### Step 3 — Full Downward API as environment variables

**03-pod-downward-api-env.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-downward-env
  namespace: default
  labels:
    app: myapp
    version: v1.2.3
    tier: backend
  annotations:
    prometheus.io/scrape: "true"
    deployment.region: "ca-central-1"
spec:
  serviceAccountName: default
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    resources:
      requests:
        cpu: "250m"
        memory: "64Mi"
      limits:
        cpu: "500m"
        memory: "128Mi"
    env:
    # --- fieldRef: pod metadata ---
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    # --- fieldRef: scheduling ---
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    - name: HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    # --- fieldRef: identity ---
    - name: SERVICE_ACCOUNT
      valueFrom:
        fieldRef:
          fieldPath: spec.serviceAccountName
    # --- fieldRef: specific label and annotation values ---
    - name: LABEL_APP
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['app']
    - name: LABEL_VERSION
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['version']
    - name: ANNOTATION_REGION
      valueFrom:
        fieldRef:
          fieldPath: metadata.annotations['deployment.region']
    # --- resourceFieldRef: container resource allocations ---
    - name: CPU_REQUEST
      valueFrom:
        resourceFieldRef:
          containerName: app
          resource: requests.cpu
          divisor: "1m"      # output in millicores: 250m → "250"
    - name: MEM_REQUEST
      valueFrom:
        resourceFieldRef:
          containerName: app
          resource: requests.memory
          divisor: "1Mi"     # output in mebibytes: 64Mi → "64"
    - name: CPU_LIMIT
      valueFrom:
        resourceFieldRef:
          containerName: app
          resource: limits.cpu
          divisor: "1m"
    - name: MEM_LIMIT
      valueFrom:
        resourceFieldRef:
          containerName: app
          resource: limits.memory
          divisor: "1Mi"
  restartPolicy: Never
```

```bash
kubectl apply -f src/03-pod-downward-api-env.yaml
kubectl wait --for=condition=Ready pod/pod-downward-env --timeout=30s
```

**Verify each category using `printenv`:**
```bash
kubectl exec pod-downward-env -- printenv POD_NAME POD_NAMESPACE POD_UID
```
```
POD_NAME=pod-downward-env
POD_NAMESPACE=default
POD_UID=<uuid>
```

```bash
kubectl exec pod-downward-env -- printenv NODE_NAME HOST_IP POD_IP
```
```
NODE_NAME=3node-m02
HOST_IP=192.168.49.3
POD_IP=10.244.x.x
```

```bash
kubectl exec pod-downward-env -- printenv LABEL_APP LABEL_VERSION ANNOTATION_REGION
```
```
LABEL_APP=myapp
LABEL_VERSION=v1.2.3
ANNOTATION_REGION=ca-central-1
```
**Observation:** only the explicitly referenced labels/annotations appear. To expose ALL labels, use a `downwardAPI` volume (Step 4).

```bash
kubectl exec pod-downward-env -- printenv CPU_REQUEST MEM_REQUEST CPU_LIMIT MEM_LIMIT
```
```
CPU_REQUEST=250
MEM_REQUEST=64
CPU_LIMIT=500
MEM_LIMIT=128
```
**Observation:** values are integers in the chosen unit. `divisor "1m"` → millicores (`250m = 250`); `divisor "1Mi"` → MiB (`64Mi = 64`). Use `divisor "1"` for raw bytes (memory) or fractional cores (CPU).

---

### Step 4 — Downward API via volume (live updates for labels and annotations)

Volume-based Downward API uses the same kubelet sync mechanism as ConfigMaps (`01-configmaps`) — files update automatically when labels or annotations change on the running pod. Env vars do not.

**04-pod-downward-api-volume.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-downward-vol
  namespace: default
  labels:
    app: myapp
    version: v1.0.0
    environment: staging
  annotations:
    build-id: "build-20260401-001"
    deployment.region: "ca-central-1"
spec:
  volumes:
  - name: pod-info
    downwardAPI:
      # defaultMode: 0444   # optional file permissions (default 0644)
      items:
      - path: "pod-name"
        fieldRef:
          fieldPath: metadata.name
      - path: "pod-namespace"
        fieldRef:
          fieldPath: metadata.namespace
      - path: "node-name"
        fieldRef:
          fieldPath: spec.nodeName
      - path: "pod-ip"
        fieldRef:
          fieldPath: status.podIP
      # labels file: ALL labels in key="value" format — one per line
      # This is the ONLY way to expose all labels (env vars expose only specific keys)
      - path: "labels"
        fieldRef:
          fieldPath: metadata.labels
      # annotations file: ALL annotations in key="value" format
      - path: "annotations"
        fieldRef:
          fieldPath: metadata.annotations
      # Resource fields work in volumes too
      - path: "cpu-request"
        resourceFieldRef:
          containerName: app
          resource: requests.cpu
          divisor: "1m"
      - path: "mem-limit"
        resourceFieldRef:
          containerName: app
          resource: limits.memory
          divisor: "1Mi"
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    resources:
      requests:
        cpu: "100m"
        memory: "32Mi"
      limits:
        cpu: "200m"
        memory: "64Mi"
    volumeMounts:
    - name: pod-info
      mountPath: /etc/podinfo
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/04-pod-downward-api-volume.yaml
kubectl wait --for=condition=Ready pod/pod-downward-vol --timeout=30s
```

**Verify the volume structure and file contents:**
```bash
kubectl exec pod-downward-vol -- ls -la /etc/podinfo/
```
```
lrwxrwxrwx    annotations -> ..data/annotations
lrwxrwxrwx    cpu-request -> ..data/cpu-request
lrwxrwxrwx    labels -> ..data/labels
lrwxrwxrwx    mem-limit -> ..data/mem-limit
lrwxrwxrwx    node-name -> ..data/node-name
lrwxrwxrwx    pod-ip -> ..data/pod-ip
lrwxrwxrwx    pod-name -> ..data/pod-name
lrwxrwxrwx    pod-namespace -> ..data/pod-namespace
..data -> ..2026_04_26_...
```
**Observation:** identical symlink structure to ConfigMap volumes, covered in full in `01-configmaps`. Each projected field is a symlink into `..data/`. The same atomic `rename()` mechanism applies — nothing new to learn about the mechanism itself here.

```bash
kubectl exec pod-downward-vol -- cat /etc/podinfo/pod-name
# pod-downward-vol
kubectl exec pod-downward-vol -- cat /etc/podinfo/node-name
# 3node-m02
kubectl exec pod-downward-vol -- cat /etc/podinfo/cpu-request
# 100
```

```bash
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
```
```
app="myapp"
environment="staging"
version="v1.0.0"
```
**Observation:** ALL labels are present in a single file, sorted alphabetically. Format is `key="value"` per line — different from env var format (`KEY=value`). This is the only way to expose all labels in one place.

```bash
kubectl exec pod-downward-vol -- cat /etc/podinfo/annotations
```
```
build-id="build-20260401-001"
deployment.region="ca-central-1"
kubectl.kubernetes.io/last-applied-configuration="..."
```
**Observation:** ALL annotations are present, including the internal `last-applied-configuration` annotation added by `kubectl apply`. This is normal — filter in the application if needed.

**Test live label update — the key advantage of volume over env var:**
```bash
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
# app="myapp"
# environment="staging"
# version="v1.0.0"

kubectl label pod pod-downward-vol release=stable
# pod/pod-downward-vol labeled

# Wait 30–90 seconds for kubelet sync (effective default 1 minute, per 01-configmaps)
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
```
```
app="myapp"
environment="staging"
release="stable"
version="v1.0.0"
```
**Observation:** the new label appeared without restarting the pod — the same kubelet sync mechanism from `01-configmaps`. An env var capturing `metadata.labels['release']` would still show nothing, since that field didn't exist when the pod started — env vars don't update.

```bash
kubectl annotate pod pod-downward-vol build-id=build-99999 --overwrite
# wait for sync
kubectl exec pod-downward-vol -- cat /etc/podinfo/annotations | grep build-id
# build-id="build-99999"
```
**Observation:** annotation updated in the volume file without pod restart.

---

### Step 5 — Cleanup

```bash
kubectl delete pod pod-envfrom-combined pod-var-subst pod-downward-env pod-downward-vol \
  2>/dev/null || true
kubectl delete configmap shared-config 2>/dev/null || true
kubectl delete secret shared-secret 2>/dev/null || true
```

---

## What You Learned

In this lab, you:
- ✅ Explained the exact envFrom/env precedence order when keys collide across multiple sources
- ✅ Explained `$(VAR_NAME)`'s left-to-right resolution and the envFrom blind spot — and what happens when a substitution can't be resolved (literal string left unchanged, no error)
- ✅ Used the full `fieldRef` and `resourceFieldRef` catalogue as environment variables
- ✅ Used Downward API as volume-mounted files, and proved live updates for labels and annotations directly
- ✅ Understood `resourceFieldRef`'s `divisor` field and its effect on output units

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

This scenario reproduces the left-to-right resolution rule from Concepts — referencing a variable that's defined *later* in the `env[]` list, rather than earlier.

**`src/break-fix/01-forward-reference-substitution.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: forward-ref-broken
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    env:
    - name: GREETING
      value: "Hello, $(USERNAME)!"   # USERNAME is defined BELOW — forward reference
    - name: USERNAME
      value: "admin"
  restartPolicy: Never
```

```bash
kubectl apply -f 01-forward-reference-substitution.yaml
kubectl wait --for=condition=Ready pod/forward-ref-broken --timeout=30s
kubectl exec forward-ref-broken -- printenv GREETING
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `$(VAR_NAME)` substitution resolves strictly left-to-right —
`GREETING` is defined *before* `USERNAME` in the `env[]` list, so
`USERNAME` isn't in scope yet at the point `GREETING` is being resolved.

**Fix:** Reorder the list so `USERNAME` comes before `GREETING`.

**Cascade:** There is **no error at all** — the pod starts and runs
completely normally. `printenv GREETING` simply returns the literal
string `Hello, $(USERNAME)!` unresolved, exactly as documented in
Concepts for the `envFrom` blind spot case — this is the same "silently
leave it unchanged" behavior, just triggered by ordering instead of
source type. This makes it a genuinely easy bug to ship unnoticed, since
nothing in `kubectl get pods`/`describe` flags it.

</details>

**Cleanup:**
```bash
kubectl delete pod forward-ref-broken 2>/dev/null || true
```

---

### Error-2

This scenario reproduces a `resourceFieldRef` pointing at a container name that doesn't exist in the pod.

**`src/break-fix/02-resourcefieldref-container-typo.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resourcefieldref-typo
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    resources:
      requests:
        cpu: "100m"
        memory: "32Mi"
    env:
    - name: CPU_REQUEST
      valueFrom:
        resourceFieldRef:
          containerName: ap    # typo — the real container is named "app"
          resource: requests.cpu
          divisor: "1m"
  restartPolicy: Never
```

```bash
kubectl apply -f 02-resourcefieldref-container-typo.yaml
kubectl get pods
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `resourceFieldRef.containerName` must exactly match a
container name defined in the same pod — `ap` doesn't match the real
container name `app`. Unlike the previous error, this one genuinely
prevents the container from starting at all.

**Fix:** Correct `containerName` to `app`.

**Cascade:** `kubectl get pods` shows `CreateContainerConfigError` —
the same failure mode already seen for a missing ConfigMap/Secret key
in `01-configmaps`/`02-secrets`, just triggered by a different cause
(a typo'd container name instead of a missing config source). `kubectl
describe pod` shows an event naming the invalid container reference
directly.

</details>

**Cleanup:**
```bash
kubectl delete pod resourcefieldref-typo 2>/dev/null || true
```

---

## Interview Prep

**Q: Two `envFrom` sources and an explicit `env` entry all define the same key. Which one wins?**
A: The explicit `env` entry always wins, regardless of ordering. Among `envFrom` sources with no matching explicit `env` entry, the first-listed source wins any collision.

**Q: Does `$(VAR_NAME)` see variables loaded via `envFrom`?**
A: No — this is the `envFrom` blind spot. Only variables explicitly declared in the same `env[]` list are in scope, resolved strictly left-to-right. A reference to an `envFrom`-loaded variable, or to one defined later in the list, is silently left as the literal unresolved string — no error either way.

**Q: What's the only way to expose all of a pod's labels to the application, and why does it have to be that way?**
A: A `downwardAPI` volume with `fieldPath: metadata.labels` — env vars via `fieldRef` can only expose one specific label key at a time (`metadata.labels['key']`), there's no "all labels" env var form. The volume form is also the only one that updates live if labels change on the running pod.

**Q: What does `resourceFieldRef`'s `divisor` field actually do?**
A: It controls the unit the resulting value is expressed in — `"1m"` gives millicores as an integer, `"1Mi"` gives mebibytes as an integer, `"1"` gives raw bytes (memory) or whole/fractional cores (CPU). Without understanding `divisor`, a `250m` CPU request could show up as a confusing `0` or `250` depending on which divisor was chosen.

**Q: If a `resourceFieldRef` names a container that doesn't exist in the pod, what happens?**
A: The pod fails to start with `CreateContainerConfigError` — the same failure class as a missing ConfigMap/Secret reference, just triggered by an invalid `containerName` instead.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Environment, Configuration and Security | CKAD | 25% | `envFrom`/`env` precedence, Downward API (both forms) |
| Application Observability and Maintenance | CKAD | 15% | `resourceFieldRef` for exposing resource allocations |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Assuming `envFrom` order doesn't matter | It does — first-listed source wins on key collisions, a common source of "which value actually won" confusion |
| Referencing an `envFrom`-loaded variable in `$(VAR_NAME)` | Silently unresolved, no error — easy to ship without noticing |
| Forgetting `$(VAR_NAME)` resolves strictly left-to-right | A forward reference (referencing a variable defined later) silently fails the same way as the `envFrom` blind spot |
| Trying to expose all labels via individual `fieldRef` entries | There's no "all labels" env var form — only a `downwardAPI` volume with `fieldPath: metadata.labels` does this |
| Forgetting `divisor` changes the output entirely | `"1m"` vs `"1Mi"` vs `"1"` produce very different-looking numbers for the same underlying resource value |

### Exam Task — Write it from scratch

Create a Pod that exposes its own name, namespace, and node name as environment variables via the Downward API, and separately exposes all of its labels as a volume-mounted file.

Official docs: [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)

<details>
<summary>Reveal solution</summary>

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: exam-pod
  labels:
    app: exam
spec:
  volumes:
    - name: pod-info
      downwardAPI:
        items:
          - path: "labels"
            fieldRef:
              fieldPath: metadata.labels
  containers:
    - name: app
      image: busybox:1.38.0
      command: ["sh", "-c", "sleep 3600"]
      env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      volumeMounts:
        - name: pod-info
          mountPath: /etc/podinfo
```

**Key fields to recall:** `env[].valueFrom.fieldRef.fieldPath` for scalar values, `volumes[].downwardAPI.items[].fieldRef.fieldPath: metadata.labels` for the all-labels file form.

</details>

---

## Key Takeaways

| Concept                            | Detail                                                                                         |
| ---------------------------------- | ---------------------------------------------------------------------------------------------- |
| envFrom precedence                 | First listed source wins on key collision; explicit `env[]` always beats all `envFrom` sources |
| `$(VAR_NAME)` scope                | Only resolves vars explicitly in the same `env[]` list; `envFrom`-loaded vars are NOT in scope |
| `$(VAR_NAME)` resolution order     | Strictly left-to-right — a forward reference to a variable defined later silently fails the same way as the envFrom blind spot |
| Undefined/unresolvable var         | If `$(VAR_NAME)` cannot be resolved, the literal string `$(VAR_NAME)` is used — no error, either cause |
| `fieldRef` metadata                | pod name, namespace, uid, nodeName, hostIP, podIP, serviceAccountName                          |
| `fieldRef` single label/annotation | `metadata.labels['key']` — only one at a time; does not update live                            |
| `resourceFieldRef` divisor         | `"1m"` → millicores integer; `"1Mi"` → MiB integer; `"1"` → raw bytes or fractional cores      |
| `resourceFieldRef` bad containerName | Causes `CreateContainerConfigError` — same failure class as a missing ConfigMap/Secret key |
| Volume vs env for labels           | Volume: ALL labels in one file, updates live; Env: one label per var, frozen at pod start      |
| `metadata.labels` file format      | `key="value"` per line, sorted alphabetically — note the quoted value format                   |
| downwardAPI volume sync            | Same kubelet `syncFrequency` mechanism as ConfigMap volumes (`01-configmaps`) — effective default 1 min |
| `printenv` for verification        | Always use `kubectl exec -- printenv KEY` to verify env vars; not pod logs                     |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl exec <pod> -- printenv <KEY>` | Verify a specific env var's value |
| `kubectl exec <pod> -- printenv \| sort` | List all env vars in a container |
| `kubectl label pod <name> <key>=<value>` | Add/update a label on a running pod — test live volume updates |
| `kubectl annotate pod <name> <key>=<value> --overwrite` | Add/update an annotation on a running pod |
| `kubectl exec <pod> -- cat <mountPath>/labels` | Read the all-labels Downward API volume file |
| `kubectl explain pod.spec.containers.env.valueFrom.resourceFieldRef` | Field reference for `resourceFieldRef` |

This demo is entirely about consumption patterns for objects already
created in earlier demos — no new imperative creation technique applies
here beyond what `01-configmaps`/`02-secrets` already covered.

---

## Troubleshooting

**A `$(VAR_NAME)` substitution isn't resolving:**
```bash
kubectl exec <pod> -- printenv <VAR_NAME_using_the_substitution>
# If the output contains the literal "$(...)" text, the referenced variable
# either came from envFrom (out of scope) or is defined LATER in the env[]
# list (forward reference) — see this demo's Break-Fix Error-1
```

**A `resourceFieldRef`-based env var causes `CreateContainerConfigError`:**
```bash
kubectl describe pod <name>
# Check Events for a message naming the container — usually a containerName typo,
# see this demo's Break-Fix Error-2
```

**Labels/annotations aren't showing up in a volume file:**
```bash
# Confirm you're checking the VOLUME mount, not an env var — env vars never update live
# Confirm you waited a full syncFrequency window (effective default 1 min, per 01-configmaps)
kubectl exec <pod> -- cat <mountPath>/labels
```

---

## Appendix — Anki Cards

**`03-env-variables-downward-api-anki.csv`:**

````
#deck:k8s-platform-labs::04-configmaps-secrets::03-env-variables-downward-api
#separator:Comma
#columns:Front,Back,Tags
"If envFrom sources and an explicit env entry share a key, which wins?","The explicit env entry always wins; among envFrom sources with no matching explicit entry, the first-listed source wins any collision.","demo03-cms,precedence,ckad-application-environment-configuration-security"
"Does $(VAR_NAME) substitution see variables loaded via envFrom?","No — this is the envFrom blind spot. Only variables explicitly declared in the same env[] list are in scope.","demo03-cms,var-substitution,ckad-application-environment-configuration-security"
"In what order does $(VAR_NAME) resolve variables in the env[] list?","Strictly left-to-right — a variable can only reference one defined earlier in the same list, not one defined later.","demo03-cms,var-substitution,ckad-application-environment-configuration-security"
"What happens if $(VAR_NAME) can't be resolved, whether due to scope or ordering?","The literal string $(VAR_NAME) is left unchanged — no error, no warning, in either failure case.","demo03-cms,var-substitution,cka-troubleshooting"
"Is there a Downward API env var form that exposes ALL of a pod's labels at once?","No — env vars via fieldRef only expose one specific label key at a time; only a downwardAPI volume with fieldPath: metadata.labels exposes all of them.","demo03-cms,downward-api,ckad-application-environment-configuration-security"
"What does resourceFieldRef's divisor field control?","The unit the resulting value is expressed in — '1m' for millicores, '1Mi' for mebibytes, '1' for raw bytes or fractional cores.","demo03-cms,downward-api,resourcefieldref,ckad-application-environment-configuration-security"
"What happens if resourceFieldRef.containerName doesn't match any container in the pod?","The pod fails to start with CreateContainerConfigError — the same failure class as a missing ConfigMap/Secret key reference.","demo03-cms,downward-api,troubleshooting,cka-troubleshooting"
"Do labels/annotations exposed via env var update if you kubectl label the running pod?","No — env vars are frozen at pod start regardless of source; only a downwardAPI volume file updates live, via the same kubelet sync mechanism as ConfigMaps.","demo03-cms,downward-api,update-propagation,ckad-application-environment-configuration-security"
"What format does the metadata.labels Downward API volume file use?","key=\"value\" per line, sorted alphabetically — different from the KEY=value format env vars use.","demo03-cms,downward-api,cka-services-networking"
````

---

## Appendix — Quiz

**`03-env-variables-downward-api-quiz.md`:**

````markdown
# Quiz — 04-configmaps-secrets/03-env-variables-downward-api: Environment Variables & Downward API

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Two `envFrom` sources share a key, and there's no matching explicit `env` entry. Which value wins?**

- A) The last-listed source
- B) The first-listed source
- C) They're merged into one value
- D) Neither — the pod fails to start

<details>
<summary>Answer</summary>

**B** — First-listed source wins any `envFrom`-to-`envFrom` collision; an explicit `env` entry would override both, but neither exists here.
Trap: A reverses the actual precedence — a common guess given no other signal to go on.

</details>

---

**Q2. Does `$(VAR_NAME)` substitution see a variable loaded via `envFrom`?**

- A) Yes, always
- B) No — only variables explicitly declared in the same `env[]` list are in scope
- C) Only if the ConfigMap is immutable
- D) Only in volume-based Downward API

<details>
<summary>Answer</summary>

**B** — This is the documented `envFrom` blind spot — no visibility into `envFrom`-sourced variables at all.
Trap: C invents an unrelated condition (immutability) that has no bearing on substitution scope.

</details>

---

**Q3. `GREETING` (defined first) references `$(USERNAME)` (defined later, below it) in the same `env[]` list. What happens?**

- A) It resolves correctly — order doesn't matter
- B) It silently fails to resolve — the literal `$(USERNAME)` string is kept, no error
- C) The pod fails validation at apply time
- D) `USERNAME` is automatically moved earlier in the list

<details>
<summary>Answer</summary>

**B** — Resolution is strictly left-to-right; a forward reference fails the exact same silent way as the `envFrom` blind spot.
Trap: C assumes some ordering validation exists — there isn't one; the pod applies and runs completely normally, just with the wrong value.

</details>

---

**Q4. Is there a way to expose ALL of a pod's labels as a single environment variable?**

- A) Yes, via `metadata.labels` as a fieldRef
- B) No — env vars via fieldRef only expose one label key at a time; only a downwardAPI volume exposes all of them
- C) Yes, but only for pods with fewer than 10 labels
- D) Yes, using `envFrom` with a special labels flag

<details>
<summary>Answer</summary>

**B** — There's no "all labels" env var form at all — `metadata.labels['key']` only ever returns one specific key's value.
Trap: A is a very natural-sounding but incorrect guess, since `metadata.labels` alone (without a specific key) isn't a valid `fieldRef` path for an env var.

</details>

---

**Q5. What does `resourceFieldRef`'s `divisor: "1Mi"` actually produce?**

- A) The value in raw bytes
- B) The value expressed as an integer in mebibytes
- C) The value as a percentage of node capacity
- D) The value in millicores

<details>
<summary>Answer</summary>

**B** — `"1Mi"` gives you MiB as an integer — e.g. a `64Mi` memory request shows up as `64`.
Trap: D confuses this with the CPU-oriented `"1m"` divisor — the two are for different resource types with different natural units.

</details>

---

**Q6. A `resourceFieldRef` names `containerName: ap` but the actual container is named `app`. What happens?**

- A) Kubernetes fuzzy-matches the closest container name
- B) The pod fails to start with `CreateContainerConfigError`
- C) The value defaults to `0`
- D) The Pod object is rejected at apply time

<details>
<summary>Answer</summary>

**B** — Same failure class as a missing ConfigMap/Secret key — the container simply can't start because a required reference is invalid.
Trap: D assumes apply-time validation catches this — it doesn't; the object is accepted, and the failure only surfaces once the kubelet tries to actually start the container.

</details>

---

**Q7. You `kubectl label` a running pod that consumes `metadata.labels['release']` via an env var (not a volume). Does the env var update?**

- A) Yes, within the next sync cycle
- B) No — env vars are frozen at pod start regardless of which field they reference
- C) Yes, immediately
- D) Only if the label existed at pod creation time already

<details>
<summary>Answer</summary>

**B** — This applies universally to env-var Downward API consumption — there's no live-update path for env vars at all, only for volumes.
Trap: D is a near-miss — even a label that existed at creation and gets its *value* changed afterward still won't update in an env var.

</details>

---

**Q8. What format does the `metadata.labels` Downward API volume file use?**

- A) `KEY=value`, same as environment variables
- B) `key="value"` per line, sorted alphabetically
- C) JSON
- D) YAML

<details>
<summary>Answer</summary>

**B** — Note the quoted value and the different casing convention from env vars — a subtle but real formatting difference worth knowing if your app parses this file.
Trap: A assumes the same format as env vars, which is a reasonable but incorrect guess given how similar the two consumption methods otherwise are.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````