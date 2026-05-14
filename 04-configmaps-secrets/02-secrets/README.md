# 02 — Secrets

## Concepts

A **Secret** stores sensitive data (passwords, tokens, certificates, SSH keys). Secrets are structurally similar to ConfigMaps — both are key-value stores — but Secrets have important security-oriented differences.

### How Secrets differ from ConfigMaps

| Property | ConfigMap | Secret |
|----------|-----------|--------|
| Purpose | Non-sensitive config | Sensitive data |
| Storage encoding | Plain text in etcd | base64-encoded in etcd |
| etcd encryption | No (by default) | Optional via `EncryptionConfiguration` |
| In-memory delivery | No — files on node disk | Yes — kubelet stores secret volumes in `tmpfs` (RAM); never written to node disk |
| RBAC visibility | Standard `get configmaps` verb | Separate `get secrets` verb — restrict tightly |
| `stringData` write field | No | Yes — accepts plain strings; auto-base64 on write; absent on read |

> **Important:** base64 is **encoding**, not encryption. Anyone with `kubectl get secret -o yaml` and access can decode it instantly. Real security requires: (1) RBAC — restrict `get`/`list` on Secrets, (2) etcd encryption at rest via `EncryptionConfiguration`, (3) External secret stores (Vault, AWS Secrets Manager, External Secrets Operator).

### Built-in Secret types

| Type | Used for |
|------|---------|
| `Opaque` | Arbitrary user-defined data (default) |
| `kubernetes.io/service-account-token` | ServiceAccount tokens (auto-created) |
| `kubernetes.io/dockerconfigjson` | Private registry pull credentials |
| `kubernetes.io/tls` | TLS certificate + key pairs |
| `kubernetes.io/basic-auth` | username + password |
| `kubernetes.io/ssh-auth` | SSH private key |
| `bootstrap.kubernetes.io/token` | Node bootstrap tokens |

The type field is validated by the API server — for typed secrets, required keys must be present or creation is rejected.

### `optional` field behaviour

Identical to ConfigMaps — verified by testing:

| Scenario | `optional` omitted (default) | `optional: true` |
|----------|------------------------------|-----------------|
| Secret exists, key exists | ✅ Env var set correctly | ✅ Env var set correctly |
| Secret exists, key missing | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not empty string) |
| Secret does not exist | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not empty string) |

### Immutable Secrets

Same mechanism as ConfigMaps — `immutable: true` seals the Secret. The API server rejects all updates. The kubelet stops watching it, eliminating the persistent watch connection overhead. Delete + recreate is the only way to change it.

### ConfigMap vs Secret — What Is Different and Why It Matters

It is worth understanding exactly
what changes when you use a Secret instead of a ConfigMap, because the
difference goes deeper than just the resource type name.

**ConfigMap — plain text, no protection:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DB_HOST: postgres.internal     # visible in plain text
  DB_PORT: "5432"                # visible in plain text
```

A ConfigMap stores its data as plain UTF-8 text in etcd with no encoding or
encryption applied by Kubernetes itself. Anyone with `kubectl get configmap`
access can read every value. The data appears in `kubectl describe`, in audit
logs, and in any backup of etcd — all in cleartext.

**Secret — base64-encoded, access-controlled, encryption-eligible:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
  DB_PASSWORD: c3VwZXJzZWNyZXQ=   # base64("supersecret") — NOT encryption
  API_KEY: bXlhcGlrZXk=
```

Kubernetes stores the Secret value as base64 in etcd. Base64 is **not
encryption** — it is encoding, and is trivially reversible. However, Secrets
give you four meaningful security properties that ConfigMaps do not:

**1. RBAC separation**
Secrets and ConfigMaps are separate Kubernetes API resources. Your RBAC policy
can grant a service account access to ConfigMaps but not Secrets, or grant read
access to specific Secrets by name. With ConfigMaps, sensitive values are mixed
with non-sensitive config — you cannot grant one without the other. Secrets let
you draw a clear permission boundary.

```
developer role:    get/list ConfigMaps ✅   get/list Secrets ✗
app service account: get specific Secret by name ✅
ops role:          get/list/create Secrets ✅
```

