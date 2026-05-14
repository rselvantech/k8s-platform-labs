# Pod Affinity & Anti-Affinity — Scheduling Pods Relative to Other Pods

## Lab Overview

Node Affinity controls which **nodes** a pod can land on based on node labels.
Pod Affinity and Anti-Affinity take this one step further — they control where
a pod is scheduled **relative to other pods** that are already running.

This is essential for two opposite real-world requirements:

- **Co-location** — schedule this pod on the same node/zone as another pod
  (e.g. a cache that must be close to the app it serves)
- **Spread** — schedule this pod away from other pods of the same type
  (e.g. web replicas that must not share a node for HA)

Neither Taints nor Node Affinity can express these requirements. Pod Affinity
and Anti-Affinity are the dedicated mechanisms for inter-pod placement rules.

**What you'll do:**
- Understand `topologyKey` — the unit of placement for affinity rules
- Use `podAffinity` to co-locate pods on the same node
- Use `podAntiAffinity` to spread pods across nodes
- Apply `required` (hard) and `preferred` (soft) rules for both
- Build a real Redis cache + web tier scenario using both together
- Explore zone-based affinity using simulated availability zones

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- **REQUIRED:** Completion of [03-node-selector-affinity](../03-node-selector-affinity/)
- Understanding of labels, selectors, and `matchExpressions`
- Familiarity with `requiredDuring` vs `preferredDuring` scheduling rules

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain what `topologyKey` means and why it is required
2. ✅ Write `podAffinity` rules to co-locate pods on the same node
3. ✅ Write `podAntiAffinity` rules to spread pods across nodes
4. ✅ Apply `requiredDuringSchedulingIgnoredDuringExecution` for hard rules
5. ✅ Apply `preferredDuringSchedulingIgnoredDuringExecution` for soft rules
6. ✅ Combine affinity and anti-affinity in one manifest
7. ✅ Use zone labels to express availability zone placement rules

## Directory Structure

```
04-pod-affinity/
├── README.md                            # This file
└── src/
    ├── pod-affinity-required.yaml        # Hard co-location — same node
    ├── pod-affinity-preferred.yaml       # Soft co-location — prefer same node
    ├── pod-anti-affinity-required.yaml   # Hard spread — one pod per node
    ├── pod-anti-affinity-preferred.yaml  # Soft spread — prefer different nodes
    ├── web-deploy.yaml                   # Real scenario — web tier with anti-affinity
    ├── cache-deploy.yaml                 # Real scenario — Redis cache co-located with web
    └── zone-affinity.yaml                # Zone-based affinity using zone labels
```

---

## Understanding Pod Affinity & Anti-Affinity

### Node Affinity vs Pod Affinity

```
Node Affinity:
  "Schedule this pod on nodes that have label X"
  → Relationship: pod ↔ node

Pod Affinity:
  "Schedule this pod on nodes that are ALREADY RUNNING pods with label X"
  → Relationship: pod ↔ pod (via the node they share)
```
---

### Pod Affinity vs Pod Anti-Affinity

```
podAffinity:     ATTRACT — schedule near matching pods
podAntiAffinity: REPEL   — schedule away from matching pods
```
---

### Why There Is No nodeAntiAffinity

Kubernetes has `podAffinity` and `podAntiAffinity` as a pair — but only
`nodeAffinity` with no `nodeAntiAffinity`. This is because node-level
exclusion is already covered by two existing mechanisms:

- **Taints & Tolerations** — node-driven exclusion (node repels pods)
- **nodeAffinity with `NotIn`/`DoesNotExist`** — pod-driven exclusion
  (pod avoids nodes with specific labels)


**nodeAntiAffinity does not exist because:**
Both above mentioned *nodeAntiAffinity*  mechanisms were already in place before pod affinity was designed.

**Why a separate **podAntiAffinity**?**

For pod-level exclusion, `podAntiAffinity` exists as a dedicated field
rather than relying on `NotIn` inside `podAffinity`'s `labelSelector`.
Both can produce the same placement result as verified by live testing.
The difference is intent and predictability:

- `podAffinity` with `NotIn` — indirect: "be near pods that are NOT X"
  Behaviour can become unpredictable when only the pods you want to
  avoid are running and no other pods exist to attract towards.

- `podAntiAffinity` — direct: "stay away from pods that ARE X"
  Intent is unambiguous regardless of what else is running in the cluster.

