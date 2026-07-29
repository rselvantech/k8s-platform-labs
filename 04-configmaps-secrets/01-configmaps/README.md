# Demo: 04-configmaps-secrets/01-configmaps — ConfigMaps

## Lab Overview

A **ConfigMap** stores non-sensitive configuration data as key-value
pairs. Pods consume ConfigMaps in three ways: as environment variables,
as command arguments, and as volume-mounted files. ConfigMaps decouple
configuration from container images so the same image runs in dev,
staging, and production with different settings.

This demo covers the full mechanics of ConfigMaps — the two data fields
(`data` vs `binaryData`), immutability and why it matters at scale, the 1
MiB size limit, and — in the most depth of any demo so far in this
series — exactly how update propagation actually works at the filesystem
level via kubelet's atomic symlink-swap mechanism.

**What this lab covers:**
- ConfigMap `data` vs `binaryData` — when to use each
- Immutable ConfigMaps and the kubelet watch mechanism they eliminate
- The 1 MiB size limit
- Update propagation — why env vars never update but volume mounts do
- Consuming ConfigMaps as env vars, command args, and volume-mounted files
- The `optional` field's exact failure/success behavior
- Imperative ConfigMap creation

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `03-services` (this demo assumes general familiarity with Pods and Deployments from earlier chapters — no Service-specific knowledge is required here)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the difference between `data` and `binaryData`, and when each is required
2. ✅ Explain what `immutable: true` actually eliminates at the control-plane level
3. ✅ Explain the ConfigMap size limit and where it's enforced
4. ✅ Consume a ConfigMap as environment variables, both `envFrom` and `env.valueFrom`
5. ✅ Consume a ConfigMap value inside `command`/`args` via `$(VAR_NAME)` substitution
6. ✅ Consume a ConfigMap as volume-mounted files, and explain the symlink chain that makes live updates possible
7. ✅ Explain precisely why env-var consumption never updates live but volume-mount consumption does
8. ✅ Explain the `optional` field's exact behavior when a ConfigMap or key is missing
9. ✅ Create ConfigMaps imperatively, from literals, files, and directories

## Directory Structure

```
04-configmaps-secrets/01-configmaps/
├── README.md
└── src/
    ├── 01-configmap-literal.yaml        # Simple key-value ConfigMap
    ├── 02-configmap-file.yaml           # Multi-line / file-like ConfigMap
    ├── 03-configmap-immutable.yaml      # Immutable ConfigMap
    ├── 04-pod-envfrom.yaml              # Pod consuming full ConfigMap as env vars
    ├── 05-pod-env-valueFrom.yaml        # Pod consuming specific keys via valueFrom
    ├── 06-pod-volume.yaml               # Pod consuming ConfigMap as volume-mounted files
    └── break-fix/
        ├── 01-size-limit-exceeded.yaml       # Embedded inline in README — not generated on disk
        └── 02-duplicate-key-overlap.yaml     # Embedded inline in README — not generated on disk
```

---

## Recall Check — 05-service-discovery

Answer from memory before continuing — no peeking at the previous demo.

1. What's the actual difference in blast radius between a CoreDNS crash and a single misconfigured Service?
2. Is `dnsPolicy: Default` actually the default DNS policy for a pod?
3. What does `dnsPolicy: None` require that the other policies don't?

<details>
<summary>Answers</summary>

1. A CoreDNS crash breaks DNS resolution for the entire cluster at once; a misconfigured Service only affects its own name.
2. No — `ClusterFirst` is the actual default; `Default` means the pod uses the node's own DNS instead of CoreDNS.
3. A fully manual `dnsConfig` — nameservers, search domains, and options are all your own responsibility, nothing is injected automatically.

</details>

---

## Concepts

A **ConfigMap** stores non-sensitive configuration data as key-value pairs. Pods consume ConfigMaps in three ways:

| Method                | How it works                                                                                   | When to use                                                            |
| --------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| Environment variables | ConfigMap keys injected as env vars at pod start                                               | App reads `os.getenv()` / `$VAR` — simple scalar values                |
| Command arguments     | ConfigMap value loaded as env var first, then referenced in `command`/`args` via `$(VAR_NAME)` | Pass config values directly to the container entrypoint or CLI flags   |
| Volume-mounted files  | Each key projected as a file in a directory                                                    | App reads config from disk — nginx.conf, .properties, JSON, YAML files |

ConfigMaps decouple configuration from container images so the same image runs in dev, staging, and production with different settings.

----

### ConfigMap data types — `data` vs `binaryData`

| Field        | Content type       | Format in manifest                    | When to use                                                                                                                       |
| ------------ | ------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `data`       | UTF-8 text strings | Plain text — write the value directly | Config values, environment strings, any text config file (nginx.conf, .properties, YAML)                                          |
| `binaryData` | Arbitrary binary   | base64-encoded string                 | Binary files that cannot be represented as valid UTF-8: TLS certificates in DER format, compiled protobuf schemas, Java keystores |

**Important:** Both `data` and `binaryData` are **optional fields**. A ConfigMap that only has `data` entries will show an empty `BinaryData` section in `kubectl describe` — this is completely normal. Kubernetes always renders both section headers regardless of whether the field is populated.

```
kubectl describe cm app-config

Data
====
APP_ENV:    production
...
BinaryData
====
            ← empty — no binaryData keys defined. This is normal.
Events:  <none>
```

**Key format rules (both fields):**

- Keys must be alphanumeric characters, `-`, `_`, or `.`
- Maximum key length: 253 characters
- Keys in `data` and `binaryData` must not overlap (no duplicate key across both fields) — this demo's Break-Fix Error-2 shows exactly what happens if you try
- Total size of `data` + `binaryData` combined cannot exceed **1 MiB** — Break-Fix Error-1 covers this one

**`data` — plain text, written directly in the manifest:**

```yaml
data:
  APP_ENV: "production"          # simple scalar — format: key: "value"
  MAX_RETRIES: "3"               # numbers must be quoted (all ConfigMap values are strings)
  nginx.conf: |                  # multi-line file using YAML literal block scalar (|)
    worker_processes 1;          # | tells YAML: preserve newlines exactly as written
    events { worker_connections 1024; }
```

**`binaryData` — binary content, base64-encoded in the manifest:**

```yaml
binaryData:
  server.der: LS0tLS1CRUdJTi...   # generate with: base64 -w0 server.der
  keystore.jks: /u3+7QAAAAIAAA... # Java keystore — binary, not valid UTF-8
```
> **Rule of thumb:** Use `data` for everything readable as text. PEM certificates (`-----BEGIN CERTIFICATE-----`) are base64-encoded text — they go in `data`. Use `binaryData` only for genuinely binary content that would be corrupted by UTF-8 handling — for example, a DER-format certificate or a compiled `.class` file.

**YAML literal block scalar (`|`) — the syntax for multi-line values in `data`:**

The `|` character is standard YAML syntax, not Kubernetes-specific. It signals: everything indented below this line is a literal string — newlines are preserved exactly as written. The leading indentation of the block is stripped by the YAML parser; the content itself is preserved as-is.

```yaml
data:
  config.yaml: |    # | = preserve all newlines; strip one final trailing newline
    key: value
    nested:
      field: true
  script.sh: |-     # |- = strip ALL trailing newlines (useful for shell scripts)
    #!/bin/sh
    echo hello
  notes.txt: |+     # |+ = keep ALL trailing newlines (rarely needed)
    line one
```

Standard `|` is almost always correct for config files. The YAML parser strips the minimum shared indentation from the block and the result becomes the file content when volume-mounted.

----

### Immutable ConfigMaps

Setting `immutable: true` permanently seals the ConfigMap. Any attempt to modify `data` or `binaryData` is rejected by the API server. The only way to change it is to delete and recreate.

**Why `immutable: true` matters — the Kubernetes watch mechanism:**

Every non-immutable ConfigMap is **actively watched** by the Kubernetes control plane. Here is what that means step by step:

