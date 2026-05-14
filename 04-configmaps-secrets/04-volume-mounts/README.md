# 04 — Volume Mounts

## Concepts

This lab covers advanced volume mount patterns for ConfigMaps and Secrets. The fundamentals (basic volume mounts) were covered in `01-configmaps` and `02-secrets`. This lab focuses on patterns that matter in production and in exams:

- `subPath` — mount a single file without replacing the entire directory
- `defaultMode` and per-file `mode` — controlling file permissions
- `projected` volumes — combining multiple sources (ConfigMap, Secret, Downward API, ServiceAccount token) into a single mount point
- `readOnly` volume mount enforcement
- Init container pattern — copying ConfigMap files to a writable location for apps that must modify config on startup

### Why subPath matters

Without `subPath`, mounting a ConfigMap volume at `/etc/nginx/nginx.conf` **replaces the entire `/etc/nginx/` directory** with the ConfigMap contents. All other files in that directory (mime.types, fastcgi_params, etc.) are hidden. `subPath` mounts a single key as a single file, leaving the rest of the directory intact.

```
Without subPath:                     With subPath:
mountPath: /etc/nginx                mountPath: /etc/nginx/nginx.conf
→ /etc/nginx/ is REPLACED            subPath: nginx.conf
  only nginx.conf exists             → /etc/nginx/ unchanged
  mime.types gone                      /etc/nginx/nginx.conf added
  fastcgi_params gone                  mime.types still there
```

> **subPath caveat:** Files mounted with `subPath` do **NOT** receive live updates when the ConfigMap changes. The symlink trick kubelet uses for atomic updates only works with full directory mounts. For live-updating single files, use a full directory mount with `items` to control which keys are projected.

### projected volumes

A `projected` volume combines up to four source types into **one** `mountPath`:

| Source type | Field name | What it provides |
|-------------|-----------|-----------------|
| ConfigMap | `configMap` | Config files |
| Secret | `secret` | Credential files |
| Downward API | `downwardAPI` | Pod identity files |
| ServiceAccount token | `serviceAccountToken` | Bound, expiring OIDC tokens |

Without `projected`, each source requires its own volume and its own `volumeMount`. With `projected`, all sources land in the same directory under controllable paths.

### ServiceAccount token projection

The `serviceAccountToken` source injects a **bound** ServiceAccount token — cryptographically tied to the pod's UID and expiring after a configurable TTL. This is the modern replacement for the auto-mounted legacy token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. The kubelet automatically rotates it before expiry.

### File permission model

Permissions on ConfigMap and Secret volume files are controlled at two levels:

| Field | Scope | Default | Recommended |
|-------|-------|---------|-------------|
| `defaultMode` | All files in the volume | `0644` | `0444` for ConfigMaps, `0400` for Secrets |
| `items[].mode` | Single file override | Inherits `defaultMode` | `0400` for private keys |

> `readOnly: true` on a `volumeMount` is enforced by the kernel at the mount level. It is independent of file mode — even if `defaultMode` is `0644`, `readOnly: true` prevents any write. Always set both for secrets.

### Init container writable copy pattern

ConfigMap and Secret volumes are read-only. Some applications require a writable config directory at startup (for templating, self-modification, or generating derived files). The solution:

```
ConfigMap (read-only)
      ↓  init container copies + transforms
emptyDir (writable)
      ↓  main container reads and writes
App process
```

The ConfigMap itself is never modified. The emptyDir lives for the pod's lifetime and is independent per-pod — no shared state between replicas.

---

## Directory Structure