`podAntiAffinity` exists to express repulsion directly and predictably —
not because it produces a fundamentally different result in simple cases.

---

### Pod Affinity & AntiAffinity  — New key field `labelSelector`

**`labelSelector`** — *Which Pods to Match Against*

The `labelSelector` inside affinity and antiaffinity rules identifies the **reference pods**
— the pods whose location influences where the new pod is scheduled.

```yaml
labelSelector:
  matchLabels:
    app: web       # find pods with this label
```

The scheduler finds all nodes running pods that match this selector, then
applies the `topologyKey` to determine eligible placement nodes.

---

### Pod Affinity & AntiAffinity  — New key field `topologyKey`

**`topologyKey`** — *The Unit of Placement*

The Most Important Concept to Understand first
Without it, pod affinity/antiaffinity rules make no sense.

**topologyKey** - `topologyKey` is what makes Pod Affinity flexible. It defines the **boundary**
within which "same" or "different" is evaluated.

#### The problem labelSelector alone cannot solve

`labelSelector` finds the reference pods — the pods you want to be
near or away from. But finding those pods is only half the job.
```
labelSelector: app=reference
→ finds pod-A running on 3node-m02
→ finds pod-B running on 3node-m03
→ result: a set of pods and the nodes they are on
→ does NOT answer: what does "near" or "away from" mean?
```

You know WHICH pods to relate to. But you do not yet know WHAT "same
place" means. Same node? Same rack? Same availability zone? Same region?

That is exactly what `topologyKey` answers.

#### What topologyKey does

`topologyKey` is a **node label key**. The scheduler reads that label's
value on the node where the reference pod is running — and that value
becomes the **topology domain**. All nodes sharing the same value for that
label are considered the same domain.
```
Reference pod is on 3node-m02.

3node-m02 has these labels:
  kubernetes.io/hostname          = 3node-m02   ← unique per node
  topology.kubernetes.io/zone     = zone-b      ← shared by all nodes in zone-b

topologyKey: kubernetes.io/hostname
  → domain value = "3node-m02"
  → "same domain" = nodes where hostname = 3node-m02
  → result: SAME NODE as the reference pod

topologyKey: topology.kubernetes.io/zone
  → domain value = "zone-b"
  → "same domain" = all nodes where zone = zone-b
  → result: SAME ZONE as the reference pod
             (could be a different node within that zone)
```

Same reference pod, same `labelSelector` — but a completely different
placement outcome depending on which `topologyKey` you choose.

#### The two jobs working together
```
labelSelector  → WHO am I relating to?
                 Finds the reference pods

topologyKey    → WHAT does "together" mean?
                 Defines the boundary for "same place"
```

Think of it this way: `labelSelector` finds Alice. `topologyKey` defines
whether "near Alice" means same desk, same floor, or same building.
Without `topologyKey` the scheduler has no way to evaluate the rule.

#### Why topologyKey is mandatory

This is why `topologyKey` is a **required field** — Kubernetes will reject
your manifest with a validation error if it is missing. The scheduler
cannot evaluate "same place" or "different place" without knowing what
unit of placement you are defining.
```bash
# Missing topologyKey → immediate validation error on apply
error: error validating: ...
  spec.template.spec.affinity.podAffinity
    .requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey:
    Required value
```

#### The two most common topologyKey values

| topologyKey | What it means | When to use |
|---|---|---|
| `kubernetes.io/hostname` | Each node is its own domain | Co-locate on same node, or spread one pod per node |
| `topology.kubernetes.io/zone` | All nodes in same AZ form one domain | Co-locate in same AZ, or spread one pod per AZ |

`kubernetes.io/hostname` is already present on every node — Kubernetes
adds it automatically. `topology.kubernetes.io/zone` must be added
manually on minikube (we do this in Step 1) — on real cloud clusters
(EKS, GKE, AKS) it is added automatically by the cloud provider.

Any node label key can be used as a `topologyKey` — but these two cover
the vast majority of production use cases.

---

### Node vs Pod Affinity Syntax — Structure Reference & Memory Aids

