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
├── 01-configmaps-anki.csv
├── 01-configmaps-quiz.md
└── src/
    ├── 01-configmap-literal.yaml        # Simple key-value ConfigMap
    ├── 02-configmap-file.yaml           # Multi-line / file-like ConfigMap
    ├── 03-configmap-immutable.yaml      # Immutable ConfigMap
    ├── 04-pod-envfrom.yaml              # Pod consuming full ConfigMap as env vars
    ├── 05-pod-env-valueFrom.yaml        # Pod consuming specific keys via valueFrom
    ├── 06-pod-volume.yaml               # Pod consuming ConfigMap as volume-mounted files
    └── break-fix/
        ├── 01-size-limit-exceeded.yaml       # Create Imperatively
        └── 02-duplicate-key-overlap.yaml     
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
apiVersion: v1
kind: ConfigMap
metadata:
  name: chomping-demo
data:
  clip-example.txt: |
    line one
    line two


  strip-example.txt: |-
    line one
    line two


  keep-example.txt: |+
    line one
    line two


  zzz-end-marker: "boundary — makes keep-example.txt's trailing blank lines unambiguous, not just EOF"
```

Standard `|` is almost always correct for config files. The YAML parser strips the minimum shared indentation from the block and the result becomes the file content when volume-mounted.

>**Note:** See **Appendix — YAML Literal Block Scalar Resulting Values** for the exact, character-by-character resulting string for all three variants shown above.

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
- Makes the ConfigMap's identity stable — safe to reference by name in GitOps and CI/CD pipelines (`05-kustomize-config-secret-management` covers this exact concept hands-on, in full, with a concrete mutable-vs-immutable example)
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

**Full update flow for a volume-mounted ConfigMap — including who opens the watch, and when:**

1. **Pod is created**, referencing this ConfigMap via a volume mount.
2. Kubelet's ConfigMap manager runs its per-pod registration step. If **no other pod already registered on this node** references this same ConfigMap, kubelet opens the watch connection **right now** — this is the answer to "who creates it, and when": kubelet's own ConfigMap manager, at pod registration, once per unique object per node (not once per pod — a second pod on the same node referencing the same ConfigMap reuses the existing watch).
3. Kubelet performs the initial atomic symlink write (see **Appendix — Atomic Symlink Swap Mechanism**) and the pod starts with current content mounted.
4. **ConfigMap is updated** (`kubectl edit`/`apply`) → API server persists to etcd → API server pushes a watch **event** down every open watch connection for this object, including the one from step 2.
5. Kubelet's **local cache** for this ConfigMap updates from that event — this part is near-instant (milliseconds), since the connection was already open.
6. The **mounted files are NOT rewritten at this instant.** The rewrite only happens the next time kubelet's own general, node-wide periodic sync loop reaches this pod and checks "does my local cache for this ConfigMap still match what's on disk." This loop is not created per ConfigMap or per pod — see **Appendix — General kubelet Sync Cycle** for what it actually is.
7. On a mismatch, kubelet performs the atomic symlink swap. Files inside the pod now show new content — no pod restart needed.
8. **If the pod is later deleted**, kubelet's ConfigMap manager unregisters it; if no other pod on that node still references this ConfigMap, the watch from step 2 is closed.

> **In practice the total delay (step 4 → step 7) is commonly cited as 10–90 seconds**, worst case one full sync-loop window — see the Appendix for why this window isn't ConfigMap-specific.

> **This entire flow — per-object watch dedup, general sync-loop-driven rewrite, atomic symlink swap — applies identically to Secret volumes.** it's the same kubelet mechanism, just watching Secret objects instead of ConfigMaps.

---



## Lab Step-by-Step Guide

This walkthrough builds three ConfigMaps (Step 1) and consumes them
through every method Concepts described: environment variables via
`envFrom` and `env.valueFrom` (Steps 2–3b), volume-mounted files (Step
4), and a `binaryData` TLS certificate (Step 5). Steps 6–7 then prove
the two central claims from Concepts directly — that an immutable
ConfigMap genuinely rejects updates, and that a volume-mounted value
updates live while an env-var-sourced value never does, on the same
cluster, side by side. Step 8 rebuilds ConfigMaps imperatively for exam
practice; Step 9 tears everything down.

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
kubectl delete pod pod-valuefrom --grace-period=0 --force
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

The second consumption method passes ConfigMap values as **command arguments**. The pattern: load the ConfigMap key as an env var first (via `env` or `envFrom`), then reference it inside `command` or `args` using `$(VAR_NAME)` syntax.

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
kubectl delete pod pod-cmd-args --force --grace-period=0
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

In the third method, pod consumes ConfigMap as **volume mounted files**.Volume mounting projects each ConfigMap key as a **file** in a directory. The key is the filename; the value is the file content. This is essential for config files that applications read from disk (nginx.conf, app.properties, etc.).

**06-pod-volume.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-volume
  namespace: default
spec:
  volumes:

  # Volume-1: backed by release-config (immutable ConfigMap — mountable like any other)
  - name: release-files      # volume name — referenced in volumeMounts below
    configMap:
      name: release-config   # immutable ConfigMap — also mountable as volume
      # defaultMode: 0444    # optional: permission for all files in this volume (default 0644)

  # Volume-2: backed by app-files ConfigMap
  - name: config-files       
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

>**Note:** : How the symlink chain works and why it exists? See **Appendix — Atomic Symlink Swap Mechanism** for the full mechanism in more depth, identical mechanism applies to Secret volume mounts.

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

### Error-1 — "I tried to embed a large file in a ConfigMap, and it won't create at all"

**The scenario:** someone tries to embed a large file (a bundled
dependency, a large dataset export) directly into a ConfigMap instead of
using a PersistentVolume, and `kubectl create` rejects it outright.
Investigate what limit was actually hit, before revealing the cause.

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

### Error-2 — "Same key, two fields — and the apply was rejected"

**The scenario:** the same key name (`server.crt`) is accidentally
written into both `data` and `binaryData` on the same ConfigMap. The
YAML looks syntactically fine at a glance, but `kubectl apply` rejects
it. Investigate what's actually conflicting, before revealing the cause.

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

**Q1. Concepts lists command arguments as a genuinely separate ConfigMap consumption method from environment variables, even though `$(VAR_NAME)` requires an env var to exist first. Why is it treated as distinct rather than just "a use of env vars"?**

- A) It isn't actually distinct — the docs just describe it that way for clarity
- B) The value ends up delivered as part of the process's argv, read via `sys.argv`/`$1`, not via `os.getenv()` — a genuinely different delivery mechanism for the receiving application
- C) It requires a completely different ConfigMap field
- D) It only works with exec-form commands

<details>
<summary>Answer</summary>

**B** — The env var step is always required first, but what the application actually receives (an argv entry vs. an environment lookup) is a real, distinct outcome.
Trap: D is disproven directly in this demo's own Concepts — `$(VAR_NAME)` is shown working in both exec-form and shell-form.

</details>

---

**Q2. `script.sh: |-` uses the block-scalar chomping indicator `|-` instead of plain `|`. What's the actual difference?**

- A) `|-` preserves all trailing newlines; `|` strips them all
- B) `|-` strips all trailing newlines; `|` strips only the final one
- C) `|-` is Kubernetes-specific syntax; `|` is standard YAML
- D) There is no difference — both are equivalent

<details>
<summary>Answer</summary>

**B** — `|` (plain) keeps internal newlines but trims to a single trailing newline; `|-` removes trailing newlines entirely — useful specifically for shell scripts where a stray trailing blank line is unwanted.
Trap: C reverses reality — both `|` and `|-` are standard YAML chomping indicators, neither is Kubernetes-specific.

</details>

---

**Q3. A ConfigMap volume item sets `path: nginx/nginx.conf` under a `mountPath` of `/etc/nginx`. Where does the file actually end up?**

- A) `/etc/nginx/nginx.conf`
- B) `/etc/nginx/nginx/nginx.conf` — a real subdirectory named `nginx` gets created
- C) `/nginx/nginx.conf`, ignoring `mountPath`
- D) The pod fails to start

<details>
<summary>Answer</summary>

**B** — Any `/` in `items[].path` creates a real subdirectory inside `mountPath` — this demo's own Lab hits this directly: `cat /etc/nginx/nginx.conf` fails with "No such file or directory" because the actual path requires the extra `nginx/` segment.
Trap: A is the intuitive-but-wrong assumption that trips up exactly this scenario in the demo's own walkthrough.

</details>

---

**Q4. `envFrom` supports an optional `prefix` field. What does setting `prefix: "CFG_"` actually do?**

- A) Filters which keys get loaded from the source
- B) Prepends `CFG_` to every key name from that specific `envFrom` source before it becomes an env var
- C) Sets a default value for any missing keys
- D) Renames only the first key alphabetically

<details>
<summary>Answer</summary>

**B** — `APP_ENV` becomes `CFG_APP_ENV`, `APP_PORT` becomes `CFG_APP_PORT`, etc. — useful specifically for avoiding key collisions when `envFrom` loads from multiple sources at once.
Trap: A invents a filtering behavior `prefix` doesn't have — it changes every key's name, it doesn't select a subset of them.

</details>

---

**Q5. A DER-format certificate must go in `binaryData`, but a PEM-format certificate of the same underlying certificate goes in `data`. Why the difference, given they represent the same certificate?**

- A) DER is a newer, more secure format than PEM
- B) PEM is base64-encoded text (`-----BEGIN CERTIFICATE-----`) and is therefore valid UTF-8; DER is the raw binary encoding of the same data and would be corrupted by UTF-8 handling
- C) PEM certificates are always self-signed; DER certificates never are
- D) DER is required for Kubernetes' own internal certificate handling

<details>
<summary>Answer</summary>

**B** — It's the same certificate, two different encodings — one happens to already be text-safe, the other genuinely isn't.
Trap: A and C both invent unrelated distinctions (security, signing) between two formats that differ only in encoding, not in what they cryptographically represent.

</details>

---

**Q6. Break-Fix Error-1 tries to create a ConfigMap from a ~1.6MB base64-encoded file. What's the actual rejection, and when does it happen?**

- A) The pod fails to start with `CreateContainerConfigError`
- B) `kubectl create configmap` itself is rejected immediately with a "Too long" error — no ConfigMap is ever created
- C) The ConfigMap is created but truncated to fit 1 MiB
- D) It succeeds, but only the first 1 MiB is readable

<details>
<summary>Answer</summary>

**B** — This fails at creation time, before any pod is even involved — there's no partial or truncated object, just an outright rejection.
Trap: C and D both imagine a partial-success outcome that doesn't happen — the object is never created at all.

</details>

---

**Q7. Break-Fix Error-2 puts the same key (`server.crt`) in both `data` and `binaryData` on one ConfigMap. Is the YAML itself syntactically invalid?**

- A) Yes — this is a YAML parsing error
- B) No — the YAML parses fine; the API server rejects it as a semantic validation error (duplicate key across the two fields)
- C) Yes, because YAML doesn't allow the same key name to appear twice anywhere in a document
- D) No — this is silently accepted, with `binaryData` taking precedence

<details>
<summary>Answer</summary>

**B** — The YAML is completely well-formed; `data` and `binaryData` are two separate maps, so `server.crt` appearing as a key in each is legal YAML — Kubernetes' own API validation is what rejects it, not the YAML parser.
Trap: C conflates "same key in the same map" (a real YAML restriction) with "same key across two different maps" (what's actually happening here) — these aren't the same rule.

</details>

---

**Q8. A pod references a ConfigMap that doesn't exist yet (no `optional: true`). Once the ConfigMap is created, does the pod need to be deleted and reapplied to pick it up?**

- A) Yes — a new pod must be created
- B) No — the existing pod transitions from `CreateContainerConfigError` to `Running` automatically once the ConfigMap exists
- C) Only if the ConfigMap is immutable
- D) Only if the pod's `restartPolicy` is `Always`

<details>
<summary>Answer</summary>

**B** — The kubelet keeps retrying container creation on its own; the same pod object recovers with no manual intervention the moment the missing dependency exists.
Trap: D invents a `restartPolicy` dependency that doesn't apply here — this is the kubelet retrying container *creation*, not a container restart after it already ran.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````
---

## Appendix — General kubelet Sync Cycle

This ConfigMap demo's own "Full update flow" refers to kubelet's periodic sync loop and `syncFrequency`. Worth being precise about what that loop actually is, since it's easy to assume it's a ConfigMap-specific mechanism — it isn't.

**`syncFrequency` is not a per-ConfigMap or per-pod timer.** It's a single, node-wide periodic loop kubelet runs once, reconciling *all* pod state on that node each cycle — checking ConfigMap/Secret volume freshness is one of the things this general loop does, among others, not something instantiated separately for each pod or each ConfigMap. It is owned entirely by the **kubelet** — the container runtime has no role in ConfigMap/Secret content management at all.

**This is a genuinely separate concern from `configMapAndSecretChangeDetectionStrategy` (`Get`/`Cache`/`Watch`).** That setting only controls *how kubelet finds out the current content* of a ConfigMap it already knows it needs (fetch live every time, use a TTL cache, or maintain a live watch-fed cache) — it has no bearing on *when* the mounted volume on disk actually gets rewritten. That timing is entirely the general sync loop's job. Confusing these two is a very common mistake in secondary sources online — worth not making it here.

**Applies identically to Secrets.** Secret volumes go through the exact same general sync loop, the same `Get`/`Cache`/`Watch` strategy setting (it's one shared kubelet setting covering both object types), and the same per-object watch-dedup logic from Concepts above — nothing about this differs for Secrets versus ConfigMaps.

---

## Appendix — Atomic Symlink Swap Mechanism

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

When kubelet needs to write (or rewrite) a ConfigMap/Secret volume's content, it does **not** touch the individual visible files (`nginx.conf`, `app.properties`, etc.) directly. Instead:

1. It writes the **complete new set of files** into a brand-new, uniquely timestamped directory on the node's filesystem (e.g. `..2026_04_26_10_45_00.987654321/`).
2. It performs a **single atomic rename operation**, repointing the `..data` symlink from the old timestamped directory to the new one.
3. Because a symlink-target rename is one indivisible filesystem operation, any process reading through `..data/<key>` at that exact moment sees either the **complete old version** or the **complete new version** of every file — never a mix of some old, some new, or a half-written file.
4. The **top-level, per-key symlinks** (`app.properties -> ..data/app.properties`, `nginx -> ..data/nginx`) are set up once and essentially never need to change on a normal update — only the one `..data` symlink's target changes. This is exactly what Step 7's own verification shows: after editing `app-files`, the per-key symlinks are unchanged, only `..data`'s target timestamp is newer.
5. The **old timestamped directory isn't deleted immediately** — kubelet cleans it up on a separate schedule, which is why Step 7's own output shows both the old and new timestamped directories briefly coexisting.

**Why this matters, precisely:** if kubelet instead overwrote `app.properties` in place, byte by byte, a process reading that exact file during the write could see a genuinely corrupted, half-old-half-new result — a real risk for any config file being read at the same moment it's being rewritten. The two-level symlink design exists specifically to make that scenario impossible.

**Applies identically to Secret volume mounts** — `02-secrets` relies on this exact same mechanism; nothing about the atomic-swap design changes for Secret content versus ConfigMap content.

> **Why `subPath` mounts do NOT get live updates:** `subPath` bind-mounts the actual file directly into the container — bypassing the `..data/` chain entirely. The atomic `rename()` on `..data/` never affects a bind-mounted file. Content is frozen at pod start time. Full `subPath` treatment (and why you'd choose it anyway) is `04-volume-mounts`' entire subject.

---

## Appendix — YAML Literal Block Scalar Resulting Values

The three chomping indicators, using **identical content** in all three cases —
so the only variable is the indicator itself, making the difference in (a)
"strip one final trailing newline," (b) "strip ALL trailing newlines," and (c)
"keep ALL trailing newlines" directly comparable rather than merely described.

**Source manifest — one ConfigMap, three keys, same two lines of content and
the same two trailing blank lines under each:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chomping-demo
data:
  clip-example.txt: |
    line one
    line two


  strip-example.txt: |-
    line one
    line two


  keep-example.txt: |+
    line one
    line two


  zzz-end-marker: "boundary — makes keep-example.txt's trailing blank lines unambiguous, not just EOF"
```

