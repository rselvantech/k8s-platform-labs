# 04 — Volume Mounts

## Concepts

This lab covers advanced volume mount patterns for ConfigMaps and Secrets. Fundamentals (basic volume mounts) were covered in `01-configmaps` and `02-secrets`. This lab focuses on:

- `subPath` — mount a single file without replacing the entire directory
- `defaultMode` and per-file `mode` — file permission control
- `projected` volumes — combining multiple sources into one mount point
- ServiceAccount token projection — bound, expiring OIDC tokens
- Init container pattern — copying ConfigMap files to a writable location

### Why subPath matters

Without `subPath`, mounting a ConfigMap volume at a directory path **replaces the entire directory** with the ConfigMap contents. All pre-existing files are hidden.

```
Without subPath:                      With subPath:
mountPath: /etc/nginx                 mountPath: /etc/nginx/nginx.conf
→ /etc/nginx/ contents REPLACED       subPath: nginx.conf
  only ConfigMap keys exist           → /etc/nginx/ contents preserved
  mime.types gone                       /etc/nginx/nginx.conf added/replaced
  fastcgi_params gone                   mime.types still present
  conf.d/ gone                          fastcgi_params still present
```

**subPath produces a direct bind-mount — not a symlink.** This is the critical difference from a full directory mount:

| Mount type | How file appears | Live updates on CM change |
|-----------|-----------------|--------------------------|
| Full directory | Symlink → `..data/key` | ✅ Yes — atomic symlink swap |
| `subPath` | Regular file (bind-mount) | ❌ No — bypass `..data/` chain entirely |

> **Exam trap:** When asked to mount a ConfigMap key into a path where other files exist (e.g. `/etc/nginx/nginx.conf`), always use `subPath`. Mounting to the directory hides everything else.

### projected volumes

A `projected` volume combines up to four source types into **one** `mountPath` — one volume spec, one volumeMount.

| Source type | Field | What it provides |
|-------------|-------|-----------------|
| ConfigMap | `configMap` | Config files |
| Secret | `secret` | Credential files |
| Downward API | `downwardAPI` | Pod identity files |
| ServiceAccount token | `serviceAccountToken` | Bound, expiring OIDC JWT |

### ServiceAccount token projection

The projected `serviceAccountToken` source is the modern replacement for the auto-mounted legacy token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. It produces a bound JWT that is:
- Cryptographically tied to the pod's UID — invalidated when the pod is deleted
- Expiring — minimum TTL 600s; kubelet rotates automatically at 80% of TTL
- Audience-scoped — only valid for the specified audience, not reusable against other APIs

### File permission model

| Field | Scope | Default | Production recommendation |
|-------|-------|---------|--------------------------|
| `defaultMode` | All files in the volume | `0644` | `0444` for ConfigMaps; `0400` for Secrets |
| `items[].mode` | Single file override | Inherits `defaultMode` | `0400` for private keys |

`readOnly: true` on a volumeMount is enforced by the kernel at the mount level — independent of file mode. Always set `readOnly: true` AND `defaultMode: 0400` for Secrets.

### Init container writable copy pattern

ConfigMap and Secret volumes are read-only at the kernel level. Some applications require a writable config directory at startup. The solution:

```
ConfigMap volume (readOnly)
        ↓ init container: cp + transform
emptyDir volume (writable)
        ↓ main container mounts and uses
Application process
```

The ConfigMap is never modified. The emptyDir is ephemeral (pod lifetime) and per-pod (no cross-replica sharing).

---

## Directory Structure

```
04-volume-mounts/
├── README.md
└── src/
    ├── 01-pod-subpath.yaml                 # subPath: inject file into existing directory
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

# Verify prerequisites exist
kubectl get configmap nginx-config app-config
kubectl get secret app-secrets
```

---

### Step 1 — subPath: inject a single file without replacing the directory