#### Required — Side by Side
```yaml
# NODE AFFINITY — required          # POD AFFINITY — required
affinity:                           affinity:
  nodeAffinity:                       podAffinity:
    requiredDuring...:                  requiredDuring...:
      nodeSelectorTerms:    # wrapper       # no wrapper
        - matchExpressions:             - labelSelector:
            - key: storage                  matchLabels:
              operator: In                    app: reference
              values:                     topologyKey:        # mandatory
                - ssd                       kubernetes.io/hostname
```

#### Preferred — Side by Side
```yaml
# NODE AFFINITY — preferred         # POD AFFINITY — preferred
affinity:                           affinity:
  nodeAffinity:                       podAffinity:
    preferredDuring...:                 preferredDuring...:
      - weight: 10                      - weight: 10
        preference:         # PREF        podAffinityTerm:    # PAT
          matchExpressions:                 labelSelector:
            - key: storage                    matchLabels:
              operator: In                      app: reference
              values:                         topologyKey:    # mandatory
                - ssd                           kubernetes.io/hostname
```

#### Structural Difference at a Glance

| | Node Affinity | Pod Affinity |
|---|---|---|
| Required wrapper | `nodeSelectorTerms` | None — `[–]` |
| Required match field | `matchExpressions` → `key / operator / values` | `labelSelector` |
| Preferred inner wrapper | `preference:` | `podAffinityTerm:` |
| Extra mandatory field | None | `topologyKey` — always required |

---

#### Memory Notation

**Required:**
```
Node:  NA → R → NST → ME → (K O V)
Pod:   PA → R → [–] → LS → T
```
```
NA  = nodeAffinity                PA   = podAffinity
R   = requiredDuring...           R    = requiredDuring...
NST = nodeSelectorTerms           [–]  = no wrapper (empty slot)
ME  = matchExpressions            LS   = labelSelector
KOV = Key · Operator · Values     T    = topologyKey (mandatory)
```

**Preferred:**
```
Node:  W → PREF → ME → (K O V)
Pod:   W → PAT  → LS → T
```
```
W    = weight                     W    = weight
PREF = preference:                PAT  = podAffinityTerm:
ME   = matchExpressions           LS   = labelSelector
KOV  = Key · Operator · Values    T    = topologyKey (mandatory)
```

**Three things to lock in:**

1. **Node required has one wrapper. Pod required has none.**
   `NST` vs `[–]`

2. **The preferred inner wrapper names itself.**
   `preference` = node. `podAffinityTerm` = pod
   (the word "pod" is inside the wrapper name).

3. **Pod affinity always ends with T.**
   `topologyKey` is mandatory on both required and preferred.
   Kubernetes rejects the manifest with a validation error if omitted.

## Lab Step-by-Step Guide

---

### Step 1: Inspect Cluster and Add Zone Labels

```bash
cd 04-pod-affinity/src

kubectl get nodes --show-labels
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   18h   v1.34.0
3node-m02   Ready    <none>          18h   v1.34.0
3node-m03   Ready    <none>          18h   v1.34.0
```

Add zone labels — these simulate availability zones used in real cloud clusters.
The label key `topology.kubernetes.io/zone` is a well-known Kubernetes label
used by EKS, GKE, and AKS automatically. We add it manually here for the demo.

```bash
kubectl label nodes 3node     topology.kubernetes.io/zone=zone-a
kubectl label nodes 3node-m02 topology.kubernetes.io/zone=zone-b
kubectl label nodes 3node-m03 topology.kubernetes.io/zone=zone-c

kubectl get nodes --show-labels | grep zone
```

**Expected output:**
```
3node       ...   topology.kubernetes.io/zone=zone-a,...
3node-m02   ...   topology.kubernetes.io/zone=zone-b,...
3node-m03   ...   topology.kubernetes.io/zone=zone-c,...
```

> `kubernetes.io/hostname` is already present on all nodes — added
> automatically by Kubernetes. You do not need to add it manually.

---

### Step 2: Pod Affinity — Required, Co-locate on Same Node

First deploy a reference pod. Pod Affinity needs at least one running pod
to match against — without it, the affinity pod goes Pending.

Deploy the reference pod onto `3node-m02`:

```bash
kubectl run reference-pod \
  --image=busybox \
  --labels="app=reference" \
  -- sh -c "sleep 3600"

kubectl get pod reference-pod -o wide
```

**Expected output:**
```
NAME            READY   STATUS    NODE
reference-pod   1/1     Running   3node-m02
```

> The scheduler may place the reference pod on any node. Note which node
> it lands on — your affinity pod should land on the same node.

