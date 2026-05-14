# Node Selector & Node Affinity — Label-Based Pod Scheduling

## Lab Overview

This lab teaches you how to control pod placement using **labels on nodes**
and **scheduling rules in pod specs**. While Taints & Tolerations work by
repelling pods from nodes, Node Selector and Node Affinity work by attracting
pods to specific nodes based on labels.

You will start with Node Selector — a simple equality-based approach — observe
its limitations, then move to Node Affinity which solves all those limitations
with hard rules, soft preferences, OR conditions, and rich operators. The lab
ends with the **Guaranteed Isolation** pattern — combining Taints + Tolerations
+ Node Affinity to ensure each pod lands exclusively on its designated node,
demonstrated with a blue/green/yellow colour-coded scenario.

**What you'll do:**
- Label nodes and schedule pods using `nodeSelector`
- Observe AND logic, Pending state, and non-retroactive label removal
- Schedule pods using `requiredDuringScheduling` Node Affinity
- Use OR logic via `values` and AND logic via multiple `matchExpressions`
- Deploy with `preferredDuringScheduling` and observe weighted distribution
- Apply all six operators: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`
- Combine Taints + Tolerations + Node Affinity for strictly isolated pod placement

## Prerequisites

**Required Software:**
- Minikube multi-node cluster (`3node` profile) — 1 control plane + 2 workers
- kubectl installed and configured
- Text editor (VS Code recommended with Kubernetes extension)

**Knowledge Requirements:**
- **REQUIRED:** Completion of [02-taints-tolerations](../02-taints-tolerations/)
- Understanding of node labels and `kubectl label`
- Familiarity with Deployment manifests

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Label nodes and use `nodeSelector` to target specific nodes
2. ✅ Explain all limitations of `nodeSelector`
3. ✅ Write `requiredDuringSchedulingIgnoredDuringExecution` Node Affinity rules
4. ✅ Write `preferredDuringSchedulingIgnoredDuringExecution` with weights
5. ✅ Use OR logic via `values` and AND logic via multiple `matchExpressions`
6. ✅ Apply all six operators including `NotIn` and `DoesNotExist` for anti-affinity
7. ✅ Combine `required` and `preferred` rules in one manifest
8. ✅ Combine Taints + Tolerations + Node Affinity for guaranteed isolated placement

## Directory Structure

```
03-node-selector-affinity/
├── README.md                       # This file
└── src/
    ├── ns-deploy.yaml              # nodeSelector — single label
    ├── ns-deploy-multi.yaml        # nodeSelector — multiple labels (AND + Pending)
    ├── na-required.yaml            # Node Affinity — required, single value
    ├── na-required-or.yaml         # Node Affinity — required, OR values
    ├── na-required-and.yaml        # Node Affinity — required, AND conditions
    ├── na-preferred.yaml           # Node Affinity — preferred with weights
    ├── na-combined.yaml            # Node Affinity — required + preferred together
    ├── na-operators.yaml           # Node Affinity — all six operators
    ├── blue-deploy.yaml            # Guaranteed isolation — blue pod → blue node
    ├── green-deploy.yaml           # Guaranteed isolation — green pod → green node
    └── yellow-deploy.yaml          # Guaranteed isolation — yellow pod → yellow node
```

---

## Understanding Node Selector & Node Affinity

### Why Label-Based Scheduling?

The scheduler places pods automatically — but in production not all nodes are
equal. Some have GPUs, NVMe storage, high memory, or are dedicated to specific
teams and environments. The scheduler cannot know these business requirements —
label-based scheduling lets you express them explicitly in your manifests.

| Technique | Type | Flexibility |
|---|---|---|
| **Node Selector** | Basic | Hard match only — equality, all labels must exist |
| **Node Affinity** | Advanced | Hard + Soft, OR via `values`, operators, anti-affinity |

### The AND vs OR Structure — Most Important Concept in Node Affinity

```
nodeSelectorTerms:                ← items here = OR between terms
  - matchExpressions:             ← items here = AND between conditions
      - key: storage
        operator: In
        values:                   ← items here = OR between values
          - ssd
          - hdd
      - key: env                  ← AND with storage condition above
        operator: In
        values:
          - prod