**2. Encryption at rest (when enabled)**
Kubernetes supports encrypting Secrets at rest in etcd using an
`EncryptionConfiguration` object. When enabled, Secret values are AES-GCM or
AES-CBC encrypted before being written to etcd. ConfigMap values are never
eligible for this encryption path — they are always stored as plaintext in etcd.
This is one of the primary reasons Secrets exist as a separate resource type.

**3. No accidental logging**
Kubernetes components and many CI/CD tools have special handling for Secret
values — they are masked in pod specs, omitted from certain audit log fields,
and excluded from `kubectl describe` output where possible. ConfigMap values
have no such treatment and appear in full everywhere.

**4. External secret store integration**
Tools like Sealed Secrets, Vault Agent Injector, External Secrets Operator,
and AWS Secrets Manager integrations all target the Secret resource type. They
can inject or sync values into Secrets without your application code knowing
where the value came from. ConfigMaps have no equivalent ecosystem.

**Summary — ConfigMap vs Secret for sensitive data:**

| Property | ConfigMap | Secret |
|---|---|---|
| Storage encoding | Plain text | Base64 (not encryption) |
| etcd encryption at rest | Not eligible | Eligible when configured |
| RBAC separation | No — mixed with config | Yes — separate resource type |
| Audit log masking | No | Partial (tool-dependent) |
| External secret store support | No | Yes (Vault, ESO, Sealed Secrets) |
| Use for | Non-sensitive config (hostnames, ports, feature flags) | Credentials, tokens, TLS certs, API keys |

---

### How Volume-Mounted Secrets Increase Security Over Environment Variables

Secrets can be consumed two ways: as environment variables or as volume-mounted
files. Volume mounting is the more secure approach, and understanding why
requires looking at what happens at the OS level in both cases.

**Environment variable injection — what happens:**

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-secret
        key: DB_PASSWORD
```

When a pod starts, the kubelet reads the Secret value and injects it directly
into the container's environment. From that point:

- The value lives in the process environment table — readable via `/proc/self/environ`
  from inside the container
- Child processes spawned by your application inherit the environment — the
  secret leaks to every subprocess, including shells, debug tools, and log
  collectors that read process environment
- Crash dumps, core files, and diagnostic tools that enumerate process state
  often capture environment variables
- Many logging frameworks accidentally log environment variables during
  startup or exception handling
- Environment variables **cannot be updated without restarting the pod** — a
  rotated secret requires a pod restart to take effect

**Volume-mounted files — what happens:**

```yaml
volumes:
  - name: secret-vol
    secret:
      secretName: app-secret
volumeMounts:
  - name: secret-vol
    mountPath: /etc/secrets
    readOnly: true
```

The kubelet mounts the Secret as files under `/etc/secrets/`. Each key in the
Secret becomes one file. Your application reads the file at runtime. The
difference in the security properties:

- The value is **not** in the process environment — it cannot leak through
  environment inheritance or environment enumeration
- The file is mounted `readOnly: true` — the container cannot modify it
- **The file lives in `tmpfs`** — a RAM-backed filesystem. The Secret value
  never touches the node's disk. If the node is powered off, the file is gone.
  A disk image of the node does not contain the secret.
- **Secret rotation propagates without pod restart** — explained in the next
  section

**tmpfs — why it matters:**

Standard node storage writes files to disk. `tmpfs` is a virtual filesystem
that exists entirely in RAM. The kubelet mounts Secrets into pods using `tmpfs`
specifically so that secret values never persist to the node's physical disk.

```
ConfigMap or Secret as environment variable:
  Secret value → process environment table → inherited by child processes
  → potentially in crash dumps, log output, /proc/self/environ

Secret as volume-mounted file (tmpfs):
  Secret value → RAM only → /etc/secrets/DB_PASSWORD (read-only)
  → not in environment → not in process table → not on disk
  → not inherited by child processes
```

This does not make secrets invulnerable — a root user inside the container can
still read the file — but it eliminates the entire class of accidental disk
persistence and environment inheritance leaks.

---

### How Secret Propagation Works — The Symlink Chain Mechanism

When a Secret is updated in Kubernetes, the new value must reach the running
pod without restarting it. Similar to ConfigMap , The kubelet uses a symlink chain to achieve atomic, consistent updates:

```
/etc/secrets/                       ← mountPath (the mount point your app reads)
├── DB_PASSWORD → ..data/DB_PASSWORD    ← symlink to ..data/
├── API_KEY     → ..data/API_KEY
└── ..data      → ..2024_01_15_10_30_00.123456789/   ← symlink to timestamped dir
    └── 2024_01_15_10_30_00.123456789/
        ├── DB_PASSWORD    ← actual file with secret value (in tmpfs)
        └── API_KEY