Now deploy a pod with *hard affinity* to co-locate with the reference pod:

**pod-affinity-required.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: affinity-required-deploy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: affinity-required
  template:
    metadata:
      labels:
        app: affinity-required
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: reference        # match pods with this label
              topologyKey: kubernetes.io/hostname  # on the SAME node
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `podAffinity` — under `spec.template.spec.affinity`, same level as `nodeAffinity`
- `requiredDuringSchedulingIgnoredDuringExecution` — HARD rule, pod goes Pending if no match
- `labelSelector` — identifies reference pods to match against
- `topologyKey: kubernetes.io/hostname` — "same node" as the reference pod
- Note the structure: `podAffinity` uses a **list of rules** directly, not wrapped
  in `nodeSelectorTerms` like `nodeAffinity`

```bash
kubectl apply -f pod-affinity-required.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                      READY   STATUS    NODE
reference-pod                             1/1     Running   3node-m02
affinity-required-deploy-xxxxxxxxx-aaaaa  1/1     Running   3node-m02
affinity-required-deploy-xxxxxxxxx-bbbbb  1/1     Running   3node-m02
```

Both replicas land on the same node as `reference-pod` — hard affinity
forces them to the node where `app=reference` pods are running.

**What happens if the reference pod is deleted?**

```bash
kubectl delete pod reference-pod --grace-period=0 --force
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                      READY   STATUS    NODE
affinity-required-deploy-xxxxxxxxx-aaaaa  1/1     Running   3node-m02
affinity-required-deploy-xxxxxxxxx-bbbbb  1/1     Running   3node-m02
```

Running pods are not evicted — `IgnoredDuringExecution` applies. But if
a pod is rescheduled now, it will go Pending — no reference pod exists.

**Cleanup:**
```bash
kubectl delete -f pod-affinity-required.yaml
```

---

### Step 3: Pod Affinity — Preferred, Soft Co-location

*Soft affinity* prefers to co-locate but schedules elsewhere if not possible.

First redeploy the reference pod:

```bash
kubectl run reference-pod \
  --image=busybox \
  --labels="app=reference" \
  -- sh -c "sleep 3600"
```

**pod-affinity-preferred.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: affinity-preferred-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: affinity-preferred
  template:
    metadata:
      labels:
        app: affinity-preferred
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: reference
                topologyKey: kubernetes.io/hostname
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

> **Structure difference from required:** `preferred` wraps the rule in
> `weight` + `podAffinityTerm`. `required` uses the rule directly in a list.
> This is a common source of YAML errors — keep this difference in mind.

```bash
kubectl apply -f pod-affinity-preferred.yaml
kubectl get pods -o wide
```

**Expected output (approximate):**
```
NAME                                       READY   STATUS    NODE
reference-pod                              1/1     Running   3node-m02
affinity-preferred-deploy-xxxxxxxxx-aaaaa  1/1     Running   3node-m02
affinity-preferred-deploy-xxxxxxxxx-bbbbb  1/1     Running   3node-m02
affinity-preferred-deploy-xxxxxxxxx-ccccc  1/1     Running   3node-m03
```

Most pods prefer the reference pod's node but the scheduler may spread
some to other nodes — soft rule, not guaranteed.

**Cleanup:**
```bash
kubectl delete -f pod-affinity-preferred.yaml
kubectl delete pod reference-pod --grace-period=0 --force
```

---

### Step 4: Pod Anti-Affinity — Required, Spread Across Nodes

Anti-Affinity is the opposite of Affinity — it **repels** pods away from
nodes where matching pods are running. With `requiredDuring` and
`topologyKey: hostname`, no two matching pods can share the same node.

In Steps 2 and 3 you used an external reference pod to attract towards.
Anti-affinity works the same way — the `labelSelector` identifies which
pods to repel from. You start with the same familiar pattern: deploy a
reference pod first, then observe the anti-affinity pods avoiding it.

Deploy the reference pod:

```bash
kubectl run reference-pod \
  --image=busybox \
  --labels="app=reference" \
  -- sh -c "sleep 3600"

kubectl get pod reference-pod -o wide
```

**Expected output:**
```
NAME            READY   STATUS    NODE
reference-pod   1/1     Running   3node-m02
```