nginx's `/etc/nginx/` ships with `mime.types`, `fastcgi_params`, `conf.d/`, and other files that nginx requires at startup. A plain ConfigMap volume mount at `/etc/nginx/` would hide all of them and nginx would fail to start. `subPath` injects only the specified key as a named file, leaving everything else untouched.

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
      # No items filter — full ConfigMap is the volume source
      # subPath on the volumeMount selects which key to inject

  initContainers:
  - name: verify
    image: busybox:1.36
    command: ["sh", "-c", "echo initContainer complete"]

  containers:
  - name: nginx
    image: nginx:1.27
    volumeMounts:
    # subPath: inject only nginx.conf as a single file into /etc/nginx/
    # The rest of /etc/nginx/ (mime.types, fastcgi_params, conf.d/) is preserved
    - name: nginx-conf
      mountPath: /etc/nginx/nginx.conf   # target: full file path (not a directory)
      subPath: nginx.conf                # which key from the ConfigMap volume
      readOnly: true
    # Second key injected using a second subPath volumeMount on the same volume
    - name: nginx-conf
      mountPath: /etc/nginx/conf.d/extra.conf
      subPath: extra.conf
      readOnly: true
```

```bash
kubectl apply -f src/01-pod-subpath.yaml
kubectl wait --for=condition=Ready pod/pod-subpath --timeout=60s
```

**Verify:**
```bash
kubectl get pod pod-subpath
# NAME          READY   STATUS    RESTARTS   AGE
# pod-subpath   1/1     Running   0          15s
#
# Observation: nginx is Running — meaning mime.types and fastcgi_params were NOT hidden.
# If subPath was missing and /etc/nginx was replaced, nginx would have exited with a config error.
```

```bash
# Confirm the injected files exist as regular files (not symlinks)
kubectl exec pod-subpath -- ls -la /etc/nginx/nginx.conf
# -rw-r--r-- 1 root root ... /etc/nginx/nginx.conf
#
# Observation: -rw-r--r-- is a regular file (not lrwxrwxrwx symlink).
# subPath produces a direct bind-mount — no symlink chain.
# This is why subPath files do NOT receive live ConfigMap updates.

kubectl exec pod-subpath -- ls -la /etc/nginx/conf.d/extra.conf
# -rw-r--r-- 1 root root ... /etc/nginx/conf.d/extra.conf
```

```bash
# Confirm native nginx files still exist alongside the injected ConfigMap file
kubectl exec pod-subpath -- ls /etc/nginx/mime.types
# /etc/nginx/mime.types   ← still present (would be gone without subPath)

kubectl exec pod-subpath -- ls /etc/nginx/fastcgi_params
# /etc/nginx/fastcgi_params   ← still present
```

```bash
# Test nginx is actually serving
kubectl exec pod-subpath -- wget -qO- http://localhost/health
# ok
#
# Observation: nginx responds correctly — it successfully loaded mime.types and the injected config.
```

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
      defaultMode: 0444   # all files: owner+group+other can read; none can write
      items:
      - key: config.yaml
        path: config.yaml

  # Secret volume: defaultMode 0400 (owner read-only — production standard)
  - name: secret-files
    secret:
      secretName: app-secrets
      defaultMode: 0400   # all files: owner can read only; group+other have NO access
      items:
      - key: db-password
        path: db-password
      - key: tls.key
        path: tls.key
        mode: 0400        # explicit per-file override (same as defaultMode here — shown for clarity)

  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: config-files
      mountPath: /etc/app
      readOnly: true     # kernel-enforced: no writes regardless of file mode
    - name: secret-files
      mountPath: /etc/secrets
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/02-pod-permissions.yaml
kubectl wait --for=condition=Ready pod/pod-permissions --timeout=30s
```