```

```
Result: (storage=ssd OR storage=hdd) AND (env=prod)
```

### requiredDuring vs preferredDuring

```
requiredDuringSchedulingIgnoredDuringExecution
  → HARD rule
  → Pod stays Pending if no matching node found
  → IgnoredDuringExecution: label changes after scheduling do NOT evict pods

preferredDuringSchedulingIgnoredDuringExecution
  → SOFT rule
  → Pod schedules elsewhere if no preferred node found — never goes Pending
  → IgnoredDuringExecution: same — running pods are not evicted
```

---

## Lab Step-by-Step Guide

---

### Step 1: Inspect Your Cluster and Existing Labels

```bash
cd 03-node-selector-affinity/src

kubectl get nodes --show-labels
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION   LABELS
3node       Ready    control-plane   18h   v1.34.0   beta.kubernetes.io/arch=amd64,...
3node-m02   Ready    <none>          18h   v1.34.0   beta.kubernetes.io/arch=amd64,...
3node-m03   Ready    <none>          18h   v1.34.0   beta.kubernetes.io/arch=amd64,...
```

No custom labels yet — only pre-populated Kubernetes system labels.

> **Pre-populated system labels on every node:**
> `kubernetes.io/hostname`, `kubernetes.io/os`, `kubernetes.io/arch`,
> `node-role.kubernetes.io/control-plane` (control plane only)

---

### Step 2: Label the Worker Nodes

```bash
kubectl label nodes 3node-m02 storage=ssd
kubectl label nodes 3node-m03 storage=hdd

kubectl get nodes --show-labels | grep storage
```

**Expected output:**
```
3node-m02   ...   storage=ssd,...
3node-m03   ...   storage=hdd,...
```

> **Remove a label** — append `-` after the key:
> `kubectl label nodes 3node-m02 storage-`
>
> **Update a label** — use `--overwrite`:
> `kubectl label nodes 3node-m03 storage=nvme --overwrite`

**Note:** before proceding to next step , make sure you to have node labels as below
```
3node-m02   ...   storage=ssd,...
3node-m03   ...   storage=hdd,...
```

---

### Step 3: Node Selector — Single Label

Node Selector is the simplest form of label-based scheduling. The pod spec
references node labels directly — the scheduler only places the pod on a node
that has all specified labels with exact matching values.

**ns-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ns-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ns-app
  template:
    metadata:
      labels:
        app: ns-app
    spec:
      terminationGracePeriodSeconds: 0
      nodeSelector:
        storage: ssd          # node must have exactly this label
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `nodeSelector` — under `spec.template.spec` (pod spec), NOT at Deployment `spec` level
- `storage: ssd` — exact key=value equality match
- No operators, no OR, no soft preferences — pure equality only

```bash
kubectl apply -f ns-deploy.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
ns-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
```

All pods land on `3node-m02` — the only node with `storage=ssd`.

**Cleanup:**
```bash
kubectl delete -f ns-deploy.yaml
```

---

### Step 4: Node Selector — AND Logic, Pending, Non-Retroactive Removal

This step demonstrates all three core behaviours of `nodeSelector` in one flow.

**ns-deploy-multi.yaml:**
```yaml
#copy ns-deploy.yaml and replace exiting nodeSelector with below 
      nodeSelector:
        storage: ssd
        env: prod             # AND condition — no node has this label yet
```

```bash
kubectl apply -f ns-deploy-multi.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
ns-deploy-xxxxxxxxx-aaaaa    0/1     Pending   <none>
ns-deploy-xxxxxxxxx-bbbbb    0/1     Pending   <none>
ns-deploy-xxxxxxxxx-ccccc    0/1     Pending   <none>
```

All pods Pending — no node satisfies BOTH labels simultaneously.

```bash
kubectl describe pod <pod-name> | grep -A5 Events
```

**Expected output:**
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available:
  1 node(s) didn't match Pod's node affinity/selector
```

**Add the missing label — pods recover immediately:**

```bash
kubectl label nodes 3node-m02 env=prod
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
ns-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
```

**Now remove the label — observe non-retroactive behaviour:**

```bash
kubectl label nodes 3node-m02 env-
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
ns-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
```