```

**Update sequence — step by step:**

```
1. You update a secret DB_PASSWORD.
   API server → updates the Kubernetes Secret object in etcd.

2. kubelet's Secret watch detects the Secret version changed.

3. kubelet writes the new values to a NEW timestamped directory:
   /etc/secrets/..2024_01_15_11_00_00.987654321/
     DB_PASSWORD  ← new value
     API_KEY      ← unchanged value

4. kubelet atomically re-points the ..data symlink:
   ..data → ..2024_01_15_11_00_00.987654321/
   (this is a single rename() syscall — atomic at the filesystem level)

5. The old timestamped directory is deleted.

6. Your application next time it reads /etc/secrets/DB_PASSWORD:
   follows DB_PASSWORD → ..data/DB_PASSWORD
   → ..data now points at the new directory
   → reads the new value

   No pod restart. No signal to the process. The file content changed.
```

**Why this is atomic:**
The `..data` symlink swap is a single `rename()` syscall. From the application's
perspective, there is no moment where a partial write is visible — either the
old value is returned or the new value is returned, never a half-written value.
This is the same mechanism used for ConfigMap volume updates.

**The kubelet sync interval:**
Secret updates do not propagate instantly. The kubelet polls for Secret changes
on a configurable interval (default: every 60 seconds via `--sync-frequency`).
After the kubelet detects the change, the file update is complete within seconds.
Total propagation time is typically under 2 minutes from Secret update to file
change inside the pod.

**Application-side requirement:**
The application must re-read the file to pick up the new value. An application
that reads credentials once at startup and caches them in memory will not benefit
from in-place propagation — it still needs a restart. Applications designed for
secret rotation typically read the file on each use or watch for file change
events using `inotify`.

**ConfigMap propagation — identical mechanism:**
ConfigMap volume mounts use the same symlink chain. The behaviour described
above applies equally to ConfigMaps mounted as volumes. The difference is that
ConfigMaps are not eligible for etcd encryption and do not benefit from the
RBAC and tooling ecosystem that Secrets have.

---

## Directory Structure

```
02-secrets/
├── README.md
└── src/
    ├── 01-secret-opaque.yaml             # Opaque secret with base64 data
    ├── 02-secret-stringdata.yaml         # Opaque secret with plain-text stringData
    ├── 03-secret-dockerconfigjson.yaml   # Private registry pull secret (reference)
    ├── 04-secret-tls.yaml                # TLS secret structure (reference)
    ├── 05-pod-secret-env.yaml            # Pod consuming secret as env vars
    └── 06-pod-secret-volume.yaml         # Pod consuming secret as volume-mounted files
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes
# NAME           STATUS   ROLES           AGE   VERSION
# 3node          Ready    control-plane   ...   v1.32.0
# 3node-m02      Ready    <none>          ...   v1.32.0
# 3node-m03      Ready    <none>          ...   v1.32.0
```

---

### Step 1 — Create an Opaque Secret with base64 data

Secret `data` values **must** be base64-encoded. Always use `echo -n` (no trailing newline) — a trailing newline changes the base64 value and the decoded secret will have an invisible newline appended.

```bash
# Demonstrate why -n matters
echo "admin" | base64        # YWRtaW4K=   ← trailing newline included — WRONG
echo -n "admin" | base64     # YWRtaW4=   ← no trailing newline — CORRECT

# Generate the values used in the manifest below
echo -n "admin" | base64              # YWRtaW4=
echo -n "S3cur3P@ss!" | base64        # UzNjdXIzUEBzcyE=
echo -n "my-api-key-12345" | base64   # bXktYXBpLWtleS0xMjM0NQ==
```

**01-secret-opaque.yaml:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: default
type: Opaque   # default type for arbitrary key-value secrets
data:
  # All values must be base64-encoded — use echo -n | base64 to generate
  username: YWRtaW4=           # "admin"
  password: UzNjdXIzUEBzcyE=  # "S3cur3P@ss!"
  api-key: bXktYXBpLWtleS0xMjM0NQ==  # "my-api-key-12345"
```

```bash
kubectl apply -f src/01-secret-opaque.yaml
```