**Verify file permissions:**
```bash
# ConfigMap: defaultMode 0444 — readable by all
kubectl exec pod-permissions -- ls -la /etc/app/
# lrwxrwxrwx    config.yaml -> ..data/config.yaml
# lrwxrwxrwx    ..data -> ..2026_04_26_...
#
# Observation: symlink entries — actual permissions are on the real file in ..data/

kubectl exec pod-permissions -- ls -la /etc/app/..data/
# -r--r--r--    config.yaml
#
# Observation: 0444 — owner, group, and others all have read-only access. No write bit.
```

```bash
# Secret: defaultMode 0400 — owner read-only only
kubectl exec pod-permissions -- ls -la /etc/secrets/..data/
# -r--------    db-password
# -r--------    tls.key
#
# Observation: 0400 — only owner (root) can read. Group and others have NO permissions.
# This is the correct production setting for secret files.
```

```bash
# Read the files — confirm content is accessible
kubectl exec pod-permissions -- cat /etc/app/config.yaml
# server:
#   port: 8080
#   timeout: 30s
# logging:
#   level: info
#   format: json

kubectl exec pod-permissions -- cat /etc/secrets/db-password
# S3cur3P@ss!
```

```bash
# Write attempt — must fail due to readOnly: true on the mount
kubectl exec pod-permissions -- sh -c 'echo "test" >> /etc/secrets/db-password'
# sh: /etc/secrets/db-password: Read-only file system
#
# Observation: the kernel rejects the write at the mount level.
# readOnly: true is independent of file mode — even 0644 files cannot be written
# when the mount itself is readOnly.
```

---

### Step 3 — projected volume: ConfigMap + Secret + Downward API in one mountPath

Without `projected`, three sources = three volumes + three volumeMounts = six spec entries. With `projected`, one volume + one volumeMount serves all three. The `path` field on each item controls the subdirectory and filename within the single mountPath.

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
      defaultMode: 0444   # applies to all files unless overridden per source or item
      sources:
      # Source 1: ConfigMap — files appear at config/ subdir
      - configMap:
          name: app-config
          items:
          - key: config.yaml
            path: config/config.yaml    # → /etc/combined/config/config.yaml

      # Source 2: Secret — files appear at secrets/ subdir with tighter permissions
      - secret:
          name: app-secrets
          items:
          - key: db-password
            path: secrets/db-password   # → /etc/combined/secrets/db-password
            mode: 0400                  # override: tighter than defaultMode 0444

      # Source 3: Downward API — files appear at podinfo/ subdir
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
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: combined
      mountPath: /etc/combined   # one mountPath receives all three sources
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/03-pod-projected.yaml
kubectl wait --for=condition=Ready pod/pod-projected --timeout=30s
```

**Verify the full file tree:**
```bash
# find follows symlinks — shows all real files across all three projected sources
kubectl exec pod-projected -- find /etc/combined -not -name '.*' -type l | sort
# /etc/combined/config/config.yaml    ← from ConfigMap
# /etc/combined/podinfo/annotations   ← from Downward API
# /etc/combined/podinfo/labels
# /etc/combined/podinfo/namespace
# /etc/combined/podinfo/pod-name
# /etc/combined/secrets/db-password   ← from Secret
#
# Observation: all three sources land in one directory tree under /etc/combined.
# Subdirectories (config/, secrets/, podinfo/) come from the path prefix in each item.
```

```bash
# Verify ConfigMap content
kubectl exec pod-projected -- cat /etc/combined/config/config.yaml
# server:
#   port: 8080
#   timeout: 30s
# logging:
#   level: info
#   format: json

# Verify Secret permission and content
kubectl exec pod-projected -- ls -la /etc/combined/..data/secrets/
# -r--------    db-password   ← 0400: tighter than defaultMode 0444
kubectl exec pod-projected -- cat /etc/combined/secrets/db-password
# S3cur3P@ss!

# Verify Downward API content
kubectl exec pod-projected -- cat /etc/combined/podinfo/labels
# app="myapp"
# version="v1.0.0"