Running pods are unaffected — label removal is not retroactive. But if a pod
is deleted and rescheduled, the affinity rules are re-evaluated:

```bash
kubectl delete pod <any-pod-name> --grace-period=0 --force
kubectl get pods -o wide
```

**Expected output:**
```
NAME                         READY   STATUS    NODE
ns-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
ns-deploy-xxxxxxxxx-ddddd    0/1     Pending   <none>
```

The replacement pod is Pending — `env=prod` no longer exists on any node.

**Cleanup:**
```bash
kubectl delete -f ns-deploy-multi.yaml
kubectl label nodes 3node-m02 env-
```

---

### Step 5: Node Selector — Limitations

| Limitation | Observed In |
|---|---|
| No OR conditions — cannot express `storage=ssd OR storage=hdd` | Steps 3–4 |
| No soft preferences — pods go Pending if no match | Step 4 |
| Equality only — no operators like `NotIn`, `Exists`, `Gt` | Steps 3–4 |
| No anti-affinity — cannot say "NOT on nodes with label X" | Not possible |
| Label removal is not retroactive — only affects new/rescheduled pods | Step 4 |

Node Affinity resolves every one of these limitations.

---

### Step 6: Node Affinity — Required, Single Value

Node Affinity uses a richer expression syntax. The same `storage=ssd` rule
expressed in Node Affinity:

**na-required.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: na-required-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: na-required-app
  template:
    metadata:
      labels:
        app: na-required-app
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - ssd
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**Key YAML Fields:**
- `affinity` — under `spec.template.spec`, same level as `containers`
- `nodeAffinity` — targets nodes by their labels
- `requiredDuringSchedulingIgnoredDuringExecution` — HARD rule, pod goes Pending if no match
- `nodeSelectorTerms` — required wrapper, list of terms (OR between terms)
- `matchExpressions` — list of conditions (AND between conditions)
- `operator: In` — key must exist AND value must match one in the list
- `values` — list of acceptable values (OR between values)

Use `kubectl explain` to browse the full field reference without leaving the terminal:

```bash
kubectl explain pod.spec.affinity.nodeAffinity
```

```bash
kubectl apply -f na-required.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                                READY   STATUS    NODE
na-required-deploy-xxxxxxxxx-aaa    1/1     Running   3node-m02
na-required-deploy-xxxxxxxxx-bbb    1/1     Running   3node-m02
na-required-deploy-xxxxxxxxx-ccc    1/1     Running   3node-m02
```

**Cleanup:**
```bash
kubectl delete -f na-required.yaml
```

---

### Step 7: Node Affinity — OR Values

Multiple values in `values:` = OR logic. Pod qualifies for any node where
the key matches any of the listed values.

**na-required-or.yaml:**
```yaml
              - matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - ssd    # OR
                      - hdd    # OR
```

```bash
kubectl apply -f na-required-or.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                           READY   STATUS    NODE
na-or-deploy-xxxxxxxxx-aaaaa   1/1     Running   3node-m02
na-or-deploy-xxxxxxxxx-bbbbb   1/1     Running   3node-m03
na-or-deploy-xxxxxxxxx-ccccc   1/1     Running   3node-m02
```

Pods spread across both workers — both satisfy `storage=ssd OR storage=hdd`.
The control plane (`3node`) has no `storage` label so it is excluded.

**Cleanup:**
```bash
kubectl delete -f na-required-or.yaml
```

---

### Step 8: Node Affinity — AND Conditions

Multiple items in `matchExpressions:` = AND logic. Node must satisfy every
condition in the list.

```bash
kubectl label nodes 3node-m02 env=prod
```

**na-required-and.yaml:**
```yaml
              - matchExpressions:
                  - key: storage      # Condition 1
                    operator: In
                    values:
                      - ssd
                  - key: env          # Condition 2 — AND with Condition 1
                    operator: In
                    values:
                      - prod
```

```bash
kubectl apply -f na-required-and.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                               READY   STATUS    NODE
na-and-deploy-xxxxxxxxx-aaaaa      1/1     Running   3node-m02
na-and-deploy-xxxxxxxxx-bbbbb      1/1     Running   3node-m02
na-and-deploy-xxxxxxxxx-ccccc      1/1     Running   3node-m02
```

