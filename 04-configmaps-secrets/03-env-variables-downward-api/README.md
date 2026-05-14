# 03 — Environment Variables & Downward API

## Concepts

This lab covers what **wasn't** covered in `01-core-concepts/03-pod-container-basics`:

- `envFrom` combining ConfigMaps and Secrets (precedence rules)
- Variable substitution `$(VAR_NAME)` syntax
- The full Downward API field catalogue — `fieldRef` and `resourceFieldRef`
- Downward API via **volume files** (not just env vars)
- `projected` volumes — combining Downward API, ConfigMap, and Secret in one mount

### Environment variable precedence (when merging sources)

When a pod defines multiple `envFrom` sources and explicit `env` entries, Kubernetes resolves conflicts using this order (highest to lowest precedence):

```
explicit env[].value / env[].valueFrom   ← highest (always wins)
      ↓
envFrom[0] (first listed source)
      ↓
envFrom[1] (second listed source)
      ↓
...
```

If `envFrom` sources have the same key, the **first listed source wins**. An explicit `env` entry always overrides any `envFrom` source with the same key.

### Variable substitution

Kubernetes supports `$(VAR_NAME)` syntax in `env[].value` to reference other env vars **already defined in the same container spec**. References resolve left-to-right in the `env` list.

```yaml
env:
- name: BASE_URL
  value: "https://api.example.com"
- name: HEALTH_URL
  value: "$(BASE_URL)/health"   # resolves to https://api.example.com/health
```

> **Exam trap:** `$(VAR_NAME)` only works in `env[].value`, NOT in `command` or `args` fields when they're in list form. Shell expansion (`$VAR`) works in `command: ["sh", "-c", "echo $VAR"]` because the shell processes it — but `$(VAR_NAME)` in a raw exec-form command is Kubernetes substitution, not shell.

### Downward API — what's new here

`01-core-concepts/03` showed basic `fieldRef` for pod name and namespace. This lab covers the **full field catalogue** plus `resourceFieldRef` and volume-based delivery.

#### All supported fieldRef paths

| fieldRef path | What it returns |
|--------------|----------------|
| `metadata.name` | Pod name |
| `metadata.namespace` | Pod namespace |
| `metadata.uid` | Pod UID |
| `metadata.labels['<KEY>']` | Value of a specific label |
| `metadata.annotations['<KEY>']` | Value of a specific annotation |
| `spec.nodeName` | Node name the pod is scheduled to |
| `spec.serviceAccountName` | Pod's ServiceAccount name |
| `spec.hostIP` | Node's primary IP address |
| `status.podIP` | Pod's IP address |
| `status.podIPs` | All pod IPs (multi-stack) |

#### All supported resourceFieldRef fields

| resourceFieldRef resource | What it returns |
|--------------------------|----------------|
| `requests.cpu` | Container CPU request |
| `requests.memory` | Container memory request |
| `limits.cpu` | Container CPU limit |
| `limits.memory` | Container memory limit |
| `requests.hugepages-<size>` | Hugepage requests |
| `limits.hugepages-<size>` | Hugepage limits |