kubectl exec pod-projected -- cat /etc/combined/podinfo/pod-name
# pod-projected
```

---

### Step 4 — projected ServiceAccount token

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
      # Bound ServiceAccount token — replaces legacy auto-mounted token
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600   # min 600s; kubelet auto-rotates at 80% of TTL
          audience: "https://kubernetes.default.svc"

      # CA cert — verifies the API server's TLS certificate
      - configMap:
          name: kube-root-ca.crt   # auto-created in every namespace by the controller
          items:
          - key: ca.crt
            path: ca.crt

      # Namespace — completes the identity bundle
      - downwardAPI:
          items:
          - path: namespace
            fieldRef:
              fieldPath: metadata.namespace

  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: workload-identity
      mountPath: /var/run/secrets/workload
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/04-pod-projected-satoken.yaml
kubectl wait --for=condition=Ready pod/pod-projected-satoken --timeout=30s
```

**Verify:**
```bash
# Confirm all three files are present
kubectl exec pod-projected-satoken -- ls -la /var/run/secrets/workload/
# lrwxrwxrwx    ca.crt -> ..data/ca.crt
# lrwxrwxrwx    namespace -> ..data/namespace
# lrwxrwxrwx    token -> ..data/token
# lrwxrwxrwx    ..data -> ..2026_04_26_...
#
# Observation: same symlink structure as ConfigMap volumes — token is rotated
# by kubelet using the same atomic ..data/ swap mechanism.

kubectl exec pod-projected-satoken -- cat /var/run/secrets/workload/namespace
# default

kubectl exec pod-projected-satoken -- head -1 /var/run/secrets/workload/ca.crt
# -----BEGIN CERTIFICATE-----
```

```bash
# Verify the token is a JWT and decode the payload
kubectl exec pod-projected-satoken -- sh -c '
  TOKEN=$(cat /var/run/secrets/workload/token)
  echo "Token starts with: $(echo $TOKEN | cut -c1-30)..."
  PAYLOAD=$(echo $TOKEN | cut -d. -f2)
  # Add padding for base64 decode
  MOD=$((${#PAYLOAD} % 4))
  [ $MOD -ne 0 ] && PAYLOAD="${PAYLOAD}$(printf "=%.0s" $(seq 1 $((4-MOD))))"
  echo "Decoded payload:"
  echo "$PAYLOAD" | base64 -d 2>/dev/null
'
# Token starts with: eyJhbGciOiJSUzI1NiIsImtpZCI6...
# Decoded payload:
# {"aud":["https://kubernetes.default.svc"],"exp":1745700000,"iat":1745696400,
#  "iss":"https://kubernetes.default.svc","kubernetes.io":{"namespace":"default",
#  "pod":{"name":"pod-projected-satoken","uid":"..."},...},"sub":"system:serviceaccount:default:default"}
#
# Observation:
# aud: matches the audience configured in expirationSeconds → audience field
# exp - iat = 3600 seconds — matches expirationSeconds
# kubernetes.io.pod.name — token is bound to this specific pod (invalidated on pod delete)
# sub: system:serviceaccount:default:default — the ServiceAccount identity
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
  volumes:
  # Source: ConfigMap (kernel read-only — cannot write)
  - name: config-source
    configMap:
      name: app-config
      items:
      - key: config.yaml
        path: config.yaml

  # Destination: emptyDir (writable, pod-lifetime, per-pod)
  - name: config-writable
    emptyDir: {}

  initContainers:
  - name: copy-config
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Copying ConfigMap file to writable emptyDir ==="
      cp /config-source/config.yaml /config-writable/config.yaml
      echo "Copied config.yaml"

      # Simulate startup-time template substitution
      sed -i "s/port: 8080/port: 9090/" /config-writable/config.yaml
      echo "Applied port substitution (8080 → 9090)"

      echo "=== Final config in writable volume ==="
      cat /config-writable/config.yaml
    volumeMounts:
    - name: config-source
      mountPath: /config-source
      readOnly: true       # read from ConfigMap
    - name: config-writable
      mountPath: /config-writable   # write to emptyDir

  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: config-writable
      mountPath: /etc/app          # writable — main container reads and writes here
    - name: config-source
      mountPath: /etc/app-source
      readOnly: true               # original ConfigMap — read-only reference
  restartPolicy: Never
```