**pod-anti-affinity-required.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anti-required-deploy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: anti-required
  template:
    metadata:
      labels:
        app: anti-required
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: reference        # repel away from the reference pod
              topologyKey: kubernetes.io/hostname  # on DIFFERENT nodes
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `podAntiAffinity` — repels pods away from nodes where matching pods run
- `labelSelector: app=reference` — identifies the reference pod to avoid
- `topologyKey: kubernetes.io/hostname` — "different node" from the reference pod

```bash
kubectl apply -f pod-anti-affinity-required.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                    READY   STATUS    NODE
reference-pod                           1/1     Running   3node-m02
anti-required-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node
anti-required-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m03
```

Both anti-affinity pods land on nodes that do NOT have the reference pod
(`3node-m02` is avoided). Anti-affinity pushed them away.

**Cleanup:**
```bash
kubectl delete -f pod-anti-affinity-required.yaml
kubectl delete pod reference-pod --grace-period=0 --force
```

---

#### Self-Referencing Anti-Affinity — The HA Spread Pattern

In Step 4 you used an external reference pod (`app=reference`) as the
target to avoid. In production the most common anti-affinity pattern is
different — a deployment's pods repel **their own kind**.

```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: web        # ← same label the deployment itself uses
      topologyKey: kubernetes.io/hostname
```

Here the `labelSelector` matches `app=web` — the same label applied to
every pod in the deployment. Each new pod sees all existing pods of the
same deployment as pods to avoid.

**How it plays out with 3 replicas across 3 nodes:**

```
Pod 1 scheduled → no existing web pods anywhere → lands on 3node
Pod 2 scheduled → 3node has app=web → avoids 3node → lands on 3node-m02
Pod 3 scheduled → 3node and 3node-m02 have app=web → lands on 3node-m03

Result: one pod per node — HA spread enforced automatically
```

**Why this is the canonical HA pattern:**

```
Without anti-affinity:
  3 replicas could all land on 3node-m02
  3node-m02 fails → all 3 replicas lost → full outage

With self-referencing anti-affinity:
  1 replica per node guaranteed
  3node-m02 fails → 1 replica lost → 2 replicas still serving
```

This pattern is used in Step 6 (web tier) and is the standard approach
for any stateless deployment that requires high availability.

---

### Step 5: Pod Anti-Affinity — Preferred, Soft Spread

Now that the self-referencing pattern is clear, Step 5 uses it directly.
Soft anti-affinity prefers to spread pods but allows stacking on the same
node if no other node is available — pods never go Pending.

**pod-anti-affinity-preferred.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anti-preferred-deploy
spec:
  replicas: 5
  selector:
    matchLabels:
      app: anti-preferred
  template:
    metadata:
      labels:
        app: anti-preferred
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: anti-preferred   # self-referencing — repel own kind
                topologyKey: kubernetes.io/hostname
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `podAffinityTerm` — required wrapper for preferred rules (vs `required`
  which has no wrapper — see Memory Notation in Understanding section)
- `labelSelector: app=anti-preferred` — self-referencing, matches own pods
- `weight: 100` — strongest soft preference to spread

```bash
kubectl apply -f pod-anti-affinity-preferred.yaml
kubectl get pods -o wide
```

**Expected output (approximate — distribution varies):**
```
NAME                                        READY   STATUS    NODE
anti-preferred-deploy-xxxxxxxxx-aaaaa       1/1     Running   3node
anti-preferred-deploy-xxxxxxxxx-bbbbb       1/1     Running   3node-m02
anti-preferred-deploy-xxxxxxxxx-ccccc       1/1     Running   3node-m03
anti-preferred-deploy-xxxxxxxxx-ddddd       1/1     Running   3node-m02
anti-preferred-deploy-xxxxxxxxx-eeeee       1/1     Running   3node-m03
```

5 pods across 3 nodes — scheduler spreads the first 3 (one per node),
then stacks the remaining 2 on existing nodes rather than leaving them
Pending. Soft rule: spread as much as possible, stack the overflow.

**Compare with required anti-affinity:**

```
required anti-affinity with 5 replicas, 3 nodes:
  3 pods scheduled (one per node)
  4th pod → Pending (no node without app=anti-preferred)
  5th pod → Pending

preferred anti-affinity with 5 replicas, 3 nodes:
  3 pods spread (one per node)
  4th pod → stacks on least loaded node
  5th pod → stacks on least loaded node
  All 5 Running — no Pending
```