**Verify:**
```bash
kubectl get secret db-credentials
# NAME             TYPE     DATA   AGE
# db-credentials   Opaque   3      2s
#
# Observation: DATA column shows 3 — the number of keys in the secret.
# Values are never shown in kubectl get output — only key count and metadata.
```

```bash
# -o yaml shows base64-encoded values — never plain text
kubectl get secret db-credentials -o yaml
# apiVersion: v1
# data:
#   api-key: bXktYXBpLWtleS0xMjM0NQ==
#   password: UzNjdXIzUEBzcyE=
#   username: YWRtaW4=
# kind: Secret
# metadata:
#   name: db-credentials
#   namespace: default
# type: Opaque
#
# Observation: values are base64-encoded in the API — not encrypted, just encoded.
# Anyone with kubectl access can decode them with: | base64 -d
```

```bash
# Decode individual values to verify correctness
kubectl get secret db-credentials -o jsonpath='{.data.username}' | base64 -d
# admin

kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d
# S3cur3P@ss!

kubectl get secret db-credentials -o jsonpath='{.data.api-key}' | base64 -d
# my-api-key-12345
#
# Observation: the decoded values match exactly what was encoded.
# Note: base64 -d output has no trailing newline — the terminal prompt appears on the same line.
# Add echo "" after if needed for clean formatting.
```

---

### Step 2 — Create a Secret with stringData

`stringData` accepts **plain-text** values — the API server base64-encodes them on write. This is more readable in manifests (no manual base64 step) but the stored object only exposes the `data` field. `stringData` is write-only — it is never returned in GET responses.

**02-secret-stringdata.yaml:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: default
type: Opaque
# stringData: plain text values — API server base64-encodes on write
# Write-only field: GET returns only the data field (base64), never stringData
# If a key appears in BOTH data and stringData, stringData wins
stringData:
  DB_HOST: "postgres.default.svc.cluster.local"
  DB_PORT: "5432"
  DB_NAME: "appdb"
  DB_PASSWORD: "plaintext-password-here"
  JWT_SECRET: |
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7...
    -----END PRIVATE KEY-----
```

```bash
kubectl apply -f src/02-secret-stringdata.yaml
```

**Verify — confirm stringData is gone from the stored object:**
```bash
# -o yaml shows the stored form — stringData is absent, only data (base64) is present
kubectl get secret app-secrets -o yaml
# apiVersion: v1
# data:
#   DB_HOST: cG9zdGdyZXMuZGVmYXVsdC5zdmMuY2x1c3Rlci5sb2NhbA==
#   DB_NAME: YXBwZGI=
#   DB_PASSWORD: cGxhaW50ZXh0LXBhc3N3b3JkLWhlcmU=
#   DB_PORT: NTQzMg==
#   JWT_SECRET: LS0tLS1CRUdJTi...
# kind: Secret
# ...
# (no stringData field in the output)
#
# Observation: stringData is a write-only convenience field.
# After creation, the API only returns data (base64). stringData is absent.
# This confirms the API server converted the plain text values to base64 on write.

# Decode DB_PASSWORD to verify round-trip
kubectl get secret app-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# plaintext-password-here
#
# Observation: decoded value matches the stringData value exactly.
```

---

### Step 3 — Docker registry pull Secret

`kubernetes.io/dockerconfigjson` is used to pull images from private registries. The imperative command is the recommended approach — it builds the required JSON structure correctly.

```bash
kubectl create secret docker-registry private-registry \
  --docker-server=registry.example.com \
  --docker-username=myuser \
  --docker-password=mypassword \
  --docker-email=myuser@example.com
```

**Verify:**
```bash
kubectl get secret private-registry
# NAME               TYPE                             DATA   AGE
# private-registry   kubernetes.io/dockerconfigjson   1      3s
#
# Observation: type is kubernetes.io/dockerconfigjson — NOT Opaque.
# DATA=1 means one key: .dockerconfigjson