```
04-volume-mounts/
├── README.md
└── src/
    ├── 01-pod-subpath.yaml                 # subPath: mount single file into existing dir
    ├── 02-pod-permissions.yaml             # defaultMode + per-file mode
    ├── 03-pod-projected.yaml               # projected: ConfigMap + Secret + Downward API
    ├── 04-pod-projected-satoken.yaml       # projected: ServiceAccount token
    └── 05-pod-initcontainer-writable.yaml  # init container copies CM to writable emptyDir
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Create all supporting ConfigMaps and Secrets for this lab
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: default
data:
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;
      server {
        listen 80;
        location /health { return 200 'ok\n'; add_header Content-Type text/plain; }
        location / { root /usr/share/nginx/html; index index.html; }
      }
    }
  extra.conf: |
    # Extra nginx snippet
    proxy_read_timeout 60s;
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
data:
  APP_ENV: "production"
  config.yaml: |
    server:
      port: 8080
      timeout: 30s
    logging:
      level: info
      format: json
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: default
type: Opaque
stringData:
  db-password: "S3cur3P@ss!"
  tls.key: |
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEA...
    -----END PRIVATE KEY-----
EOF
```

---

### Step 1 — subPath: inject a single file without replacing the directory

nginx's `/etc/nginx/` ships with `mime.types`, `fastcgi_params`, `conf.d/`, and other files. A plain ConfigMap volume mount at `/etc/nginx/` would hide all of them. `subPath` injects only the specified key as a named file, leaving the directory's existing contents untouched.

**01-pod-subpath.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-subpath
  namespace: default
spec:
  volumes:
  - name: nginx-conf
    configMap:
      name: nginx-config
      # No items filter here — the full ConfigMap is the volume source
      # subPath on the volumeMount selects one key

  initContainers:
  - name: verify
    image: busybox:1.36
    # Verify the nginx dir contents are visible before nginx starts
    # (initContainer shares the same volume but checks its own mount)
    command: ["sh", "-c", "echo initContainer complete"]

  containers:
  - name: nginx
    image: nginx:1.27
    volumeMounts:
    # Without subPath: mountPath: /etc/nginx would REPLACE the whole directory
    # With subPath: only nginx.conf is injected; /etc/nginx/ contents are preserved
    - name: nginx-conf
      mountPath: /etc/nginx/nginx.conf   # full file path, not a directory
      subPath: nginx.conf                # key name in the ConfigMap
      readOnly: true
    # Mount a second key from the same volume using a second subPath mount
    - name: nginx-conf
      mountPath: /etc/nginx/conf.d/extra.conf
      subPath: extra.conf
      readOnly: true
  # If nginx starts successfully without errors, subPath worked correctly —
  # nginx validates mime.types, fastcgi_params etc. at startup; if they were
  # hidden by a full directory mount, nginx would exit with a config error.
```

```bash
kubectl apply -f src/01-pod-subpath.yaml
kubectl wait --for=condition=Ready pod/pod-subpath --timeout=30s

# nginx is running — meaning mime.types and other files were NOT hidden
kubectl get pod pod-subpath
# NAME          READY   STATUS    RESTARTS   AGE
# pod-subpath   1/1     Running   0          10s

# Confirm both ConfigMap files are injected as individual files
kubectl exec pod/pod-subpath -- ls -la /etc/nginx/nginx.conf
kubectl exec pod/pod-subpath -- ls -la /etc/nginx/conf.d/extra.conf

# Confirm native nginx files still exist (they would be gone without subPath)
kubectl exec pod/pod-subpath -- ls /etc/nginx/mime.types
kubectl exec pod/pod-subpath -- ls /etc/nginx/fastcgi_params

# Confirm the injected nginx.conf is a regular file (not a symlink — subPath files are direct binds)
kubectl exec pod/pod-subpath -- ls -la /etc/nginx/nginx.conf
# -rw-r--r-- ... /etc/nginx/nginx.conf   ← regular file, NOT a symlink

# Compare: a full directory mount produces symlinks; subPath produces a direct bind
# This is why subPath files do NOT get live updates — no symlink to repoint