Use `required` when strict one-per-node HA is mandatory.
Use `preferred` when you want best-effort spread but cannot afford Pending.

**Cleanup:**
```bash
kubectl delete -f pod-anti-affinity-preferred.yaml
```

---

### Step 6: Real Scenario — Redis Cache Co-located with Web Tier

**The problem this solves:**

A Redis cache instance serves a web application. Network latency between
the web pod and Redis matters — if they are on different nodes, every cache
call crosses the network. Co-locating them on the same node keeps cache
calls on the loopback interface.

At the same time, web pods must spread across nodes for HA — if one node
fails, not all web replicas go down.

```
Goal:
  web pods   → spread across nodes (anti-affinity with each other)
  cache pods → co-locate with a web pod on the same node (affinity to web)
```

**Deploy the web tier first** — with **intra-deployment anti-affinity** 
(each pod repels its own kind) to spread replicas across nodes:

**web-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        tier: frontend
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: web          # spread web pods — one per node
              topologyKey: kubernetes.io/hostname
      containers:
        - name: web
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f web-deploy.yaml
kubectl get pods -o wide -l app=web
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
web-deploy-xxxxxxxxx-aaaaa   1/1     Running   3node
web-deploy-xxxxxxxxx-bbbbb   1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ccccc   1/1     Running   3node-m03
```

Web pods spread — one per node.

**Now deploy the Redis cache** — with affinity to **co-locate with web** pods:

**cache-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
        tier: cache
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: web          # co-locate with web pods
              topologyKey: kubernetes.io/hostname  # on the SAME node
      containers:
        - name: cache
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f cache-deploy.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                           READY   STATUS    NODE
web-deploy-xxxxxxxxx-aaaaa     1/1     Running   3node
web-deploy-xxxxxxxxx-bbbbb     1/1     Running   3node-m02
web-deploy-xxxxxxxxx-ccccc     1/1     Running   3node-m03
cache-deploy-xxxxxxxxx-ddddd   1/1     Running   3node
cache-deploy-xxxxxxxxx-eeeee   1/1     Running   3node-m02
cache-deploy-xxxxxxxxx-fffff   1/1     Running   3node-m03
```

Each cache pod lands on a node that already has a web pod — co-located for
low-latency cache access. Web pods are spread for HA. Both requirements
satisfied simultaneously.

**Cleanup:**
```bash
kubectl delete -f cache-deploy.yaml
kubectl delete -f web-deploy.yaml
```

---

### Step 7: Zone-Based Affinity

Using `topologyKey: topology.kubernetes.io/zone` instead of hostname changes
the placement boundary from "same node" to "same availability zone". This is
the most common production use case — keeping related pods in the same zone
to avoid cross-zone network costs and latency.

Deploy a reference pod and observe its zone:

```bash
kubectl run zone-reference \
  --image=busybox \
  --labels="app=zone-ref" \
  -- sh -c "sleep 3600"

kubectl get pod zone-reference -o wide
```

Note which node it landed on, then check its zone label:

```bash
kubectl get node <node-name> --show-labels | grep zone
```

**zone-affinity.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zone-affinity-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: zone-affinity
  template:
    metadata:
      labels:
        app: zone-affinity
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: zone-ref
              topologyKey: topology.kubernetes.io/zone  # same ZONE as reference
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f zone-affinity.yaml
kubectl get pods -o wide
```

**Expected output (if zone-reference landed on 3node-m02, zone-b):**
```
NAME                                  READY   STATUS    NODE
zone-reference                        1/1     Running   3node-m02
zone-affinity-deploy-xxxxxxxxx-aaaaa  1/1     Running   3node-m02
zone-affinity-deploy-xxxxxxxxx-bbbbb  1/1     Running   3node-m02
zone-affinity-deploy-xxxxxxxxx-ccccc  1/1     Running   3node-m02
```

All pods land in zone-b (on `3node-m02`) — the only node in zone-b.

> In a real cloud cluster with multiple nodes per zone, the pods would
> spread across all nodes within zone-b, not just one. See the EKS
> extension section below for this scenario.

**Cleanup:**
```bash
kubectl delete -f zone-affinity.yaml
kubectl delete pod zone-reference --grace-period=0 --force
```

---

### Step 8: Final Cleanup

```bash
# Remove zone labels added in Step 1
kubectl label nodes 3node     topology.kubernetes.io/zone-
kubectl label nodes 3node-m02 topology.kubernetes.io/zone-
kubectl label nodes 3node-m03 topology.kubernetes.io/zone-