Only `3node-m02` satisfies `storage=ssd AND env=prod`. `3node-m03` has
`storage=hdd` (fails Condition 1) and no `env` label.

**Cleanup:**
```bash
kubectl delete -f na-required-and.yaml
kubectl label nodes 3node-m02 env-
```

---

### Step 9: Node Affinity — Preferred with Weights

`preferredDuringSchedulingIgnoredDuringExecution` is a soft rule. Pods prefer
matching nodes but schedule elsewhere if no match exists — they never go Pending.

**na-preferred.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: na-preferred-deploy
spec:
  replicas: 10
  selector:
    matchLabels:
      app: na-preferred-app
  template:
    metadata:
      labels:
        app: na-preferred-app
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 10              # Higher preference → ssd node
              preference:
                matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - ssd
            - weight: 5               # Lower preference → hdd node
              preference:
                matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - hdd
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**How weights work:**
- `weight` ranges from 1 to 100 — higher = stronger preference
- A node matching multiple preferences accumulates all their weights (additive)
- Final pod distribution is also influenced by resource availability and other
  scheduler factors — distribution is approximate, not mathematically exact

```bash
kubectl apply -f na-preferred.yaml
kubectl get pods -o wide
```

**Expected output (approximate — distribution varies):**
```
NAME                                  READY   STATUS    NODE
na-preferred-deploy-xxxxxxxxx-aaa     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-bbb     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-ccc     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-ddd     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-eee     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-fff     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-ggg     1/1     Running   3node-m02   ← ssd weight 10
na-preferred-deploy-xxxxxxxxx-hhh     1/1     Running   3node-m03   ← hdd weight 5
na-preferred-deploy-xxxxxxxxx-iii     1/1     Running   3node-m03   ← hdd weight 5
na-preferred-deploy-xxxxxxxxx-jjj     1/1     Running   3node-m03   ← hdd weight 5
```

`3node-m02` (weight 10) receives approximately 70% of pods.
`3node-m03` (weight 5) receives approximately 30%.

**Cleanup:**
```bash
kubectl delete -f na-preferred.yaml
```

---

### Step 10: Node Affinity — Required + Preferred Combined

Combining both rules gives a hard gate (required) with a soft preference within
the qualifying nodes:

A real scenario: your database pods must run on dedicated storage nodes
(never on the control plane or general-purpose nodes), but prefer SSD for
performance. If all SSD nodes are full or under maintenance, they fall back to
HDD rather than going Pending.

```
required  → hard gate: only storage nodes qualify
preferred → soft tie-breaker: within storage nodes, SSD gets priority over HDD
```

**na-combined.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-deploy
spec:
  replicas: 6
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      terminationGracePeriodSeconds: 0
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:    # HARD: storage nodes only
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role
                    operator: In
                    values:
                      - storage
          preferredDuringSchedulingIgnoredDuringExecution:   # SOFT: SSD over HDD
            - weight: 10
              preference:
                matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - ssd
            - weight: 5
              preference:
                matchExpressions:
                  - key: storage
                    operator: In
                    values:
                      - hdd
      containers:
        - name: db
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

**What this achieves:**
- `required` — only nodes with a `storage` label qualify (control plane excluded)
- `preferred` — among qualifying nodes, ssd nodes get more pods than hdd nodes

**Label the nodes** (storage=ssd and storage=hdd labels are already on the nodes)
```bash
kubectl label nodes 3node-m02 node-role=storage
kubectl label nodes 3node-m03 node-role=storage
```

```bash
kubectl apply -f na-combined.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                       READY   STATUS    NODE
db-deploy-xxxxxxxxx-aaa    1/1     Running   3node-m02   ← ssd, weight 10
db-deploy-xxxxxxxxx-bbb    1/1     Running   3node-m02   ← ssd, weight 10
db-deploy-xxxxxxxxx-ccc    1/1     Running   3node-m02   ← ssd, weight 10
db-deploy-xxxxxxxxx-ddd    1/1     Running   3node-m02   ← ssd, weight 10
db-deploy-xxxxxxxxx-eee    1/1     Running   3node-m03   ← hdd, weight 5
db-deploy-xxxxxxxxx-fff    1/1     Running   3node-m03   ← hdd, weight 5
```