# Test nginx responds
kubectl exec pod/pod-subpath -- wget -qO- http://localhost/health
# ok
```

> **Exam trap:** When asked to mount a ConfigMap key into a specific file path inside a directory that has other contents (e.g. `/etc/nginx/nginx.conf`), always use `subPath`. Mounting to the directory itself destroys the existing contents.

---

### Step 2 — File permissions: defaultMode and per-file mode

**02-pod-permissions.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-permissions
  namespace: default
spec:
  volumes:
  # ConfigMap volume: defaultMode 0444 (read for owner, group, others)
  - name: config-files
    configMap:
      name: app-config
      defaultMode: 0444        # applies to all files in this volume
      items:
      - key: config.yaml
        path: config.yaml

  # Secret volume: defaultMode 0400 (owner read-only — production standard for secrets)
  - name: secret-files
    secret:
      secretName: app-secrets
      defaultMode: 0400        # owner read-only — secrets should never be group/world readable
      items:
      - key: db-password
        path: db-password
      - key: tls.key
        path: tls.key
        mode: 0400             # explicit per-file mode (same as default, shown for clarity)

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Config files (defaultMode 0444) ==="
      ls -la /etc/app/
      echo ""
      echo "=== Secret files (defaultMode 0400) ==="
      ls -la /etc/secrets/
      echo ""
      echo "=== Reading config (0444 — readable by all) ==="
      cat /etc/app/config.yaml
      echo ""
      echo "=== Reading secret (0400 — owner read-only) ==="
      cat /etc/secrets/db-password
      echo ""
      echo "=== Write attempt on readOnly mount (must fail) ==="
      echo "test" >> /etc/secrets/db-password 2>&1 || echo "EXPECTED: write blocked by readOnly mount"
      sleep 3600
    volumeMounts:
    - name: config-files
      mountPath: /etc/app
      readOnly: true           # readOnly on the mount — enforced by kernel, independent of file mode
    - name: secret-files
      mountPath: /etc/secrets
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/02-pod-permissions.yaml
kubectl wait --for=condition=Ready pod/pod-permissions --timeout=30s

kubectl logs pod/pod-permissions
# === Config files (defaultMode 0444) ===
# lrwxrwxrwx ... config.yaml -> ..data/config.yaml
# -r--r--r-- ... (actual file: 0444)
#
# === Secret files (defaultMode 0400) ===
# -r-------- ... db-password    ← 0400 owner read-only
# -r-------- ... tls.key        ← 0400 owner read-only
#
# === Reading config (0444 — readable by all) ===
# server:
#   port: 8080
# ...
#
# === Reading secret (0400 — owner read-only) ===
# S3cur3P@ss!
#
# === Write attempt on readOnly mount (must fail) ===
# EXPECTED: write blocked by readOnly mount
```

---

### Step 3 — projected volume: ConfigMap + Secret + Downward API in one mountPath

Without `projected`, three sources = three volumes + three volumeMounts = six spec entries. With `projected`, one volume + one volumeMount serves all three. Files are organised into subdirectories via `path` prefixes.

**03-pod-projected.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-projected
  namespace: default
  labels:
    app: myapp
    version: v1.0.0
  annotations:
    deployment.region: "ca-central-1"
spec:
  volumes:
  - name: combined
    projected:
      defaultMode: 0444
      sources:
      # Source 1: ConfigMap
      - configMap:
          name: app-config
          items:
          - key: config.yaml
            path: config/config.yaml     # → /etc/combined/config/config.yaml

      # Source 2: Secret
      - secret:
          name: app-secrets
          items:
          - key: db-password
            path: secrets/db-password   # → /etc/combined/secrets/db-password
            mode: 0400                  # override to owner read-only

      # Source 3: Downward API
      - downwardAPI:
          items:
          - path: podinfo/pod-name
            fieldRef:
              fieldPath: metadata.name
          - path: podinfo/namespace
            fieldRef:
              fieldPath: metadata.namespace
          - path: podinfo/labels
            fieldRef:
              fieldPath: metadata.labels
          - path: podinfo/annotations
            fieldRef:
              fieldPath: metadata.annotations

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== All files in projected volume (one mountPath, three sources) ==="
      find /etc/combined -type f | sort
      echo ""
      echo "=== config/config.yaml (from ConfigMap) ==="
      cat /etc/combined/config/config.yaml
      echo ""
      echo "=== secrets/db-password (from Secret, mode 0400) ==="
      ls -la /etc/combined/secrets/db-password
      cat /etc/combined/secrets/db-password
      echo ""
      echo "=== podinfo/labels (from Downward API) ==="
      cat /etc/combined/podinfo/labels
      sleep 3600
    volumeMounts:
    - name: combined
      mountPath: /etc/combined   # single mountPath receives all three sources
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/03-pod-projected.yaml
kubectl wait --for=condition=Ready pod/pod-projected --timeout=30s