# Remove any remaining deployments
kubectl delete deployment --all

# Verify clean state
kubectl get all
kubectl get nodes --show-labels | grep zone
# zone label should no longer appear
```

---

## ☁️ Taking It Further — EKS / Multi-Node-Per-Zone

> This section cannot be fully verified on a 3-node minikube cluster.
> Use it as a reference when you have access to an EKS or other cloud cluster.
> Come back and verify the outputs to reinforce your understanding.

### Why Zone Affinity Behaves Differently on Real Cloud Clusters

On minikube with 1 node per zone, zone affinity is identical to node affinity.
The real difference emerges when a zone has **multiple nodes**.

In a real EKS cluster with this topology:

```
us-east-1a: node-1a-1, node-1a-2
us-east-1b: node-1b-1, node-1b-2
us-east-1c: node-1c-1, node-1c-2
```

A pod with `podAffinity topologyKey: topology.kubernetes.io/zone` targeting
a reference pod in `us-east-1a` will schedule on **either** `node-1a-1` or
`node-1a-2` — the scheduler picks within the zone freely.

This is intentional: you want zone-locality but not node-pinning. The
scheduler retains flexibility within the zone for bin-packing and load
distribution.

### Cross-Zone Anti-Affinity — Production HA Pattern

```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: web
      topologyKey: topology.kubernetes.io/zone
```

On EKS with 3 zones this forces one web pod per zone — even if a zone has
10 nodes. No two web pods share a zone. A full AZ failure takes out at most
one web replica.

**To verify on EKS:**
1. Deploy with `replicas: 3` and the above anti-affinity rule
2. Run `kubectl get pods -o wide` — confirm one pod per AZ
3. Scale to `replicas: 4` — observe the 4th pod go Pending (only 3 zones)
4. Change to `preferredDuring` — observe 4th pod schedule into an existing zone

### Co-location Across Zone Boundaries — When Not to Use Zone Affinity

If a web pod and its cache pod are in different zones, every cache call
crosses AZ network boundaries — adding ~1ms latency and inter-AZ data
transfer costs. Zone affinity ensures they stay together. But if the web
pod moves zones (rescheduled after a node failure), the cache pod does not
automatically follow — `IgnoredDuringExecution` means the cache keeps running
in the old zone. This is a known limitation to plan for in production.

---

## Experiments to Try

1. **No reference pod — observe Pending behaviour:**
   ```bash
   # Apply pod-affinity-required.yaml without deploying reference-pod first
   # All pods go Pending — no node satisfies the affinity rule
   kubectl apply -f pod-affinity-required.yaml
   kubectl get pods -o wide
   kubectl describe pod <pod-name> | grep -A5 Events
   # Then deploy reference-pod and watch pods recover
   ```

2. **Anti-affinity with zone topology — one pod per zone:**
   ```bash
   # Edit pod-anti-affinity-required.yaml
   # Change topologyKey from kubernetes.io/hostname
   # to topology.kubernetes.io/zone
   # Deploy with replicas: 3 — one pod per zone
   # Scale to replicas: 4 — 4th pod Pending (only 3 zones)
   ```

3. **Affinity to a different namespace:**
   ```yaml
   # By default labelSelector matches pods in the SAME namespace
   # To match across namespaces add:
   namespaces:
     - other-namespace
   # Or use namespaceSelector (Kubernetes 1.22+)
   ```

4. **Self-affinity — all replicas co-located:**
   ```yaml
   # labelSelector matches the deployment's OWN pods
   podAffinity:
     requiredDuringSchedulingIgnoredDuringExecution:
       - labelSelector:
           matchLabels:
             app: my-app    # matches itself
         topologyKey: kubernetes.io/hostname
   # All replicas stack on one node — first pod determines location
   # Useful for stateful apps that share a local volume
   ```

---

## Common Questions

### Q: What happens if the reference pod is deleted after dependent pods are running?

**A:** Nothing immediately — `IgnoredDuringExecution` applies. Running pods
keep running. But if any of the dependent pods are deleted and rescheduled,
they will go Pending because there is no reference pod to satisfy the affinity
rule. This is an important operational concern for required affinity rules.

### Q: Can I use both `podAffinity` and `podAntiAffinity` in the same manifest?

**A:** Yes — and this is the recommended pattern for the web+cache scenario.
`podAffinity` and `podAntiAffinity` are separate fields under `affinity:` and
are evaluated independently. Both must be satisfied for a node to be eligible.

### Q: Can `topologyKey` be any label key?

**A:** Yes — any label that exists on nodes can be used as a `topologyKey`.
However, for security reasons, cluster administrators can restrict which keys
are allowed via the `LimitPodHardAntiAffinityTopology` admission plugin.
In practice, `hostname` and `zone` cover the vast majority of use cases.

---

## What You Learned

In this lab, you:
- ✅ Understood `topologyKey` as the boundary for placement decisions
- ✅ Used `podAffinity required` to hard co-locate pods on the same node
- ✅ Used `podAffinity preferred` for soft co-location with fallback
- ✅ Used `podAntiAffinity required` to strictly spread pods — one per node
- ✅ Used `podAntiAffinity preferred` for soft spread with stacking allowed
- ✅ Built a real Redis + web tier scenario using both together
- ✅ Applied zone-based affinity using `topology.kubernetes.io/zone`

**Key Takeaway:** Pod Affinity attracts pods to nodes where specific other
pods are running. Pod Anti-Affinity repels pods from those nodes. `topologyKey`
defines the granularity — node, zone, or region. Required rules are hard
constraints that cause Pending if unsatisfied. Preferred rules are soft hints
that allow fallback. The web + cache co-location combined with web spread is
the canonical production pattern for these mechanisms.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl label nodes <n> topology.kubernetes.io/zone=<zone>` | Add zone label to node |
| `kubectl label nodes <n> topology.kubernetes.io/zone-` | Remove zone label |
| `kubectl get pods -o wide -l app=<label>` | Filter pods by label, show node placement |
| `kubectl scale deployment <n> --replicas=<n>` | Scale deployment to observe Pending |
| `kubectl explain pod.spec.affinity.podAffinity` | Browse podAffinity field docs |
| `kubectl explain pod.spec.affinity.podAntiAffinity` | Browse podAntiAffinity field docs |