1. When you create or update a ConfigMap, the API server stores the new version in etcd.
2. The **kubelet** on every node that has a pod consuming that ConfigMap holds open a **long-lived watch connection** to the API server — an HTTP/2 streaming connection that stays open indefinitely and delivers change events the moment a ConfigMap is updated.
3. When a change event arrives, the kubelet re-fetches the ConfigMap content and:
   - For **volume mounts**: performs an atomic symlink swap to update the projected files (see Step 4 for details).
   - For **env vars**: does nothing — env vars cannot be changed in a running container.
4. Each watch connection consumes resources on the API server: a goroutine, memory in the watch cache, and CPU for change detection and event fan-out.

At small scale (tens of ConfigMaps), this overhead is negligible. At large scale (thousands of pods across hundreds of nodes, each watching dozens of ConfigMaps), the aggregate watch load becomes significant — thousands of persistent connections, each delivering events on every change.

Setting `immutable: true` tells the API server: **stop issuing watch events for this object**. The kubelet reads it once at pod start and never opens a watch connection. This directly reduces API server goroutine count, memory usage, and event processing load — measurably so at scale.

**Benefits of `immutable: true`:**

- Protects against accidental misconfiguration — `kubectl edit` and `kubectl patch` are both rejected
- Eliminates the watch connection overhead for this ConfigMap on every node
- Makes the ConfigMap's identity stable — safe to reference by name in GitOps and CI/CD pipelines
- Forces a deliberate delete+recreate workflow for any change (auditable, reviewed, intentional)

----

### ConfigMap size limit

A ConfigMap cannot exceed **1 MiB** (combined size of all keys and values in `data` and `binaryData`). Enforced by the API server at creation and update time. For larger configs use a PersistentVolume-backed volume or a dedicated config server (Consul, AWS AppConfig, etc.).

----

### Update propagation

**Update propagation** describes what happens inside a running pod when the ConfigMap it references is modified after the pod is already running.

| Consumption method          | Propagation behaviour                                                    | Root cause                                                                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `envFrom` / `env.valueFrom` | **Never updates** in a running container — pod must be restarted         | Env vars are set once at container start by the container runtime. The runtime reads the ConfigMap value at that moment and bakes it into the process environment. After start, no link exists between the process's `environ` and the ConfigMap object. |
| Volume mount                 | **Eventually consistent** — updates automatically within `syncFrequency` | The kubelet holds a watch connection to the API server. When the ConfigMap changes, it performs an atomic file swap on the node filesystem. The pod sees updated file content without restart.           |

**The kubelet `syncFrequency` — name, location, and default:**

The parameter is called **`syncFrequency`** in the kubelet configuration. It is configured in the kubelet config file at `/var/lib/kubelet/config.yaml` on each node, and can also be set via the `--sync-frequency` kubelet flag.

```bash
# Inspect the configured value on a minikube node
minikube ssh -p 3node -- sudo grep -i sync /var/lib/kubelet/config.yaml
# syncFrequency: 0s
```
> **What `0s` means:** A value of `0s` does NOT mean sync is disabled or instant. It means "use the compiled-in default". The compiled-in default is **1 minute**. minikube ships with `syncFrequency: 0s` as a sentinel value to indicate "no override — use the default". The effective sync interval is 1 minute.

**Full update flow for a volume-mounted ConfigMap:**

```
ConfigMap updated  →  etcd stores new version
        ↓
  API server emits watch event (near-instant, milliseconds)
        ↓
  kubelet on the node receives event via open watch connection
        ↓
  kubelet queues a sync for this ConfigMap volume
        ↓
  Next sync cycle fires (within syncFrequency window, effective default: 1 min)
        ↓
  kubelet fetches new content from the API server
        ↓
  Atomic symlink swap on the node filesystem
        ↓
  Files inside the pod show new content — no pod restart needed
```
> In practice the delay is **10–90 seconds** — depends on where the watch event lands relative to the current sync cycle. Worst case is one full `syncFrequency` window.

---

## Lab Step-by-Step Guide

### Step 1 — Create ConfigMaps

Three ConfigMaps are created below — a literal key-value map, a file-like multi-line map, and an immutable map.

**01-configmap-literal.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
data:
  # Format: key: "value" — all ConfigMap values are strings; quote numbers
  APP_ENV: "production"
  APP_PORT: "8080"
  APP_LOG_LEVEL: "info"
  MAX_CONNECTIONS: "100"
```

**02-configmap-file.yaml:**

This ConfigMap stores complete config file contents as values using YAML's **literal block scalar** (`|`) syntax. The `|` tells YAML: preserve all newlines and indentation exactly as written — do not fold or collapse.

When this ConfigMap is **volume-mounted**: the key (`nginx.conf`) becomes the **filename** on disk inside the pod; the value (everything after `|`) becomes the **exact file content**.

When consumed as an **env var** (`envFrom`): the entire multi-line string becomes a single env var value — technically valid but not useful for config files read from disk.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-files
  namespace: default
data:
  # Key: nginx.conf  → becomes the filename when volume-mounted
  # Value: everything indented under |  → becomes the file content
  # The leading indentation is stripped by the YAML parser;
  # the content itself is preserved exactly (newlines, spacing, special chars)
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      server {
        listen 80;
        location /health {
          return 200 'ok';
          add_header Content-Type text/plain;
        }
        location / {
          root /usr/share/nginx/html;
          index index.html;
        }
      }
    }
  # Key: app.properties  → Java-style properties file
  app.properties: |
    # Application runtime properties
    database.host=postgres.default.svc.cluster.local
    database.port=5432
    cache.ttl=300
    feature.dark_mode=true
```

**03-configmap-immutable.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-config
  namespace: default
# immutable: true seals this ConfigMap permanently
# Updates to data/binaryData are rejected by the API server
# kubelet stops watching it — no persistent watch connection overhead
# Delete + recreate is the only way to change it
immutable: true
data:
  RELEASE_VERSION: "v2.4.1"
  BUILD_DATE: "2026-04-01"
  REGION: "ca-central-1"
```

```bash
kubectl apply -f src/01-configmap-literal.yaml
kubectl apply -f src/02-configmap-file.yaml
kubectl apply -f src/03-configmap-immutable.yaml
```

**Verify:**
```bash
kubectl get configmaps
```
```
NAME             DATA   AGE
app-config       4      5s
app-files        2      3s
release-config   3      1s
```

```bash
kubectl describe configmap app-config
```
```
Name:         app-config
Namespace:    default
Labels:       <none>
Annotations:  <none>

Data
====
APP_ENV:
----
production
APP_LOG_LEVEL:
----
info
APP_PORT:
----
8080
MAX_CONNECTIONS:
----
100

BinaryData
====

Events:  <none>
```
**Observation:** `BinaryData` section is empty — this is normal. `kubectl describe` always shows both `Data` and `BinaryData` headers. An empty `BinaryData` section simply means no `binaryData` keys were defined in this ConfigMap.

```bash
# describe truncates long values — use -o yaml to see full multi-line content
kubectl get configmap app-files -o yaml
```
```yaml
apiVersion: v1
data:
  app.properties: |
    # Application runtime properties
    database.host=postgres.default.svc.cluster.local
    database.port=5432
    cache.ttl=300
    feature.dark_mode=true
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    ...
kind: ConfigMap
...
```

---

### Step 2 — Consume ConfigMap as environment variables (envFrom)

`envFrom` loads **all keys** from the ConfigMap as environment variables in one shot. The key name in the ConfigMap becomes the env var name directly — no renaming is possible with `envFrom`.

**04-pod-envfrom.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-envfrom
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    envFrom:
    # Loads ALL keys from app-config as env vars — 1:1 key → env var name mapping
    - configMapRef:
        name: app-config
      # prefix: "CFG_"   # optional — prepends a string to every key from this source
      #                     APP_ENV → CFG_APP_ENV, APP_PORT → CFG_APP_PORT, etc.
      #                     Useful to avoid key collisions when loading multiple ConfigMaps
  restartPolicy: Never
```

```bash
kubectl apply -f src/04-pod-envfrom.yaml
kubectl wait --for=condition=Ready pod/pod-envfrom --timeout=30s
```

**Verify — use `printenv` to inspect environment variables:**
```bash
# Check specific keys by name — confirms each ConfigMap key was injected correctly
kubectl exec pod-envfrom -- printenv APP_ENV APP_PORT APP_LOG_LEVEL MAX_CONNECTIONS
```
```
APP_ENV=production
APP_PORT=8080
APP_LOG_LEVEL=info
MAX_CONNECTIONS=100
```
**Observation:** ConfigMap key names are used as-is as env var names. `APP_ENV` in ConfigMap → `APP_ENV` in container (no renaming with `envFrom`).