kubectl logs pod/pod-projected
# === All files in projected volume (one mountPath, three sources) ===
# /etc/combined/config/config.yaml
# /etc/combined/podinfo/annotations
# /etc/combined/podinfo/labels
# /etc/combined/podinfo/namespace
# /etc/combined/podinfo/pod-name
# /etc/combined/secrets/db-password
#
# === config/config.yaml (from ConfigMap) ===
# server:
#   port: 8080
# ...
#
# === secrets/db-password (from Secret, mode 0400) ===
# -r-------- ... /etc/combined/secrets/db-password
# S3cur3P@ss!
#
# === podinfo/labels (from Downward API) ===
# app="myapp"
# version="v1.0.0"
```

---

### Step 4 — projected ServiceAccount token

The `serviceAccountToken` projection replaces the legacy auto-mounted token. It produces a bound, expiring, audience-scoped JWT that kubelet rotates automatically.

**04-pod-projected-satoken.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-projected-satoken
  namespace: default
spec:
  volumes:
  - name: workload-identity
    projected:
      defaultMode: 0444
      sources:
      # Modern bound ServiceAccount token
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600        # minimum 600s; kubelet rotates at 80% of TTL
          audience: "https://kubernetes.default.svc"

      # CA cert — needed to verify the API server's TLS certificate
      - configMap:
          name: kube-root-ca.crt         # auto-created in every namespace
          items:
          - key: ca.crt
            path: ca.crt

      # Namespace — completes the legacy token equivalent
      - downwardAPI:
          items:
          - path: namespace
            fieldRef:
              fieldPath: metadata.namespace

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Workload identity bundle ==="
      ls -la /var/run/secrets/workload/
      echo ""
      echo "=== ServiceAccount token (first 100 chars) ==="
      cat /var/run/secrets/workload/token | cut -c1-100
      echo "..."
      echo ""
      echo "=== Namespace ==="
      cat /var/run/secrets/workload/namespace
      echo ""
      echo "=== CA cert (first line) ==="
      head -1 /var/run/secrets/workload/ca.crt
      sleep 3600
    volumeMounts:
    - name: workload-identity
      mountPath: /var/run/secrets/workload
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/04-pod-projected-satoken.yaml
kubectl wait --for=condition=Ready pod/pod-projected-satoken --timeout=30s

kubectl logs pod/pod-projected-satoken
# === Workload identity bundle ===
# -r--r--r-- ... ca.crt
# -r--r--r-- ... namespace
# -r--r--r-- ... token
#
# === ServiceAccount token (first 100 chars) ===
# eyJhbGciOiJSUzI1NiIsImtpZCI6Ii...
# ...
#
# === Namespace ===
# default
#
# === CA cert (first line) ===
# -----BEGIN CERTIFICATE-----

# Verify it's a JWT with the correct audience — decode the payload
kubectl exec pod/pod-projected-satoken -- sh -c '
  TOKEN=$(cat /var/run/secrets/workload/token)
  PAYLOAD=$(echo $TOKEN | cut -d. -f2)
  echo $PAYLOAD | base64 -d 2>/dev/null
'
# {"aud":["https://kubernetes.default.svc"],"exp":...,"iat":...,"iss":"https://kubernetes.default.svc",...}
# exp - iat = 3600  ← matches expirationSeconds
```

---

### Step 5 — Init container writable copy pattern

**05-pod-initcontainer-writable.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-initcontainer-writable
  namespace: default