# Inspect the generated JSON structure
kubectl get secret private-registry -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
# {"auths":{"registry.example.com":{"username":"myuser","password":"mypassword","email":"myuser@example.com","auth":"bXl1c2VyOm15cGFzc3dvcmQ="}}}
#
# Observation: the auth field is base64("myuser:mypassword").
# This is the standard Docker registry authentication format.
```

For reference, the declarative form (reference only — use imperative above):

**03-secret-dockerconfigjson.yaml:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: private-registry-ref
  namespace: default
# This type enforces that the .dockerconfigjson key must be present
type: kubernetes.io/dockerconfigjson
data:
  # Value is a base64-encoded JSON: {"auths":{"server":{"username":"...","password":"...","auth":"..."}}}
  # Generate with: kubectl create secret docker-registry ... --dry-run=client -o yaml
  .dockerconfigjson: eyJhdXRocyI6eyJyZWdpc3RyeS5leGFtcGxlLmNvbSI6eyJ1c2VybmFtZSI6Im15dXNlciIsInBhc3N3b3JkIjoibXlwYXNzd29yZCIsImF1dGgiOiJiWGwxYzJWeU9tMTVjR0Z6YzNkdmNtUT0ifX19
```

**To use a pull secret in a Pod:**
```yaml
spec:
  imagePullSecrets:
  - name: private-registry   # reference the secret by name
  containers:
  - name: app
    image: registry.example.com/myapp:latest
```

---

### Step 4 — TLS Secret (reference)

**04-secret-tls.yaml:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: tls-secret
  namespace: default
# kubernetes.io/tls type enforces that tls.crt and tls.key keys must both be present
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-PEM-certificate>   # base64 of the PEM cert file
  tls.key: <base64-encoded-PEM-private-key>   # base64 of the PEM key file
# Imperative equivalent:
# kubectl create secret tls tls-secret --cert=path/to/cert.crt --key=path/to/key.key
```

> **TLS Secrets in practice:** Ingress controllers (Traefik, nginx) and cert-manager reference TLS Secrets by name. cert-manager creates and auto-rotates them. See `14-ingress/` for full TLS labs.

---

### Step 5 — Consume Secret as environment variables

**05-pod-secret-env.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-env
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    env:
    # secretKeyRef: identical pattern to configMapKeyRef — same fields, same behaviour
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-credentials   # Secret name
          key: username          # key inside the Secret
    - name: DB_PASS
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password
          # optional: true       # if true and secret/key missing: pod starts, var is ABSENT
    - name: API_KEY
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: api-key
    # envFrom for Secrets — loads ALL keys as env vars (same as ConfigMap envFrom):
    # envFrom:
    # - secretRef:
    #     name: db-credentials
  restartPolicy: Never
```

```bash
kubectl apply -f src/05-pod-secret-env.yaml
kubectl wait --for=condition=Ready pod/pod-secret-env --timeout=30s
```

**Verify using `printenv`:**
```bash
# Check each secret-sourced env var by its renamed container name
kubectl exec pod-secret-env -- printenv DB_USER DB_PASS API_KEY
# DB_USER=admin
# DB_PASS=S3cur3P@ss!
# API_KEY=my-api-key-12345
#
# Observation: the decoded secret values are visible as plain text in the container's environment.
# This is expected and correct — the container must be able to use the value.
# Security is enforced at the Kubernetes layer (RBAC on Secrets), not inside the container.
```

```bash
# Confirm the secret keys are NOT present under their original names
kubectl exec pod-secret-env -- printenv | grep -E 'username|password|api-key'
# (no output)
#
# Observation: the original Secret keys (username, password, api-key) are not in the environment.
# Only the renamed versions (DB_USER, DB_PASS, API_KEY) are present.
```

---

**Failure scenario — CreateContainerConfigError when Secret is missing:**

```bash
kubectl delete pod pod-secret-env
kubectl delete secret db-credentials

kubectl apply -f src/05-pod-secret-env.yaml
```

```bash
kubectl get pods
# NAME             READY   STATUS                       RESTARTS   AGE
# pod-secret-env   0/1     CreateContainerConfigError   0          4s
#
# Observation: identical behaviour to a missing ConfigMap.
# The kubelet cannot start the container until all referenced Secrets exist.
```

```bash
kubectl describe pod pod-secret-env
# ...
# Events:
#   Type     Reason     Age              From      Message
#   ----     ------     ----             ----      -------
#   Normal   Scheduled  15s              scheduler Successfully assigned default/pod-secret-env to 3node-m02
#   Normal   Pulled     3s (x3 over 14s) kubelet   Container image "busybox:1.36" already present on machine
#   Warning  Failed     3s (x3 over 14s) kubelet   Error: secret "db-credentials" not found
#
# Observation: Warning event — "secret db-credentials not found"
# The kubelet retries every few seconds. Pod recovers automatically when Secret is recreated.
```

