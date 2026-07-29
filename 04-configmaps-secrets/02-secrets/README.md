# Demo: 04-configmaps-secrets/02-secrets — Secrets

## Lab Overview

A **Secret** stores sensitive data (passwords, tokens, certificates, SSH
keys). Secrets are structurally similar to ConfigMaps — both are
key-value stores, both use the same consumption methods, and both share
the exact same symlink-chain update mechanism covered in full in
`01-configmaps` — but Secrets have important security-oriented
differences that this demo focuses on entirely: base64 encoding (and why
it's not encryption), RBAC separation, `tmpfs`-backed volume delivery,
and typed Secrets with API-enforced required keys.

**What this lab covers:**
- How Secrets differ from ConfigMaps, and why that difference matters
- Built-in Secret types and their enforced required keys
- `data` (manual base64) vs `stringData` (plain text, auto-encoded, write-only)
- Why volume-mounted Secrets are more secure than env-var Secrets — the OS-level reasoning
- `tmpfs` — why Secret files never touch node disk
- Imperative Secret creation, including `docker-registry` and `tls` types

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-configmaps` (this demo assumes you already understand the symlink-chain update mechanism, `optional` field behavior, and all three consumption methods from that demo — none of it is re-explained here)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain what changes, concretely, when using a Secret instead of a ConfigMap for sensitive data
2. ✅ Explain why base64 is encoding, not encryption, and what actually protects a Secret's value
3. ✅ Create Secrets using `data` (manual base64) and `stringData` (plain text, write-only)
4. ✅ Explain why volume-mounted Secrets are more secure than env-var Secrets, at the OS level
5. ✅ Explain why `tmpfs` matters for Secret volume delivery
6. ✅ Create typed Secrets (`Opaque`, `docker-registry`, `tls`) and explain what the API server validates for each
7. ✅ Create Secrets imperatively, including via `--from-literal` and `--from-file`

## Directory Structure

```
04-configmaps-secrets/02-secrets/
├── README.md
└── src/
    ├── 01-secret-opaque.yaml             # Opaque secret with base64 data
    ├── 02-secret-stringdata.yaml         # Opaque secret with plain-text stringData
    ├── 03-secret-dockerconfigjson.yaml   # Private registry pull secret (reference)
    ├── 04-secret-tls.yaml                # TLS secret structure (reference)
    ├── 05-pod-secret-env.yaml            # Pod consuming secret as env vars
    ├── 06-pod-secret-volume.yaml         # Pod consuming secret as volume-mounted files
    └── break-fix/
        ├── 01-missing-echo-n.yaml            # Embedded inline in README — not generated on disk
        └── 02-tls-missing-required-key.yaml   # Embedded inline in README — not generated on disk
```

---

## Recall Check — 01-configmaps

Answer from memory before continuing — no peeking at the previous demo.

1. What does `immutable: true` eliminate at the control-plane level, beyond just blocking edits?
2. Do `envFrom`-loaded ConfigMap values ever update in a running container without a restart?
3. If `optional: true` and the referenced ConfigMap/key is missing, is the env var set to an empty string?

<details>
<summary>Answers</summary>

1. The kubelet watch connection for that ConfigMap on every consuming node — reducing API server goroutine count, memory, and event load at scale.
2. No — never, regardless of how long you wait. The value is baked into the process environment once at container start.
3. No — it's absent entirely, not present-with-empty-value.

</details>

---

## Concepts

A **Secret** stores sensitive data (passwords, tokens, certificates, SSH keys). Secrets are structurally similar to ConfigMaps — both are key-value stores — but Secrets have important security-oriented differences.

### How Secrets differ from ConfigMaps

| Property                 | ConfigMap                      | Secret                                                                           |
| ------------------------ | ------------------------------- | ---------------------------------------------------------------------------------- |
| Purpose                  | Non-sensitive config            | Sensitive data                                                                    |
| Storage encoding         | Plain text in etcd             | base64-encoded in etcd                                                           |
| etcd encryption          | No (by default)                | Optional via `EncryptionConfiguration`                                           |
| In-memory delivery       | No — files on node disk        | Yes — kubelet stores secret volumes in `tmpfs` (RAM); never written to node disk |
| RBAC visibility          | Standard `get configmaps` verb | Separate `get secrets` verb — restrict tightly                                   |
| `stringData` write field | No                              | Yes — accepts plain strings; auto-base64 on write; absent on read                |

> **Important:** base64 is **encoding**, not encryption. Anyone with `kubectl get secret -o yaml` and access can decode it instantly. Real security requires: (1) RBAC — restrict `get`/`list` on Secrets, (2) etcd encryption at rest via `EncryptionConfiguration`, (3) External secret stores (Vault, AWS Secrets Manager, External Secrets Operator).

----

### Built-in Secret types

| Type                                  | Used for                              |
| -------------------------------------- | -------------------------------------- |
| `Opaque`                               | Arbitrary user-defined data (default) |
| `kubernetes.io/service-account-token`  | ServiceAccount tokens (auto-created)  |
| `kubernetes.io/dockerconfigjson`       | Private registry pull credentials     |
| `kubernetes.io/tls`                    | TLS certificate + key pairs            |
| `kubernetes.io/basic-auth`             | username + password                    |
| `kubernetes.io/ssh-auth`               | SSH private key                        |
| `bootstrap.kubernetes.io/token`        | Node bootstrap tokens                  |

The type field is validated by the API server — for typed secrets, required keys must be present or creation is rejected. This demo's Break-Fix Error-2 shows exactly what that rejection looks like for `kubernetes.io/tls`.

----

### `optional` field behaviour

Identical to ConfigMaps (`01-configmaps`) — verified by testing:

| Scenario                   | `optional` omitted (default)   | `optional: true`                                       |
| --------------------------- | -------------------------------- | ---------------------------------------------------------- |
| Secret exists, key exists  | ✅ Env var set correctly        | ✅ Env var set correctly                                |
| Secret exists, key missing | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not empty string) |
| Secret does not exist      | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not empty string) |

----

### Immutable Secrets

Same mechanism as ConfigMaps — `immutable: true` seals the Secret. The API server rejects all updates. The kubelet stops watching it, eliminating the persistent watch connection overhead. Delete + recreate is the only way to change it.

----

### ConfigMap vs Secret — What Is Different and Why It Matters

It is worth understanding exactly what changes when you use a Secret instead of a ConfigMap, because the difference goes deeper than just the resource type name.

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

A ConfigMap stores its data as plain UTF-8 text in etcd with no encoding or encryption applied by Kubernetes itself. Anyone with `kubectl get configmap` access can read every value. The data appears in `kubectl describe`, in audit logs, and in any backup of etcd — all in cleartext.

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

Kubernetes stores the Secret value as base64 in etcd. Base64 is **not encryption** — it is encoding, and is trivially reversible. However, Secrets give you four meaningful security properties that ConfigMaps do not:

**1. RBAC separation.** Secrets and ConfigMaps are separate Kubernetes API resources. Your RBAC policy can grant a service account access to ConfigMaps but not Secrets, or grant read access to specific Secrets by name. With ConfigMaps, sensitive values are mixed with non-sensitive config — you cannot grant one without the other. Secrets let you draw a clear permission boundary.

```
developer role:       get/list ConfigMaps ✅   get/list Secrets ✗
app service account:  get specific Secret by name ✅
ops role:             get/list/create Secrets ✅
```

**2. Encryption at rest (when enabled).** Kubernetes supports encrypting Secrets at rest in etcd using an `EncryptionConfiguration` object. When enabled, Secret values are AES-GCM or AES-CBC encrypted before being written to etcd. ConfigMap values are never eligible for this encryption path — they are always stored as plaintext in etcd. This is one of the primary reasons Secrets exist as a separate resource type.

**3. No accidental logging.** Kubernetes components and many CI/CD tools have special handling for Secret values — they are masked in pod specs, omitted from certain audit log fields, and excluded from `kubectl describe` output where possible. ConfigMap values have no such treatment and appear in full everywhere.

**4. External secret store integration.** Tools like Sealed Secrets, Vault Agent Injector, External Secrets Operator, and AWS Secrets Manager integrations all target the Secret resource type. They can inject or sync values into Secrets without your application code knowing where the value came from. ConfigMaps have no equivalent ecosystem.

**Summary — ConfigMap vs Secret for sensitive data:**

| Property                      | ConfigMap                                              | Secret                                    |
| ------------------------------ | -------------------------------------------------------- | -------------------------------------------- |
| Storage encoding               | Plain text                                                | Base64 (not encryption)                    |
| etcd encryption at rest        | Not eligible                                              | Eligible when configured                    |
| RBAC separation                | No — mixed with config                                    | Yes — separate resource type               |
| Audit log masking              | No                                                         | Partial (tool-dependent)                    |
| External secret store support  | No                                                         | Yes (Vault, ESO, Sealed Secrets)            |
| Use for                        | Non-sensitive config (hostnames, ports, feature flags)    | Credentials, tokens, TLS certs, API keys   |

----

### How Volume-Mounted Secrets Increase Security Over Environment Variables

Secrets can be consumed two ways: as environment variables or as volume-mounted files. Volume mounting is the more secure approach, and understanding why requires looking at what happens at the OS level in both cases.

**Environment variable injection — what happens:**

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: app-secret
        key: DB_PASSWORD
```

When a pod starts, the kubelet reads the Secret value and injects it directly into the container's environment. From that point:

- The value lives in the process environment table — readable via `/proc/self/environ` from inside the container
- Child processes spawned by your application inherit the environment — the secret leaks to every subprocess, including shells, debug tools, and log collectors that read process environment
- Crash dumps, core files, and diagnostic tools that enumerate process state often capture environment variables
- Many logging frameworks accidentally log environment variables during startup or exception handling
- Environment variables **cannot be updated without restarting the pod** — a rotated secret requires a pod restart to take effect

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

The kubelet mounts the Secret as files under `/etc/secrets/`. Each key in the Secret becomes one file. Your application reads the file at runtime. The difference in the security properties:

- The value is **not** in the process environment — it cannot leak through environment inheritance or environment enumeration
- The file is mounted `readOnly: true` — the container cannot modify it
- **The file lives in `tmpfs`** — a RAM-backed filesystem. The Secret value never touches the node's disk. If the node is powered off, the file is gone. A disk image of the node does not contain the secret.
- **Secret rotation propagates without pod restart** — via the exact same symlink-chain mechanism as ConfigMaps, covered in full in `01-configmaps` (not re-explained here — only what's genuinely different for Secrets follows)

**`tmpfs` — why it matters, and what's actually different from ConfigMaps here:**

Standard node storage writes files to disk. `tmpfs` is a virtual filesystem that exists entirely in RAM. The kubelet mounts Secrets into pods using `tmpfs` specifically so that secret values never persist to the node's physical disk — **this is the one genuinely Secret-specific piece of the delivery mechanism; ConfigMap volumes use regular node-disk storage, not `tmpfs`.** Everything else about how the files get there — the two-level `..data` symlink chain, the atomic `rename()` swap, the `syncFrequency`-bound update delay — is identical to what `01-configmaps` already covered in full, applied here to a RAM-backed mount instead of a disk-backed one.

```
Secret as environment variable:
  Secret value → process environment table → inherited by child processes
  → potentially in crash dumps, log output, /proc/self/environ

Secret as volume-mounted file (tmpfs):
  Secret value → RAM only → /etc/secrets/DB_PASSWORD (read-only)
  → not in environment → not in process table → not on disk
  → not inherited by child processes
```

This does not make secrets invulnerable — a root user inside the container can still read the file — but it eliminates the entire class of accidental disk persistence and environment inheritance leaks.

> **Update propagation mechanics (symlink chain, `syncFrequency`, atomic `rename()`):** identical to ConfigMaps in every respect except the `tmpfs` backing just described — see `01-configmaps`'s **Update propagation** section for the full step-by-step walkthrough. It applies here unchanged.

----

### TLS Secrets in Practice

Ingress controllers (Traefik, nginx) and cert-manager reference TLS Secrets by name. cert-manager creates and auto-rotates them. See `14-ingress/` for full TLS labs.

---

## Lab Step-by-Step Guide

### Step 1 — Create an Opaque Secret with base64 data

Secret `data` values **must** be base64-encoded. Always use `echo -n` (no trailing newline) — a trailing newline changes the base64 value and the decoded secret will have an invisible newline appended. This demo's Break-Fix Error-1 shows exactly what breaks when this is missed.

```bash
# Demonstrate why -n matters
echo "admin" | base64        # YWRtaW4K=   ← trailing newline included — WRONG
echo -n "admin" | base64     # YWRtaW4=    ← no trailing newline — CORRECT

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
  username: YWRtaW4=                # "admin"
  password: UzNjdXIzUEBzcyE=       # "S3cur3P@ss!"
  api-key: bXktYXBpLWtleS0xMjM0NQ==  # "my-api-key-12345"
```

```bash
kubectl apply -f src/01-secret-opaque.yaml
```

**Verify:**
```bash
kubectl get secret db-credentials
```
```
NAME             TYPE     DATA   AGE
db-credentials   Opaque   3      2s
```
**Observation:** `DATA` column shows 3 — the number of keys in the secret. Values are never shown in `kubectl get` output — only key count and metadata.

```bash
# -o yaml shows base64-encoded values — never plain text
kubectl get secret db-credentials -o yaml
```
```yaml
apiVersion: v1
data:
  api-key: bXktYXBpLWtleS0xMjM0NQ==
  password: UzNjdXIzUEBzcyE=
  username: YWRtaW4=
kind: Secret
metadata:
  name: db-credentials
  namespace: default
type: Opaque
```
**Observation:** values are base64-encoded in the API — not encrypted, just encoded. Anyone with kubectl access can decode them with `| base64 -d`.

```bash
# Decode individual values to verify correctness
kubectl get secret db-credentials -o jsonpath='{.data.username}' | base64 -d
# admin
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d
# S3cur3P@ss!
kubectl get secret db-credentials -o jsonpath='{.data.api-key}' | base64 -d
# my-api-key-12345
```
**Observation:** the decoded values match exactly what was encoded. `base64 -d` output has no trailing newline — the terminal prompt appears on the same line; add `echo ""` after if needed for clean formatting.

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
kubectl get secret app-secrets -o yaml
```
```yaml
apiVersion: v1
data:
  DB_HOST: cG9zdGdyZXMuZGVmYXVsdC5zdmMuY2x1c3Rlci5sb2NhbA==
  DB_NAME: YXBwZGI=
  DB_PASSWORD: cGxhaW50ZXh0LXBhc3N3b3JkLWhlcmU=
  DB_PORT: NTQzMg==
  JWT_SECRET: LS0tLS1CRUdJTi...
kind: Secret
...
```
**Observation:** `stringData` is a write-only convenience field. After creation, the API only returns `data` (base64). `stringData` is absent — confirming the API server converted the plain text values to base64 on write.

```bash
kubectl get secret app-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# plaintext-password-here
```
**Observation:** decoded value matches the `stringData` value exactly.

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
```
```
NAME               TYPE                             DATA   AGE
private-registry   kubernetes.io/dockerconfigjson   1      3s
```
**Observation:** type is `kubernetes.io/dockerconfigjson` — NOT `Opaque`. `DATA=1` means one key: `.dockerconfigjson`.

```bash
kubectl get secret private-registry -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```
```
{"auths":{"registry.example.com":{"username":"myuser","password":"mypassword","email":"myuser@example.com","auth":"bXl1c2VyOm15cGFzc3dvcmQ="}}}
```
**Observation:** the `auth` field is `base64("myuser:mypassword")` — the standard Docker registry authentication format.

For reference, the declarative form (reference only — use the imperative command above):

**03-secret-dockerconfigjson.yaml:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: private-registry-ref
  namespace: default
type: kubernetes.io/dockerconfigjson   # enforces .dockerconfigjson key must be present
data:
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
type: kubernetes.io/tls   # enforces that tls.crt and tls.key must BOTH be present
data:
  tls.crt: <base64-encoded-PEM-certificate>
  tls.key: <base64-encoded-PEM-private-key>
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
    image: busybox:1.38.0
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
kubectl exec pod-secret-env -- printenv DB_USER DB_PASS API_KEY
```
```
DB_USER=admin
DB_PASS=S3cur3P@ss!
API_KEY=my-api-key-12345
```
**Observation:** the decoded secret values are visible as plain text in the container's environment. This is expected and correct — the container must be able to use the value. Security is enforced at the Kubernetes layer (RBAC on Secrets), not inside the container.

```bash
# Confirm the secret keys are NOT present under their original names
kubectl exec pod-secret-env -- printenv | grep -E 'username|password|api-key'
# (no output)
```
**Observation:** the original Secret keys (`username`, `password`, `api-key`) are not in the environment — only the renamed versions (`DB_USER`, `DB_PASS`, `API_KEY`) are present.

**Failure scenario — CreateContainerConfigError when Secret is missing:**
```bash
kubectl delete pod pod-secret-env
kubectl delete secret db-credentials

kubectl apply -f src/05-pod-secret-env.yaml
kubectl get pods
```
```
NAME             READY   STATUS                       RESTARTS   AGE
pod-secret-env   0/1     CreateContainerConfigError   0          4s
```
**Observation:** identical behaviour to a missing ConfigMap (`01-configmaps`). The kubelet cannot start the container until all referenced Secrets exist.

```bash
kubectl apply -f src/01-secret-opaque.yaml
kubectl get pods -w
```
```
NAME             READY   STATUS                       RESTARTS   AGE
pod-secret-env   0/1     CreateContainerConfigError   0          30s
pod-secret-env   1/1     Running                      0          33s
```
**Observation:** pod transitions to `Running` without any manual pod delete or reapply — same auto-recovery behavior as ConfigMaps.

---

### Step 6 — Consume Secret as volume-mounted files

Volume-mounted Secrets are stored in `tmpfs` (RAM-backed filesystem) on the node — files never touch node disk storage. The same symlink-chain mechanism used for ConfigMaps applies here — same atomic update behaviour, just backed by RAM instead of disk.

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
    image: busybox:1.38.0
    command:
    - sh
    - -c
    - |
      echo "=== Symlink structure at mountPath ==="
      ls -la /etc/secrets/
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
kubectl logs pod/pod-secret-volume
```
```
=== Symlink structure at mountPath ===
lrwxrwxrwx    1 root     root    ... ..data -> ..2026_04_26_10_30_00.123456789
drwxr-xr-x    1 root     root    ... ..2026_04_26_10_30_00.123456789
lrwxrwxrwx    1 root     root    ... db -> ..data/db

=== File permissions ===
-r--------    1 root     root    ... password    ← 0400: owner read-only
-r--------    1 root     root    ... username    ← 0400: owner read-only

=== Secret values ===
Username: admin
Password: S3cur3P@ss!

=== Verify tmpfs — RAM-backed, not disk ===
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           ...   ...  ...   ...  /etc/secrets
```
**Observation:** the symlink structure here is identical in shape to `01-configmaps`' `..data` chain — the only genuinely new details are `tmpfs` as the filesystem type, and `0400` (owner read-only) permissions instead of the more permissive `0644` default ConfigMaps use.

```bash
kubectl exec pod-secret-volume -- df -h /etc/secrets
```
```
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           ...              ...  /etc/secrets
```
**Observation:** `tmpfs` confirms RAM-backed delivery — data never written to node disk.

---

### Step 7 — Imperative Secret creation (exam technique)

**Opaque from literals:**
```bash
kubectl create secret generic exam-secret \
  --from-literal=username=admin \
  --from-literal=password=secret123

kubectl get secret exam-secret -o yaml
```
```yaml
apiVersion: v1
data:
  password: c2VjcmV0MTIz
  username: YWRtaW4=
kind: Secret
type: Opaque
```
**Observation:** kubectl handles base64 encoding automatically — no manual encoding needed.

```bash
kubectl get secret exam-secret -o jsonpath='{.data.username}' | base64 -d
# admin
kubectl get secret exam-secret -o jsonpath='{.data.password}' | base64 -d
# secret123
```

**From a file:**
```bash
echo -n "s3cr3t-token-value" > /tmp/token.txt
cat /tmp/token.txt
# s3cr3t-token-value

kubectl create secret generic token-secret --from-file=/tmp/token.txt
kubectl get secret token-secret -o jsonpath='{.data.token\.txt}' | base64 -d
# s3cr3t-token-value
```
**Observation:** key name = filename (`token.txt`); value = file content base64-encoded.

```bash
# Custom key name
kubectl create secret generic token-secret2 --from-file=token=/tmp/token.txt
kubectl get secret token-secret2 -o jsonpath='{.data.token}' | base64 -d
# s3cr3t-token-value
```
**Observation:** same content, key is now `token` instead of `token.txt`.

**Dry-run — scaffold YAML (essential exam technique):**
```bash
kubectl create secret generic exam-secret2 \
  --from-literal=username=admin \
  --from-literal=password=secret123 \
  --dry-run=client -o yaml
```
```yaml
apiVersion: v1
data:
  password: c2VjcmV0MTIz
  username: YWRtaW4=
kind: Secret
metadata:
  creationTimestamp: null
  name: exam-secret2
type: Opaque
```
**Observation:** `--dry-run=client -o yaml` outputs a complete manifest with values pre-encoded. Redirect to a file or pipe to `kubectl apply -f -` for immediate use. Full canonical `--dry-run` explanation is `appendix-kubectl/01-kubectl-fundamentals`.

---

### Step 8 — Cleanup

```bash
kubectl delete pod pod-secret-env pod-secret-volume 2>/dev/null || true
kubectl delete secret db-credentials app-secrets private-registry private-registry-ref \
  tls-secret exam-secret exam-secret2 token-secret token-secret2 2>/dev/null || true
```

---

## What You Learned

In this lab, you:
- ✅ Explained exactly what changes, concretely, when using a Secret instead of a ConfigMap — RBAC separation, encryption eligibility, audit masking, external store integration
- ✅ Confirmed base64 is encoding, not encryption, by decoding a Secret's value directly with `kubectl`
- ✅ Created Secrets using both `data` (manual base64) and `stringData` (plain text, write-only, auto-encoded)
- ✅ Created typed Secrets (`docker-registry`, `tls`) and understood what required keys the API server enforces
- ✅ Explained why volume-mounted Secrets are more secure than env-var Secrets at the OS level
- ✅ Confirmed Secret volumes are backed by `tmpfs`, not node disk
- ✅ Reused the symlink-chain and `optional`-field mechanics from `01-configmaps` without needing them re-taught
- ✅ Created Secrets imperatively from literals and files

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

This scenario reproduces a very common, easy-to-make mistake: forgetting `-n` when piping a value through `echo` before base64-encoding it — introducing an invisible trailing newline into a Secret value that then breaks an exact-match comparison downstream.

**`src/break-fix/01-missing-echo-n.yaml`:**
```bash
# WRONG — missing -n, adds a trailing newline
echo "s3cr3t-api-token" | base64
# czNjcjN0LWFwaS10b2tlbgo=   ← note this differs from the -n version

kubectl create secret generic broken-token \
  --from-literal=API_TOKEN="$(echo 's3cr3t-api-token')"
  # --from-literal itself doesn't have this problem (it doesn't use echo/base64
  # manually) — this reproduces the mistake the way someone hand-crafting
  # a data: block with `echo | base64` actually makes it:

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: broken-token-manual
data:
  API_TOKEN: czNjcjN0LWFwaS10b2tlbgo=
EOF

kubectl get secret broken-token-manual -o jsonpath='{.data.API_TOKEN}' | base64 -d | wc -c
kubectl get secret broken-token-manual -o jsonpath='{.data.API_TOKEN}' | base64 -d | xxd | tail -1
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `echo "s3cr3t-api-token"` (without `-n`) appends a trailing
newline (`\n`, `0x0a`) before the value is base64-encoded. The decoded
Secret value is therefore `s3cr3t-api-token\n`, not `s3cr3t-api-token` —
16 bytes of real token plus 1 invisible newline byte.

**Fix:** Always use `echo -n` (or `printf '%s'`) before piping to `base64`
when hand-crafting a Secret's `data` field. `--from-literal` and
`--from-file` (with a file created via `echo -n` or a proper editor) both
avoid this specific trap.

**Cascade:** This is a genuinely dangerous silent failure — `kubectl get
secret ... | base64 -d` visually looks completely correct in a terminal,
since a trailing newline is invisible in normal output. The bug only
surfaces when something does an *exact* comparison against the value —
an API that checks `token === "s3cr3t-api-token"` will reject the
newline-appended version, and the resulting authentication failure gives
no hint that the actual cause is one invisible extra byte in a Secret.

</details>

**Cleanup:**
```bash
kubectl delete secret broken-token broken-token-manual 2>/dev/null || true
```

---

### Error-2

This scenario reproduces the "typed Secrets have API-enforced required keys" rule from Concepts — creating a `kubernetes.io/tls` Secret with only one of its two mandatory keys present.

**`src/break-fix/02-tls-missing-required-key.yaml`:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: incomplete-tls
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==   # present
  # tls.key is missing entirely
```

```bash
kubectl apply -f 02-tls-missing-required-key.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `kubernetes.io/tls` is a typed Secret — the API server
validates that both `tls.crt` and `tls.key` are present before accepting
it. This one only has `tls.crt`, so it's rejected:
```
The Secret "incomplete-tls" is invalid: data[tls.key]: Required value
```

**Fix:** Provide both keys, or (much more reliably) use the imperative
form instead of hand-writing the YAML: `kubectl create secret tls
incomplete-tls --cert=path/to/cert.crt --key=path/to/key.key` builds the
correctly-structured object for you, the same way `kubectl create secret
docker-registry` did in Step 3.

**Cascade:** none — rejected outright at apply time, no partially-valid
Secret is ever created. Worth contrasting with `Opaque` Secrets, which
have no required-key validation at all — you could create an entirely
empty `Opaque` Secret with no complaint, since only *typed* Secrets carry
this enforcement.

</details>

**Cleanup:**
```bash
kubectl delete secret incomplete-tls 2>/dev/null || true
```

---

## Interview Prep

**Q: Is base64 encoding a meaningful security control?**
A: No — it's encoding, not encryption, and trivially reversible by anyone with read access to the Secret object. The real security controls are RBAC (restricting who can `get`/`list` Secrets), optional etcd encryption at rest, and keeping sensitive values out of ConfigMaps entirely so they benefit from Secret-specific tooling and audit handling.

**Q: Why are volume-mounted Secrets considered more secure than env-var Secrets?**
A: Env vars live in the process environment table — readable via `/proc/self/environ`, inherited by every child process, and prone to accidental capture in crash dumps or startup logs. Volume-mounted Secrets in `tmpfs` avoid all of that: not in the environment, not inherited by subprocesses, and never written to node disk even if the node itself is compromised or imaged.

**Q: What's the one thing about Secret volume delivery that's genuinely different from ConfigMap volume delivery, versus what's identical?**
A: `tmpfs` (RAM-backed, never touches node disk) is the one real difference — ConfigMap volumes use regular node-disk storage. Everything else — the two-level `..data` symlink chain, the atomic `rename()` swap, the `syncFrequency`-bound update delay — is exactly the same mechanism, just applied to a different backing filesystem.

**Q: What does forgetting `echo -n` before base64-encoding a Secret value actually break?**
A: It appends an invisible trailing newline to the decoded value. This looks completely fine in a terminal (newlines don't display), but breaks any exact-match comparison downstream — an API token check, a password comparison — with no obvious hint that a single invisible byte is the actual cause.

**Q: Does an `Opaque` Secret enforce any required keys the way `kubernetes.io/tls` does?**
A: No — `Opaque` accepts any arbitrary key-value pairs, including none at all. Required-key validation is specific to typed Secrets like `kubernetes.io/tls` (needs `tls.crt` + `tls.key`) and `kubernetes.io/dockerconfigjson` (needs `.dockerconfigjson`).

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Environment, Configuration and Security | CKAD | 25% | Secret creation, consumption, typed Secrets |
| Application Design and Build | CKAD | 20% | `data` vs `stringData`, imperative creation, `imagePullSecrets` |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Forgetting `echo -n` before base64-encoding a value by hand | Adds an invisible trailing newline — looks fine, breaks exact-match comparisons downstream |
| Assuming base64 provides any real confidentiality | It doesn't — anyone with read access decodes it instantly; RBAC is the actual control |
| Hand-writing a typed Secret's YAML instead of using the imperative form | Easy to miss a required key (`tls.key`, `.dockerconfigjson`) — `kubectl create secret tls`/`docker-registry` build the correct structure for you |
| Assuming `stringData` values are still visible on GET | They're write-only — only `data` (base64) is ever returned, `stringData` disappears from the stored object |
| Forgetting Secret env vars need a pod restart to pick up rotation | Identical rule to ConfigMaps — volume mounts update live, env vars never do |

### Exam Task — Write it from scratch

Create an `Opaque` Secret named `exam-db-secret` with `stringData` keys `DB_USER=admin` and `DB_PASS=S3cret!`, then create a Pod that mounts it as a volume at `/etc/db-creds` with `0400` file permissions.

Official docs: [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

<details>
<summary>Reveal solution</summary>

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: exam-db-secret
type: Opaque
stringData:
  DB_USER: admin
  DB_PASS: S3cret!
---
apiVersion: v1
kind: Pod
metadata:
  name: exam-pod
spec:
  volumes:
    - name: db-creds
      secret:
        secretName: exam-db-secret
        defaultMode: 0400
  containers:
    - name: app
      image: busybox:1.38.0
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: db-creds
          mountPath: /etc/db-creds
          readOnly: true
```

**Key fields to recall:** `stringData` for plain-text authoring, `spec.volumes[].secret.defaultMode` for permissions (octal, e.g. `0400`), `readOnly: true` on the `volumeMounts` entry.

</details>

---

## Key Takeaways

| Concept                    | Detail                                                                                                                    |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| base64 is NOT encryption    | Anyone with `get secret` access can decode instantly; use RBAC + etcd encryption at rest                                   |
| `echo -n` required          | Without `-n`, `echo` adds a trailing newline that changes the base64 value and corrupts the decoded secret                 |
| `data` vs `stringData`      | `data` requires manual base64; `stringData` accepts plain text and is auto-encoded on write                                |
| `stringData` is write-only  | It is converted to `data` on write and never returned on GET — only `data` appears in stored object                        |
| `tmpfs` delivery            | Volume-mounted secrets live in RAM on the node — never written to node disk; this is the one genuine delta vs ConfigMap volumes |
| Symlink chain is unchanged from ConfigMaps | Same two-level `key → ..data/key → timestamped-dir/key` mechanism — see `01-configmaps` for the full walkthrough |
| `0400` file mode            | Owner read-only — correct default for secret files; set via `defaultMode` or per-file `mode`                               |
| `optional` field            | Same behavior as ConfigMaps: omitted → `CreateContainerConfigError` if missing; `true` → env var absent, not empty string  |
| Pod auto-recovers           | `CreateContainerConfigError` pod recovers automatically once the missing Secret is recreated                              |
| `imagePullSecrets`          | Attach `kubernetes.io/dockerconfigjson` secrets to pull from private registries                                            |
| Typed Secrets               | Type field validated by API server — required keys must exist or creation is rejected; `Opaque` has no such enforcement    |
| `immutable: true`           | Seals the Secret; kubelet stops watching; reduces apiserver watch load; delete+recreate to change                          |
| Env var update              | Secret env vars require pod restart to pick up changes; volume-mounted secrets update within `syncFrequency`, same as ConfigMaps |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get secrets` | List all Secrets (values never shown) |
| `kubectl get secret <name> -o yaml` | Show base64-encoded data |
| `kubectl get secret <name> -o jsonpath='{.data.<key>}' \| base64 -d` | Decode a specific key's value |
| `kubectl create secret generic <name> --from-literal=K=V` | Create Opaque Secret from literals |
| `kubectl create secret generic <name> --from-file=<path>` | Create from a file (key = filename) |
| `kubectl create secret docker-registry <name> --docker-server=... --docker-username=... --docker-password=...` | Create registry pull secret |
| `kubectl create secret tls <name> --cert=<crt> --key=<key>` | Create TLS Secret with required keys guaranteed correct |

### Generating YAML skeletons with --dry-run

```bash
kubectl create secret generic exam-secret --from-literal=username=admin --from-literal=password=secret123 --dry-run=client -o yaml
```
See `appendix-kubectl/01-kubectl-fundamentals` for the full canonical `--dry-run` explanation.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Secret (generic/Opaque) | `kubectl create secret generic NAME --from-literal=K=V` | Repeatable for multiple keys |
| Secret (docker-registry) | `kubectl create secret docker-registry NAME --docker-server=S --docker-username=U --docker-password=P` | Builds the `.dockerconfigjson` structure correctly — avoid hand-writing this type |
| Secret (tls) | `kubectl create secret tls NAME --cert=FILE --key=FILE` | Guarantees both required keys are present — avoid hand-writing this type (see Break-Fix Error-2) |

---

## Troubleshooting

**Pod stuck in `CreateContainerConfigError`:**
```bash
kubectl describe pod <name>
# Check Events for "secret ... not found" or "key ... not found"
kubectl get secret <name>
```

**Decoded Secret value has unexpected extra characters:**
```bash
kubectl get secret <name> -o jsonpath='{.data.<key>}' | base64 -d | wc -c
# Compare the byte count against the expected string length —
# an extra byte usually means a missing echo -n when the Secret was authored
```

**Typed Secret rejected at creation:**
```bash
# Check the error for "Required value" against a specific key —
# means a mandatory key for that type is missing (Break-Fix Error-2)
# Prefer the imperative kubectl create secret tls/docker-registry forms
# over hand-writing typed Secret YAML
```

**Volume-mounted Secret changes aren't appearing:**
```bash
# Same troubleshooting approach as ConfigMaps (01-configmaps) —
# confirm you waited a full syncFrequency window, and confirm this
# is a volume mount, not env-var consumption (which never updates live)
```

---

## Appendix — Anki Cards

**`02-secrets-anki.csv`:**

````
#deck:k8s-platform-labs::04-configmaps-secrets::02-secrets
#separator:Comma
#columns:Front,Back,Tags
"Is base64 encoding a meaningful security control for Secrets?","No — it's encoding, not encryption, trivially reversible by anyone with read access. RBAC and etcd encryption at rest are the actual controls.","demo02-cms,secrets,ckad-application-environment-configuration-security"
"What's the one genuinely different thing about Secret volume delivery vs ConfigMap volume delivery?","tmpfs (RAM-backed, never touches node disk) — ConfigMap volumes use regular node-disk storage; everything else (symlink chain, atomic rename, syncFrequency) is identical.","demo02-cms,secrets,tmpfs,cka-cluster-architecture-installation-configuration"
"What does forgetting echo -n before base64-encoding a Secret value actually cause?","An invisible trailing newline gets appended to the decoded value — invisible in terminal output, but breaks any exact-match comparison downstream.","demo02-cms,secrets,troubleshooting,cka-troubleshooting"
"Does an Opaque Secret enforce any required keys?","No — Opaque accepts any arbitrary key-value pairs, including none. Required-key validation only applies to typed Secrets like kubernetes.io/tls and kubernetes.io/dockerconfigjson.","demo02-cms,secrets,typed-secrets,ckad-application-design-build"
"Is stringData ever visible when you GET a Secret after creation?","No — it's write-only. The API server converts it to base64 data on write, and only data is ever returned on GET.","demo02-cms,secrets,stringdata,ckad-application-design-build"
"Why are volume-mounted Secrets considered more secure than env-var Secrets?","Env vars live in the process table, inherited by child processes and prone to leaking via crash dumps/logs. Volume-mounted Secrets in tmpfs avoid all of that, and never touch node disk.","demo02-cms,secrets,security,ckad-application-environment-configuration-security"
"What required keys does a kubernetes.io/tls Secret enforce?","Both tls.crt and tls.key must be present, or the API server rejects creation with a 'Required value' error.","demo02-cms,secrets,tls,typed-secrets,ckad-application-design-build"
"What's the safest way to create a kubernetes.io/tls or dockerconfigjson Secret?","Use the imperative kubectl create secret tls/docker-registry commands rather than hand-writing the YAML — they guarantee the required structure and keys are correct.","demo02-cms,secrets,imperative,ckad-application-design-build"
"Do Secret env vars update live when the underlying Secret changes?","No — identical rule to ConfigMaps: env vars are baked in at container start and never update without a pod restart; only volume mounts update live.","demo02-cms,secrets,update-propagation,ckad-application-environment-configuration-security"
````

---

## Appendix — Quiz

**`02-secrets-quiz.md`:**

````markdown
# Quiz — 04-configmaps-secrets/02-secrets: Secrets

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Is base64 encoding a meaningful security control on its own?**

- A) Yes, it prevents unauthorized users from reading Secret values
- B) No — it's trivially reversible; RBAC and etcd encryption at rest are the real controls
- C) Yes, but only for Opaque Secrets
- D) Only if combined with a strong password

<details>
<summary>Answer</summary>

**B** — Anyone with `kubectl get secret` access decodes it instantly; base64 is encoding for API transport, not a confidentiality mechanism.
Trap: C invents a distinction between Secret types that doesn't exist — base64 behaves identically regardless of type.

</details>

---

**Q2. What is the one genuinely different thing about how Secret volumes are delivered compared to ConfigMap volumes?**

- A) Secrets use a completely different symlink mechanism
- B) Secrets are backed by `tmpfs` (RAM); ConfigMaps use regular node-disk storage
- C) Secrets never support live updates at all
- D) Secrets always require `defaultMode: 0400`

<details>
<summary>Answer</summary>

**B** — `tmpfs` is the real delta; the symlink chain, atomic swap, and sync timing are identical mechanisms shared with ConfigMaps.
Trap: A overstates the difference — the actual update mechanism is the same, only the backing filesystem differs.

</details>

---

**Q3. You base64-encode a Secret value using `echo "mytoken" | base64` (no `-n`). What's the practical consequence?**

- A) Nothing — the value decodes back identically
- B) A trailing newline is silently appended to the decoded value, breaking exact-match comparisons
- C) The Secret is rejected at creation
- D) Only the first character is affected

<details>
<summary>Answer</summary>

**B** — This is invisible in normal terminal output but genuinely breaks anything doing an exact string comparison against the value downstream.
Trap: C assumes validation exists for this — there's no such check; the Secret is created successfully with the wrong value silently baked in.

</details>

---

**Q4. Does an `Opaque` Secret enforce any required keys the way `kubernetes.io/tls` does?**

- A) Yes, identical enforcement
- B) No — `Opaque` accepts anything, including an empty Secret; required-key validation is specific to typed Secrets
- C) Only if `stringData` is used
- D) Only in namespaces with a ResourceQuota

<details>
<summary>Answer</summary>

**B** — Required-key enforcement is a property of specific typed Secrets (`kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`), not a universal rule.
Trap: A assumes uniform validation across all Secret types, which isn't how the API server actually behaves.

</details>

---

**Q5. Is `stringData` ever returned when you run `kubectl get secret <name> -o yaml` after creation?**

- A) Yes, alongside `data`
- B) No — it's write-only; only `data` (base64) is ever returned
- C) Only for `Opaque` type
- D) Only immediately after creation, then it disappears after 60 seconds

<details>
<summary>Answer</summary>

**B** — `stringData` is converted to `data` at write time and never appears in the stored object at all — this isn't a timing thing, it's absent from the very first read.
Trap: D invents a time-based disappearance that doesn't reflect how the field actually works — it's never present on GET, immediately or otherwise.

</details>

---

**Q6. Why are volume-mounted Secrets considered more secure than env-var Secrets?**

- A) They're encrypted automatically
- B) Env vars are inherited by child processes and can leak via crash dumps/logs; volume mounts in tmpfs avoid this and never touch node disk
- C) Volume mounts require a separate RBAC permission
- D) There's no real security difference

<details>
<summary>Answer</summary>

**B** — The OS-level reasoning matters here: process environment inheritance and diagnostic capture are real leak vectors that volume mounting sidesteps entirely.
Trap: A assumes automatic encryption that doesn't exist for either consumption method by default.

</details>

---

**Q7. What required keys does a `kubernetes.io/tls` Secret enforce?**

- A) Just `tls.crt`
- B) Both `tls.crt` and `tls.key`
- C) `tls.crt`, `tls.key`, and `tls.ca`
- D) None — TLS Secrets are just `Opaque` with a different label

<details>
<summary>Answer</summary>

**B** — Both keys are mandatory; missing either one gets the Secret rejected outright with a "Required value" error.
Trap: C adds a plausible-sounding third field that isn't part of this Secret type's actual requirement.

</details>

---

**Q8. What's the safest way to create a `kubernetes.io/dockerconfigjson` or `kubernetes.io/tls` Secret?**

- A) Hand-write the YAML for full control
- B) Use the imperative `kubectl create secret docker-registry`/`tls` commands, which guarantee the correct required structure
- C) Both approaches are equally safe
- D) Use `kubectl create configmap` instead, then change the `kind`

<details>
<summary>Answer</summary>

**B** — The imperative commands build the exact structure and required keys these types need; hand-writing risks exactly the missing-key mistake in this demo's Break-Fix Error-2.
Trap: D suggests something structurally nonsensical — changing `kind` after the fact doesn't produce a valid typed Secret.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````