spec:
  # Problem: some apps must write to their config directory at startup.
  # ConfigMap/Secret mounts are read-only — they cannot be written to.
  # Solution: init container copies ConfigMap files to an emptyDir volume.
  # The main container mounts the emptyDir, which is writable.

  volumes:
  # Source: ConfigMap (read-only — cannot write here)
  - name: config-source
    configMap:
      name: app-config
      items:
      - key: config.yaml
        path: config.yaml

  # Destination: emptyDir (writable, ephemeral, lives for pod lifetime)
  - name: config-writable
    emptyDir: {}

  initContainers:
  - name: copy-config
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Copying config from ConfigMap mount to writable emptyDir ==="
      cp /config-source/config.yaml /config-writable/config.yaml

      # Simulate template substitution (envsubst, sed, custom scripts)
      sed -i "s/port: 8080/port: 9090/" /config-writable/config.yaml
      echo "Applied port substitution"

      echo "=== Final config written to writable volume ==="
      cat /config-writable/config.yaml
    volumeMounts:
    - name: config-source
      mountPath: /config-source
      readOnly: true
    - name: config-writable
      mountPath: /config-writable

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== App reading from writable config volume ==="
      cat /etc/app/config.yaml
      echo ""
      echo "=== Writing app runtime state to same volume (allowed) ==="
      echo "started_at: $(date)" >> /etc/app/runtime.state
      cat /etc/app/runtime.state
      echo ""
      echo "=== Write attempt on original ConfigMap mount (must fail) ==="
      echo "test" >> /etc/app-source/config.yaml 2>&1 || echo "EXPECTED: read-only filesystem"
      sleep 3600
    volumeMounts:
    - name: config-writable
      mountPath: /etc/app          # writable — app can read AND write here
    - name: config-source
      mountPath: /etc/app-source
      readOnly: true               # original ConfigMap — strictly read-only
  restartPolicy: Never
```

```bash
kubectl apply -f src/05-pod-initcontainer-writable.yaml
kubectl wait --for=condition=Ready pod/pod-initcontainer-writable --timeout=60s

# Check init container output
kubectl logs pod/pod-initcontainer-writable -c copy-config
# === Copying config from ConfigMap mount to writable emptyDir ===
# Applied port substitution
# === Final config written to writable volume ===
# server:
#   port: 9090          ← substituted from 8080 by init container
# ...

# Check main container
kubectl logs pod/pod-initcontainer-writable -c app
# === App reading from writable config volume ===
# server:
#   port: 9090          ← sees the init container's transformed version
# ...
# === Writing app runtime state to same volume (allowed) ===
# started_at: Sun Apr 19 ...
#
# === Write attempt on original ConfigMap mount (must fail) ===
# EXPECTED: read-only filesystem

# Confirm the emptyDir is writable by the main container
kubectl exec pod/pod-initcontainer-writable -c app -- \
  sh -c 'echo "live write $(date)" >> /etc/app/runtime.state && cat /etc/app/runtime.state'
# started_at: ...
# live write ...        ← new write succeeded
```

---

### Step 6 — Cleanup

```bash
kubectl delete pod pod-subpath pod-permissions pod-projected pod-projected-satoken pod-initcontainer-writable
kubectl delete configmap nginx-config app-config
kubectl delete secret app-secrets
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| `subPath` | Injects one key as one file; preserves existing directory contents; no live updates |
| Full directory mount | All keys become files; live updates via kubelet symlink rotation; existing dir contents hidden |
| `defaultMode` | Octal permission for all files in volume; `0444` for ConfigMaps, `0400` for Secrets |
| `items[].mode` | Per-file override; useful for private keys (`0400`) within a volume with looser `defaultMode` |
| `readOnly: true` on mount | Kernel-enforced; independent of file mode; always set for Secrets |
| `projected` | One volume, one mountPath, up to four source types; paths control subdirectory layout |
| `serviceAccountToken` | Bound JWT: pod-UID-scoped, expiring, audience-scoped, auto-rotated by kubelet |
| `kube-root-ca.crt` | Auto-created ConfigMap in every namespace; project alongside SA token for full bundle |
| `emptyDir` + init container | The correct pattern when an app needs a writable config dir; ConfigMap is never mutated |