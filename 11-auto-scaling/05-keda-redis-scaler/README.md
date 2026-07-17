# Demo: 11-auto-scaling/05-keda-redis-scaler — KEDA Redis Scaler — Secured Queue Consumer

## Lab Overview

**What this lab builds, end to end:** a Redis-backed work queue and a consumer that KEDA scales
automatically based on how many items are waiting. Concretely: Redis holds a list (`work-queue`); a
Deployment (`redis-list-consumer`) is normally scaled to zero; a `TriggerAuthentication` gives KEDA a way
to read Redis's password securely; a `ScaledObject` watches the queue length and tells KEDA when to scale
the consumer up or down. Steps 1–2 set up Redis itself; Step 3 wires up secure access; Step 4 deploys the
(initially idle) consumer; Step 5 creates the actual autoscaling rule; Steps 6–8 prove the whole chain
works by watching it react to real load.

This demo extends KEDA from the zero-infrastructure Cron scaler (`04-keda-fundamentals`) to a real
event-driven workload, with credentials handled correctly via a `TriggerAuthentication` object rather than
embedded in plaintext. No prior Redis knowledge is assumed — Redis itself, its architecture, and every
Kubernetes object it introduces are explained from first principles in Concepts below.

> **Environment:** minikube `3node` profile (`v1.34.0`). KEDA `2.20.0` (installed in `04-keda-fundamentals`,
> stays installed for this demo, uninstalled at the end of this demo's Cleanup).

## Prerequisites

**Required Software:**
- `kubectl` v1.30+ — cluster interaction
- `helm` v3.14+ — Redis chart install
- minikube `3node` profile — running, from earlier demos in this series
- KEDA v2.20.0 — installed in `04-keda-fundamentals`, must still be present

**Verify KEDA is installed before starting:**
```bash
kubectl get pods -n keda
helm list -n keda
```
```
NAME                                               READY   STATUS    RESTARTS       AGE
keda-admission-webhooks-85957885bf-tzvzn           1/1     Running   0              4d6h
keda-operator-6bb79ff79-86qbt                      1/1     Running   1 (4d6h ago)   4d6h
keda-operator-metrics-apiserver-656749fd7c-765nm   1/1     Running   0              4d6h

NAME    NAMESPACE       REVISION        UPDATED                 STATUS          CHART           APP VERSION
keda    keda            1               2026-07-07 18:15:46...  deployed        keda-2.20.0     2.20.0
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `04-keda-fundamentals` — ScaledObject anatomy, `pollingInterval`/
  `cooldownPeriod`, the two polling loops, scale-to-zero/from-zero mechanics, activation vs. scaling
- **REQUIRED:** Kubernetes Secrets basics — how a Secret is referenced by name from another object
- **NOT required:** any prior Redis knowledge — covered from scratch below

## Lab Objectives

1. ✅ Deploy a secured (AUTH-enabled) Redis instance via Helm as the KEDA scaling target
2. ✅ Create a `TriggerAuthentication` object that references Redis credentials from a Kubernetes Secret
3. ✅ Configure a `ScaledObject` using KEDA's `redis` scaler (List-length trigger) bound to that
   `TriggerAuthentication`
4. ✅ Deploy a queue-consumer Deployment that KEDA scales from zero based on Redis List length
5. ✅ Verify the full scale-to-zero → scale-from-zero → scale-to-zero cycle, including the activation
   boundary, under real load and idle conditions
6. ✅ Diagnose and fix real misconfigurations encountered hands-on: an invalid image reference, a
   `TriggerAuthentication` pointed at the wrong Secret key, and a musl/Alpine DNS resolution failure
7. ✅ Map Redis-scaler concepts and commands to CKA/CKAD exam objectives

## Directory Structure

```
11-auto-scaling/05-keda-redis-scaler/
├── README.md
├── 05-keda-redis-scaler-anki.csv
├── 05-keda-redis-scaler-quiz.md
└── src/
    ├── 01-redis-values.yaml
    ├── 02-trigger-auth-redis.yaml
    ├── 03-consumer-deployment.yaml
    ├── 04-scaledobject-redis.yaml
    └── break-fix/
        ├── 01-broken-image.yaml
        └── 02-broken-triggerauth.yaml
```

## Recall Check — 04-keda-fundamentals

Answer from memory before reading:

1. What is the difference between KEDA's `cron` scaler and a native Kubernetes `CronJob`?
2. When `ACTIVE` flips from `True` to `False` on a ScaledObject, does that happen at the same moment the
   workload actually scales down, or is there a gap?
3. A trigger's scaling math says 4 replicas are needed, but the metric value is below the trigger's
   activation floor. How many replicas does KEDA actually run?

<details>
<summary>Answers</summary>

1. The `cron` scaler changes the **replica count** of an existing, always-running Deployment/StatefulSet on
   a schedule. A `CronJob` **creates new Job/Pod objects** on a schedule, each running to completion and
   exiting. Different mechanisms for different workload shapes.
2. They happen together, as one combined transition — not with a visible gap between two separate events.
   `ACTIVE` stays `True` for the entire `cooldownPeriod` after the trigger last reported active, and only
   flips `False` at the exact moment KEDA scales down.
3. Zero — activation always overrides scaling when they disagree, regardless of what the scaling math alone
   would suggest.

</details>

## Concepts

### Redis, from scratch

Redis ("REmote DIctionary Server") is an in-memory, single-threaded key-value data store. "In-memory" means
data lives in RAM by default — extremely fast, but lost on restart unless persistence is configured
(disabled in this lab: `persistence.enabled: false`). "Single-threaded" means Redis achieves high
throughput through fast memory access and an optimized event loop, not parallelism.

**The List type.** Each Redis key can hold one of several data structures; this demo uses only **Lists** —
an ordered collection of strings:
- `RPUSH key value [value ...]` — push value(s) onto the **right** (tail) end (enqueue)
- `BRPOP key timeout` — **B**locking pop from the right end; blocks up to `timeout` seconds waiting for an
  item if the list is empty, rather than returning immediately
- `LLEN key` — current length of the list

`RPUSH` + `BRPOP` from opposite ends gives FIFO ordering — a work queue. `LLEN` is what KEDA polls.

**AUTH.** Redis supports a single shared-secret mechanism (`requirepass`). Any client must `AUTH <password>`
(or `-a <password>` on `redis-cli`) before other commands — issuing a command without it returns `NOAUTH
Authentication required.`; a wrong password returns `WRONGPASS invalid username-password pair`.

### Who develops Redis, and what license is it under?

Redis was created by **Salvatore Sanfilippo** ("antirez") in 2009. It's now developed and commercially
backed by **Redis Ltd.** (formerly Redis Labs), though the core server remains a community-developed
project with external contributors.

**License — this has changed twice, worth knowing precisely rather than assuming it's simply "open source":**

| Period | License | Open source (OSI-approved)? |
|---|---|---|
| Up to Redis 7.2.4 | BSD-3-Clause | Yes — fully permissive |
| Redis 7.4–7.8 (March 2024 – May 2025) | RSALv2 / SSPLv1 (dual, source-available) | **No** — neither is OSI-approved |
| Redis 8.0 onward (current) | Tri-license: RSALv2, SSPLv1, **or** AGPLv3 | **Yes, if you choose AGPLv3** — the other two options remain source-available, not open source |

In March 2024, Redis Ltd. moved off BSD specifically to stop cloud providers from offering Redis as a
managed service without contributing back — RSALv2 explicitly prohibits building a competing managed
service, and SSPLv1 requires publishing your entire surrounding service stack if you offer the software
as a network service. This triggered the community-led **Valkey** fork (BSD-3-Clause, Linux Foundation,
forked from Redis 7.2.4) — now the default Redis-compatible package in several major Linux distributions,
and what AWS ElastiCache and Google Cloud Memorystore both default new deployments to. In May 2025, Redis
Ltd. added AGPLv3 as a third licensing option starting with Redis 8, restoring an OSI-approved open source
choice — but note AGPLv3 is copyleft: if you operate a **modified** Redis as a network service for others,
you're expected to publish those modifications. For this lab's use (self-hosting internally, unmodified),
none of the three license options impose any practical restriction — this distinction matters far more for
anyone building a product on top of Redis than for a lab or internal deployment like this one.

### Official Redis vs. Bitnami's Redis — same software, different packaging

These are **not different Redis implementations** — Bitnami's chart deploys the exact same open-source
Redis server binary as the official image, just packaged differently:

| | Official Redis image (`redis:*` on Docker Hub) | Bitnami Redis (`bitnami/redis`, used in this lab) |
|---|---|---|
| Maintained by | Redis Ltd. / Docker's official images team | Broadcom (Bitnami) |
| Underlying software | Redis Ltd.'s Redis server | Identical Redis server — Bitnami doesn't fork or modify Redis itself |
| What's different | Minimal base image, no built-in Helm chart | Hardened/non-root container conventions, a full Helm chart with AUTH/persistence/replication/Sentinel wiring pre-built, a metrics exporter sidecar option, and standardized config-templating scripts |
| Kubernetes deployment story | You write the StatefulSet/Service/Secret yourself | The chart generates all of it, matching the architecture table above |
| Free-tier image tagging (since Aug 2025) | Normal versioned tags remain available | `latest`-only for free tier — see the dedicated note below |

In short: **Bitnami adds operational packaging around the real Redis, it does not replace or modify Redis
itself.** This lab uses the official `redis:7` image directly for the consumer's `redis-cli` calls (Concepts,
Image choice section below), and the Bitnami chart only for standing up the server itself, precisely because
the chart's StatefulSet/Secret/Service wiring is what makes this a realistic, production-shaped setup rather
than a hand-rolled one.

### What Redis is actually used for — a few concrete examples

This lab uses exactly one pattern (a work queue via Lists), but Redis's in-memory speed makes it common
across several distinct use cases, worth knowing the breadth of even if this demo only exercises one:

- **Caching** — the original, most common use case: storing expensive-to-compute or expensive-to-fetch
  results in memory, with a `TTL` (expiry), to avoid repeated database/API calls
- **Session storage** — web application session data, shared across multiple app server instances
- **Rate limiting** — atomic increment/expire operations (`INCR` + `EXPIRE`) make Redis a natural fit for
  request-throttling logic
- **Leaderboards / ranking** — the Sorted Set data type (`ZADD`/`ZRANGE`) maintains a score-ordered
  collection natively, without application-side sorting
- **Pub/Sub messaging** — `PUBLISH`/`SUBSCRIBE` for simple real-time fan-out messaging (distinct from the
  List-based queue pattern this lab uses — Pub/Sub has no persistence or replay; a subscriber that's offline
  when a message publishes simply never sees it)
- **Distributed locks** — using `SET key value NX EX <seconds>` (set-if-not-exists with expiry) as a simple
  mutual-exclusion primitive across multiple application instances
- **Work queues** (this lab) — Lists as a FIFO queue between producers and consumers

### Other Redis deployment types — how standalone compares

This lab uses **standalone** — a single Redis process, no redundancy. Worth knowing what the alternatives
trade off, even though this lab doesn't exercise them:

| Deployment type | What it adds over standalone | Trade-off |
|---|---|---|
| **Standalone** (this lab) | — | Single point of failure; simplest possible setup |
| **Replication** (primary + read replicas) | Read scalability, a hot standby copy of the data | No *automatic* failover — a human (or external tooling) must promote a replica manually |
| **Sentinel** | Automatic failover on top of replication — monitors the primary, promotes a replica if it fails | Adds Sentinel's own separate quorum process to operate; still single-primary for writes |
| **Cluster** | Horizontal write scaling — data is sharded across multiple primaries, each with its own replicas | Significantly more operational complexity; client libraries must be cluster-aware |

The Bitnami chart supports all four via its `architecture:` and `sentinel.enabled`/`cluster.enabled` values
— this lab deliberately stays on `architecture: standalone` to keep the KEDA-facing parts of the demo the
focus, not Redis's own high-availability configuration.

### `redis-cli` — the command-line client used throughout this lab

`redis-cli` is Redis's official CLI client, bundled in every official Redis image and installable
standalone. It has two modes and a set of commands worth knowing beyond just the four this lab uses.

**Two modes of operation:**
```bash
# One-shot mode (used throughout this lab) — runs one command, prints result, exits
redis-cli -h <host> -a <password> <COMMAND> [args...]

# Interactive mode — omit the command, get a live prompt for multiple commands in sequence
redis-cli -h <host> -a <password>
127.0.0.1:6379> PING
PONG
127.0.0.1:6379> exit
```

**Common connection flags:**
- `-h <host>` — server hostname (defaults to `127.0.0.1`)
- `-p <port>` — server port (defaults to `6379`)
- `-a <password>` — AUTH password, passed inline (triggers the "using a password on the command line"
  warning — cosmetic here; `REDISCLI_AUTH` as an env var avoids it where shell history exposure matters)
- `-n <db>` — select a logical database index (`0`–`15` by default); this lab uses the default (`0`)
  throughout, never explicitly selecting one

**Commands used in this lab, and what each does:**

| Command | Syntax | Function |
|---|---|---|
| `PING` | `PING` | Connectivity + AUTH check — returns `PONG` if both succeed |
| `RPUSH` | `RPUSH key value [value ...]` | Enqueue: push one or more values onto the list's right (tail) end |
| `BRPOP` | `BRPOP key timeout` | Blocking dequeue: pop from the left (head) end, waiting up to `timeout` seconds if empty rather than returning immediately |
| `LLEN` | `LLEN key` | Return the current item count of a list |
| `DEL` | `DEL key [key ...]` | Remove one or more keys entirely (used here to drain/reset the queue) |

**A few more worth knowing, not used hands-on in this lab but genuinely common:**

| Command | Syntax | Function |
|---|---|---|
| `LRANGE` | `LRANGE key start stop` | Read a range of list items without removing them — useful for inspecting a queue's contents without consuming it |
| `KEYS` | `KEYS pattern` | List all keys matching a pattern — **avoid in production**, it's O(N) and blocks the single-threaded server; `SCAN` is the safe incremental alternative |
| `SCAN` | `SCAN cursor [MATCH pattern] [COUNT n]` | Incrementally iterate all keys without blocking, unlike `KEYS` |
| `TTL` | `TTL key` | Seconds remaining before a key expires (`-1` if no expiry set, `-2` if the key doesn't exist) |
| `INFO` | `INFO [section]` | Server statistics and state — memory usage, connected clients, replication status, etc. |
| `CONFIG GET`/`CONFIG SET` | `CONFIG GET <param>` | Read/change a live server configuration parameter without a restart |

**Non-interactive diagnostic flags** (run standalone, not as a command argument):
- `redis-cli --bigkeys` — scans the keyspace and reports the largest keys per data type
- `redis-cli --stat` — continuously prints live server load statistics
- `redis-cli --latency` — measures round-trip latency to the server over time

`kubectl exec ... -- redis-cli ...` runs this client one-shot inside an already-running pod, rather than
opening an interactive session — faster and more reliable than spinning up a throwaway pod per check.

### Redis in this Kubernetes deployment — architecture

Deployed via the **Bitnami Redis Helm chart**, standalone mode (no replicas, no Sentinel). What the chart
creates:

| Object | Name | Purpose |
|---|---|---|
| **StatefulSet** | `redis-queue-master` | Runs the Redis server pod: `redis-queue-master-0` |
| **Service (ClusterIP)** | `redis-queue-master` | Stable DNS name clients connect to |
| **Service (headless)** | `redis-queue-headless` | Direct per-pod DNS, used internally by the chart |
| **Secret** | `redis-queue` | Auto-generated, holds the AUTH password under key `redis-password` |

**Component diagram — standalone architecture, as deployed in this lab:**

```
                          Namespace: keda-demo
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                    │
  │  redis-list-consumer          redis-queue-master (ClusterIP Svc)   │
  │  (Deployment, scales 0-5) ───► 10.98.73.244:6379                   │
  │       │  BRPOP work-queue          │                               │
  │       ▼                            ▼                               │
  │  ┌─────────┐               ┌─────────────────────┐                 │
  │  │consumer │◄──RESP proto──│ redis-queue-master-0 │                │
  │  │ pod(s)  │   over TCP    │ (StatefulSet, 1 pod)  │                │
  │  └─────────┘               │  - redis-server proc  │                │
  │       ▲                    │  - AUTH: requirepass   │                │
  │       │                    │  - in-memory List:     │                │
  │  RPUSH work-queue          │    "work-queue"        │                │
  │  (from redis-cli,          └─────────────────────┘                  │
  │   e.g. via kubectl exec)            ▲                               │
  │                                     │                               │
  │                          redis-queue-headless (headless Svc)        │
  │                          — used internally by the chart for         │
  │                            direct pod DNS, not by this lab directly │
  │                                                                      │
  │  redis-queue (Secret) ──► mounted into consumer via secretKeyRef,   │
  │                           read directly by kubectl/redis-cli        │
  │                           elsewhere via base64-decoded lookup       │
  └──────────────────────────────────────────────────────────────────┘
```

**Reading this diagram:** there is exactly one Redis process in this lab (`redis-queue-master-0`) — every
client, whether it's the consumer Deployment's pods or an ad-hoc `redis-cli` command via `kubectl exec`,
talks to that same single process, either through the ClusterIP Service's stable DNS name or (for the
consumer/producer traffic in this diagram) directly. There is no replication, no failover, and no sharding
— a genuine single point of failure, acceptable for this lab, not for production (see "Other Redis
deployment types" below for what production setups add on top of this).

**Why StatefulSet, not Deployment?** Every object hands-on so far in this series used Deployments, which
treat replicas as interchangeable with no persistent identity. A stateful service needs a stable, predictable
pod name (`redis-queue-master-**0**`) and, in a multi-replica setup, storage that follows a specific ordinal
across rescheduling. This demo has one replica, so the multi-replica benefit is subtle here — but it's why
the chart is built this way, and why it works correctly the moment you scale beyond standalone mode.

> **Known limitation — Bitnami image pinning.** Since the August 2025 Bitnami Secure Images transition,
> free-tier Bitnami images no longer publish pinned version tags — only `latest`. The Helm **chart** version
> is pinned (`--version 27.0.14`); the **container image** the chart deploys resolves to `latest` regardless.
> Accepted for this lab rather than using the frozen, unsupported `bitnamilegacy` registry.

### `TriggerAuthentication` — fields and purpose

Decouples scaler credentials from the ScaledObject spec — the wrong way would be plain text directly in the
trigger's `metadata:` block, visible to anyone who can `kubectl get scaledobject -o yaml`.

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: redis-trigger-auth
  namespace: keda-demo
spec:
  secretTargetRef:
    - parameter: password
      name: redis-queue
      key: redis-password
```

**Field-by-field:**
- `secretTargetRef` — a **list**, not a single object; each entry maps one Secret key to one
  scaler-recognized parameter
- `parameter` — **not a Kubernetes field name.** It's the name the *scaler itself* expects internally
  (`password`, for the redis scaler specifically — this varies by scaler type, always check that scaler's
  own docs). Think of it as "which argument in the scaler's own function signature this Secret value fills."
- `name` — the Secret's own Kubernetes name
- `key` — the specific key within that Secret's `data` map

So the block above reads: *"take the value at key `redis-password` in the `redis-queue` Secret, and hand it
to the redis scaler as its `password` parameter."*

`TriggerAuthentication` is **namespaced**; `ClusterTriggerAuthentication` is the cluster-scoped equivalent.

**Confirmed behavior worth knowing:** editing a `TriggerAuthentication`'s referenced key does not
retroactively invalidate an already-open, already-authenticated scaler connection — Redis doesn't re-check
credentials on an existing session. The failure only surfaces once a fresh connection is attempted (an
operator restart, a pod reschedule, or a naturally dropped connection) — see Break-Fix 2.

### The KEDA `redis` scaler — activation vs. scaling

```yaml
triggers:
  - type: redis
    metadata:
      address: redis-queue-master.keda-demo.svc.cluster.local:6379
      listName: work-queue
      listLength: "5"
      activationListLength: "1"
    authenticationRef:
      name: redis-trigger-auth
```

- `listName` — which Redis List to watch
- `listLength` — the **scaling target** (not a hard cap): `desiredReplicas = ceil(currentListLength /
  listLength)` — "how many list items one replica is expected to handle"
- `activationListLength` — the **activation floor**, a separate concern from the scaling target

**These can genuinely disagree, and activation always wins.** With `listLength: "5"` and
`activationListLength: "50"`, a queue at 40 items: scaling math alone says `ceil(40/5) = 8`, but 40 is below
the activation floor of 50 — so the trigger is **not active**, and KEDA scales to zero regardless. The
comparison is strictly `metric > activationValue` — a queue sitting at exactly the activation value stays
inactive; confirmed directly in Step 7 below with a single-item test before the full push.

### `cooldownPeriod` in this demo

Behaves exactly as established in `04-keda-fundamentals` — see that demo's Concepts for the full mechanism
and confirmed event-timing evidence (`ACTIVE` and the scale-down are one combined transition, not two
separately-gapped events). This demo uses `60s` rather than `04`'s `30s`, reflecting typically slower,
less bursty queue-drain patterns versus a fixed cron window.

### Image choice for the consumer — glibc vs. musl (Alpine)

The consumer Deployment uses `redis:7` (Debian-based, glibc) rather than `redis:7-alpine`. Alpine Linux
uses musl libc, whose DNS resolver only supports UDP (no TCP fallback for larger responses) and interacts
poorly with Kubernetes' default `ndots:5` CoreDNS search-domain configuration — a well-documented class of
bug across many Alpine-based images in Kubernetes, not specific to this setup. Symptom:
`redis-cli`/`getaddrinfo` fails with "Name has no usable address" against a Service DNS name that resolves
fine via `nslookup`. Discriminating test, if you hit this: `nslookup <name>` succeeds while `getent hosts
<name>` fails — that split confirms the musl resolver specifically, not a genuine CoreDNS problem. Fix:
use a glibc-based image for anything doing repeated DNS lookups in a loop.

### Message flow — four separate scenarios, because "how KEDA works" isn't one single path

KEDA's message flow genuinely differs depending on what's happening — collapsing it into one diagram hides
that there are two entirely independent tracks (Loop 1 activation, Loop 2 scaling — see "The Two Polling
Loops" in `04-keda-fundamentals`), plus a failure mode that can silently sidestep both for a while.

**Scenario A — normal 1↔N scaling (Deployment already has ≥1 replica, ordinary HPA loop):**

1. HPA controller's own reconcile loop (its sync period, default 15s — not KEDA's `pollingInterval: 15` in
   this demo's spec; the matching number here is coincidental, not a dependency) requests a metric via the
   External Metrics API for `s0-redis-work-queue`
2. `keda-operator-metrics-apiserver` receives the request and queries Redis fresh — by default, a live
   `LLEN work-queue` against `redis-queue-master.keda-demo.svc.cluster.local:6379`, not a cached value from
   Loop 1 (confirmed: no `useCachedMetrics` set on this trigger)
3. The current list length is returned to HPA in External Metrics API format
4. HPA computes `ceil(currentListLength / listLength)` — `listLength: "5"`, baked into the HPA's own target
   once, at ScaledObject reconcile time, not re-read from the trigger metadata on every poll
5. HPA patches `redis-list-consumer`'s scale subresource; the ReplicaSet controller reconciles actual pod
   count to match, capped at `maxReplicaCount: 5` regardless of what the raw division suggests

**Scenario B — scale-from-zero (0 → 1, Loop 1 only, HPA not yet involved):**

1. `keda-operator`'s own Loop 1 poll (`pollingInterval: 15s`) directly queries Redis — `LLEN work-queue` —
   independently of whatever Scenario A's HPA loop is doing
2. The redis scaler's `IsActive()` compares the result against `activationListLength: "1"` — strictly
   greater-than, confirmed hands-on in Step 7's single-item test
3. Once active, `keda-operator` patches `redis-list-consumer`'s replica count directly, `0 → 1` — bypassing
   the HPA entirely for this specific transition; the underlying HPA's own `minReplicas: 1` floor (visible
   in `describe hpa`) is never consulted here
4. Only once at least one pod exists does the HPA (Scenario A's track) take over for any further `1 → N`
   scaling

**Scenario C — scale-to-zero (N → 0, cooldownPeriod-gated, one combined action):**

1. `keda-operator`'s Loop 1 poll finds the queue empty (`LLEN work-queue` = 0, at or below
   `activationListLength`)
2. `ACTIVE` does **not** flip `False` yet — the `cooldownPeriod: 60` countdown starts, timed from this
   last-active poll, not from whenever someone happens to check
3. Every following Loop 1 poll during the countdown re-checks the trigger; any renewed activity resets the
   countdown entirely — confirmed hands-on with the cooldown-reset test added to Step 7
4. Once 60 seconds of continued inactivity elapse, `keda-operator` performs one combined action: patches
   replicas `N → 0` **and** flips `ACTIVE` to `False` simultaneously — confirmed via real event timestamps
   in this demo (`KEDAScaleTargetDeactivated` and the pod `Killing` events landing in the same few-second
   window), not two separately-gapped events

**Scenario D — TriggerAuthentication credential failure (only surfaces on a fresh connection):**

1. `TriggerAuthentication.spec.secretTargetRef` is patched to reference a wrong Secret key
2. If `keda-operator`'s redis scaler already holds an open, previously-authenticated connection, nothing
   changes — Redis doesn't re-validate credentials on an existing session, and both Loop 1 and Loop 2
   continue succeeding through that same connection, confirmed in Break-Fix 2's first (misleading) attempt
3. Only when a fresh connection is required — an operator restart, a pod reschedule, or a naturally dropped
   connection — does `keda-operator` attempt to re-authenticate using the now-wrong credential
4. Redis rejects the new connection attempt (`NOAUTH Authentication required.`); `keda-operator` surfaces
   this as `KEDAScalerFailed`, visible in both its own logs and the ScaledObject's `describe` events
5. HPA (Loop 2) independently fails the same way on its own next `keda-operator-metrics-apiserver`-mediated
   query, reported separately as `ScaledObjectCheckFailed`

### What's the production-recommended tool to load-test a Redis-based solution?

Two official tools, for different purposes — neither is what this lab uses (`redis-cli` is a functional
client, not a load-testing tool):

- **`redis-benchmark`** — bundled with every Redis installation, the quickest way to get a rough throughput
  number (`redis-benchmark -h <host> -a <password> -t set,get -n 100000`). Good for a fast sanity check,
  not detailed enough for serious capacity planning.
- **`memtier_benchmark`** — Redis Ltd.'s own production-grade benchmarking tool (used internally by Redis
  for its own release regression testing), and the tool major cloud providers' official documentation
  (Azure, among others) recommends for real capacity/performance testing. Supports configurable
  read/write ratios, multiple worker threads, latency percentile reporting, and replaying captured
  real traffic via `--monitor-input`. This is the one to reach for before sizing a production Redis
  deployment, not `redis-benchmark`.