```bash
# List ALL env vars sorted — shows ConfigMap keys alongside system vars
kubectl exec pod-envfrom -- printenv | sort
```
```
APP_ENV=production
APP_LOG_LEVEL=info
APP_PORT=8080
HOME=/root
HOSTNAME=pod-envfrom
MAX_CONNECTIONS=100
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
...
```
**Observation:** only the 4 ConfigMap keys appear as custom vars — all others are container defaults.

---

### Step 3 — Consume specific keys via env.valueFrom

`env.valueFrom.configMapKeyRef` loads **individual keys** with full control over the env var name inside the container. This is the right choice when you need only some keys, or want to rename them.

This pod demonstrates two things simultaneously:

1. **Selective key injection with renaming** — instead of loading the entire ConfigMap with `envFrom`, each `env` entry picks exactly one key from one ConfigMap. The env var name inside the container can be completely different from the ConfigMap key name: `APP_PORT` in the ConfigMap becomes `PORT` in the container.

2. **Cross-ConfigMap references** — a single pod can pull env vars from multiple different ConfigMaps in the same `env` list. `PORT` and `LOG_LEVEL` come from `app-config`; `VERSION` comes from `release-config`. This works because each `env` entry independently specifies which ConfigMap and which key to read.

The `optional: true` field controls failure behaviour: without it, the pod fails to start (`CreateContainerConfigError`) if the referenced ConfigMap or key does not exist; with it, the env var is **absent entirely** and the pod starts regardless.

**05-pod-env-valueFrom.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-valuefrom
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    command: ["sh", "-c", "sleep 3600"]
    env:
    # name: env var name INSIDE the container (can differ from the ConfigMap key)
    # configMapKeyRef.name: which ConfigMap to read from
    # configMapKeyRef.key:  which key inside that ConfigMap
    - name: PORT                       # container sees $PORT
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_PORT                # APP_PORT (ConfigMap) → PORT (container)
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_LOG_LEVEL           # APP_LOG_LEVEL → LOG_LEVEL
    - name: VERSION
      valueFrom:
        configMapKeyRef:
          name: release-config         # different ConfigMap — fully valid in one env list
          key: RELEASE_VERSION
          # optional: true             # see behaviour table below
  restartPolicy: Never
```

**`optional` field behaviour — verified by testing:**

| Scenario                      | `optional` omitted (default)   | `optional: true`                                     |
| ------------------------------ | ------------------------------- | ------------------------------------------------------ |
| ConfigMap exists, key exists  | ✅ Env var set correctly        | ✅ Env var set correctly                              |
| ConfigMap exists, key missing | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not set at all) |
| ConfigMap does not exist      | ❌ `CreateContainerConfigError` | ✅ Pod starts; env var is **absent** (not set at all) |

> **Verified behaviour:** When `optional: true` and the ConfigMap or key is missing, the env var is **absent entirely** — it is NOT set to an empty string. Running `printenv VERSION` will show nothing and exit non-zero.

```bash
kubectl apply -f src/05-pod-env-valueFrom.yaml
kubectl wait --for=condition=Ready pod/pod-valuefrom --timeout=30s
```

**Verify — check each renamed env var by its new container name:**
```bash
kubectl exec pod-valuefrom -- printenv PORT LOG_LEVEL VERSION
```
```
PORT=8080
LOG_LEVEL=info
VERSION=v2.4.1
```
**Observation:** env var names are `PORT`, `LOG_LEVEL`, `VERSION`. The original ConfigMap keys (`APP_PORT`, `APP_LOG_LEVEL`, `RELEASE_VERSION`) do NOT appear. This is the rename that `valueFrom.configMapKeyRef` provides — `envFrom` cannot do this.

---

**Failure scenario — what happens when the ConfigMap is missing:**

```bash
kubectl delete pod pod-valuefrom
kubectl delete configmap release-config

kubectl apply -f src/05-pod-env-valueFrom.yaml
```

```bash
kubectl get pods
```
```
NAME            READY   STATUS                       RESTARTS   AGE
pod-envfrom     1/1     Running                      0          5m
pod-valuefrom   0/1     CreateContainerConfigError   0          3s
```
**Observation:** `STATUS = CreateContainerConfigError`. The pod is stuck — kubelet cannot start the container because a required ConfigMap is missing. It will keep retrying but will not progress until the ConfigMap exists.

```bash
kubectl describe pod pod-valuefrom
```
```
...
Events:
  Type     Reason     Age               From               Message
  ----     ------     ----              ----               -------
  Normal   Scheduled  20s               default-scheduler  Successfully assigned default/pod-valuefrom to 3node-m02
  Normal   Pulled     5s (x3 over 19s)  kubelet            Container image "busybox:1.38.0" already present on machine
  Warning  Failed     5s (x3 over 19s)  kubelet            Error: configmap "release-config" not found
```
**Observation:** Warning event with message "configmap release-config not found". The kubelet retries container start every few seconds. The `(x3 over 19s)` counter shows it has already retried 3 times.

**Recreate the ConfigMap — pod recovers automatically without any manual intervention:**
```bash
kubectl apply -f src/03-configmap-immutable.yaml
# configmap/release-config created

kubectl get pods -w
```
```
NAME            READY   STATUS                       RESTARTS   AGE
pod-valuefrom   0/1     CreateContainerConfigError   0          45s
pod-valuefrom   1/1     Running                      0          48s
```
**Observation:** the pod transitions from `CreateContainerConfigError` → `Running` automatically once the missing ConfigMap is recreated. No pod delete or `kubectl apply` needed — kubelet detects the ConfigMap and starts the container.

> **Try `optional: true` yourself:** Edit `05-pod-env-valueFrom.yaml`, add `optional: true` under the `release-config` key reference. Delete `release-config` again, reapply the pod. The pod will start and run. Run `kubectl exec pod-valuefrom -- printenv VERSION` — the variable will not appear at all, confirming it is absent rather than empty.

---

### Step 3b — Consume ConfigMap via command arguments

The third consumption method passes ConfigMap values as **command arguments**. The pattern: load the ConfigMap key as an env var first (via `env` or `envFrom`), then reference it inside `command` or `args` using `$(VAR_NAME)` syntax.

> **Is this really a separate consumption method?** Yes — the Kubernetes documentation lists it as distinct because the outcome is different: the value is delivered as part of the process's argv, not as an environment variable. The process reads it via `sys.argv` or `$1`/`$2` in shell scripts, not via `os.getenv()`. The env var step is always required first — there is no direct ConfigMap → args path.

```bash
# release-config was recreated in the previous step — app-config still exists
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pod-cmd-args
  namespace: default
spec:
  containers:
  - name: app
    image: busybox:1.38.0
    # $(VAR_NAME) — Kubernetes substitutes this value before the command reaches the container runtime
    command: ["sh", "-c", "echo Starting on port $(APP_PORT) in $(APP_ENV) mode; sleep 3600"]
    # Same pattern in exec-form (no shell needed):
    # command: ["/usr/bin/myapp"]
    # args: ["--port=$(APP_PORT)", "--env=$(APP_ENV)"]
    envFrom:
    - configMapRef:
        name: app-config   # APP_PORT and APP_ENV loaded as env vars
  restartPolicy: Never
EOF

kubectl wait --for=condition=Ready pod/pod-cmd-args --timeout=30s

kubectl logs pod/pod-cmd-args
```
```
Starting on port 8080 in production mode
```
**Observation:** `APP_PORT=8080` and `APP_ENV=production` from `app-config` were substituted into the command string. The container received the already-substituted string.

```bash
kubectl delete pod pod-cmd-args
```

**How `$(VAR_NAME)` substitution works — it is NOT shell substitution:**

Kubernetes processes `command` and `args` as a raw string array. Before handing the command to the container runtime, the kubelet scans each string for `$(VAR_NAME)` patterns and replaces them with the value of the matching env var defined in the same container spec.

```
Container spec (raw):   ["sh", "-c", "echo Starting on port $(APP_PORT)"]
                                                                ↑
                              Kubernetes substitutes APP_PORT=8080 here
                                                                ↓