- No pods on 3node — blocked by the required rule (node-role=storage absent)
- More pods on 3node-m02 — preferred because storage=ssd scores higher
- 3node-m03 still receives pods — soft rule means HDD nodes are used, not ignored

**Cleanup:**
```bash
kubectl delete -f na-combined.yaml
kubectl label nodes 3node-m02 node-role-
kubectl label nodes 3node-m03 node-role-
```
---

### Step 11: All Six Operators

Label nodes for this demo:

```bash
kubectl label nodes 3node-m02 high-memory=true cpu=8 disk=200
```

**na-operators.yaml:**
```yaml
#Copy na-preferred.yaml and repalce affinty block with below
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:

                  # In — storage must be ssd or hdd
                  - key: storage
                    operator: In
                    values:
                      - ssd
                      - hdd

                  # NotIn — env must NOT be dev (node anti-affinity)
                  - key: env
                    operator: NotIn
                    values:
                      - dev

                  # Exists — high-memory key must exist (any value)
                  - key: high-memory
                    operator: Exists

                  # DoesNotExist — node must NOT have 'dedicated' key
                  - key: dedicated
                    operator: DoesNotExist

                  # Gt — cpu label value must be greater than 4
                  - key: cpu
                    operator: Gt
                    values:
                      - "4"

                  # Lt — disk label value must be less than 500
                  - key: disk
                    operator: Lt
                    values:
                      - "500"
```

**Operator reference:**

| Operator | `values:` required? | Matches when |
|---|---|---|
| `In` | ✅ Yes | key exists AND value is in list |
| `NotIn` | ✅ Yes | key exists AND value is NOT in list |
| `Exists` | ❌ Omit entirely | key exists on node (any value) |
| `DoesNotExist` | ❌ Omit entirely | key does NOT exist on node |
| `Gt` | ✅ Single numeric string | node label value > given value |
| `Lt` | ✅ Single numeric string | node label value < given value |

> ⚠️ `Exists` and `DoesNotExist` must NOT have a `values:` field —
> including it causes a validation error on apply.

> ⚠️ `Gt` and `Lt` compare numeric string values. Both the node label and
> the values field must be numeric strings: label `cpu=8`, values `["4"]`.

> `NotIn` and `DoesNotExist` act as **node anti-affinity** — pod-driven
> exclusion. All six conditions above use AND logic — a node must satisfy
> all of them.

```bash
kubectl apply -f na-operators.yaml
kubectl get pods -o wide
# Only 3node-m02 satisfies all six conditions
```

**Cleanup:**
```bash
kubectl delete -f na-operators.yaml
kubectl label nodes 3node-m02 high-memory- cpu- disk-
```

---

### Step 12: Guaranteed Isolation — Taints + Tolerations + Node Affinity

This is the most important pattern in production pod scheduling. It combines
all three mechanisms to achieve **strict bidirectional isolation** — each pod
lands exclusively on its designated node, and no other pod can enter that node.

#### Why Each Mechanism Alone Is Not Enough

```
Tolerations alone  → permits pod onto tainted node, but does NOT attract it there
                     pod can still land on any other untainted node

Node Affinity alone → attracts pod to a node, but does NOT block other pods
                     any pod without affinity rules can still land on that node

Together:
  Taint      → node repels all pods WITHOUT matching toleration
  Toleration → permits THIS pod onto the tainted node
  Affinity   → attracts THIS pod exclusively TO that node

Result: this pod → this node only. this node → this pod only.
```

#### Scenario: Three Teams, Three Nodes, Strict Isolation
```
3node      → YELLOW team node — only yellow pods allowed
3node-m02  → BLUE   team node — only blue pods allowed
3node-m03  → GREEN  team node — only green pods allowed
```

> **Note:** This cluster has 1 control plane + 2 workers. To demonstrate all
> three colours, `3node` (control plane) is used as the yellow node. Minikube
> does not apply a control plane taint by default — so no extra toleration is
> needed. The yellow manifest is identical in structure to blue and green.
> In production on a kubeadm cluster, the control plane has a
> `node-role.kubernetes.io/control-plane:NoSchedule` taint — you would need
> an additional toleration for it, or better, use a dedicated third worker node.