`resourceFieldRef` requires `containerName` (which container's resources) and `divisor` (unit for the output).

#### Downward API via volume vs env var

| Method | Best for | Can expose |
|--------|---------|-----------|
| `env.valueFrom.fieldRef` | Single scalar values | All fieldRef paths |
| `env.valueFrom.resourceFieldRef` | Single resource quantity | All resourceFieldRef fields |
| `downwardAPI` volume | Labels/annotations (can change at runtime) | All paths + all resources |

**Critical:** Labels and annotations can be updated on a running pod. A `downwardAPI` volume automatically reflects the latest values (like a ConfigMap volume). Env vars do not — they capture the value at pod start only. For labels and annotations, **always prefer the volume method** if you need live updates.

---

## Directory Structure

```
03-env-variables-downward-api/
├── README.md
└── src/
    ├── 01-pod-envfrom-combined.yaml      # envFrom ConfigMap + Secret, precedence demo
    ├── 02-pod-var-substitution.yaml      # $(VAR_NAME) substitution
    ├── 03-pod-downward-api-env.yaml      # Full fieldRef + resourceFieldRef as env vars
    └── 04-pod-downward-api-volume.yaml   # Downward API as volume files (labels/annotations)
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Create ConfigMap and Secret used in this lab
kubectl create configmap shared-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=OVERRIDE_ME=from-configmap

kubectl create secret generic shared-secret \
  --from-literal=API_KEY=secret-key-value \
  --from-literal=OVERRIDE_ME=from-secret
```

---

### Step 1 — envFrom with multiple sources and precedence

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
    command:
    - sh
    - -c
    - |
      echo "APP_ENV=$APP_ENV"
      echo "LOG_LEVEL=$LOG_LEVEL"
      echo "API_KEY=$API_KEY"
      # OVERRIDE_ME exists in BOTH ConfigMap (from-configmap) and Secret (from-secret)
      # envFrom[0] is the ConfigMap — it wins over envFrom[1] (Secret)
      echo "OVERRIDE_ME=$OVERRIDE_ME"
      # EXPLICIT_OVERRIDE is set directly in env[] — always wins over any envFrom source
      echo "EXPLICIT_OVERRIDE=$EXPLICIT_OVERRIDE"
      sleep 3600
    envFrom:
    # Source 0 — ConfigMap loaded first: APP_ENV, LOG_LEVEL, OVERRIDE_ME
    - configMapRef:
        name: shared-config
    # Source 1 — Secret loaded second: API_KEY, OVERRIDE_ME
    # OVERRIDE_ME from secret loses to OVERRIDE_ME from configmap (source 0 wins)
    - secretRef:
        name: shared-secret
    env:
    # Explicit env entry — always wins over any envFrom key with the same name
    - name: EXPLICIT_OVERRIDE
      value: "set-directly-in-env"
    # This would override OVERRIDE_ME from ALL envFrom sources:
    # - name: OVERRIDE_ME
    #   value: "explicit-wins"
  restartPolicy: Never
```

```bash
kubectl apply -f src/01-pod-envfrom-combined.yaml
kubectl wait --for=condition=Ready pod/pod-envfrom-combined --timeout=30s

kubectl logs pod/pod-envfrom-combined
# APP_ENV=production          ← from ConfigMap (envFrom[0])
# LOG_LEVEL=info              ← from ConfigMap (envFrom[0])
# API_KEY=secret-key-value    ← from Secret (envFrom[1], unique key)
# OVERRIDE_ME=from-configmap  ← ConfigMap wins (envFrom[0] beats envFrom[1])
# EXPLICIT_OVERRIDE=set-directly-in-env  ← explicit env[] always wins
```

---

### Step 2 — Variable substitution with $(VAR_NAME)

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
    command:
    - sh
    - -c
    - |
      echo "BASE_URL=$BASE_URL"
      echo "HEALTH_URL=$HEALTH_URL"
      echo "DB_URL=$DB_URL"
      echo "GREETING=$GREETING"
      sleep 3600
    env:
    # Variables are resolved left-to-right — a variable can only reference one defined before it
    - name: PROTOCOL
      value: "https"
    - name: HOST
      value: "api.example.com"
    - name: PORT
      value: "8443"
    - name: BASE_URL
      # $(VAR_NAME) substitution — references PROTOCOL, HOST, PORT defined above
      value: "$(PROTOCOL)://$(HOST):$(PORT)"
    - name: HEALTH_URL
      # Chain substitution — BASE_URL was defined above, so this works
      value: "$(BASE_URL)/health"
    - name: DB_HOST
      valueFrom:
        configMapKeyRef:
          name: shared-config
          key: APP_ENV           # using APP_ENV as a stand-in for demo
    - name: DB_URL
      # Can combine substitution with valueFrom-sourced vars
      value: "postgres://$(DB_HOST):5432/appdb"
    - name: GREETING
      # If VAR doesn't exist, the literal string $(UNDEFINED) is used — no error
      value: "Hello from $(APP_ENV)"    # APP_ENV comes from envFrom below, but...
      # IMPORTANT: env[] substitution only works with vars in the SAME env[] list
      # vars from envFrom are NOT available for $(VAR) substitution in env[].value
    envFrom:
    - configMapRef:
        name: shared-config
  restartPolicy: Never
```

```bash
kubectl apply -f src/02-pod-var-substitution.yaml
kubectl wait --for=condition=Ready pod/pod-var-subst --timeout=30s

kubectl logs pod/pod-var-subst
# BASE_URL=https://api.example.com:8443
# HEALTH_URL=https://api.example.com:8443/health
# DB_URL=postgres://production:5432/appdb
# GREETING=Hello from $(APP_ENV)   ← NOT substituted — envFrom vars not in env[] scope
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
    command:
    - sh
    - -c
    - |
      echo "=== Pod Identity ==="
      echo "POD_NAME=$POD_NAME"
      echo "POD_NAMESPACE=$POD_NAMESPACE"
      echo "POD_UID=$POD_UID"
      echo ""
      echo "=== Scheduling ==="
      echo "NODE_NAME=$NODE_NAME"
      echo "HOST_IP=$HOST_IP"
      echo "POD_IP=$POD_IP"
      echo ""
      echo "=== Service Account ==="
      echo "SERVICE_ACCOUNT=$SERVICE_ACCOUNT"
      echo ""
      echo "=== Labels ==="
      echo "LABEL_APP=$LABEL_APP"
      echo "LABEL_VERSION=$LABEL_VERSION"
      echo ""
      echo "=== Annotations ==="
      echo "ANNOTATION_REGION=$ANNOTATION_REGION"
      echo ""
      echo "=== Resource Requests/Limits ==="
      echo "CPU_REQUEST=$CPU_REQUEST"
      echo "MEM_REQUEST=$MEM_REQUEST"
      echo "CPU_LIMIT=$CPU_LIMIT"
      echo "MEM_LIMIT=$MEM_LIMIT"
      sleep 3600
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
    # --- fieldRef: scheduling info ---
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
    # --- fieldRef: specific label/annotation values ---
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
          containerName: app        # which container's resources to expose
          resource: requests.cpu
          divisor: "1m"            # output unit: "1m" = millicores (250m = 250)
    - name: MEM_REQUEST
      valueFrom:
        resourceFieldRef:
          containerName: app
          resource: requests.memory
          divisor: "1Mi"           # output unit: "1Mi" = mebibytes (64Mi = 64)
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

kubectl logs pod/pod-downward-env
# === Pod Identity ===
# POD_NAME=pod-downward-env
# POD_NAMESPACE=default
# POD_UID=<uid>
#
# === Scheduling ===
# NODE_NAME=3node-m02           ← which worker the pod landed on
# HOST_IP=192.168.49.3          ← node IP
# POD_IP=10.244.x.x             ← pod's cluster IP
#
# === Service Account ===
# SERVICE_ACCOUNT=default
#
# === Labels ===
# LABEL_APP=myapp
# LABEL_VERSION=v1.2.3
#
# === Annotations ===
# ANNOTATION_REGION=ca-central-1
#
# === Resource Requests/Limits ===
# CPU_REQUEST=250
# MEM_REQUEST=64
# CPU_LIMIT=500
# MEM_LIMIT=128
```

---

### Step 4 — Downward API via volume (live labels and annotations)

Volume-based Downward API is essential for labels and annotations because they can change on a running pod. The volume file updates automatically; env vars don't.

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
  # downwardAPI volume — projects pod fields as files
  - name: pod-info
    downwardAPI:
      # defaultMode: 0444    # optional: file permissions (default 0644)
      items:
      # Each item projects one field path or resource field as a file
      - path: "pod-name"              # filename inside mountPath
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
      # Labels file — contains ALL labels as key="value" lines
      # This is the ONLY way to expose all labels (env vars expose only specific ones)
      - path: "labels"
        fieldRef:
          fieldPath: metadata.labels
      # Annotations file — contains ALL annotations as key="value" lines
      - path: "annotations"
        fieldRef:
          fieldPath: metadata.annotations
      # Resource fields also work in volumes
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
    command:
    - sh
    - -c
    - |
      echo "=== All pod info files ==="
      ls -la /etc/podinfo/
      echo ""
      echo "=== pod-name ==="
      cat /etc/podinfo/pod-name
      echo ""
      echo "=== labels (all labels as file) ==="
      cat /etc/podinfo/labels
      echo ""
      echo "=== annotations ==="
      cat /etc/podinfo/annotations
      echo ""
      echo "=== cpu-request ==="
      cat /etc/podinfo/cpu-request
      sleep 3600
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

kubectl logs pod/pod-downward-vol
# === All pod info files ===
# -r--r--r-- ... annotations
# -r--r--r-- ... cpu-request
# -r--r--r-- ... labels
# -r--r--r-- ... mem-limit
# -r--r--r-- ... node-name
# -r--r--r-- ... pod-ip
# -r--r--r-- ... pod-name
# -r--r--r-- ... pod-namespace
#
# === pod-name ===
# pod-downward-vol
#
# === labels (all labels as file) ===
# app="myapp"
# environment="staging"
# version="v1.0.0"
#
# === annotations ===
# build-id="build-20260401-001"
# deployment.region="ca-central-1"
# kubectl.kubernetes.io/last-applied-configuration="..."
#
# === cpu-request ===
# 100
```

Now test live label update — only possible via volume:

```bash
# Add a new label to the running pod
kubectl label pod pod-downward-vol release=stable

# Wait ~30s for kubelet sync, then check the file (no pod restart needed)
kubectl exec pod/pod-downward-vol -- cat /etc/podinfo/labels
# app="myapp"
# environment="staging"
# release="stable"       ← new label appeared without restart
# version="v1.0.0"

# Update an annotation
kubectl annotate pod pod-downward-vol build-id=build-99999

kubectl exec pod/pod-downward-vol -- cat /etc/podinfo/annotations | grep build-id
# build-id="build-99999"   ← updated without restart
```

---

### Step 5 — Cleanup

```bash
kubectl delete pod pod-envfrom-combined pod-var-subst pod-downward-env pod-downward-vol
kubectl delete configmap shared-config
kubectl delete secret shared-secret
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| envFrom precedence | First listed source wins on key collision; explicit `env[]` always beats `envFrom` |
| `$(VAR_NAME)` scope | Only resolves vars in the same `env[]` list; `envFrom` vars are NOT in scope |
| `fieldRef` metadata | Exposes pod name, namespace, uid, nodeName, hostIP, podIP, serviceAccountName |
| `fieldRef` labels/annotations | `metadata.labels['key']` for one; full file for all (volume only) |
| `resourceFieldRef` divisor | `"1m"` for millicores, `"1Mi"` for mebibytes, `"1"` for raw bytes/cores |
| Volume vs env for labels | Labels and annotations can change at runtime — use volume for live updates |
| `metadata.labels` as file | The only way to expose ALL labels in one place; format is `key="value"` per line |