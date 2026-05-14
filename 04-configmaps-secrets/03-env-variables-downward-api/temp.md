# 03 — Environment Variables & Downward API

## Concepts

This lab covers topics not included in `01-core-concepts/03-pod-container-basics`:

- `envFrom` combining ConfigMaps and Secrets — precedence rules when keys collide
- `$(VAR_NAME)` substitution in `env[].value` — scope rules and the envFrom blind spot
- The full Downward API field catalogue — `fieldRef` and `resourceFieldRef`
- Downward API via **volume files** — required for live label/annotation updates
- `projected` volumes — covered in `04-volume-mounts`

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

### `$(VAR_NAME)` substitution — scope and the envFrom blind spot

Kubernetes supports `$(VAR_NAME)` in `env[].value` to compose values from other env vars defined **in the same `env[]` list**. Resolution is left-to-right — a variable can only reference one defined before it.

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

### Downward API — full field catalogue

#### All supported `fieldRef` paths

| fieldRef path | What it returns |
|--------------|----------------|
| `metadata.name` | Pod name |
| `metadata.namespace` | Pod namespace |
| `metadata.uid` | Pod UID |
| `metadata.labels['<KEY>']` | Value of a specific label |
| `metadata.annotations['<KEY>']` | Value of a specific annotation |
| `spec.nodeName` | Node the pod is scheduled to |
| `spec.serviceAccountName` | Pod's ServiceAccount name |
| `spec.hostIP` | Node's primary IP |
| `status.podIP` | Pod's IP address |
| `status.podIPs` | All pod IPs (dual-stack) |

#### All supported `resourceFieldRef` fields

| resourceFieldRef resource | What it returns |
|--------------------------|----------------|
| `requests.cpu` | Container CPU request |
| `requests.memory` | Container memory request |
| `limits.cpu` | Container CPU limit |
| `limits.memory` | Container memory limit |
| `requests.hugepages-<size>` | Hugepage requests |
| `limits.hugepages-<size>` | Hugepage limits |

`resourceFieldRef` requires `containerName` (which container) and `divisor` (output unit: `"1m"` for millicores, `"1Mi"` for mebibytes, `"1"` for raw bytes or cores).

#### Volume vs env var — when to use which

| Method | Updates live? | Can expose ALL labels? | Best for |
|--------|--------------|----------------------|---------|
| `env.valueFrom.fieldRef` | ❌ No — baked at pod start | No — one label at a time | Scalar values that don't change |
| `downwardAPI` volume | ✅ Yes — same sync as ConfigMap | Yes — entire labels file | Labels, annotations, any value that may change at runtime |

**Critical:** Labels and annotations can be updated on a running pod (`kubectl label`, `kubectl annotate`). An env var captures the value at pod start and never updates. A `downwardAPI` volume file updates automatically via the same kubelet sync mechanism as ConfigMaps (`syncFrequency`, default 1 min effective). **For labels and annotations, always use the volume method if live updates matter.**

---

## Directory Structure

```
03-env-variables-downward-api/
├── README.md
└── src/
    ├── 01-pod-envfrom-combined.yaml      # envFrom ConfigMap + Secret, precedence demo
    ├── 02-pod-var-substitution.yaml      # $(VAR_NAME) substitution and scope
    ├── 03-pod-downward-api-env.yaml      # Full fieldRef + resourceFieldRef as env vars
    └── 04-pod-downward-api-volume.yaml   # Downward API as volume files (live updates)
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Create ConfigMap and Secret used in Steps 1–2
kubectl create configmap shared-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=OVERRIDE_ME=from-configmap

kubectl create secret generic shared-secret \
  --from-literal=API_KEY=secret-key-value \
  --from-literal=OVERRIDE_ME=from-secret

# Verify both were created
kubectl get configmap shared-config
kubectl get secret shared-secret
# NAME            DATA   AGE
# shared-config   3      2s
# NAME            TYPE     DATA   AGE
# shared-secret   Opaque   2      1s
```

---

### Step 1 — envFrom with multiple sources and precedence

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
    image: busybox:1.36
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
# from-configmap
#
# Observation: ConfigMap value wins — it was listed first in envFrom.
# The Secret's OVERRIDE_ME=from-secret was silently discarded.