```bash
kubectl apply -f src/05-pod-initcontainer-writable.yaml
kubectl wait --for=condition=Ready pod/pod-initcontainer-writable --timeout=60s
```

**Verify init container output:**
```bash
kubectl logs pod-initcontainer-writable -c copy-config
# === Copying ConfigMap file to writable emptyDir ===
# Copied config.yaml
# Applied port substitution (8080 → 9090)
# === Final config in writable volume ===
# server:
#   port: 9090          ← substituted by init container
#   timeout: 30s
# logging:
#   level: info
#   format: json
#
# Observation: init container successfully copied and transformed the config.
# The ConfigMap itself was never modified — only the emptyDir copy was changed.
```

**Verify main container sees the transformed config:**
```bash
kubectl exec pod-initcontainer-writable -c app -- cat /etc/app/config.yaml
# server:
#   port: 9090    ← sees the init container's transformed version
#   timeout: 30s
# ...
#
# Observation: main container reads from emptyDir (writable copy), not the ConfigMap.

# Verify the original ConfigMap mount is still unchanged and read-only
kubectl exec pod-initcontainer-writable -c app -- cat /etc/app-source/config.yaml
# server:
#   port: 8080    ← original value — ConfigMap was never modified
```

```bash
# Confirm the emptyDir is writable — main container can write runtime state
kubectl exec pod-initcontainer-writable -c app -- \
  sh -c 'echo "started_at: $(date)" >> /etc/app/runtime.state && cat /etc/app/runtime.state'
# started_at: Mon Apr 26 ...
#
# Observation: write succeeded — emptyDir is writable by the main container.

# Confirm the ConfigMap mount is NOT writable
kubectl exec pod-initcontainer-writable -c app -- \
  sh -c 'echo "test" >> /etc/app-source/config.yaml 2>&1'
# sh: /etc/app-source/config.yaml: Read-only file system
#
# Observation: write blocked — readOnly: true on the ConfigMap volumeMount is kernel-enforced.
```

---

### Step 6 — Cleanup

```bash
kubectl delete pod pod-subpath pod-permissions pod-projected pod-projected-satoken \
  pod-initcontainer-writable 2>/dev/null || true
kubectl delete configmap nginx-config app-config 2>/dev/null || true
kubectl delete secret app-secrets 2>/dev/null || true
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| `subPath` file type | Produces a regular file (bind-mount) — NOT a symlink; no live updates on CM change |
| Full directory mount | Produces symlinks via `..data/` chain; live updates via atomic `rename()` swap |
| `subPath` preservation | Existing directory contents are preserved — only the specified file is added/replaced |
| `defaultMode` | Octal permission applied to all files in the volume; `0444` for ConfigMaps, `0400` for Secrets |
| `items[].mode` | Per-file permission override; takes priority over `defaultMode` |
| `readOnly: true` | Kernel-enforced at mount level; independent of file mode; always set for Secrets |
| `projected` advantage | One volume + one volumeMount for multiple sources; paths control subdirectory layout |
| `serviceAccountToken` | Bound JWT: pod-UID-scoped, audience-scoped, expiring, auto-rotated by kubelet at 80% TTL |
| `kube-root-ca.crt` | Auto-created ConfigMap in every namespace; project alongside SA token for full workload identity bundle |
| `emptyDir` + init container | Correct pattern for writable config; ConfigMap is read-only source, emptyDir is writable destination |
| Init container ordering | Init containers complete before main containers start — safe for config preparation |
| Write error message | `sh: /path/file: Read-only file system` — kernel error when writing to a `readOnly: true` mount |