---

## CKA Certification Tips

✅ **Structure difference — required vs preferred:**
```yaml
# required — rule directly in list
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:        # ← directly here
        matchLabels:
          app: web
      topologyKey: kubernetes.io/hostname

# preferred — wrapped in weight + podAffinityTerm
podAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:      # ← extra wrapper
        labelSelector:
          matchLabels:
            app: web
        topologyKey: kubernetes.io/hostname
```

✅ **`topologyKey` is mandatory** — omitting it causes a validation error.
Always include it. The most common values:
```
kubernetes.io/hostname              → same/different node
topology.kubernetes.io/zone        → same/different zone
```

✅ **Anti-affinity with self-label = spread pattern:**
```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app: web          # same label as the deployment itself
      topologyKey: kubernetes.io/hostname
# Forces one pod per node — classic HA spread
```

✅ **Use `kubectl explain` in the exam:**
```bash
kubectl explain pod.spec.affinity.podAffinity
kubectl explain pod.spec.affinity.podAntiAffinity
```

---

## Troubleshooting

**Pods stuck in Pending after applying affinity rule?**
```bash
kubectl describe pod <pod-name> | grep -A8 Events
# Common causes:
# 1. No reference pod running — labelSelector finds no matching pods
# 2. Hard anti-affinity — more replicas than available nodes
# 3. topologyKey label missing on nodes — scheduler cannot evaluate the rule
kubectl get nodes --show-labels | grep <topologyKey>
```

**Pods not co-locating as expected with preferred affinity?**
```bash
# Preferred is a hint — scheduler may override for resource balance
kubectl describe node <node> | grep -A10 "Allocated resources"
# Check if target node is resource-constrained
```

**Validation error on apply?**
```bash
kubectl apply -f <file> --dry-run=client
# Common causes:
# 1. topologyKey missing
# 2. preferred rule missing podAffinityTerm wrapper
# 3. affinity: placed at wrong YAML level
```

**General debugging:**
```bash
kubectl describe pod <n>                        # scheduling events
kubectl get events --sort-by='.lastTimestamp'   # cluster-wide events
```