```bash
# Recreate the Secret — pod recovers automatically
kubectl apply -f src/01-secret-opaque.yaml

kubectl get pods -w
# NAME             READY   STATUS                       RESTARTS   AGE
# pod-secret-env   0/1     CreateContainerConfigError   0          30s
# pod-secret-env   1/1     Running                      0          33s
#
# Observation: pod transitions to Running without any manual pod delete or reapply.
```

---

### Step 6 — Consume Secret as volume-mounted files

Volume-mounted Secrets are stored in `tmpfs` (RAM-backed filesystem) on the node. Files never touch node disk storage. The same symlink chain mechanism used for ConfigMaps applies here — the same atomic update behaviour.

**06-pod-secret-volume.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-volume
  namespace: default
spec:
  volumes:
  - name: db-creds
    secret:
      secretName: db-credentials
      # defaultMode: 0400   # recommended: owner read-only for all files in this volume
      items:
      - key: username
        path: db/username   # creates subdirectory db/ inside mountPath
        mode: 0400          # owner read-only per file
      - key: password
        path: db/password
        mode: 0400
  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Symlink structure at mountPath ==="
      ls -la /etc/secrets/
      echo ""
      echo "=== Symlink structure inside db/ subdir ==="
      ls -la /etc/secrets/db/
      echo ""
      echo "=== File permissions ==="
      ls -la /etc/secrets/..data/db/
      echo ""
      echo "=== Secret values ==="
      echo "Username: $(cat /etc/secrets/db/username)"
      echo "Password: $(cat /etc/secrets/db/password)"
      echo ""
      echo "=== Verify tmpfs — RAM-backed, not disk ==="
      df -h /etc/secrets
      sleep 3600
    volumeMounts:
    - name: db-creds
      mountPath: /etc/secrets
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/06-pod-secret-volume.yaml
kubectl wait --for=condition=Ready pod/pod-secret-volume --timeout=30s
```

**Check pod logs:**
```bash
kubectl logs pod/pod-secret-volume
# === Symlink structure at mountPath ===
# lrwxrwxrwx    1 root     root    ... ..data -> ..2026_04_26_10_30_00.123456789
# drwxr-xr-x    1 root     root    ... ..2026_04_26_10_30_00.123456789
# lrwxrwxrwx    1 root     root    ... db -> ..data/db
#
# === Symlink structure inside db/ subdir ===
# lrwxrwxrwx    1 root     root    ... password -> ../..data/db/password
# lrwxrwxrwx    1 root     root    ... username -> ../..data/db/username
#
# === File permissions ===
# -r--------    1 root     root    ... password    ← 0400: owner read-only
# -r--------    1 root     root    ... username    ← 0400: owner read-only
#
# === Secret values ===
# Username: admin
# Password: S3cur3P@ss!
#
# === Verify tmpfs — RAM-backed, not disk ===
# Filesystem      Size  Used Avail Use% Mounted on
# tmpfs           ...   ...  ...   ...  /etc/secrets
#
# Observation: Filesystem type is tmpfs — RAM-backed.
# Secret data never touches node disk storage.
# The same ..data symlink chain as ConfigMaps enables atomic updates.
# 0400 permissions: only the owner (root) can read — group and others have no access.
```

**Verify file structure directly:**
```bash
# Top-level: db is a symlink (items used db/ as subdir prefix)
kubectl exec pod-secret-volume -- ls -la /etc/secrets/
# lrwxrwxrwx  ..data -> ..2026_04_26_...
# lrwxrwxrwx  db -> ..data/db
#
# Observation: 'db' entry is a symlink to ..data/db, not a real directory.
# Same two-level chain as ConfigMaps: db → ..data/db → timestamped-dir/db/

# Files inside db/ — accessed via the symlink chain
kubectl exec pod-secret-volume -- ls -la /etc/secrets/db/
# lrwxrwxrwx  password -> ../..data/db/password
# lrwxrwxrwx  username -> ../..data/db/username
#
# Observation: each projected file is a symlink, not a real file.

# Read the values — symlink resolution is transparent to cat
kubectl exec pod-secret-volume -- cat /etc/secrets/db/username
# admin