Container runtime gets: ["sh", "-c", "echo Starting on port 8080"]
```

By the time the shell runs, it receives the literal string `echo Starting on port 8080` — it never sees `$(APP_PORT)`. This is why `$(VAR_NAME)` works equally in shell-form commands (`sh -c "..."`) and exec-form commands (no shell at all).

`$VAR` (without parentheses) is **shell substitution** — the shell expands it from its own environment at runtime. It only works inside `sh -c "..."`. Both forms happen to produce the same result in shell-form, but only `$(VAR_NAME)` works in exec-form without a shell.

---

### Step 4 — Consume ConfigMap as volume-mounted files

Volume mounting projects each ConfigMap key as a **file** in a directory. The key is the filename; the value is the file content. This is essential for config files that applications read from disk (nginx.conf, app.properties, etc.).

**06-pod-volume.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-volume
  namespace: default
spec:
  volumes:
  # Volume-1: backed by app-files ConfigMap
  - name: config-files       # volume name — referenced in volumeMounts below
    configMap:
      name: app-files        # the ConfigMap to project
      # items: selectively project only some keys and control filenames
      # Without items, ALL keys are projected using their key as the filename
      items:
      - key: nginx.conf         # key in the ConfigMap
        path: nginx/nginx.conf  # path inside the mounted directory (subdirs allowed)
      - key: app.properties
        path: app.properties
        # mode: 0400           # optional: per-file permission (octal)
  # Volume-2: backed by release-config (immutable ConfigMap — mountable like any other)
  - name: release-files
    configMap:
      name: release-config   # immutable ConfigMap — also mountable as volume
      # defaultMode: 0444    # optional: permission for all files in this volume (default 0644)

  containers:
  - name: app
    image: busybox:1.38.0
    command:
    - sh
    - -c
    - |
      echo "=== nginx.conf ==="
      cat /etc/nginx/nginx/nginx.conf
      echo ""
      echo "=== app.properties ==="
      cat /etc/nginx/app.properties
      echo ""
      echo "=== release files ==="
      ls /etc/release/
      echo ""
      echo "=== RELEASE_VERSION ==="
      cat /etc/release/RELEASE_VERSION
      sleep 3600
    volumeMounts:
    - name: config-files
      mountPath: /etc/nginx
      readOnly: true
    - name: release-files
      mountPath: /etc/release
      readOnly: true
  restartPolicy: Never
```

```bash
kubectl apply -f src/06-pod-volume.yaml
kubectl wait --for=condition=Ready pod/pod-volume --timeout=30s
```

**Check pod logs — confirms file content is readable from the container:**
```bash
kubectl logs pod/pod-volume
```
```
=== nginx.conf ===
worker_processes 1;
events { worker_connections 1024; }
http {
  server {
    listen 80;
    location /health {
      return 200 'ok';
      add_header Content-Type text/plain;
    }
    location / {
      root /usr/share/nginx/html;
      index index.html;
    }
  }
}

=== app.properties ===
# Application runtime properties
database.host=postgres.default.svc.cluster.local
database.port=5432
cache.ttl=300
feature.dark_mode=true

=== release files ===
BUILD_DATE
REGION
RELEASE_VERSION

=== RELEASE_VERSION ===
v2.4.1
```

**Verify the symlink structure — inspect what is actually inside the mount:**
```bash
# nginx is a symlink to ..data/nginx — ls -lR on a symlink shows the symlink itself, not the target
kubectl exec pod-volume -- ls -lR /etc/nginx/nginx
```
```
lrwxrwxrwx    1 root     root            12 Apr 26 06:28 /etc/nginx/nginx -> ..data/nginx
```
**Observation:** busybox `ls -lR` does NOT follow symlinks — it shows the symlink entry only. To see inside the symlink target, use the resolved path directly:
```bash
kubectl exec pod-volume -- ls -la /etc/nginx/..data/nginx/
```
```
-rw-r--r--    1 root     root           ... nginx.conf
```
**Observation:** the actual nginx.conf file lives inside `..data/nginx/` on the node filesystem.

```bash
# Read the nginx config using the path that resolves through both symlinks
kubectl exec pod-volume -- cat /etc/nginx/nginx/nginx.conf
```
```
worker_processes 1;
events { worker_connections 1024; }
http {
  server {
    listen 80;
...
```
**Observation:** `/etc/nginx/nginx` is a symlink to `..data/nginx` (a directory). Appending `/nginx.conf` reads the file inside that directory — this works correctly.

```bash
# This path does NOT exist — there is no nginx.conf directly at /etc/nginx/nginx.conf
kubectl exec pod-volume -- cat /etc/nginx/nginx.conf
```
```
cat: can't open '/etc/nginx/nginx.conf': No such file or directory
```
**Observation:** `items[].path` was `"nginx/nginx.conf"` which creates a subdirectory `nginx` inside `mountPath` `/etc/nginx`. The correct path is `/etc/nginx/nginx/nginx.conf`, NOT `/etc/nginx/nginx.conf`. This is a common mistake when using subdirs in `path`.

```bash
# app.properties has no subdir in its path — accessible directly at mountPath root
kubectl exec pod-volume -- cat /etc/nginx/app.properties
```
```
# Application runtime properties
database.host=postgres.default.svc.cluster.local
database.port=5432
cache.ttl=300
feature.dark_mode=true
```

```bash
# List /etc/release — release-config had no items filter, so all 3 keys are projected
kubectl exec pod-volume -- ls -l /etc/release
```
```
total 0
lrwxrwxrwx    1 root     root            17 Apr 26 06:28 BUILD_DATE -> ..data/BUILD_DATE
lrwxrwxrwx    1 root     root            13 Apr 26 06:28 REGION -> ..data/REGION
lrwxrwxrwx    1 root     root            22 Apr 26 06:28 RELEASE_VERSION -> ..data/RELEASE_VERSION
```
**Observation:** all 3 ConfigMap keys projected as symlinks. Key name is used directly as filename (no items remapping). Each symlink points into `..data/` where the actual file content lives.

```bash
# Read individual release files
kubectl exec pod-volume -- cat /etc/release/RELEASE_VERSION
# v2.4.1

kubectl exec pod-volume -- cat /etc/release/BUILD_DATE
# 2026-04-01
```

**How the symlink chain works and why it exists:**

When kubelet projects a ConfigMap as a volume, it does NOT write file content directly to the target path. It builds a two-level symlink chain:

```
/etc/nginx/app.properties            ← Level 1: top-level symlink (what the app opens)
        ↓ points to
/etc/nginx/..data/app.properties     ← via the ..data directory symlink
        ↓ ..data points to
/etc/nginx/..2026_04_25_10_30_00.123456789/app.properties  ← actual file with content
```

**Why two levels?** A single file-to-file symlink swap is not atomic — there is a brief window where the target does not exist. The two-level approach enables a fully atomic update:

1. kubelet writes **new content** into a brand-new timestamped directory (`..2026_04_25_10_45_00.987654321/`)
2. kubelet issues a single `rename()` syscall to point `..data` at the new directory
3. `rename()` is atomic at the filesystem level — readers always see either the complete old version or the complete new version, never a partial state
4. The top-level symlinks (`app.properties`, `nginx`) never change — they always resolve through `..data/`