**Setup — label and taint the nodes:**

```bash

# Yellow node — 3node-m02
kubectl label nodes 3node team=yellow
kubectl taint nodes 3node team=yellow:NoSchedule

# Blue node — 3node-m02
kubectl label nodes 3node-m02 team=blue
kubectl taint nodes 3node-m02 team=blue:NoSchedule

# Green node — 3node-m03
kubectl label nodes 3node-m03 team=green
kubectl taint nodes 3node-m03 team=green:NoSchedule
```

Verify:
```bash
kubectl describe node 3node | grep -E "Taints|Labels" -A15
kubectl describe node 3node-m02 | grep -E "Taints|Labels" -A15
kubectl describe node 3node-m03 | grep -E "Taints|Labels" -A15
```

---
**yellow-deploy.yaml** 
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yellow-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: yellow-app
  template:
    metadata:
      labels:
        app: yellow-app
    spec:
      terminationGracePeriodSeconds: 0
      # Toleration — permits this pod onto the yellow tainted node
      tolerations:
        - key: "team"
          operator: "Equal"
          value: "yellow"
          effect: "NoSchedule"
      # Node Affinity — attracts this pod strictly to the yellow node
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: team
                    operator: In
                    values:
                      - yellow
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

---

**blue-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blue-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: blue-app
  template:
    metadata:
      labels:
        app: blue-app
    spec:
      terminationGracePeriodSeconds: 0
      # Toleration — permits this pod onto the blue tainted node
      tolerations:
        - key: "team"
          operator: "Equal"
          value: "blue"
          effect: "NoSchedule"
      # Node Affinity — attracts this pod strictly to the blue node
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: team
                    operator: In
                    values:
                      - blue
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

---

**green-deploy.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: green-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: green-app
  template:
    metadata:
      labels:
        app: green-app
    spec:
      terminationGracePeriodSeconds: 0
      # Toleration — permits this pod onto the green tainted node
      tolerations:
        - key: "team"
          operator: "Equal"
          value: "green"
          effect: "NoSchedule"
      # Node Affinity — attracts this pod strictly to the green node
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: team
                    operator: In
                    values:
                      - green
      containers:
        - name: app
          image: busybox
          command: ["sh", "-c", "sleep 3600"]
```

---

**Apply blue and green:**

```bash
kubectl apply -f yellow-deploy.yaml
kubectl apply -f blue-deploy.yaml
kubectl apply -f green-deploy.yaml
kubectl get pods -o wide
```

**Expected output:**
```
NAME                             READY   STATUS    NODE
yellow-deploy-xxxxxxxxx-aaaaa     1/1     Running   3node
yellow-deploy-xxxxxxxxx-bbbbb     1/1     Running   3node
yellow-deploy-xxxxxxxxx-ccccc     1/1     Running   3node
blue-deploy-xxxxxxxxx-aaaaa       1/1     Running   3node-m02
blue-deploy-xxxxxxxxx-bbbbb       1/1     Running   3node-m02
blue-deploy-xxxxxxxxx-ccccc       1/1     Running   3node-m02
green-deploy-xxxxxxxxx-ddddd      1/1     Running   3node-m03
green-deploy-xxxxxxxxx-eeeee      1/1     Running   3node-m03
green-deploy-xxxxxxxxx-fffff      1/1     Running   3node-m03
```

**Verify isolation is strict — try deploying a plain pod with no toleration:**

```bash
kubectl run intruder --image=busybox -- sh -c "sleep 3600"
kubectl get pod intruder -o wide
```

**Expected output:**
```
NAME       READY   STATUS    NODE
intruder   0/1     Pending   <none>
```

The intruder pod cannot land on any nodes (taint on each nodes blocks it). It is stuck Pending with no viable node.

```bash
kubectl describe pod intruder | grep -A5 Events
```

**Expected output:**
```
Events:
  Warning  FailedScheduling  ...  0/3 nodes are available:
  1 node(s) had untolerated taint {team: blue},
  1 node(s) had untolerated taint {team: green},
 1 node(s) had untolerated taint {team: yellow},