# Check a key unique to each source
kubectl exec pod-envfrom-combined -- printenv APP_ENV LOG_LEVEL API_KEY
# APP_ENV=production     ← from ConfigMap (envFrom[0])
# LOG_LEVEL=info         ← from ConfigMap (envFrom[0])
# API_KEY=secret-key-value  ← from Secret (envFrom[1], unique key — no collision)

# Check the explicit env entry
kubectl exec pod-envfrom-combined -- printenv EXPLICIT_OVERRIDE
# set-directly-in-env
#
# Observation: explicit env[] value is present exactly as specified.
# It would win even if envFrom sources also had EXPLICIT_OVERRIDE as a key.
```

---

### Step 2 — Variable substitution with `$(VAR_NAME)`

This pod demonstrates `$(VAR_NAME)` substitution in `env[].value` — including chain substitution, cross-type references (from valueFrom-sourced vars), and the envFrom blind spot.

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
    image: busybox:1.36
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
      # Only vars in the same env[] list are in scope for substitution
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
# BASE_URL=https://api.example.com:8443
# HEALTH_URL=https://api.example.com:8443/health
# DB_URL=postgres://production:5432/appdb
# GREETING=Hello from $(APP_ENV)
#
# Observation:
# BASE_URL   — composed correctly from PROTOCOL, HOST, PORT (all in env[] list)
# HEALTH_URL — chain substitution works — BASE_URL was defined above in env[]
# DB_URL     — valueFrom-sourced var (DB_HOST=production from ConfigMap) IS in scope
# GREETING   — $(APP_ENV) was NOT substituted — APP_ENV came from envFrom, not env[]
#              The literal string "$(APP_ENV)" is the value — Kubernetes leaves it unchanged

# Confirm APP_ENV is present as an env var (from envFrom), just not available for substitution
kubectl exec pod-var-subst -- printenv APP_ENV
# production
#
# Observation: APP_ENV exists in the container but was NOT available for $(VAR_NAME)
# substitution in env[].value — demonstrating the envFrom blind spot.
```

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
    image: busybox:1.36
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
# Pod identity
kubectl exec pod-downward-env -- printenv POD_NAME POD_NAMESPACE POD_UID
# POD_NAME=pod-downward-env
# POD_NAMESPACE=default
# POD_UID=<uuid>   ← actual UID assigned by Kubernetes

# Scheduling info — confirms which node the pod landed on
kubectl exec pod-downward-env -- printenv NODE_NAME HOST_IP POD_IP
# NODE_NAME=3node-m02        ← worker node name
# HOST_IP=192.168.49.3       ← node's IP address
# POD_IP=10.244.x.x          ← pod's cluster-internal IP

# Labels and annotations — only specific keys, not all
kubectl exec pod-downward-env -- printenv LABEL_APP LABEL_VERSION ANNOTATION_REGION
# LABEL_APP=myapp
# LABEL_VERSION=v1.2.3
# ANNOTATION_REGION=ca-central-1
#
# Observation: only the explicitly referenced labels/annotations appear.
# To expose ALL labels, use a downwardAPI volume (Step 4).

# Resource allocations — divisor controls the output unit
kubectl exec pod-downward-env -- printenv CPU_REQUEST MEM_REQUEST CPU_LIMIT MEM_LIMIT
# CPU_REQUEST=250    ← 250m millicores (divisor "1m" → integer millicores)
# MEM_REQUEST=64     ← 64 MiB (divisor "1Mi" → integer mebibytes)
# CPU_LIMIT=500
# MEM_LIMIT=128
#
# Observation: values are integers in the chosen unit.
# divisor "1m" → millicores (250m = 250); divisor "1Mi" → MiB (64Mi = 64)
# Use divisor "1" for raw bytes (memory) or fractional cores (CPU)
```

---

### Step 4 — Downward API via volume (live updates for labels and annotations)

Volume-based Downward API uses the same kubelet sync mechanism as ConfigMaps — files update automatically when labels or annotations change on the running pod. Env vars do not.

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
    image: busybox:1.36
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
# List files — downwardAPI volume uses the same symlink chain as ConfigMaps
kubectl exec pod-downward-vol -- ls -la /etc/podinfo/
# lrwxrwxrwx    annotations -> ..data/annotations
# lrwxrwxrwx    cpu-request -> ..data/cpu-request
# lrwxrwxrwx    labels -> ..data/labels
# lrwxrwxrwx    mem-limit -> ..data/mem-limit
# lrwxrwxrwx    node-name -> ..data/node-name
# lrwxrwxrwx    pod-ip -> ..data/pod-ip
# lrwxrwxrwx    pod-name -> ..data/pod-name
# lrwxrwxrwx    pod-namespace -> ..data/pod-namespace
# lrwxrwxrwx    ..data -> ..2026_04_26_...
#
# Observation: identical symlink structure to ConfigMap volumes.
# Each projected field is a symlink into ..data/. The same atomic rename() mechanism applies.
```