> **Why `subPath` mounts do NOT get live updates:** `subPath` bind-mounts the actual file directly into the container — bypassing the `..data/` chain entirely. The atomic `rename()` on `..data/` never affects a bind-mounted file. Content is frozen at pod start time. Full `subPath` treatment (and why you'd choose it anyway) is `04-volume-mounts`' entire subject.

---

### Step 5 — binaryData — real use case: embedding a binary TLS certificate

`binaryData` is required when the content is genuinely binary and would be corrupted by UTF-8 handling. A DER-format TLS certificate is a real production example — applications like Java's SSL stack consume DER directly and cannot use PEM.

> **PEM vs DER:** PEM (`-----BEGIN CERTIFICATE-----`) is base64-encoded text — valid in `data`. DER is the raw binary encoding of the same certificate — must go in `binaryData`.

```bash
# Step 5.1 — Generate a self-signed certificate in both formats
openssl req -x509 -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt \
  -days 365 -nodes -subj "/CN=demo.example.com" 2>/dev/null

# Convert PEM → DER (binary format)
openssl x509 -in /tmp/server.crt -outform DER -out /tmp/server.der

# Verify: PEM is readable text; DER is binary
head -1 /tmp/server.crt
# -----BEGIN CERTIFICATE-----   ← readable text, valid in data:

xxd /tmp/server.der | head -2
# 00000000: 3082 04a0 3082 03 ...   ← raw binary, must go in binaryData:

file /tmp/server.der
# /tmp/server.der: Certificate, Version=3
```

```bash
# Step 5.2 — Base64-encode the DER file and create the ConfigMap
# -w0 = no line wraps in the base64 output (required for embedding in YAML)
BASE64_DER=$(base64 -w0 /tmp/server.der)

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tls-cert-config
  namespace: default
binaryData:
  server.der: ${BASE64_DER}   # binary DER content — base64-encoded for the manifest
data:
  server.crt: |               # PEM text content — written directly
$(cat /tmp/server.crt | sed 's/^/    /')
EOF
```

```bash
# Step 5.3 — Verify the ConfigMap
kubectl describe configmap tls-cert-config
```
```
Name:         tls-cert-config
Data
====
server.crt:
----
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgI...
-----END CERTIFICATE-----

BinaryData
====
server.der:  <756 bytes>
```
**Observation:** `BinaryData` entries show key name + byte count only — content is NOT displayed. This is intentional: binary content is not printable. Compare: `Data` entries show their full text content.

```bash
# Confirm the binary content is stored and retrievable correctly
kubectl get configmap tls-cert-config -o jsonpath='{.binaryData.server\.der}' | base64 -d | xxd | head -2
# 00000000: 3082 04a0 ...   ← DER bytes recovered correctly — no corruption
```

```bash
# Step 5.4 — Mount binaryData in a pod and verify both files are accessible
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pod-binarydata
  namespace: default
spec:
  volumes:
  - name: certs
    configMap:
      name: tls-cert-config   # both data and binaryData keys are mounted together
  containers:
  - name: app
    image: busybox:1.38.0
    command:
    - sh
    - -c
    - |
      echo "=== Files in /etc/certs ==="
      ls -la /etc/certs/
      echo ""
      echo "=== server.crt (PEM — readable text, from data:) ==="
      head -2 /etc/certs/server.crt
      echo "..."
      echo ""
      echo "=== server.der (DER — binary, from binaryData:) ==="
      echo "File size: $(wc -c < /etc/certs/server.der) bytes"
      xxd /etc/certs/server.der | head -2
      sleep 3600
    volumeMounts:
    - name: certs
      mountPath: /etc/certs
      readOnly: true
  restartPolicy: Never
EOF

kubectl wait --for=condition=Ready pod/pod-binarydata --timeout=30s

kubectl logs pod/pod-binarydata
```
```
=== Files in /etc/certs ===
lrwxrwxrwx    1 root root  ... server.crt -> ..data/server.crt
lrwxrwxrwx    1 root root  ... server.der -> ..data/server.der

=== server.crt (PEM — readable text, from data:) ===
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgI...
...

=== server.der (DER — binary, from binaryData:) ===
File size: 756 bytes
00000000: 3082 04a0 3082 ...
```
**Observation:** both `data` (PEM text) and `binaryData` (DER binary) keys are mounted as files in the same directory. `binaryData` content is decoded from base64 by Kubernetes before mounting — the file on disk contains raw bytes, not base64. Applications read it as a normal file with no extra decoding needed.

```bash
kubectl delete pod pod-binarydata
kubectl delete configmap tls-cert-config
```

---

### Step 6 — Test immutability

```bash
# Attempt to update an immutable ConfigMap
kubectl patch configmap release-config --type=merge -p '{"data":{"RELEASE_VERSION":"v9.9.9"}}'
```
```
Error from server (Forbidden): configmaps "release-config" is forbidden:
field is immutable when `immutable` is set
```
**Observation:** the API server rejects the request before it reaches etcd. Neither `kubectl edit` nor `kubectl patch` nor `kubectl apply` can modify an immutable ConfigMap.

```bash
# The only way to change it: delete and recreate
kubectl delete configmap release-config
kubectl apply -f src/03-configmap-immutable.yaml

# Verify the value is back to original
kubectl get configmap release-config -o jsonpath='{.data.RELEASE_VERSION}'
# v2.4.1
```

---

### Step 7 — Test live volume update

ConfigMap volume mounts update **without a pod restart**. Env vars do NOT.

```bash
# Check syncFrequency on the minikube node — requires sudo
minikube ssh -p 3node -- sudo grep -i sync /var/lib/kubelet/config.yaml
# syncFrequency: 0s
```
**Observation:** `0s` = "use the compiled-in default of 1 minute". It does NOT mean disabled or instant. The effective sync interval is 1 minute.

**Record baseline values before making any changes:**
```bash
kubectl exec pod-volume -- cat /etc/nginx/app.properties | grep cache.ttl
# cache.ttl=300   ← baseline

kubectl exec pod-envfrom -- printenv APP_LOG_LEVEL
# info   ← baseline
```

**Edit both ConfigMaps:**
```bash
# Edit app-files — used by pod-volume as a volume mount
kubectl edit configmap app-files
# In the editor: change   cache.ttl=300
#                to       cache.ttl=600
# Save and exit (:wq in vi)

# Edit app-config — used by pod-envfrom as envFrom
kubectl edit configmap app-config
# In the editor: change   APP_LOG_LEVEL: "info"
#                to       APP_LOG_LEVEL: "error"
# Save and exit
```

**Wait 30–90 seconds for the kubelet sync cycle, then verify:**
```bash
# Volume mount — file content has been updated automatically
kubectl exec pod-volume -- cat /etc/nginx/app.properties | grep cache.ttl
# cache.ttl=600   ← UPDATED without restarting the pod
```

```bash
# Confirm the atomic symlink swap occurred
kubectl exec pod-volume -- ls -la /etc/nginx/
```
```
total 0
lrwxrwxrwx    1 root     root    21 Apr 26 06:28 app.properties -> ..data/app.properties
lrwxrwxrwx    1 root     root    12 Apr 26 06:28 nginx -> ..data/nginx
lrwxrwxrwx    1 root     root    31 Apr 26 10:45 ..data -> ..2026_04_26_10_45_00.987654321
drwxr-xr-x    1 root     root    ... ..2026_04_26_10_45_00.987654321
drwxr-xr-x    1 root     root    ... ..2026_04_26_06_28_00.123456789
```
**Observation:** `..data` is a symlink pointing to the NEW timestamped directory (10:45). The old timestamped directory (06:28) still exists temporarily before kubelet cleans it up. The top-level symlinks (`app.properties`, `nginx`) are UNCHANGED — they always point through `..data`. This is the atomic `rename()` in action: only `..data` was swapped, nothing else changed.

```bash
# Env var — does NOT update in a running container
kubectl exec pod-envfrom -- printenv APP_LOG_LEVEL
# info   ← UNCHANGED — still the value baked in at container start
```
**Observation:** `app-config` was updated to `"error"` but the running container still shows `"info"`. Env vars have no live link to the ConfigMap after pod start.

```bash
# To pick up the change, the pod must be restarted
kubectl delete pod pod-envfrom
kubectl apply -f src/04-pod-envfrom.yaml
kubectl wait --for=condition=Ready pod/pod-envfrom --timeout=30s

kubectl exec pod-envfrom -- printenv APP_LOG_LEVEL
# error   ← new value visible only after pod restart
```

---

### Step 8 — Imperative ConfigMap creation (exam technique)

**From literals** (most common exam pattern):
```bash
kubectl create configmap exam-config \
  --from-literal=ENV=staging \
  --from-literal=PORT=9090

# Verify — confirm keys and values were stored correctly
kubectl get configmap exam-config -o yaml
```
```yaml
apiVersion: v1
data:
  ENV: staging
  PORT: "9090"
kind: ConfigMap
metadata:
  name: exam-config
  namespace: default
```

**From a file** — the file's full content becomes the value; the filename (or a custom key) becomes the key:
```bash
# Create a sample config file
cat > /tmp/settings.conf <<'EOF'
timeout=30
max_retries=5
log_level=warn
EOF

cat /tmp/settings.conf
# timeout=30
# max_retries=5
# log_level=warn

# Key = filename (settings.conf), value = full file content
kubectl create configmap file-config --from-file=/tmp/settings.conf

kubectl get configmap file-config -o yaml
```
```yaml
data:
  settings.conf: |
    timeout=30
    max_retries=5
    log_level=warn
```
**Observation:** entire file content stored as a single value; key = filename.

```bash
# Custom key name — overrides the filename as the key
kubectl create configmap file-config2 --from-file=mykey=/tmp/settings.conf
kubectl get configmap file-config2 -o yaml
```
```yaml
data:
  mykey: |
    timeout=30
    max_retries=5
    log_level=warn
```
**Observation:** same content, key is now `mykey` instead of `settings.conf`.

**From a directory** — every file in the directory becomes a separate key:
```bash
mkdir -p /tmp/configdir
echo "host=redis.default.svc" > /tmp/configdir/redis.conf
echo "host=pg.default.svc"    > /tmp/configdir/postgres.conf

kubectl create configmap dir-config --from-file=/tmp/configdir/
kubectl get configmap dir-config -o yaml
```
```yaml
data:
  postgres.conf: |
    host=pg.default.svc
  redis.conf: |
    host=redis.default.svc
```
**Observation:** one key per file in the directory; filename becomes the key name.

**Dry-run — scaffold YAML without applying (essential exam technique):**
```bash
kubectl create configmap exam-config2 \
  --from-literal=ENV=staging \
  --from-literal=PORT=9090 \
  --dry-run=client -o yaml
```
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  creationTimestamp: null
  name: exam-config2
data:
  ENV: staging
  PORT: "9090"
```
**Observation:** `--dry-run=client -o yaml` generates the manifest without applying it. Redirect to a file (`> configmap.yaml`) or pipe to `kubectl apply -f -` for quick apply. Full canonical explanation of `--dry-run` is `appendix-kubectl/01-kubectl-fundamentals`.

---

### Step 9 — Cleanup

```bash
kubectl delete pod pod-envfrom pod-valuefrom pod-volume 2>/dev/null || true
kubectl delete configmap app-config app-files release-config exam-config exam-config2 \
  file-config file-config2 dir-config 2>/dev/null || true
```

---

## What You Learned

In this lab, you:
- ✅ Explained `data` vs `binaryData`, and when `binaryData` is genuinely required (DER certs, keystores)
- ✅ Explained the ConfigMap watch mechanism and exactly what `immutable: true` eliminates at scale
- ✅ Explained the 1 MiB size limit and where it's enforced
- ✅ Consumed a ConfigMap via `envFrom` (all keys, no renaming) and `env.valueFrom` (selective, renameable, cross-ConfigMap)
- ✅ Consumed a ConfigMap value inside `command`/`args` via `$(VAR_NAME)`, and understood it's Kubernetes substitution, not shell substitution
- ✅ Consumed a ConfigMap as volume-mounted files, and traced the full two-level symlink chain that makes atomic live updates possible
- ✅ Directly observed why env vars never update live but volume mounts do, on the same cluster, side by side
- ✅ Verified the exact `optional` field behavior — absent, not empty string
- ✅ Created ConfigMaps imperatively from literals, files, and directories

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

This scenario reproduces the 1 MiB ConfigMap size limit hitting in practice — a common real-world mistake when someone tries to embed a large file (a bundled dependency, a large dataset export) directly into a ConfigMap instead of using a PersistentVolume.

**`src/break-fix/01-size-limit-exceeded.yaml`:**
```bash
# Generate a file larger than 1 MiB
head -c 1200000 /dev/urandom | base64 -w0 > /tmp/oversized.txt
wc -c /tmp/oversized.txt
# roughly 1.6 MB after base64 expansion — comfortably over the 1 MiB limit

kubectl create configmap oversized-config --from-file=/tmp/oversized.txt
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The combined size of all `data`/`binaryData` values in a ConfigMap cannot exceed 1 MiB — this file alone exceeds it. The API server rejects the request outright:
```
The ConfigMap "oversized-config" is invalid: []: Too long: must have at most 1048576 bytes
```

**Fix:** Split the content across multiple ConfigMaps if it's genuinely config-like and under 1 MiB per map, or — more appropriately for anything this large — use a PersistentVolume-backed volume or an external config store (Consul, AWS AppConfig), exactly as this demo's Concepts section already recommends.

**Cascade:** none — this is rejected entirely at `kubectl create` time, no partial ConfigMap is ever created. The error message itself is fairly clear once you know to look for "Too long," but it's easy to be confused the first time since nothing about the command itself looked wrong.

</details>

**Cleanup:**
```bash
kubectl delete configmap oversized-config 2>/dev/null || true
rm -f /tmp/oversized.txt
```

---

### Error-2

This scenario reproduces the key-overlap rule mentioned in Concepts — the same key name appearing in both `data` and `binaryData` on the same ConfigMap.

**`src/break-fix/02-duplicate-key-overlap.yaml`:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: duplicate-key-config
data:
  server.crt: "some-text-value"
binaryData:
  server.crt: c29tZS1iaW5hcnktdmFsdWU=   # same key name as in data above
```

```bash
kubectl apply -f 02-duplicate-key-overlap.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `server.crt` appears as a key in both `data` and `binaryData` on the same ConfigMap — this is explicitly disallowed, since a single key can't simultaneously be "plain text" and "binary." The API server rejects the object:
```
The ConfigMap "duplicate-key-config" is invalid: data: Invalid value: "server.crt":
duplicate key present in binaryData
```

**Fix:** Pick one field for `server.crt` based on what it actually is — plain text (PEM) goes in `data`, genuine binary (DER) goes in `binaryData` — never both.

**Cascade:** none — rejected outright at apply time, no ConfigMap is created in a half-valid state. This is a good one to recognize by the error message shape, since the YAML itself looks syntactically fine at a glance — the mistake is only semantic (same key, two fields).

</details>

**Cleanup:**
```bash
kubectl delete configmap duplicate-key-config 2>/dev/null || true
```

---

## Interview Prep

**Q: Why does `immutable: true` matter beyond just preventing accidental edits?**
A: The bigger benefit is eliminating the kubelet watch connection for that ConfigMap on every node consuming it. At small scale this is negligible, but at scale (thousands of pods, hundreds of nodes) the aggregate watch overhead on the API server — goroutines, memory, event fan-out — becomes real. `immutable: true` tells the control plane to stop watching entirely.

**Q: Why do env-var-consumed ConfigMap values never update, but volume-mounted ones do?**
A: The container runtime reads the ConfigMap value once, at container start, and bakes it into the process's environment table. After that there's no ongoing link between the process's `environ` and the ConfigMap object at all. Volume mounts work completely differently — kubelet holds an open watch connection and performs an atomic filesystem-level symlink swap whenever the ConfigMap changes, which the running process can pick up on its next file read with no restart needed.

**Q: What is the `..data` symlink actually for, and why not just overwrite the file directly?**
A: A direct file overwrite isn't atomic — a reader could catch the file mid-write and see a corrupted, half-old-half-new version. The `..data` symlink lets kubelet write the complete new content into a brand-new timestamped directory first, then perform a single atomic `rename()` to repoint `..data` at it. Readers always see either the fully old or fully new version, never a partial state.

**Q: Why doesn't `$(VAR_NAME)` work if the variable came from `envFrom`?**
A: `$(VAR_NAME)` substitution in `command`/`args` only looks at variables explicitly defined in the same `env[]` list of that container — it doesn't have visibility into what `envFrom` loaded. If you need a value from `envFrom` inside `command`/`args`, you'd need to also declare it explicitly via `env.valueFrom`, or restructure the reference.

**Q: If a ConfigMap referenced by `optional: true` is missing, is the env var set to an empty string?**
A: No — this is a common misconception. It's absent entirely, not present-with-empty-value. `printenv VAR_NAME` in that case returns nothing and a non-zero exit code, exactly as if the variable had never been declared at all.

**Q: Can a single ConfigMap key exist in both `data` and `binaryData`?**
A: No — the API server rejects this outright as a validation error. A key represents one value; it can't simultaneously be plain text and binary.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Environment, Configuration and Security | CKAD | 25% | ConfigMap creation, all 3 consumption methods, `optional` behavior |
| Application Design and Build | CKAD | 20% | `data` vs `binaryData`, immutability, imperative creation |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Forgetting `envFrom` can't rename keys | Only `env.valueFrom.configMapKeyRef` supports renaming — a common "why doesn't my env var have this name" confusion |
| Assuming a ConfigMap update reaches a running pod's env vars | It never does, regardless of how long you wait — only a pod restart picks up the new value for env-var consumption |
| Using `path` with a subdirectory and then reading the wrong mount path | `path: subdir/file.conf` creates a real subdirectory under `mountPath` — the file is NOT directly at `mountPath/file.conf` |
| Forgetting numbers must be quoted in `data` | `data` values are always strings — `PORT: 8080` (unquoted) is actually valid YAML but becomes a problem if your tooling expects a string type explicitly; `PORT: "8080"` is the safe, explicit form |
| Assuming `stringData`-equivalent exists for ConfigMaps | It doesn't — that convenience field (plain text → auto base64) is Secret-only; ConfigMaps only have `data` (plain text, no encoding) and `binaryData` (explicitly base64) |

### Exam Task — Write it from scratch

Create a ConfigMap named `exam-app-config` with keys `ENV=production` and `PORT=8080` using `--from-literal`, then create a Pod that consumes `ENV` via `envFrom` and `PORT` via a renamed `env.valueFrom` (container sees it as `APP_PORT`).

Official docs: [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create configmap exam-app-config --from-literal=ENV=production --from-literal=PORT=8080
```
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: exam-pod
spec:
  containers:
    - name: app
      image: busybox:1.38.0
      command: ["sh", "-c", "sleep 3600"]
      envFrom:
        - configMapRef:
            name: exam-app-config
      env:
        - name: APP_PORT
          valueFrom:
            configMapKeyRef:
              name: exam-app-config
              key: PORT
```

**Key fields to recall:** `envFrom.configMapRef.name` for bulk loading, `env[].valueFrom.configMapKeyRef.{name,key}` for a single renamed key.

</details>

---

## Key Takeaways

| Concept                           | Detail                                                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Three consumption methods         | Env vars (`envFrom`/`valueFrom`), command args (`$(VAR_NAME)` via env), volume files                                                                               |
| `envFrom`                         | All keys → env vars at pod start; key name used as-is; pod restart required for updates                                                                            |
| `env.valueFrom`                   | Individual keys, rename-able, cross-ConfigMap; pod restart required for updates                                                                                    |
| Command args                      | Load as env var first; reference with `$(VAR_NAME)` in `command`/`args`; Kubernetes substitutes before container runtime receives the command                      |
| `$(VAR_NAME)` vs `$VAR`           | `$(VAR_NAME)` = Kubernetes substitution in raw command string before runtime (works exec-form + shell-form); `$VAR` = shell expansion at runtime (shell-form only) |
| Volume mount                      | Keys → files on disk; live-updates via atomic symlink swap; no pod restart needed                                                                                  |
| `data`                            | UTF-8 string values written directly in YAML; use `\|` for multi-line file content                                                                                  |
| `binaryData`                      | base64-encoded binary in manifest; decoded to raw bytes on disk when mounted; shown as byte count in `describe`                                                    |
| Empty BinaryData section          | Normal — `kubectl describe` always shows both headers; empty means no `binaryData` keys defined                                                                    |
| YAML `\|` block scalar             | Preserves newlines exactly; `\|-` strips final newline; `\|+` keeps all trailing newlines                                                                            |
| `optional` field                  | Omitted: pod fails `CreateContainerConfigError` if CM/key missing; `true`: pod starts, env var is **absent** (not empty string)                                    |
| Pod auto-recovers                 | Pod in `CreateContainerConfigError` recovers automatically once the missing ConfigMap is created — no pod delete needed                                            |
| `immutable: true`                 | Sealed permanently; API server rejects all updates; kubelet stops watching; delete+recreate to change                                                              |
| Watch mechanism                   | kubelet holds open HTTP/2 watch connection per non-immutable ConfigMap per node; delivers events on every change                                                   |
| `syncFrequency: 0s`               | minikube default — means "use compiled-in default of 1 minute"; NOT disabled or instant                                                                            |
| `syncFrequency` location          | `/var/lib/kubelet/config.yaml` on each node; requires `sudo` to read; also settable via `--sync-frequency` kubelet flag                                            |
| Symlink chain                     | `key → ..data/key → timestamped-dir/key`; kubelet swaps `..data` (a symlink) via atomic `rename()` syscall                                                         |
| `ls -lR` does not follow symlinks | busybox `ls -lR` shows the symlink entry only — use resolved path (`..data/subdir/`) to see inside                                                                 |
| `subPath` no live update          | `subPath` bind-mounts file directly — bypasses `..data/` chain; atomic swap never affects it; content frozen at pod start — full treatment in `04-volume-mounts`   |
| `items[].path` with subdir        | `path: subdir/file.conf` creates a subdirectory inside `mountPath`; access as `mountPath/subdir/file.conf` not `mountPath/file.conf`                               |
| Key format                        | Alphanumeric, `-`, `_`, `.` only; max 253 chars; no key overlap between `data` and `binaryData`                                                                     |
| 1 MiB limit                       | Total `data` + `binaryData` per ConfigMap; enforced by API server at creation and update time                                                                      |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get configmaps` | List all ConfigMaps |
| `kubectl describe configmap <name>` | Show keys and values (truncates long values) |
| `kubectl get configmap <name> -o yaml` | Full content, including multi-line values |
| `kubectl create configmap <name> --from-literal=K=V` | Create from key-value literals |
| `kubectl create configmap <name> --from-file=<path>` | Create from a file (key = filename) |
| `kubectl create configmap <name> --from-file=<dir>/` | Create from a directory (one key per file) |
| `kubectl patch configmap <name> --type=merge -p '{"data":{...}}'` | Update via patch (fails if `immutable: true`) |
| `kubectl edit configmap <name>` | Update interactively (fails if `immutable: true`) |

### Generating YAML skeletons with --dry-run

```bash
kubectl create configmap exam-config --from-literal=ENV=staging --from-literal=PORT=9090 --dry-run=client -o yaml
```
See `appendix-kubectl/01-kubectl-fundamentals` for the full canonical `--dry-run` explanation.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| ConfigMap (literals) | `kubectl create configmap NAME --from-literal=K=V` | Repeatable flag for multiple keys |
| ConfigMap (file) | `kubectl create configmap NAME --from-file=/path/to/file` | Key defaults to filename; override with `--from-file=key=/path` |
| ConfigMap (directory) | `kubectl create configmap NAME --from-file=/path/to/dir/` | One key per file in the directory |

---

## Troubleshooting

**Pod stuck in `CreateContainerConfigError`:**
```bash
kubectl describe pod <name>
# Check Events for "configmap ... not found" or "key ... not found"
kubectl get configmap <name>
# Confirm the ConfigMap and the specific key both actually exist
```

**Volume-mounted ConfigMap changes aren't appearing:**
```bash
# Confirm you waited long enough — up to one full syncFrequency window (effective default 1 min)
# Confirm this is a volume mount, not envFrom/valueFrom (env vars never update live)
kubectl exec <pod> -- ls -la <mountPath>
# Check the ..data symlink's target timestamp — has it actually swapped?
```

**"field is immutable" error on update:**
```bash
kubectl get configmap <name> -o jsonpath='{.immutable}'
# If true, the only path forward is delete + recreate
```

**ConfigMap rejected at creation:**
```bash
# Check the actual error message shape:
#   "Too long" → 1 MiB size limit exceeded (Break-Fix Error-1)
#   "duplicate key ... in binaryData" → key overlap between data/binaryData (Break-Fix Error-2)
```

---

## Appendix — Anki Cards

**`01-configmaps-anki.csv`:**

````
#deck:k8s-platform-labs::04-configmaps-secrets::01-configmaps
#separator:Comma
#columns:Front,Back,Tags
"When is binaryData required instead of data?","When the content is genuinely binary and would be corrupted by UTF-8 handling — e.g. a DER-format certificate or compiled protobuf schema. PEM certs are text and belong in data.","demo01-cms,configmaps,ckad-application-environment-configuration-security"
"Can the same key exist in both data and binaryData on one ConfigMap?","No — the API server rejects this as a duplicate key overlap between the two fields.","demo01-cms,configmaps,ckad-application-design-build"
"What does immutable: true actually eliminate at the control-plane level?","The kubelet watch connection for that ConfigMap on every node consuming it — at scale this measurably reduces API server goroutine count, memory, and event load.","demo01-cms,configmaps,immutable,cka-cluster-architecture-installation-configuration"
"What is the ConfigMap size limit, and what's included in it?","1 MiB total, combining all data and binaryData values together — enforced by the API server at creation and update time.","demo01-cms,configmaps,ckad-application-design-build"
"Do envFrom-loaded ConfigMap values ever update in a running container?","No — never, regardless of how long you wait. The container runtime bakes the value into the process environment once at start; only a pod restart picks up a change.","demo01-cms,configmaps,update-propagation,ckad-application-environment-configuration-security"
"Do volume-mounted ConfigMap values update in a running container?","Yes — eventually, within one kubelet syncFrequency window (effective default 1 minute), via an atomic symlink swap, with no pod restart needed.","demo01-cms,configmaps,update-propagation,ckad-application-environment-configuration-security"
"Why does kubelet use a two-level ..data symlink instead of overwriting the file directly?","A direct overwrite isn't atomic — a reader could see a half-written file. The two-level chain lets kubelet write new content to a fresh directory, then atomically rename() the ..data symlink to point at it.","demo01-cms,configmaps,symlink-chain,cka-troubleshooting"
"Can envFrom rename a ConfigMap key when injecting it as an env var?","No — only env.valueFrom.configMapKeyRef supports renaming; envFrom always uses the ConfigMap's key name as-is.","demo01-cms,configmaps,ckad-application-environment-configuration-security"
"If optional: true and the referenced ConfigMap/key is missing, is the env var set to an empty string?","No — it's absent entirely, not present-with-empty-value. printenv on it returns nothing and a non-zero exit code.","demo01-cms,configmaps,optional-field,ckad-application-environment-configuration-security"
"Does $(VAR_NAME) substitution in command/args see variables loaded via envFrom?","No — it only sees variables explicitly declared in the same env[] list; envFrom-loaded variables are invisible to it.","demo01-cms,configmaps,var-substitution,ckad-application-design-build"
"Is $(VAR_NAME) shell substitution or Kubernetes substitution?","Kubernetes substitution — it happens on the raw command string before the container runtime ever sees it, which is why it also works in exec-form commands with no shell at all.","demo01-cms,configmaps,var-substitution,ckad-application-design-build"
"What happens if a pod references a nonexistent ConfigMap without optional: true?","The pod is stuck in CreateContainerConfigError, retrying indefinitely, until the ConfigMap is created — no manual pod restart is needed once it exists.","demo01-cms,configmaps,troubleshooting,cka-troubleshooting"
"Why does a subPath-mounted ConfigMap file never get live updates?","subPath bind-mounts the file directly into the container, bypassing the ..data/ symlink chain entirely — the atomic rename() that updates ..data never touches a bind-mounted file.","demo01-cms,configmaps,subpath,cka-troubleshooting"
````

---

## Appendix — Quiz

**`01-configmaps-quiz.md`:**

````markdown
# Quiz — 04-configmaps-secrets/01-configmaps: ConfigMaps

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. When is `binaryData` actually required instead of `data`?**

- A) Whenever a value is longer than a few lines
- B) When the content is genuinely binary and would be corrupted by UTF-8 handling
- C) Never — `data` can hold anything if base64-encoded
- D) Only for TLS Secrets, never ConfigMaps

<details>
<summary>Answer</summary>

**B** — PEM certificates are base64-encoded *text* and belong in `data`; only genuinely binary content like DER certs needs `binaryData`.
Trap: C confuses base64 encoding with a requirement — `data` is meant for readable text, and encoding text unnecessarily into `binaryData` doesn't reflect what the field is actually for.

</details>

---

**Q2. Two ConfigMap fields, `data` and `binaryData`, both contain a key named `server.crt`. What happens?**

- A) `binaryData` silently wins
- B) The API server rejects the ConfigMap as invalid
- C) Both values are merged
- D) `data` silently wins

<details>
<summary>Answer</summary>

**B** — This is an explicit validation rule: a key can't exist in both fields at once, and the object is rejected outright.
Trap: A and D both assume silent precedence resolution, which isn't how this specific rule works — it's a hard rejection, not first/last-wins.

</details>

---

**Q3. What does `immutable: true` eliminate at the control-plane level, beyond just blocking edits?**

- A) Nothing else — it's purely a permissions feature
- B) The kubelet watch connection for that ConfigMap on every consuming node
- C) The need for RBAC on that ConfigMap
- D) The 1 MiB size limit

<details>
<summary>Answer</summary>

**B** — This is the real scale-relevant benefit: no more persistent watch connection, reducing API server load measurably across thousands of pods/nodes.
Trap: D confuses two unrelated ConfigMap rules — immutability and the size limit are independent constraints.

</details>

---

**Q4. Do `envFrom`-loaded ConfigMap values ever update in a running container without a restart?**

- A) Yes, within the syncFrequency window
- B) No — never, regardless of how long you wait
- C) Only if `immutable: false` is explicitly set
- D) Only for `stringData` values

<details>
<summary>Answer</summary>

**B** — Env vars are baked into the process environment once at container start; there's no ongoing link to the ConfigMap object afterward.
Trap: A describes volume-mount behavior, not env-var behavior — a very common mix-up between the two consumption methods.

</details>

---

**Q5. Why does kubelet use a two-level `..data` symlink chain instead of overwriting a file in place?**

- A) It's a legacy implementation detail with no functional purpose
- B) A direct overwrite isn't atomic — the two-level chain lets kubelet swap `..data` with a single atomic `rename()`
- C) It's required by the busybox `ls` command
- D) It only matters for `binaryData`

<details>
<summary>Answer</summary>

**B** — This atomicity is the entire point: readers always see either the fully old or fully new file content, never a partial write.
Trap: C confuses a diagnostic tool's display behavior (busybox `ls` not following symlinks) with the actual reason the mechanism exists.

</details>

---

**Q6. Can `envFrom` rename a ConfigMap key when loading it as an environment variable?**

- A) Yes, using the `prefix` field
- B) No — only `env.valueFrom.configMapKeyRef` supports renaming
- C) Yes, using `items`
- D) Yes, automatically, based on naming conventions

<details>
<summary>Answer</summary>

**B** — `envFrom` always uses the ConfigMap's own key name as the env var name; `prefix` can prepend a string but doesn't rename the key itself.
Trap: A is a near-miss — `prefix` is real but doesn't achieve a rename, just a namespaced prefix on the existing key name.

</details>

---

**Q7. `optional: true` is set and the referenced ConfigMap doesn't exist. What does `printenv` show for that variable?**

- A) An empty string
- B) Nothing at all — the variable is absent entirely
- C) The literal text "null"
- D) The pod fails to start

<details>
<summary>Answer</summary>

**B** — Absent, not empty — `printenv` on a genuinely undeclared variable returns nothing and a non-zero exit code, which is exactly this case.
Trap: A is the most common wrong assumption — "optional" sounds like it should default to blank, but Kubernetes simply omits the variable instead.

</details>

---

**Q8. Does `$(VAR_NAME)` substitution in `command`/`args` see a variable that was loaded via `envFrom`?**

- A) Yes, always
- B) No — only variables explicitly declared in the same `env[]` list are in scope
- C) Only in exec-form commands
- D) Only if the variable name is uppercase

<details>
<summary>Answer</summary>

**B** — This is the "envFrom blind spot" — `$(VAR_NAME)` substitution has no visibility into `envFrom`-sourced variables, only ones explicitly listed in `env[]`.
Trap: A assumes full visibility into the container's entire environment, which isn't how this specific substitution mechanism works.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````