For this lab specifically — testing KEDA's *scaling reaction* to queue depth rather than Redis's raw
throughput — the manual `RPUSH` commands in Steps 7–8 are the right tool; `memtier_benchmark` answers a
different question (how much load can this Redis instance sustain), not the one this demo is teaching.

### Reference

- [KEDA Redis Scaler docs](https://keda.sh/docs/latest/scalers/redis-lists/)
- [KEDA TriggerAuthentication docs](https://keda.sh/docs/latest/concepts/authentication/)
- [Bitnami Redis Helm chart docs](https://github.com/bitnami/charts/tree/main/bitnami/redis)
- [Redis List commands reference](https://redis.io/docs/latest/commands/?group=list)
- [Redis licensing FAQ](https://redis.io/legal/licenses/)
- [memtier_benchmark](https://github.com/redis/memtier_benchmark)

## Lab Step-by-Step Guide

---

### Step 1 — Install Redis via Helm (AUTH-enabled)

This step stands up the actual system KEDA will scale against — a running, secured Redis instance with a
stable DNS name.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/redis --versions | head
```
```
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
bitnami/redis           27.0.15         8.8.0           Redis(R) is an open source, advanced key-value ...
bitnami/redis           27.0.14         8.8.0           Redis(R) is an open source, advanced key-value ...
```

**`src/01-redis-values.yaml`:**
```yaml
architecture: standalone
auth:
  enabled: true
master:
  persistence:
    enabled: false   # ephemeral for lab purposes
```

```bash
helm install redis-queue bitnami/redis \
  --namespace keda-demo --create-namespace \
  --version 27.0.14 \
  -f src/01-redis-values.yaml
```
```
NAME: redis-queue
STATUS: deployed
CHART VERSION: 27.0.14
APP VERSION: 8.8.0
Redis(R) can be accessed via port 6379 on the following DNS name from within your cluster:
    redis-queue-master.keda-demo.svc.cluster.local
```

**Verify — confirm what was actually installed:**
```bash
kubectl get all -n keda-demo
```
```
NAME                       READY   STATUS    RESTARTS   AGE
pod/redis-queue-master-0   1/1     Running   0          72s

NAME                           TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/redis-queue-headless   ClusterIP   None           <none>        6379/TCP   72s
service/redis-queue-master     ClusterIP   10.98.73.244   <none>        6379/TCP   72s

NAME                                  READY   AGE
statefulset.apps/redis-queue-master   1/1     72s
```
```bash
kubectl get secret -n keda-demo redis-queue
kubectl describe secret -n keda-demo redis-queue
```
```
NAME           TYPE     DATA   AGE
redis-queue    Opaque   1      5m6s

Data
====
redis-password:  24 bytes

# Observation: one StatefulSet pod (not a Deployment), two Services (the headless one is used internally
# by the chart, not by this demo directly), and one auto-generated Secret holding the AUTH password —
# matches the architecture table in Concepts exactly.
```

### Step 2 — Retrieve the Redis AUTH password and confirm connectivity

This step proves the credential chain works before wiring anything else to it.

```bash
export PASSWORD=$(kubectl get secret redis-queue -n keda-demo -o jsonpath='{.data.redis-password}' | base64 -d)
echo "[$PASSWORD]"   # must NOT print "[]"
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" PING
```
```
[FFxZw0GVC8NcLVGNP6ZKYval]
Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
PONG

# Observation: PONG confirms both connectivity AND correct AUTH in one command — if either were wrong,
# this would fail with a connection error or NOAUTH/WRONGPASS instead.
```

> **Environment gotcha, confirmed repeatedly across this series:** `export PASSWORD=...` only persists for
> the current shell session. A new terminal/tmux pane silently loses it, producing `NOAUTH`/`WRONGPASS` on
> every subsequent command. Always re-verify with `echo "[$PASSWORD]"` before continuing.

### Step 3 — Create the TriggerAuthentication object

This step creates the credential bridge between KEDA and Redis — without it, the ScaledObject in Step 5
would have no way to authenticate to Redis at all.

**`src/02-trigger-auth-redis.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: redis-trigger-auth
  namespace: keda-demo
spec:
  secretTargetRef:
    - parameter: password
      name: redis-queue
      key: redis-password
```
```bash
kubectl apply -f src/02-trigger-auth-redis.yaml
```
```
triggerauthentication.keda.sh/redis-trigger-auth created
```
⚡ *No imperative equivalent — `TriggerAuthentication` is a CRD with no `kubectl create` shortcut.*

**Verify:**
```bash
kubectl get triggerauthentication redis-trigger-auth -n keda-demo
kubectl describe triggerauthentication redis-trigger-auth -n keda-demo

# Observation: describe output should show secretTargetRef with key: redis-password — confirm this now,
# since Break-Fix 2 later deliberately corrupts this exact field.
```

### Step 4 — Deploy the queue-consumer application

This step deploys the workload KEDA will actually scale — starting at zero replicas, since nothing is
driving it yet.

**`src/03-consumer-deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-list-consumer
  namespace: keda-demo
spec:
  replicas: 0
  selector:
    matchLabels:
      app: redis-list-consumer
  template:
    metadata:
      labels:
        app: redis-list-consumer
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: consumer
          image: redis:7   # glibc-based — see the musl/Alpine DNS note in Concepts
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                redis-cli -h "$REDIS_HOST" -a "$REDIS_PASSWORD" BRPOP work-queue 5
                sleep 1
              done
          env:
            - name: REDIS_HOST
              value: redis-queue-master.keda-demo.svc.cluster.local
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-queue
                  key: redis-password
```
```bash
kubectl apply -f src/03-consumer-deployment.yaml
```
```
deployment.apps/redis-list-consumer created
```
⚡ *Imperative equivalent: `kubectl create deployment redis-list-consumer --image=redis:7 --replicas=0
--dry-run=client -o yaml` generates only the container/image skeleton — the `command`/`args` BRPOP loop and
the `env`/`secretKeyRef` wiring must always be hand-added.*

**Verify:**
```bash
kubectl get deployment redis-list-consumer -n keda-demo
kubectl get pods -n keda-demo -l app=redis-list-consumer
```
```
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
redis-list-consumer   0/0     0            0           17s

# Observation: 0/0, as expected — replicas: 0 in the manifest, and nothing is driving it yet (that's
# Step 5's job). No pods listed either, for the same reason.
```

### Step 5 — Create the ScaledObject

This step is the actual autoscaling rule — it ties Steps 1–4 together by telling KEDA to watch
`work-queue`'s length and scale `redis-list-consumer` in response.

**`src/04-scaledobject-redis.yaml`:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: redis-consumer-scaledobject
  namespace: keda-demo
spec:
  scaleTargetRef:
    name: redis-list-consumer
  pollingInterval: 15
  cooldownPeriod: 60
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: redis
      metadata:
        address: redis-queue-master.keda-demo.svc.cluster.local:6379
        listName: work-queue
        listLength: "5"
        activationListLength: "1"
      authenticationRef:
        name: redis-trigger-auth
```
```bash
kubectl apply -f src/04-scaledobject-redis.yaml
```
```
scaledobject.keda.sh/redis-consumer-scaledobject created
```
⚡ *No imperative equivalent — `ScaledObject` is a CRD.*

**Verify:**
```bash
kubectl get scaledobject redis-consumer-scaledobject -n keda-demo
kubectl get hpa -n keda-demo
```
```
NAME                          SCALETARGETKIND      SCALETARGETNAME       MIN   MAX   READY   ACTIVE    FALLBACK   PAUSED   TRIGGERS   AUTHENTICATIONS      AGE
redis-consumer-scaledobject   apps/v1.Deployment   redis-list-consumer   0     5     True    Unknown   False      False    redis      redis-trigger-auth   18s

NAME                                   REFERENCE                        TARGETS             MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-redis-consumer-scaledobject   Deployment/redis-list-consumer   <unknown>/5 (avg)   1         5         0          28s
```
**Reading this output:**
- `READY` — whether the ScaledObject itself is validly configured (not whether it's currently scaling)
- `ACTIVE: Unknown` — expected immediately after creation, before the first poll completes; settles to
  `True`/`False` within one `pollingInterval`
- `TARGETS: <unknown>/5 (avg)` — same reason; `<unknown>` until the first real metric read succeeds
- `MINPODS: 1` — this differs from the ScaledObject's own `MIN: 0` deliberately; see Concepts/`04` for why
  (KEDA manages `0↔1` outside the HPA's own bounds)

```bash
kubectl describe scaledobject redis-consumer-scaledobject -n keda-demo
```
```
Spec:
  Cooldown Period:    60
  Max Replica Count:  5
  Min Replica Count:  0
  Polling Interval:   15
  Triggers:
    Metadata:
      Activation List Length:  1
      Address:                 redis-queue-master.keda-demo.svc.cluster.local:6379
      List Length:             5
      List Name:               work-queue
    Type:                      redis
Status:
  Conditions:
    Message:  ScaledObject is defined correctly and is ready for scaling
    Reason:   ScaledObjectReady
    Status:   True
    Type:     Ready
    Message:  Scaling is not performed because triggers are not active
    Reason:   ScalerNotActive
    Status:   False
    Type:     Active
Events:
  Normal  KEDAScalersStarted  keda-operator  Scaler redis is built
  Normal  ScaledObjectReady   keda-operator  ScaledObject is ready for scaling
```

### Step 6 — Verify scale-to-zero at idle

```bash
kubectl get deployment redis-list-consumer -n keda-demo
```
```
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
redis-list-consumer   0/0     0            0           17s

# Observation: confirms the idle baseline — 0/0, ACTIVE False, before any load is introduced in Step 7.
```

### Step 7 — Push items and observe scale-from-zero

**Recommended: open three terminals (or tmux panes) so you can watch every layer react to the same event
in real time, side by side:**
```bash
# Terminal 1
kubectl get hpa -n keda-demo -w

# Terminal 2
watch -n2 'kubectl get scaledobject redis-consumer-scaledobject -n keda-demo'

# Terminal 3 — run everything below here
```

**Confirm the clean baseline first (Terminal 3, before pushing anything):**
```bash
kubectl describe hpa -n keda-demo
kubectl describe scaledobject redis-consumer-scaledobject -n keda-demo
```
```
Min replicas:                                    1
Max replicas:                                    5
Deployment pods:                                 0 current / 0 desired
Conditions:
  ScalingActive   False   ScalingDisabled    scaling is disabled since the replica count of the target is zero

# Observation: ACTIVE: False, 0 current / 0 desired, ScalingDisabled — the clean starting point. Compare
# this against the output after the push below.
```

**Activation-boundary micro-test — push exactly one item first:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH work-queue item1
sleep 20
kubectl get scaledobject redis-consumer-scaledobject -n keda-demo

# Observation: with activationListLength: 1, a single item should NOT activate the scaler — the comparison
# is strictly greater-than. ACTIVE should still read False here. This directly confirms the activation vs.
# scaling distinction from Concepts, hands-on, before the full push below.
```

**Now push enough items to cross the activation floor and drive real scaling:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH work-queue item2 item3 item4 item5 item6
```
```
(integer) 6
```
```bash
kubectl describe hpa -n keda-demo
kubectl describe scaledobject redis-consumer-scaledobject -n keda-demo
```
```
Metrics:                                         ( current / target )
  "s0-redis-work-queue" (target average value):  6 / 5
Deployment pods:                                 1 current / 2 desired
Conditions:
  AbleToScale     True    SucceededRescale    the HPA controller was able to update the target scale to 2
  ScalingActive   True    ValidMetricFound    ...
Events:
  Normal  SuccessfulRescale  New size: 2; reason: external metric s0-redis-work-queue(...) above target
```
```
Status:
  Message:  Scaling is performed because triggers are active
  Reason:   ScalerActive
Events:
  Normal  KEDAScaleTargetActivated  Scaled apps/v1.Deployment keda-demo/redis-list-consumer from 0 to 1

# Observation: 6 items, listLength target 5 → ceil(6/5) = 2 desired replicas, matching the HPA's own math
# exactly. ACTIVE now True. Terminal 1/2 should show this same transition live, in parallel.
```

**`maxReplicaCount` ceiling test — push enough items that the scaling math would exceed the cap:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH work-queue \
  item7 item8 item9 item10 item11 item12 item13 item14 item15 item16 item17 item18 item19 item20
sleep 20
kubectl describe hpa -n keda-demo
kubectl get deployment redis-list-consumer -n keda-demo

# Observation: with the earlier 6 items still in flight, the list is now around 20+ deep. ceil(20/5) = 4,
# and combined with whatever remained from the first push this can compute even higher — but replicas
# should never exceed maxReplicaCount: 5, regardless of how large the ceil() math says the ideal count
# would be. Confirm the Deployment caps at 5, not whatever the raw division suggests — maxReplicaCount is
# a hard ceiling on the HPA's own output, not a target the queue math is aware of.
```

**Cooldown-reset test — drain most of the queue, then push again before `cooldownPeriod` (60s) fully elapses:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" LLEN work-queue
# once this reads low enough that ACTIVE would soon go False, but before ~60s of continued inactivity
# passes, push again:
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH work-queue newitem1 newitem2
kubectl get scaledobject redis-consumer-scaledobject -n keda-demo -w

# Observation: this should show ACTIVE staying True continuously, with no intervening False — the
# cooldownPeriod countdown resets on any renewed activity, exactly as described in the worked example in
# 04-keda-fundamentals' Concepts. The Deployment should never actually reach 0 replicas during this test,
# unlike Step 8 below where the queue is allowed to stay genuinely empty.
```

### Step 8 — Drain the queue and observe automatic scale-to-zero

No manual intervention needed in normal operation — the consumer's `BRPOP` loop drains the list on its own,
and once the trigger goes inactive, KEDA scales down automatically after `cooldownPeriod`.

```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" LLEN work-queue
```
Watch this drop toward `0` as the consumer processes items (confirm the consumer is actually logging BRPOP
activity, not just sitting idle — a good sanity check regardless of whether draining looks slow):
```bash
kubectl logs -n keda-demo -l app=redis-list-consumer --tail=20 --prefix

# Observation: real BRPOP results in these logs — if you instead see repeated connection/DNS errors here,
# that's the musl/Alpine issue from Concepts, not a queue-logic problem; confirm the consumer image is
# redis:7, not redis:7-alpine.
```

Once the queue is empty, watch the automatic deactivation:
```bash
kubectl get scaledobject redis-consumer-scaledobject -n keda-demo -w
```
```
Normal  KEDAScaleTargetActivated    Scaled ... from 0 to 1, triggered by s0-redis-work-queue
Normal  KEDAScaleTargetDeactivated  Deactivated ... from 1 to 0          # ~60s after activation

# Observation: the gap between activation and deactivation events is consistently ~60-64s here, matching
# cooldownPeriod: 60 — the mechanism from Concepts/04, now confirmed against this demo's own numbers.
```

### Step 9 — Cleanup

**(a) Demo-scoped resources:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" DEL work-queue
kubectl delete scaledobject redis-consumer-scaledobject -n keda-demo --ignore-not-found
kubectl delete triggerauthentication redis-trigger-auth -n keda-demo --ignore-not-found
kubectl delete deployment redis-list-consumer -n keda-demo --ignore-not-found
helm uninstall redis-queue -n keda-demo
kubectl delete namespace keda-demo --ignore-not-found
kubectl get all -n keda-demo   # confirm removal
```

**(b) Cluster-scoped shared component — KEDA:**
No demo currently planned after this one in `11-auto-scaling` depends on KEDA (`06`/`07` use the Prometheus
Adapter, not KEDA). Uninstall as this demo's final cleanup action:
```bash
helm uninstall keda -n keda
kubectl delete namespace keda --ignore-not-found
```

---

## What You Learned

1. ✅ Deployed a secured, AUTH-enabled Redis instance via the Bitnami Helm chart, and understood why the
   chart uses a StatefulSet rather than a Deployment
2. ✅ Wired Redis credentials to KEDA correctly via `TriggerAuthentication` + Secret, including what the
   `parameter` field means and confirming it doesn't force reconnection on its own
3. ✅ Configured and verified the `redis` scaler trigger, confirming the activation-boundary behavior
   hands-on with a single-item test before the full push
4. ✅ Watched KEDA scale a Deployment from zero, through multiple replicas, and back to zero automatically,
   with real cooldown timing evidence
5. ✅ Diagnosed and fixed three real misconfigurations: an invalid image reference, a `TriggerAuthentication`
   pointed at a wrong Secret key, and a musl/Alpine DNS resolution failure
6. ✅ Learned to verify installed/configured state after every step rather than assuming success from
   `kubectl apply` output alone
7. ✅ Mapped Redis-scaler concepts and commands to CKA/CKAD exam objectives

## Break-Fix

### Break-Fix 1 — Invalid container image reference

**`src/break-fix/01-broken-image.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-list-consumer
  namespace: keda-demo
spec:
  replicas: 0
  selector:
    matchLabels:
      app: redis-list-consumer
  template:
    metadata:
      labels:
        app: redis-list-consumer
    spec:
      containers:
        - name: consumer
          image: "<TBD — see Assumption A3>"   # unresolved placeholder — the actual bug
          env:
            - name: REDIS_HOST
              value: redis-queue-master.keda-demo.svc.cluster.local
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-queue
                  key: redis-password
```

**Symptom:**
```bash
kubectl get pods -n keda-demo
```
```
NAME                                   READY   STATUS             RESTARTS   AGE
redis-list-consumer-789b84bc45-8hqjx   0/1     InvalidImageName   0          17s
```
```bash
kubectl describe pod -n keda-demo redis-list-consumer-789b84bc45-8hqjx
```
```
Warning  InspectFailed  kubelet  Failed to apply default image tag "<TBD — see Assumption A3>":
                                  couldn't parse image name: invalid reference format
Warning  Failed         kubelet  Error: InvalidImageName
```

**Cause:** the `image:` field contained a literal, never-replaced placeholder string. `InvalidImageName`
(distinct from `ImagePullBackOff`) fails at parse time, before any pull is attempted.

**Fix:**
```bash
kubectl apply -f src/03-consumer-deployment.yaml   # corrected: image: redis:7
kubectl get pods -n keda-demo -w
```

**Cleanup:** none required beyond the fix — the corrected Deployment replaces the broken one in place.

### Break-Fix 2 — TriggerAuthentication pointed at a wrong Secret key

**`src/break-fix/02-broken-triggerauth.yaml`:**
```yaml
# Applied via: kubectl patch triggerauthentication redis-trigger-auth -n keda-demo --type merge -p "$(cat src/break-fix/02-broken-triggerauth.yaml)"
spec:
  secretTargetRef:
    - parameter: password
      name: redis-queue
      key: wrong-key    # correct key is redis-password
```

**Setup:**
```bash
kubectl patch triggerauthentication redis-trigger-auth -n keda-demo --type merge \
  -p '{"spec":{"secretTargetRef":[{"parameter":"password","name":"redis-queue","key":"wrong-key"}]}}'
```
Pushing items and checking status immediately afterward shows no error — an already-open, authenticated
connection isn't re-validated. The break only surfaces once a fresh connection is forced:
```bash
kubectl rollout restart deployment keda-operator -n keda
kubectl rollout status deployment keda-operator -n keda --timeout=60s
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH work-queue x
sleep 20
kubectl logs -n keda deploy/keda-operator --since=1m | grep -i -B2 -A5 "error"
```
```
ERROR scale_handler error resolving auth params
  {"error": "connection to redis failed: NOAUTH Authentication required."}
```
```bash
kubectl describe scaledobject redis-consumer-scaledobject -n keda-demo | tail -10
```
```
Warning  KEDAScalerFailed         connection to redis failed: NOAUTH Authentication required.
Warning  ScaledObjectCheckFailed  failed to ensure HPA is correctly created for ScaledObject: ...
```

**Cause:** the referenced Secret key no longer matches the actual key in the `redis-queue` Secret.

**Fix:**
```bash
kubectl patch triggerauthentication redis-trigger-auth -n keda-demo --type merge \
  -p '{"spec":{"secretTargetRef":[{"parameter":"password","name":"redis-queue","key":"redis-password"}]}}'
```
Recovery isn't instant — the ScaledObject's events show `KEDAScalersStarted (x2 over 4m51s)` before
settling into `ScaledObjectReady`.

**Cleanup:** none beyond the restore — confirm with `kubectl get triggerauthentication ... -o yaml | grep
-A3 secretTargetRef` that `key: redis-password` is back in place before continuing.

### Break-Fix 3 — Wrong `listName` (producer/consumer mismatch)

**Setup:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" RPUSH wrong-queue-name x y z
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" LLEN wrong-queue-name
```
```
(integer) 3
```
```bash
kubectl get scaledobject redis-consumer-scaledobject -n keda-demo
kubectl get deployment redis-list-consumer -n keda-demo
```
```
ACTIVE   False
redis-list-consumer   0/0
```

**Cause:** the ScaledObject's `listName: work-queue` trigger is scoped precisely — Redis Lists at any
other key are invisible to it, no matter how much data accumulates there. A producer/consumer name
mismatch produces zero errors anywhere; the ScaledObject just never activates.

**Fix:** correct whichever side (producer or `listName`) is actually wrong in a real deployment.

**Cleanup:**
```bash
kubectl exec -n keda-demo redis-queue-master-0 -- redis-cli -a "$PASSWORD" DEL wrong-queue-name work-queue
```

## Interview Prep

**1. Your team's ScaledObject looks healthy — `Ready: True`, no error events — but a Redis-backed consumer
never scales up despite a growing queue. What are the first two things to check?**
<details><summary>Answer</summary>
Whether the producer and the ScaledObject's `listName` actually match (a mismatch produces zero errors,
just silent inactivity), and whether the queue length has crossed `activationListLength`, not just
`listLength` — a queue at exactly the activation threshold stays inactive by design.
</details>

**2. A teammate rotates the Redis password and updates the Secret, but sees no immediate failure in KEDA. A
day later, scaling stops working entirely. Explain what happened.**
<details><summary>Answer</summary>
KEDA's Redis scaler reuses an already-authenticated connection rather than re-checking credentials on every
poll. The failure surfaced later, when the operator was rescheduled/restarted or the connection dropped,
forcing a fresh authentication attempt with the (if inconsistently updated) stale credential reference.
</details>

**3. Why does the Bitnami Redis chart deploy a StatefulSet instead of a Deployment, even at one replica?**
<details><summary>Answer</summary>
Stateful services need stable, predictable pod identity (ordinal naming) and, at multiple replicas, storage
that follows a specific ordinal across rescheduling. The chart is architected this way so it's correct the
moment you scale beyond standalone mode, even though the benefit is subtle at one replica.
</details>

**4. What does the `parameter` field in `TriggerAuthentication.spec.secretTargetRef` actually refer to?**
<details><summary>Answer</summary>
Not a Kubernetes field — the name the specific scaler expects internally for that credential (`password`
for the redis scaler). It maps a Secret's value to an argument name in the scaler's own configuration,
and the exact name varies by scaler type.
</details>

**5. A container in your cluster intermittently fails to resolve a valid Service DNS name, but `nslookup`
against the same name succeeds from the same pod. What's the likely cause, and how do you confirm it?**
<details><summary>Answer</summary>
Likely a musl libc (Alpine Linux) DNS resolver limitation — musl only supports DNS over UDP and interacts
poorly with Kubernetes' default `ndots:5` configuration. Confirm by comparing `nslookup` (uses a different
resolution path, often succeeds) against `getent hosts` (uses the musl NSS resolver directly, often fails)
inside the same pod. Fix: switch to a glibc-based image for anything doing repeated lookups.
</details>

## CKA/CKAD Certification Tips

### Exam Objective Mapping

> **Scope note:** KEDA itself is not a CKA/CKAD exam objective — it's a CNCF Sandbox add-on, not core
> Kubernetes. What this demo reinforces that **is** in scope: Secrets and how they're referenced by other
> objects, StatefulSets as a workload type, CRDs as a general mechanism, and the HPA/External Metrics API
> relationship this series has covered since `01-hpa-basic`.

| Exam Objective | Where covered |
|---|---|
| CKA/CKAD: Understand Secrets | Steps 2–3 — auto-generated auth Secret, `secretKeyRef` |
| CKA/CKAD: Understand Deployments | Step 4 — consumer Deployment |
| CKA: Workloads — StatefulSets | Step 1 — Redis master, and why it's a StatefulSet not a Deployment |
| CKAD: Application Observability and Maintenance | Steps 5–8 — `describe`/`get -w` on ScaledObject and HPA |

### Common Exam Traps

| Trap | Why it happens | How to avoid it |
|---|---|---|
| Reaching for `kubectl create scaledobject`/`triggerauthentication` | Both are CRDs with no imperative shortcut | Write the YAML directly from memory |
| Assuming `Min replicas: 1` in `describe hpa` means scale-to-zero isn't configured | KEDA manages `0↔1` outside the HPA's own bounds | Check the ScaledObject's `minReplicaCount`, not the derived HPA field |
| Confusing `activationListLength` with `listLength` | Both are queue-length numbers in the same trigger block | `activationListLength` gates *whether* to scale from zero at all; `listLength` is the target for *how many* replicas |
| Assuming `kubectl create statefulset` exists | Different mental model from Deployment | No imperative shortcut at all — always requires YAML |

### Exam Task — Write it from scratch

**Task:** From scratch, write a `TriggerAuthentication` named `queue-auth` referencing Secret `queue-creds`
key `password`, and a `ScaledObject` named `worker-scaledobject` targeting Deployment `worker` using the
`redis` scaler: `listName: jobs`, `listLength: 10`, `activationListLength: 1`, `minReplicaCount: 0`,
`maxReplicaCount: 8`, address `redis.default.svc.cluster.local:6379`.

<details>
<summary>Reference solution</summary>

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: queue-auth
spec:
  secretTargetRef:
    - parameter: password
      name: queue-creds
      key: password
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-scaledobject
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 0
  maxReplicaCount: 8
  triggers:
    - type: redis
      metadata:
        address: redis.default.svc.cluster.local:6379
        listName: jobs
        listLength: "10"
        activationListLength: "1"
      authenticationRef:
        name: queue-auth
```
</details>

Key fields to recall: `secretTargetRef` is a list; trigger metadata numeric values are strings (`"10"`, not
`10`); no imperative shortcut for either object.

## Key Takeaways

| Concept | Detail |
|---|---|
| Redis List as a queue | `RPUSH` (enqueue tail) + `BRPOP` (blocking dequeue head) gives FIFO ordering; `LLEN` is what KEDA polls |
| Redis AUTH | Single shared-secret; `NOAUTH`/`WRONGPASS` on any command issued before/with wrong `AUTH` |
| Bitnami Redis chart architecture | StatefulSet + ClusterIP Service + auto-generated Secret |
| Why StatefulSet, not Deployment | Stable pod identity/ordinal naming, needed for stateful services even at 1 replica |
| `TriggerAuthentication.parameter` | Not a K8s field — the scaler's own internal argument name for that credential |
| Confirmed: credential change ≠ immediate break | Already-open scaler connections aren't re-validated; failure surfaces only on next reconnect |
| `activationListLength` vs `listLength` | Activation threshold (whether to scale from zero) vs. scaling target (how many replicas) |
| Activation comparison is strict | `metric > activationValue`; a value at exactly the threshold stays inactive |
| KEDA-managed HPA shows `Min replicas: 1` | KEDA handles `0↔1` outside the HPA's own bounds — check ScaledObject's `minReplicaCount` instead |
| `cooldownPeriod` behavior | Same combined-transition model as `04` — `ACTIVE` and scale-down happen together, ~60s after last active |
| Wrong `listName` is a silent failure | No error anywhere; the ScaledObject just never activates |
| musl/Alpine DNS limitation | Alpine images can fail to resolve valid Service DNS names; use glibc-based images for repeated lookups |
| No imperative equivalent for CRDs | `ScaledObject`/`TriggerAuthentication` always require hand-written YAML |
| `kubectl exec` vs `kubectl run --rm -it` | Exec into an existing pod for iterative testing — faster, no image pull, no attach race |
| `InvalidImageName` vs `ImagePullBackOff` | `InvalidImageName` fails at parse time, before any pull attempt |

## Quick Commands Reference

| Command | Description |
|---|---|
| `helm search repo bitnami/redis --versions` | Lists available chart versions to pin before install |
| `helm install <release> bitnami/redis --version <ver> -f <values.yaml>` | Installs Redis with a version-pinned chart |
| `kubectl exec -n <ns> <redis-pod> -- redis-cli -a "$PASSWORD" <cmd>` | Fast, reliable way to run Redis commands |
| `kubectl get secret <name> -n <ns> -o jsonpath='{.data.<key>}' \| base64 -d` | Reads a generated Secret value in plaintext |
| `kubectl describe scaledobject <name> -n <ns>` | Full spec, status conditions, recent events — check here first for scaler failures |
| `kubectl rollout restart deployment keda-operator -n keda` | Forces KEDA to drop cached connections |
| `kubectl logs -n keda deploy/keda-operator --since=1m` | Operator-level errors — check when ScaledObject status looks healthy but scaling isn't happening |
| `redis-cli -a <password> RPUSH/LLEN/DEL <list>` | Enqueue / read depth / drain a Redis List |

### Generating YAML skeletons with --dry-run

```bash
kubectl create deployment redis-list-consumer --image=redis:7 --replicas=0 --dry-run=client -o yaml
kubectl create secret generic redis-queue --from-literal=redis-password=<pw> --dry-run=client -o yaml
```

**Not supported — no imperative shortcut exists (CRDs):** `ScaledObject`, `TriggerAuthentication`.
**Not supported — StatefulSets:** no `kubectl create statefulset` command at all.
**Not supported — commands that read, describe, or operate on running objects:** `get`, `describe`, `logs`,
`exec`, `delete`, `apply`, `patch`, `label`.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Deployment | `kubectl create deployment NAME --image=IMG --replicas=0` | `command`/`args`/`env` still require manual editing |
| Secret | `kubectl create secret generic NAME --from-literal=redis-password=VALUE` | Only if not using the chart-generated Secret |
| StatefulSet | *(no imperative equivalent)* | Always requires YAML |
| ScaledObject | *(no imperative equivalent — CRD)* | Must write YAML directly |
| TriggerAuthentication | *(no imperative equivalent — CRD)* | Must write YAML directly |

## Troubleshooting

**Symptom: `redis-cli` commands fail with `NOAUTH`/`WRONGPASS` despite exporting `$PASSWORD` earlier.**
Cause: the export only persists for the current shell; a new terminal/pane loses it silently. Fix:
re-export and verify with `echo "[$PASSWORD]"` before continuing.

**Symptom: a container repeatedly fails to resolve a valid Kubernetes Service DNS name with "Name has no
usable address" or similar, while `nslookup` against the same name succeeds.**
Cause: musl libc (Alpine Linux) DNS resolver limitation — see the dedicated Concepts note. Confirm via
`nslookup` (works) vs `getent hosts` (fails) inside the affected container. Fix: use a glibc-based image
(e.g. `redis:7` instead of `redis:7-alpine`) for anything doing repeated DNS lookups in a loop.

**Symptom: `kubectl apply -f <old-backup>.yaml` fails with a `resourceVersion` conflict.**
Cause: the backup file's `resourceVersion` is stale relative to the live object. Fix: don't restore from an
old capture — re-`kubectl get -o yaml` fresh, or use `kubectl patch` for the specific field instead.

**Symptom: `kubectl logs ... --tail=50` doesn't show the error you expect.**
On a busy operator, background reconcile noise can push relevant lines out of a line-count-based tail. Use
`--since=<duration>` scoped tightly around when the event actually happened instead.

## Appendix — Anki Cards

**`05-keda-redis-scaler-anki.csv`:**

```
#deck:k8s-platform-labs::11-auto-scaling::05-keda-redis-scaler
#separator:Comma
#columns:Front,Back,Tags
"What Redis command blocks waiting for a list item, and what's its non-blocking equivalent?","BRPOP (blocking); RPOP is the non-blocking equivalent","cka ckad redis"
"Why does the Bitnami Redis chart deploy a StatefulSet instead of a Deployment?","Stateful services need stable, predictable pod identity and storage that follows a specific ordinal across rescheduling, even if the multi-replica benefit isn't exercised at one replica","cka ckad k8s-objects"
"In TriggerAuthentication.spec.secretTargetRef, what does the 'parameter' field actually refer to?","Not a Kubernetes field name -- the name the specific scaler expects internally for that credential (e.g. 'password' for the redis scaler)","cka ckad keda"
"Does editing a TriggerAuthentication's secretTargetRef immediately break an already-active scaler connection?","No -- Redis doesn't re-check credentials on an existing open connection; the failure only surfaces when a new connection is attempted","cka ckad keda redis"
"In a redis-type KEDA trigger, what's the difference between activationListLength and listLength?","activationListLength gates whether to scale from zero at all; listLength is the scaling target used to compute desired replica count once active","cka ckad keda"
"Is the activation threshold comparison >= or strictly >?","Strictly greater-than; a value exactly at the threshold stays inactive","cka ckad keda"
"Why might kubectl describe hpa show Min replicas: 1 even though the ScaledObject's minReplicaCount is 0?","KEDA manages the 0-to-1 transition itself, outside the underlying HPA's own bounds","cka ckad keda hpa"
"What happens if a producer pushes to the wrong Redis list name relative to the ScaledObject's listName?","Nothing visible -- no error anywhere; the ScaledObject simply never activates","cka ckad keda troubleshooting"
"Is there an imperative kubectl create command for ScaledObject, TriggerAuthentication, or StatefulSet?","No -- all three require YAML written directly; no imperative shortcut exists for any of them","cka ckad exam-trap"
"What Kubernetes error indicates a malformed image reference string, distinct from a failed pull?","InvalidImageName -- fails at parse time, before any pull attempt is even made","cka ckad troubleshooting"
"A container can't resolve a valid Service DNS name but nslookup succeeds against the same name. What's the likely cause?","A musl libc (Alpine Linux) DNS resolver limitation -- confirm via nslookup (works) vs getent hosts (fails)","cka ckad troubleshooting dns"
"What's the standard fix for musl/Alpine DNS resolution failures in Kubernetes?","Use a glibc-based image instead (e.g. redis:7 instead of redis:7-alpine) for anything doing repeated DNS lookups","cka ckad troubleshooting"
"What's a faster, more reliable alternative to kubectl run --rm -it for repeated Redis CLI checks?","kubectl exec into the already-running redis-queue-master-0 pod -- no image pull, no attach race","cka ckad ops"
```

## Appendix — Quiz

**`05-keda-redis-scaler-quiz.md`:**

````markdown
# Quiz — 11-auto-scaling/05-keda-redis-scaler: KEDA Redis Scaler — Secured Queue Consumer

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. What does `activationListLength: 1` mean for a redis-type KEDA trigger?**

- A) The scaler activates once the list reaches exactly 1 item
- B) The scaler stays inactive while the list length is at or below 1; activation requires strictly more than 1
- C) The scaler always keeps at least 1 replica running
- D) The scaler polls every 1 second

<details>
<summary>Answer</summary>

**B** — the activation comparison is strictly greater-than, not `>=`. A queue at exactly the activation
value stays inactive.

Trap A: reverses the comparison direction — "at 1" is exactly the boundary that stays inactive, not the
trigger point. Trap C: confuses activation threshold with `minReplicaCount`; a value in the trigger's
`metadata` doesn't set a replica floor. Trap D: confuses `activationListLength` with `pollingInterval`,
a completely separate field governing poll frequency, not the activation value itself.

</details>

---

**Q2. In `TriggerAuthentication.spec.secretTargetRef`, what does the `parameter` field refer to?**

- A) A Kubernetes API field name
- B) The name the specific scaler expects internally for that credential
- C) The namespace the Secret lives in
- D) A label selector

<details>
<summary>Answer</summary>

**B** — it maps a Secret's value to an argument name in the scaler's own configuration; the exact name
varies by scaler type (`password` for redis).

Trap A: `parameter` looks like it should be a standard Kubernetes API concept given the surrounding YAML,
but it's scaler-internal, not part of the Kubernetes object model. Trap C: namespace scoping is handled by
`metadata.namespace` on the TriggerAuthentication itself, unrelated to `parameter`. Trap D: label selectors
use `matchLabels`/`matchExpressions`, an entirely different mechanism with no relation to credential wiring.

</details>

---

**Q3. Why does editing a TriggerAuthentication's secretTargetRef key have no immediate effect on an
already-running scaler?**

- A) KEDA caches TriggerAuthentication objects for 24 hours
- B) Redis doesn't re-check credentials on an already-open, authenticated connection
- C) The patch command silently failed
- D) TriggerAuthentication changes require a full cluster restart

<details>
<summary>Answer</summary>

**B** — an existing connection isn't re-validated; the failure only surfaces on the next fresh connection
attempt.

Trap A: there's no such fixed caching window documented anywhere in KEDA — this invents a plausible-sounding
but fictional mechanism. Trap C: the patch genuinely succeeds (confirmed via `kubectl get ... -o yaml`
showing the new key) — the object updates correctly, it's the live connection that doesn't re-check it.
Trap D: wildly overstates the fix — a targeted operator restart (not a full cluster restart) is enough to
force reconnection, as shown in Break-Fix 2.

</details>

---

**Q4. `kubectl describe hpa` shows `Min replicas: 1` for a KEDA-managed HPA whose ScaledObject specifies
`minReplicaCount: 0`. What's the correct interpretation?**

- A) This is a bug — the values should always match
- B) KEDA manages the 0-to-1 transition itself, outside the HPA's own bounds
- C) The ScaledObject failed to apply correctly
- D) minReplicaCount only takes effect after the first successful scale event

<details>
<summary>Answer</summary>

**B** — check the ScaledObject's own `minReplicaCount`, not the HPA's derived field, for the true
scale-to-zero floor.

Trap A: assumes the two fields are meant to mirror each other; they deliberately don't — this is expected
behavior, not a defect. Trap C: the ScaledObject applies and reports `Ready: True` correctly in this
scenario — nothing failed. Trap D: invents a timing condition that doesn't exist; the discrepancy is present
from the very first `describe hpa`, not something that resolves after a scale event.

</details>

---

**Q5. Why does the Bitnami Redis chart deploy a StatefulSet rather than a Deployment, even in single-replica
standalone mode?**

- A) StatefulSets are required for all Helm charts
- B) Deployments can't run containers that use persistent volumes
- C) Stable, predictable pod identity is architecturally needed for stateful services, even if the
  multi-replica benefit isn't exercised at one replica
- D) StatefulSets start faster than Deployments

<details>
<summary>Answer</summary>

**C** — stateful services need stable, predictable pod identity (ordinal naming) and, at multiple replicas,
storage that follows a specific ordinal across rescheduling — the chart is architected this way so it works
correctly the moment you scale beyond standalone mode.

Trap A: false — the vast majority of Helm charts, including most workloads in this series, deploy
Deployments; there's no such blanket requirement. Trap B: Deployments can absolutely mount persistent
volumes — the distinction is about pod *identity* (stable naming/ordinal storage), not volume support at
all. Trap D: no meaningful startup-speed difference between the two controller types; this isn't a real
consideration in choosing between them.

</details>

---

**Q6. A producer pushes items to a Redis list named `jobs-queue`, but the ScaledObject's trigger specifies
`listName: work-queue`. What happens?**

- A) KEDA scales based on the total across all lists in the Redis instance
- B) An error appears in the ScaledObject's events immediately
- C) Nothing visible happens — the ScaledObject never activates, with no error anywhere
- D) KEDA automatically detects and corrects the mismatch

<details>
<summary>Answer</summary>

**C** — the ScaledObject's `listName: work-queue` trigger is scoped precisely; Redis Lists at any other key
are invisible to it, no matter how much data accumulates there.

Trap A: the redis scaler watches exactly one named list, never an aggregate across the whole instance —
this overstates its scope. Trap B: confirmed directly in Break-Fix 3 — no error surfaces anywhere; this is
precisely what makes the mismatch dangerous in practice. Trap D: KEDA has no name-matching or auto-correction
logic; a typo or mismatch is silent until someone notices manually.

</details>

---

**Q7. Is there an imperative `kubectl create` shortcut for `ScaledObject`, `TriggerAuthentication`, or
`StatefulSet`?**

- A) Yes, for all three
- B) Yes, only for StatefulSet
- C) No, for all three — all must be written as full YAML
- D) Yes, only for ScaledObject

<details>
<summary>Answer</summary>

**C** — `ScaledObject` and `TriggerAuthentication` are CRDs with no generic imperative verb, and
`StatefulSet`, despite being a built-in Kubernetes type, was never given a `kubectl create` shortcut either.

Trap A and D: both assume at least one of these has an imperative path, likely by analogy to
`kubectl create deployment`/`kubectl autoscale`. Trap B: singles out StatefulSet as the exception, but it's
equally YAML-only as the two CRDs — no partial exception exists here.

</details>

---

**Q8. A container fails to resolve a valid Kubernetes Service DNS name with "Name has no usable address,"
while `nslookup` against the same name succeeds. What's the most likely cause?**

- A) The Service doesn't actually exist
- B) A musl libc (Alpine Linux) DNS resolver limitation
- C) CoreDNS is down
- D) The container has no network connectivity at all

<details>
<summary>Answer</summary>

**B** — confirm via `nslookup` (works) vs `getent hosts` (fails) inside the affected container; fix by
switching to a glibc-based image.

Trap A: ruled out by the premise itself — `nslookup` succeeding confirms the Service and its DNS record
genuinely exist. Trap C: also ruled out by the same fact — if CoreDNS were down, `nslookup` would fail too,
not just the application's own resolution path. Trap D: a total connectivity failure would break `nslookup`
as well; the split between "one tool works, one doesn't" is the specific signature that points to the
resolver library itself, not the network.

</details>

---

**Q9. What kubectl action can force KEDA to attempt a fresh Redis connection, useful for surfacing a stale
credential problem?**

- A) `kubectl delete scaledobject <name>` then reapply
- B) `kubectl rollout restart deployment keda-operator -n keda`
- C) `kubectl edit triggerauthentication <name>`
- D) `kubectl scale deployment <name> --replicas=0`

<details>
<summary>Answer</summary>

**B** — restarting the operator drops any cached/open scaler connections, forcing a genuinely fresh
connection attempt on the next reconcile, exactly as demonstrated in Break-Fix 2.

Trap A: deleting and reapplying the ScaledObject is disruptive and unnecessary — it doesn't target the
actual stale resource (the operator's live connection), and risks losing state unrelated to the auth issue.
Trap C: editing the TriggerAuthentication again is what *causes* a stale-vs-fresh mismatch in the first
place in Break-Fix 2 — it doesn't by itself force reconnection, as the test directly showed (no immediate
error after the first patch). Trap D: scaling the target Deployment doesn't touch KEDA's own connection to
Redis at all; the scaler's connection lives at the operator level, not the workload level.

</details>

---

**Q10. `RPUSH` and `BRPOP` from opposite ends of a Redis List gives what ordering?**

- A) LIFO (last-in-first-out)
- B) FIFO (first-in-first-out)
- C) Random order
- D) Priority order based on value

<details>
<summary>Answer</summary>

**B** — pushing onto the right end and popping from the right end (with `RPUSH`/`BRPOP`, opposite operations
on the same "tail vs head" axis as their names suggest) drains items in the order they arrived.

Trap A: LIFO would result from pushing and popping the *same* end (e.g. `RPUSH`+`RPOP`) — a common
confusion since Lists support both ends. Trap C: Redis Lists are strictly ordered by insertion; there's no
randomness anywhere in the data structure. Trap D: Lists have no concept of value-based priority at all —
that would require a Sorted Set (`ZADD`/`ZRANGE`), a different Redis data type entirely.

</details>

Score guide:
| Score | Action |
|---|---|
| 10/10 | Import Anki cards, move to next Demo |
| 8–9/10 | Review the wrong answers, then proceed |
| 6–7/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
````