```

**Cleanup intruder:**
```bash
kubectl delete pod intruder --grace-period=0 --force
```

**What each mechanism contributed:**

| Mechanism | Role | Without it |
|---|---|---|
| Taint on node | Repels pods without matching toleration | Other pods could land on the node |
| Toleration on pod | Permits entry to the tainted node | Pod goes Pending — cannot reach its node |
| Node Affinity on pod | Attracts pod strictly to its designated node | Pod could land on any untainted node |

---

### Step 13: Final Cleanup

```bash
# Remove taints first (must be done before label removal)
kubectl taint nodes 3node team=yellow:NoSchedule-
kubectl taint nodes 3node-m02 team=blue:NoSchedule-
kubectl taint nodes 3node-m03 team=green:NoSchedule-

# Remove labels
kubectl label nodes 3node team-
kubectl label nodes 3node-m02 team- storage-
kubectl label nodes 3node-m03 team- storage-

# Remove all deployments
kubectl delete deployment --all

# Verify clean state
kubectl get all
kubectl get nodes --show-labels
```

---

## Experiments to Try

1. **Prove tolerations alone don't guarantee placement:**
   ```bash
   # Taint 3node-m02 with team=blue
   # Deploy a pod with team=blue toleration but NO node affinity
   # Watch it land on 3node-m03 or even 3node — toleration only unblocked 3node-m02,
   # it did not attract the pod there
   ```

2. **Prove node affinity alone doesn't prevent intruders:**
   ```bash
   # Remove the taint from 3node-m02 but keep the label
   # Deploy blue-deploy (affinity only, no taint) and a plain pod
   # Watch the plain pod also land on 3node-m02 — nothing blocks it
   ```

3. **Test IgnoredDuringExecution:**
   ```bash
   kubectl apply -f na-required.yaml
   # Wait for pods to run on 3node-m02
   kubectl label nodes 3node-m02 storage-
   kubectl get pods -o wide
   # Pods keep running — IgnoredDuringExecution, no eviction
   # Delete one pod and watch the replacement go Pending
   kubectl delete pod <pod-name> --grace-period=0 --force
   ```

4. **Additive weights — double match:**
   ```bash
   kubectl label nodes 3node-m02 storage=ssd env=prod
   # Deploy na-combined.yaml
   # 3node-m02 matches BOTH preferences: weight 10 + 5 = 15
   # 3node-m03 matches only hdd: weight 5
   # 3node-m02 gets significantly more pods
   ```

5. **nodeSelectorTerms OR between terms:**
   ```yaml
   nodeSelectorTerms:
     - matchExpressions:         # Term 1
         - key: storage
           operator: In
           values: [ssd]
     - matchExpressions:         # Term 2 — OR with Term 1
         - key: team
           operator: Exists
   # Pod qualifies if (storage=ssd) OR (team key exists on node)
   ```

---

## Common Questions

### Q: Where exactly does `affinity:` go in a Deployment YAML?

**A:** Under `spec.template.spec` (the pod spec), same level as `containers`:

```yaml
spec:                    # Deployment spec
  template:
    spec:                # Pod spec
      affinity:          # ← correct ✅
        nodeAffinity: ...
      containers:
      - name: ...