```bash
# Read scalar fields
kubectl exec pod-downward-vol -- cat /etc/podinfo/pod-name
# pod-downward-vol

kubectl exec pod-downward-vol -- cat /etc/podinfo/node-name
# 3node-m02

kubectl exec pod-downward-vol -- cat /etc/podinfo/cpu-request
# 100   ← 100 millicores (divisor "1m")
```

```bash
# Read the labels file — ALL labels in key="value" format
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
# app="myapp"
# environment="staging"
# version="v1.0.0"
#
# Observation: ALL labels are present in a single file, sorted alphabetically.
# Format is key="value" per line — different from env var format (KEY=value).
# This is the only way to expose all labels in one place.
```

```bash
# Read the annotations file
kubectl exec pod-downward-vol -- cat /etc/podinfo/annotations
# build-id="build-20260401-001"
# deployment.region="ca-central-1"
# kubectl.kubernetes.io/last-applied-configuration="..."
#
# Observation: ALL annotations are present, including the internal last-applied annotation
# added by kubectl apply. This is normal — filter in the application if needed.
```

**Test live label update — the key advantage of volume over env var:**
```bash
# Record baseline
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
# app="myapp"
# environment="staging"
# version="v1.0.0"

# Add a new label to the running pod
kubectl label pod pod-downward-vol release=stable
# pod/pod-downward-vol labeled

# Wait 30–90 seconds for kubelet sync (syncFrequency: 0s = 1 minute effective default)
# Then verify — no pod restart needed
kubectl exec pod-downward-vol -- cat /etc/podinfo/labels
# app="myapp"
# environment="staging"
# release="stable"     ← new label appeared without restarting the pod
# version="v1.0.0"
#
# Observation: the new label is reflected in the volume file automatically.
# This is the kubelet sync mechanism — same as ConfigMap volume updates.
# An env var capturing metadata.labels['release'] would still show nothing — env vars don't update.

# Update an annotation
kubectl annotate pod pod-downward-vol build-id=build-99999 --overwrite

# Wait for sync, then verify
kubectl exec pod-downward-vol -- cat /etc/podinfo/annotations | grep build-id
# build-id="build-99999"
#
# Observation: annotation updated in the volume file without pod restart.
```

---

### Step 5 — Cleanup

```bash
kubectl delete pod pod-envfrom-combined pod-var-subst pod-downward-env pod-downward-vol \
  2>/dev/null || true
kubectl delete configmap shared-config 2>/dev/null || true
kubectl delete secret shared-secret 2>/dev/null || true
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| envFrom precedence | First listed source wins on key collision; explicit `env[]` always beats all `envFrom` sources |
| `$(VAR_NAME)` scope | Only resolves vars explicitly in the same `env[]` list; `envFrom`-loaded vars are NOT in scope |
| Undefined var | If `$(VAR_NAME)` cannot be resolved, the literal string `$(VAR_NAME)` is used — no error |
| `fieldRef` metadata | pod name, namespace, uid, nodeName, hostIP, podIP, serviceAccountName |
| `fieldRef` single label/annotation | `metadata.labels['key']` — only one at a time; does not update live |
| `resourceFieldRef` divisor | `"1m"` → millicores integer; `"1Mi"` → MiB integer; `"1"` → raw bytes or fractional cores |
| Volume vs env for labels | Volume: ALL labels in one file, updates live; Env: one label per var, frozen at pod start |
| `metadata.labels` file format | `key="value"` per line, sorted alphabetically — note the quoted value format |
| downwardAPI volume sync | Same kubelet `syncFrequency` mechanism as ConfigMap volumes — effective default 1 min |
| `printenv` for verification | Always use `kubectl exec -- printenv KEY` to verify env vars; not pod logs |