kubectl exec pod-secret-volume -- cat /etc/secrets/db/password
# S3cur3P@ss!

# Confirm tmpfs
kubectl exec pod-secret-volume -- df -h /etc/secrets
# Filesystem      Size  Used Avail Use% Mounted on
# tmpfs           ...              ...  /etc/secrets
#
# Observation: tmpfs confirms RAM-backed delivery — data never written to node disk.
```

---

### Step 7 — Imperative Secret creation (exam technique)

**Opaque from literals:**
```bash
kubectl create secret generic exam-secret \
  --from-literal=username=admin \
  --from-literal=password=secret123

kubectl get secret exam-secret -o yaml
# apiVersion: v1
# data:
#   password: c2VjcmV0MTIz
#   username: YWRtaW4=
# kind: Secret
# type: Opaque
#
# Observation: kubectl handles base64 encoding automatically — no manual encoding needed.

# Decode to verify
kubectl get secret exam-secret -o jsonpath='{.data.username}' | base64 -d
# admin
kubectl get secret exam-secret -o jsonpath='{.data.password}' | base64 -d
# secret123
```

**From a file:**
```bash
# Use echo -n to avoid trailing newline in the secret value
echo -n "s3cr3t-token-value" > /tmp/token.txt

# Verify file content — no trailing newline
cat /tmp/token.txt
# s3cr3t-token-value

kubectl create secret generic token-secret --from-file=/tmp/token.txt
kubectl get secret token-secret -o jsonpath='{.data.token\.txt}' | base64 -d
# s3cr3t-token-value
#
# Observation: key name = filename (token.txt); value = file content base64-encoded

# Custom key name
kubectl create secret generic token-secret2 --from-file=token=/tmp/token.txt
kubectl get secret token-secret2 -o jsonpath='{.data.token}' | base64 -d
# s3cr3t-token-value
#
# Observation: key name is now "token" instead of "token.txt"
```

**Dry-run — scaffold YAML (essential exam technique):**
```bash
kubectl create secret generic exam-secret2 \
  --from-literal=username=admin \
  --from-literal=password=secret123 \
  --dry-run=client -o yaml
# apiVersion: v1
# data:
#   password: c2VjcmV0MTIz
#   username: YWRtaW4=
# kind: Secret
# metadata:
#   creationTimestamp: null
#   name: exam-secret2
# type: Opaque
#
# Observation: --dry-run=client -o yaml outputs a complete manifest with values pre-encoded.
# Redirect to a file or pipe to kubectl apply -f - for immediate use.
```

---

### Step 8 — Cleanup

```bash
kubectl delete pod pod-secret-env pod-secret-volume 2>/dev/null || true
kubectl delete secret db-credentials app-secrets private-registry private-registry-ref \
  tls-secret exam-secret exam-secret2 token-secret token-secret2 2>/dev/null || true
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| base64 is NOT encryption | Anyone with `get secret` access can decode instantly; use RBAC + etcd encryption at rest |
| `echo -n` required | Without `-n`, `echo` adds a trailing newline that changes the base64 value and corrupts the decoded secret |
| `data` vs `stringData` | `data` requires manual base64; `stringData` accepts plain text and is auto-encoded on write |
| `stringData` is write-only | It is converted to `data` on write and never returned on GET — only `data` appears in stored object |
| `tmpfs` delivery | Volume-mounted secrets live in RAM on the node — never written to node disk |
| Symlink chain | Same two-level `key → ..data/key → timestamped-dir/key` mechanism as ConfigMaps; atomic updates apply |
| `0400` file mode | Owner read-only — correct default for secret files; set via `defaultMode` or per-file `mode` |
| `optional` field | Omitted: `CreateContainerConfigError` if Secret/key missing; `true`: pod starts, env var is **absent** (not empty string) |
| Pod auto-recovers | `CreateContainerConfigError` pod recovers automatically once the missing Secret is recreated |
| `imagePullSecrets` | Attach `kubernetes.io/dockerconfigjson` secrets to pull from private registries |
| Typed Secrets | Type field validated by API server — required keys must exist or creation is rejected |
| `immutable: true` | Seals the Secret; kubelet stops watching; reduces apiserver watch load; delete+recreate to change |
| Env var update | Secret env vars require pod restart to pick up changes; volume-mounted secrets update within syncFrequency |