```

### Q: Can I use both `nodeSelector` and `nodeAffinity` together?

**A:** Yes — both must be satisfied. A node must match `nodeSelector` AND all
`nodeAffinity` rules. In practice if you are using `nodeAffinity` there is no
reason to also use `nodeSelector` — `nodeAffinity` is a strict superset.

### Q: What happens if a node label is removed after pods are running?

**A:** Nothing — both rule types have `IgnoredDuringExecution`. Running pods
are not evicted. Only newly scheduled or rescheduled pods re-evaluate the rules.

### Q: Is preferred weight distribution always exact?

**A:** No — weight is one of several factors the scheduler considers. Resource
availability, current pod spread, and other constraints all influence the final
score. The distribution is approximate.

### Q: What is the difference between `NotIn` anti-affinity and Taints?

**A:** Both prevent pods from landing on specific nodes but through different
mechanisms. Taints are node-driven — the node rejects pods without a matching
toleration. `NotIn`/`DoesNotExist` is pod-driven — the pod avoids nodes with
specific labels. Use taints when the node itself must be protected from all
unwanted pods. Use `NotIn` when the pod has the avoidance requirement.

---

## What You Learned

In this lab, you:
- ✅ Labelled nodes and used `nodeSelector` for simple single and multi-label scheduling
- ✅ Observed AND logic, Pending state, and non-retroactive label removal
- ✅ Wrote `requiredDuringSchedulingIgnoredDuringExecution` Node Affinity rules
- ✅ Applied OR logic via `values` and AND logic via `matchExpressions`
- ✅ Deployed with `preferredDuringSchedulingIgnoredDuringExecution` and weighted distribution
- ✅ Used all six operators including `NotIn` and `DoesNotExist` for node anti-affinity
- ✅ Combined `required` + `preferred` rules in one manifest
- ✅ Achieved guaranteed pod isolation using Taints + Tolerations + Node Affinity

**Key Takeaway:** `nodeSelector` is simple but limited — equality match only,
hard rules only, no OR. `nodeAffinity` resolves every limitation. For
guaranteed pod isolation, all three mechanisms are required together —
tolerations permit entry, affinity attracts the pod, and taints block intruders.
No single mechanism achieves true isolation alone.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get nodes --show-labels` | List all nodes with all labels |
| `kubectl label nodes <n> key=value` | Add or set a label on a node |
| `kubectl label nodes <n> key-` | Remove a label (trailing `-`) |
| `kubectl label nodes <n> key=value --overwrite` | Update an existing label |
| `kubectl taint nodes <n> key=value:Effect` | Add a taint to a node |
| `kubectl taint nodes <n> key=value:Effect-` | Remove a taint (trailing `-`) |
| `kubectl explain pod.spec.affinity.nodeAffinity` | Browse nodeAffinity field docs |
| `kubectl explain pod.spec.nodeSelector` | Browse nodeSelector field docs |

---

## CKA Certification Tips

✅ **`affinity:` placement — most common exam mistake:**
```yaml
spec:              # Deployment spec — WRONG level ❌
  affinity: ...

spec:              # Deployment spec
  template:
    spec:          # Pod spec — CORRECT ✅
      affinity: ...
```

✅ **KOVE for matchExpressions:**
```
K → key      O → operator      V → values      (E → effect is for tolerations only)
```

✅ **AND vs OR — lock this in:**
```
Multiple matchExpressions items  = AND between conditions
Multiple values in one item      = OR between values
Multiple nodeSelectorTerms       = OR between terms
```

✅ **`Exists` / `DoesNotExist` — never include `values:`:**
```yaml
# ❌ Validation error
- key: high-memory
  operator: Exists
  values: ["true"]

# ✅ Correct
- key: high-memory
  operator: Exists
```

✅ **`Gt` / `Lt` require numeric string values on both sides:**
```bash
kubectl label node 3node-m02 cpu=8       # label: numeric string
```
```yaml
- key: cpu
  operator: Gt
  values:
    - "4"                                 # value: numeric string
```

✅ **Use `kubectl explain` — no internet needed in the exam:**
```bash
kubectl explain pod.spec.affinity.nodeAffinity
kubectl explain pod.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution
```

✅ **Guaranteed isolation pattern — remember all three pieces:**
```
Taint on node      → repels unwanted pods
Toleration on pod  → permits entry to tainted node
Node Affinity      → attracts pod to designated node
```

✅ **Generate deployment YAML fast, add affinity manually:**
```bash
kubectl create deployment myapp --image=busybox --replicas=3 \
  --dry-run=client -o yaml -- sh -c "sleep 3600" > deploy.yaml
```

---

## Troubleshooting

**Pods stuck in Pending with nodeSelector or required affinity?**
```bash
kubectl describe pod <pod-name> | grep -A8 Events
# Look for: "didn't match Pod's node affinity/selector"
# Verify node has the expected label
kubectl get nodes --show-labels | grep <key>
```

**Validation error on apply?**
```bash
kubectl apply -f <file> --dry-run=client    # validate without applying
# Common causes:
# 1. values: field present on Exists/DoesNotExist operator
# 2. affinity: at wrong YAML level
# 3. nodeSelectorTerms: wrapper missing
```