Each block has exactly the same two content lines (`line one`, `line two`)
followed by exactly two blank lines before the next key — this is the part
that actually exposes the difference between the three indicators. (The
final `zzz-end-marker` key exists purely so `keep-example.txt`'s trailing
blank lines are clearly bounded *within the document*, not just trailing
off the end of the file, which some parsers can treat as a separate edge
case.)

**Resulting values — shown with explicit `\n` markers so nothing is left
to infer:**

**`clip-example.txt` (`|` — default, clip):**
```
line one\n
line two\n
```
One trailing newline kept — the two blank lines in the source are discarded entirely.

**`strip-example.txt` (`|-` — strip):**
```
line one\n
line two
```
**Zero** trailing newlines — not even the one that would normally terminate
the last content line. The value's very last character is the `o` in `two`.

**`keep-example.txt` (`|+` — keep):**
```
line one\n
line two\n
\n
\n
```
**All three** trailing newlines kept: the one that terminates `line two`
itself, plus one for each of the two blank lines that followed it in the
source.

**How to verify this yourself, rather than take it on faith:**

```bash
kubectl apply -f chomping-demo.yaml
kubectl exec <any-pod-with-this-mounted> -- cat -A /path/to/clip-example.txt
kubectl exec <any-pod-with-this-mounted> -- cat -A /path/to/strip-example.txt
kubectl exec <any-pod-with-this-mounted> -- cat -A /path/to/keep-example.txt
```

`cat -A` marks every line ending with a literal `$` — a blank line shows as
a bare `$` on its own line. Run against the three files above, you'd see:

```
# clip-example.txt
line one$
line two$

# strip-example.txt
line one$
line two          ← no trailing $ at all — "two" is the literal last byte

# keep-example.txt
line one$
line two$
$
$
```

**Why this matters practically:** when this data is volume-mounted, the
file on disk is byte-for-byte this exact value — an application reading
`strip-example.txt` genuinely gets a file with no trailing newline at all,
which some tools (a strict line-based parser expecting POSIX-style
newline-terminated files) can actually choke on. This isn't cosmetic —
getting the chomping indicator wrong produces a real, different file.

This applies identically whether the data lives in a ConfigMap's `data`
field or a Secret's `stringData` field — the YAML parsing behavior is
unrelated to which object type is holding it.
