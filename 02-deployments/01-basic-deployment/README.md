# Demo: 02-deployments/01-basic-deployment — Basic Deployment

## Lab Overview

This lab introduces Kubernetes Deployments, the most common way to run
applications in Kubernetes. A Deployment manages a set of identical pods,
ensuring your application stays running and healthy — building directly on
everything you already know about Pods from `01-core-concepts`.

In this hands-on lab, you'll create your first Deployment running nginx,
understand exactly how it creates and owns a ReplicaSet and Pods underneath
it (down to the actual labeling mechanism that makes it work), and observe
self-healing in action. This demo deliberately stays scoped to a *stable*
Deployment — no updates, no strategies yet. Once you understand how a
Deployment manages a single, unchanging version, `02-rolling-update-recreate`
covers what happens when the pod template *changes*, and
`03-deployment-strategies` covers Blue-Green and Canary patterns built on
top of that.

**What you'll do:**
- Create a Deployment with 3 nginx replicas
- Understand the Deployment → ReplicaSet → Pod hierarchy, and the actual label-based mechanism that implements it
- Explore how Kubernetes maintains desired state through self-healing
- Learn essential kubectl commands for managing Deployments
- Examine Deployment specifications and both forms of selector syntax

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-core-concepts` (this demo assumes you already understand Pod anatomy, admission control, and the kubelet/container-runtime split covered there — none of that is re-explained here)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create and deploy a basic Kubernetes Deployment
2. ✅ Write a Deployment selector using both `matchLabels` and `matchExpressions`, and know when each is appropriate
3. ✅ Explain every field in a Deployment spec, including what's deferred to `02-rolling-update-recreate` and `03-deployment-strategies`
4. ✅ Explain the `pod-template-hash` mechanism that actually connects a Deployment to its ReplicaSet and Pods
5. ✅ Walk through the full end-to-end flow of creating/scaling a Deployment, and how it hands off to the Pod-creation flow already covered in `01-core-concepts`
6. ✅ Verify Deployment status and health
7. ✅ Observe Kubernetes self-healing in action, and explain which controller is actually doing it
8. ✅ Scale Deployments up and down, including to zero
9. ✅ Properly clean up Kubernetes resources
10. ✅ Explain what `kubectl describe rs` reveals about a ReplicaSet's ownership, and why scaling or editing it directly doesn't stick
11. ✅ Change a Deployment's selector without a downtime window, using `--cascade=orphan`

## Directory Structure

```
02-deployments/01-basic-deployment/
├── README.md
├── src/
│   ├── 01-nginx-deploy.yaml    # Basic nginx deployment with 3 replicas
│   └── break-fix/
│       ├── 01-selector-template-mismatch.yaml    # Embedded inline in README — not generated on disk
│       └── 02-immutable-selector-patch.yaml      # Embedded inline in README — not generated on disk
├── 01-basic-deployment-anki.csv
└── 01-basic-deployment-quiz.md
```

---

## Recall Check — 04-kubectl-essentials

Answer from memory before continuing — no peeking at the previous demo.

1. What's the real mechanical difference between `--dry-run=client` and `--dry-run=server`?
2. You suspect a pod failed to schedule a few minutes ago, but it's since disappeared. What's the risk of checking `kubectl get events` right now, and which of the two events commands sorts chronologically by default?
3. A container has no shell and won't `exec` into. What command lets you attach a debug container to it without restarting it?

<details>
<summary>Answers</summary>

1. `--dry-run=server` runs the object through the full admission control pipeline (ResourceQuota, LimitRange, webhooks) before discarding it; `--dry-run=client` never leaves your machine and has no cluster awareness at all.
2. Events expire (1 hour by default, via the API server's `--event-ttl`) — if the failure happened outside that window, they're already gone. `kubectl events` sorts chronologically by default; `kubectl get events` doesn't and needs `--sort-by`.
3. `kubectl debug` — it attaches a temporary ephemeral container to the running pod, no restart required.

</details>

---

## Concepts

### What is a Deployment?

A Deployment is a Kubernetes object that manages a set of identical pods.
It ensures that a specified number of pod replicas are running at all
times. If a pod fails or is deleted, the Deployment's underlying ReplicaSet
(see **Deployment Internals** below for the actual mechanism) automatically
creates a new one to maintain the desired state.

**The Kubernetes Hierarchy:**

```
Deployment (nginx-deploy)
    │
    └── ReplicaSet (nginx-deploy-xxxxxxxxx)
            │
            ├── Pod 1 (nginx-deploy-xxxxxxxxx-xxxxx)
            ├── Pod 2 (nginx-deploy-xxxxxxxxx-xxxxx)
            └── Pod 3 (nginx-deploy-xxxxxxxxx-xxxxx)
```

**Responsibilities:**
- **Deployment** — manages updates, rollbacks, and desired state declarations
- **ReplicaSet** — ensures the specified number of pod replicas are running
- **Pods** — run the actual containers, exactly as covered in full in `01-core-concepts/03-pod-container-basics`

**Why Use Deployments Instead of Pods?**

Deployments provide:
- **Self-healing** — automatic pod restart if they crash or are deleted
- **Scaling** — easy to change the number of replicas
- **Rolling updates** — update applications with zero downtime (full mechanics in `02-rolling-update-recreate`)
- **Rollback** — revert to previous versions if updates fail (also `02-rolling-update-recreate`)
- **Declarative management** — describe what you want, Kubernetes makes it happen

This is the same "naked pods have no self-healing" point from
`01-core-concepts/03-pod-container-basics`, from the other side: a
Deployment is exactly the controller that demo told you to use instead of
creating pods directly.

---

### Anatomy of a Deployment — What a Deployment Can Contain

| Field | One-line summary |
|---|---|
| `apiVersion` | `apps/v1` — not `v1`, unlike Pod. See **apiVersion: why `apps/v1`?** below |
| `metadata.name` | The Deployment's own name — becomes the prefix for its ReplicaSet's and Pods' names |
| `metadata.namespace` | Which namespace the Deployment lives in — same namespace scoping from Demo 02 of `01-core-concepts` |
| `metadata.labels` | Labels on the Deployment object *itself* — separate from, and easy to confuse with, `spec.template.metadata.labels` below |
| `spec.replicas` | Desired number of pod replicas |
| `spec.selector` | How the Deployment identifies which pods belong to it — immutable once set |
| `spec.template` | The full Pod template — identical in shape to a standalone Pod spec |
| `spec.strategy` *(deferred)* | Controls how pods are replaced when the template changes — full treatment in `02-rolling-update-recreate` |
| `spec.revisionHistoryLimit` *(deferred)* | How many old ReplicaSets to retain for rollback — `02-rolling-update-recreate` |
| `spec.minReadySeconds` | How long a new pod must stay Ready before it's considered available |
| `spec.progressDeadlineSeconds` | How long the controller waits for progress before flagging the Deployment as stuck |
| `spec.paused` *(deferred)* | Freezes the controller from acting on template changes — `02-rolling-update-recreate` |

Full explanation of each field follows below.

**`apiVersion: apps/v1`** — see **apiVersion: why `apps/v1`?** immediately
below for the full explanation of why this differs from a Pod's `v1`.

**`metadata.name`, `metadata.namespace`** — The Deployment's own identity.
`metadata.name` (`nginx-deploy` in this demo) becomes the literal prefix
for the ReplicaSet's name, which in turn prefixes every Pod's name — this
is why `kubectl get pods` in this demo shows names starting with
`nginx-deploy-`.

**`metadata.labels`** — Labels on the Deployment object itself. This is
easy to mix up with `spec.template.metadata.labels` (below), but they are
two completely separate label sets serving different purposes: this one
lets you find/select the *Deployment* object itself (`kubectl get
deployments -l ...`); `spec.template.metadata.labels` is what gets stamped
onto every *Pod* it creates, and is what `spec.selector` actually matches
against. Worth knowing: `kubectl apply -f` does **not** set any labels on
the Deployment object itself unless you put them in the YAML's own
`metadata.labels` — this demo's `01-nginx-deploy.yaml` doesn't, which is
exactly why `kubectl get deploy --show-labels` shows `<none>` for the
Deployment row even though every Pod clearly has labels.

**`spec.replicas`** — The desired number of pod replicas. This is the
single number the ReplicaSet controller continuously reconciles the actual
pod count against — delete a pod manually and it comes back purely because
the *actual* count no longer matches this *desired* count.

**`spec.selector`** — How the Deployment identifies which pods belong to
it. This field is what makes the Deployment→ReplicaSet→Pod chain actually
work, and it comes in two syntactic forms covered fully below under
**Selector Syntax**. Once set at creation, `spec.selector` is immutable —
the same rule you've already seen apply to Pods' own immutable fields in
`01-core-concepts`.

**`spec.template`** — A full Pod template (`metadata` + `spec`), identical
in shape to everything covered in `01-core-concepts/03-pod-container-basics`'s
Anatomy of a Pod / Anatomy of a Container sections — nothing about what a
Pod can contain changes just because a Deployment is creating it. The only
new thing here is that `template.metadata.labels` must satisfy
`spec.selector` (this demo's Break-Fix will be built around getting that
wrong). See **How a Pod Spec Fits Inside a Deployment** below for a full
visual breakdown of exactly where this nests.

**`spec.strategy`** *(deferred)* — Controls *how* pods are replaced when
the template changes: `RollingUpdate` (default) or `Recreate`. Since this
demo never changes the template after creation, strategy has nothing to do
yet — full treatment, including `maxSurge`/`maxUnavailable`, is
`02-rolling-update-recreate`'s entire subject.

**`spec.revisionHistoryLimit`** *(deferred)* — How many old ReplicaSets to
retain for rollback purposes (default 10). Only meaningful once updates
exist to have a history of — covered in `02-rolling-update-recreate`.

**`spec.minReadySeconds`** — How long a newly created pod must stay
`Ready` before it's considered available. Default `0` (available the
instant it's ready). Raising this adds a soak period per pod — useful if a
pod can pass its readiness probe before it's actually fully warmed up.

**`spec.progressDeadlineSeconds`** — How long the Deployment controller
waits for progress (default 600s) before marking the Deployment as failed
to progress in its `Conditions`. This is a stuck-rollout detector, not
something that halts or reverts anything by itself — it only changes what
`kubectl describe` reports.

**`spec.paused`** *(deferred)* — Freezes the Deployment controller from
acting on template changes. Meaningful in the context of controlled
rollouts — covered alongside `kubectl rollout pause`/`resume` in
`02-rolling-update-recreate`.

---

### apiVersion: why `apps/v1`?

Every Pod you've written so far uses `apiVersion: v1` — the **core** API
group, which has no group name at all in the field (it's written just
`v1`). A Deployment uses `apiVersion: apps/v1` — the **`apps`** API group.
This isn't arbitrary: Kubernetes organizes its object types into API
groups, and `core`/`v1` is reserved for the small set of foundational,
original object types (Pod, Service, Namespace, ConfigMap, Secret, Node).
Everything built as a *controller that manages other objects* —
Deployment, ReplicaSet, StatefulSet, DaemonSet — lives in the `apps` group
instead, versioned independently from the core group. Practically, this
means:
- Getting the `apiVersion` wrong is a schema-validation failure, not a
  subtle bug — `apiVersion: v1` on a `kind: Deployment` is rejected
  outright, since `v1` (core) has no `Deployment` kind at all.
- `kubectl explain <kind>` (from `04-kubectl-essentials`) will show you the
  correct `apiVersion` for any kind if you're ever unsure — this is
  exactly the kind of lookup `kubectl explain` exists for.

---

### How a Pod Spec Fits Inside a Deployment

```
Deployment
├── apiVersion: apps/v1          ← "apps" group — see above
├── kind: Deployment
├── metadata:                    ← the Deployment's OWN identity/labels
│   ├── name: nginx-deploy
│   └── labels: {}               ← separate from template labels below
└── spec:
    ├── replicas: 3
    ├── selector:
    │   └── matchLabels: {app: nginx}
    └── template:                ← ← ← THIS is a full Pod spec, verbatim
        ├── metadata:
        │   └── labels: {app: nginx}   ← must satisfy selector above
        └── spec:                      ┐
            ├── restartPolicy           │  Everything from here down is
            ├── containers:             │  IDENTICAL in shape to a
            │   ├── name                │  standalone Pod's spec, covered
            │   ├── image                │  fully in 01-core-concepts/
            │   ├── command/args        │  03-pod-container-basics —
            │   ├── ports                │  nothing new to learn here,
            │   ├── env                  │  just nested one level deeper
            │   └── resources           │  under spec.template instead of
            └── ...every other Pod      │  being the top-level object.
                spec field              ┘
```

The one-sentence version: **`spec.template` *is* a Pod spec** — everything
you already know from `01-core-concepts` about what a Pod can contain
applies unchanged, just indented one level further because a Deployment is
now the top-level object instead of the Pod itself.



**`matchLabels` — the simple, common form:**
```yaml
spec:
  selector:
    matchLabels:
      app: nginx
```
This is a plain equality check: the Deployment manages every pod whose
`metadata.labels` includes `app: nginx`, nothing more. This is what
`02-rolling-update-recreate` and `03-deployment-strategies` both use
throughout, and it's what you should reach for by default — it covers the
overwhelming majority of real-world cases.

**`matchExpressions` — the same result, expressed with operators:**
```yaml
spec:
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - nginx
```
Functionally identical to the `matchLabels` example above, but written
using an explicit operator form. `matchExpressions` supports logic
`matchLabels` cannot express at all:
- `In` — value is in a given list
- `NotIn` — value is not in a given list
- `Exists` — the key is present, regardless of value
- `DoesNotExist` — the key is absent

Reach for `matchExpressions` specifically when you need one of those three
richer operators — `NotIn`/`Exists`/`DoesNotExist` have no `matchLabels`
equivalent at all. For a plain equality match like this demo's, `matchLabels`
is simpler and is what you'll see used consistently elsewhere in this
series.

---

### Deployment Internals — The pod-template-hash Mechanism

The Deployment→ReplicaSet→Pod hierarchy isn't just an organizational
diagram — it's implemented with a specific, inspectable label.

When the Deployment controller creates a ReplicaSet, it computes a hash of
the pod template (`spec.template`) and adds it as a label —
`pod-template-hash` — to three places: the ReplicaSet's own name (that's
the `xxxxxxxxx` suffix you'll see in every ReplicaSet and Pod name in this
demo's output), the ReplicaSet's `spec.selector`, and every Pod the
ReplicaSet creates. This is exactly what makes a ReplicaSet's selector able
to claim *only* the pods it created, even though your own
`spec.selector.matchLabels` (`app: nginx`) is broader and would otherwise
match pods from a completely different ReplicaSet too.

```
Deployment's own selector:        app: nginx
                                   (what YOU wrote — matches broadly)

ReplicaSet's actual selector:     app: nginx, pod-template-hash: 7d9f8b6c4
                                   (auto-generated — matches precisely,
                                    only pods from THIS ReplicaSet)
```

This mechanism is what makes the entire rolling-update model in
`02-rolling-update-recreate` possible: change the pod template, and its
hash changes, which means the Deployment controller creates a **new**
ReplicaSet with a new hash — rather than trying to somehow mutate the
existing one — while the old ReplicaSet (and its now-mismatched hash)
sticks around at 0 replicas for rollback. Nothing about that mechanism is
new; it's this same hash-labeling behavior you'll observe directly in this
demo's own Step 4, just without a second ReplicaSet to compare against yet.

**Two different suffixes, easy to conflate.** A real Pod name from this
demo looks like `nginx-deploy-85f7d4dd78-29r6g` — that's *two* separate
generated suffixes stacked on top of `metadata.name`, not one:
- `85f7d4dd78` is the **ReplicaSet's** `pod-template-hash`, exactly as
  described above — every Pod from this ReplicaSet shares this same
  segment.
- `29r6g` is a **second, separate random suffix**, generated fresh for
  *this individual Pod* by the ReplicaSet controller when it creates it —
  every Pod gets its own different one of these, which is precisely what
  keeps `nginx-deploy-85f7d4dd78-29r6g` and `nginx-deploy-85f7d4dd78-2fhcd`
  distinct from each other despite sharing the same ReplicaSet and the same
  `pod-template-hash`. This part has nothing to do with the pod template's
  content — it's purely there to guarantee name uniqueness among sibling
  Pods.

---

### End-to-End: What Happens When You Create or Scale a Deployment

This section picks up exactly where `01-core-concepts/03-pod-container-basics`'s
own End-to-End section left off — that demo covered everything from
"a Pod object exists with no node assigned" through to a running container;
none of that is repeated here. What's new at this layer is the extra
reconciliation hop above the Pod.

**Creating a Deployment.** `kubectl apply` sends the Deployment object
through the same authentication → authorization → admission control →
schema validation → etcd persistence pipeline already covered for Pods —
Deployments go through the identical pipeline, just for a different object
kind. Once persisted, the **Deployment controller** (a control loop running
inside kube-controller-manager, watching for Deployment objects) notices it,
computes the `pod-template-hash` described above, and creates a ReplicaSet
— setting itself as that ReplicaSet's **owner** via an owner reference (refer `Controlled By` parameter in `kubectl describe`). This
owner reference is the mechanism behind cascading deletes: delete the
Deployment, and Kubernetes' garbage collector deletes everything that
declares the Deployment as its owner, all the way down.

**The ReplicaSet controller takes over from there.** A separate control
loop — the **ReplicaSet controller**, also inside kube-controller-manager —
watches for ReplicaSet objects independently of the Deployment controller.
It compares the ReplicaSet's `spec.replicas` against how many Pods
currently carry its `pod-template-hash`-qualified selector, and creates or
deletes Pod objects to close that gap — setting itself as the owner of each
Pod it creates. From the moment a Pod object exists, everything is
identical to `01-core-concepts`'s End-to-End flow: kube-scheduler assigns a
node, kubelet notices, the pause container gets created, the container
runtime pulls the image and starts your container — none of that changes
because a Deployment happens to be three levels up the ownership chain.

**Scaling.** `kubectl scale deployment --replicas=N` only ever changes one
number: the Deployment's `spec.replicas`. The Deployment controller copies
that number down to the ReplicaSet's own `spec.replicas`; the ReplicaSet
controller is the one that actually creates or deletes Pod objects to
match it. The Deployment itself never touches a Pod directly, at any point
— it's strictly a two-hop chain of command.

**Self-healing.** When you manually delete one of the three Pods in this
demo, **neither the Deployment nor its controller does anything at all.**
The ReplicaSet controller is the one watching Pod count against
`spec.replicas`; it notices the mismatch (2 Pods instead of 3, still
carrying its `pod-template-hash`) and creates a replacement immediately.
This is worth being precise about, since "the Deployment self-heals" is a
common but slightly imprecise way to describe what's actually two
controllers, one level apart, each reconciling only its own tier.

---

## Don't Manage a Deployment's ReplicaSet Directly

Everything above establishes that the ReplicaSet controller—not the Deployment—is what actually watches and reconciles Pod count. A natural follow-up question is: what happens if *you* try to act directly on a Deployment-owned ReplicaSet, bypassing the Deployment entirely? Official Kubernetes documentation is explicit that you shouldn't, because the Deployment remains the **source of truth** for the application's desired state.

* **Scaling it directly** (`kubectl scale replicaset <name> --replicas=N`) — the Deployment controller continuously reconciles the ReplicaSet's `spec.replicas` back to whatever the **Deployment's** `spec.replicas` specifies. Your manual change is overwritten, typically within seconds—you'll see the ReplicaSet's replica count briefly change before returning to the Deployment's desired value. This demo's **Break-Fix Error-3** demonstrates this behavior.
* **Editing its Pod template directly** — a Deployment treats each ReplicaSet as a specific rollout revision rather than something to modify in place. Any change to the application's desired configuration—such as the container image, environment variables, resource requirements, or Pod labels—should be made on the **Deployment**, not on its managed ReplicaSet or individual Pods. The Deployment then creates a **new ReplicaSet** representing the updated revision and gradually replaces the old one through a rolling update. Editing a Deployment-managed ReplicaSet directly is unsupported and can be rejected or leave it inconsistent with the Deployment's desired state.
* **Deleting it directly** — the Deployment controller notices that the expected ReplicaSet is missing and simply creates a replacement ReplicaSet from the Deployment's current `spec.template`. You haven't permanently removed the application's controller-managed state—you've only forced the Deployment to recreate one of its managed resources.

The practical rule is simple: **treat the Deployment as the only control surface.** Any change to your application's desired state—replica count, container image, resources, labels, or environment variables—should be made on the **Deployment**, not on the ReplicaSet. The ReplicaSet is an implementation detail created and managed by the Deployment to maintain the desired number of Pods and support rolling updates.

---

### Working Around an Immutable Selector — `--cascade=orphan`

`spec.selector` is immutable (as demonstrated earlier in this demo and in **Break-Fix Error-2**). When a Deployment's selector genuinely needs to change, the standard approach is to create a **new** Deployment with the desired selector and migrate traffic using Kubernetes' normal rolling update mechanisms. Simply deleting and recreating the Deployment can briefly remove the managing controller and, depending on how it is performed, may also terminate the existing ReplicaSet and Pods.

`kubectl delete deployment <name> --cascade=orphan` provides an alternative deletion behavior. Instead of deleting the entire ownership hierarchy, Kubernetes removes **only** the Deployment object while leaving its ReplicaSet and Pods running by orphaning them (removing their owner reference). This avoids immediately terminating the running workload and can be useful during advanced recovery, controller migration, or ownership transfer scenarios.

> **Note:** `--cascade=orphan` is an advanced ownership-preservation mechanism rather than a common solution for changing Deployment selectors. Although Kubernetes controllers can adopt orphaned resources under specific conditions, this is not the typical method for migrating to a new selector. In practice, selector changes are usually handled by creating a new Deployment and performing a standard rolling update. Orphaning is more commonly used to preserve child resources while removing a parent object—for example, `kubectl delete cronjob backup --cascade=orphan` removes the CronJob while allowing existing Jobs and Pods to continue running, or when removing/replacing a custom controller or Operator without deleting the workloads it manages.

---

### Minimal and Essential Deployment YAML

**Deployment, using `matchLabels`**

**`src/01-nginx-deploy.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.30.4
```

**The same Deployment, using `matchExpressions` instead** (functionally
identical — shown so you can see both forms produce the same running
result):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
spec:
  replicas: 3
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.30.4
```

---

## Lab Step-by-Step Guide

### Step 1: Create the Deployment

```bash
cd 02-deployments/01-basic-deployment/src
kubectl apply -f 01-nginx-deploy.yaml
```

**Expected output:**
```
deployment.apps/nginx-deploy created
```

---

### Step 2: Verify Deployment Creation

```bash
kubectl get deployments
```

**Expected output:**
```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deploy   3/3     3            3           10s
```

**Understanding the columns:**
- `READY` — ready pods / desired pods (3/3 means all 3 are ready)
- `UP-TO-DATE` — pods matching the current template
- `AVAILABLE` — pods that have satisfied `minReadySeconds` and are available to serve requests
- `AGE` — time since the Deployment was created

---

### Step 3: View the ReplicaSet and Pods

```bash
kubectl get replicasets
# Or use the shorthand
kubectl get rs
```

**Expected output:**
```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-xxxxxxxxx    3         3         3       20s
```

```bash
kubectl get pods
```

**Expected output:**
```
NAME                            READY   STATUS    RESTARTS   AGE
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   0          30s
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   0          30s
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   0          30s
```

Notice the ReplicaSet name and every Pod name share the same `xxxxxxxxx`
suffix — that's the `pod-template-hash` from **Deployment Internals**
above, made visible.

**A faster way to see the whole hierarchy at once — `kubectl get all`:**
```bash
kubectl get all
```

**Expected output:**
```
NAME                                READY   STATUS    RESTARTS   AGE
pod/nginx-deploy-85f7d4dd78-29r6g   1/1     Running   0          3m7s
pod/nginx-deploy-85f7d4dd78-2fhcd   1/1     Running   0          3m7s
pod/nginx-deploy-85f7d4dd78-bdkt9   1/1     Running   0          3m7s

NAME                          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/kubernetes            ClusterIP   10.96.0.1       <none>        443/TCP   129d

NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/nginx-deploy   3/3     3            3           3m7s

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/nginx-deploy-85f7d4dd78   3         3         3       3m7s
```

`kubectl get all` is genuinely convenient, but "all" is narrower than it
sounds — it only covers a fixed set of common namespaced object types
(Pods, Services, Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs,
CronJobs, and a few more). It deliberately does **not** include
ConfigMaps, Secrets, Ingress, PersistentVolumeClaims, or any CRD-based
object — you still need to `kubectl get` those individually or by name.
Also worth noting: `service/kubernetes` shows up here, but not because
it's namespace-agnostic — the API server's own ClusterIP service only
ever lives in the **`default`** namespace (it's created and pinned there
by the control plane itself, regardless of cluster). It appears in this
output only because this lab never switches away from `default`; running
`kubectl get all -n <other-namespace>` would not show it at all.

**Now look at the ReplicaSet in detail — this is where the ownership
chain from End-to-End stops being theory:**

```bash
kubectl describe rs nginx-deploy-85f7d4dd78
```

**Expected output (trimmed to what's worth reading):**

```
Name:           nginx-deploy-85f7d4dd78
Namespace:      default
Selector:       app=nginx,pod-template-hash=85f7d4dd78
Labels:         app=nginx
                pod-template-hash=85f7d4dd78
Annotations:    deployment.kubernetes.io/desired-replicas: 3
                deployment.kubernetes.io/max-replicas: 4
                deployment.kubernetes.io/revision: 1
Controlled By:  Deployment/nginx-deploy
Replicas:       3 current / 3 desired
Pods Status:    3 Running / 0 Waiting / 0 Succeeded / 0 Failed
Pod Template:
  Labels:  app=nginx
           pod-template-hash=85f7d4dd78
  Containers:
   nginx:
    Image:      nginx:1.30.4
    Port:       80/TCP
    Host Port:  0/TCP
Events:
  Type    Reason            Age   From                   Message
  ----    ------            ----  ----                   -------
  Normal  SuccessfulCreate  9m    replicaset-controller  Created pod: nginx-deploy-85f7d4dd78-29r6g
  Normal  SuccessfulCreate  9m    replicaset-controller  Created pod: nginx-deploy-85f7d4dd78-2fhcd
  Normal  SuccessfulCreate  9m    replicaset-controller  Created pod: nginx-deploy-85f7d4dd78-bdkt9
```

Every field here explained, since several of them only make sense with
what you already know from **Deployment Internals** and **End-to-End**:

- **`Selector: app=nginx,pod-template-hash=85f7d4dd78`** — this is the
  exact narrower, auto-generated selector from **Deployment Internals**
  above, now visible directly rather than inferred from a `jsonpath` query
  (as Step 4 below does). Compare it to the *Deployment's* own selector
  (`app=nginx` alone, no hash) and the difference is right there.
- **`Controlled By: Deployment/nginx-deploy`** — the owner reference from
  **End-to-End**, one level up from what a Pod's own `describe` shows
  (`Controlled By: ReplicaSet/...`). Following `Controlled By` upward at
  each level is how you'd trace any Pod all the way back to the
  Deployment that ultimately owns it.
- **`Annotations: deployment.kubernetes.io/desired-replicas` /
  `max-replicas` / `revision`** — these three are written by the
  *Deployment* controller onto the ReplicaSet it owns, not by you and not
  by the ReplicaSet controller itself. `max-replicas` in particular is
  worth noticing: `4`, not `3` — this is `spec.replicas` (3) plus
  `maxSurge`'s default of 25% rounded up to 1 extra, the same
  `RollingUpdateStrategy` defaults you'll see again in Step 5's
  `describe deployment` output. `revision` mirrors the Deployment's own
  `deployment.kubernetes.io/revision` annotation, covered fully in `02-rolling-update-recreate`.
- **`Replicas: 3 current / 3 desired`** and **`Pods Status`** — the
  ReplicaSet controller's own view of its reconciliation target and
  actual state, the mechanism behind every self-healing and scaling
  observation in Steps 7–8 below.
- **`Events` — `SuccessfulCreate`, `From: replicaset-controller`** — the
  control loop from **End-to-End** naming itself directly in its own
  event log, the ReplicaSet-level equivalent of the
  `deployment-controller` events you'll see in Step 5.

---

### Step 4: See the pod-template-hash label directly

```bash
kubectl get pods --show-labels
```

**Expected output:**
```
NAME                            READY   STATUS    LABELS
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,pod-template-hash=xxxxxxxxx
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,pod-template-hash=xxxxxxxxx
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,pod-template-hash=xxxxxxxxx
```

```bash
# Compare: the Deployment's own selector vs. the ReplicaSet's actual selector
kubectl get deployment nginx-deploy -o jsonpath='{.spec.selector}'
echo
kubectl get rs -o jsonpath='{.items[0].spec.selector}'
echo
```

**Expected:** the Deployment's selector is just `{"matchLabels":{"app":"nginx"}}`
— exactly what you wrote. The ReplicaSet's selector additionally includes
`pod-template-hash` — confirming it's narrower and auto-generated, not
something you wrote yourself.

---

### Step 5: Examine Deployment and Pod details

```bash
kubectl describe deployment nginx-deploy
```

**Expected output (trimmed to the fields that matter most):**
```
Selector:               app=nginx
Replicas:               3 desired | 3 updated | 3 total | 3 available | 0 unavailable
StrategyType:           RollingUpdate
MinReadySeconds:        0
RollingUpdateStrategy:  25% max unavailable, 25% max surge
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
OldReplicaSets:  <none>
NewReplicaSet:   nginx-deploy-85f7d4dd78 (3/3 replicas created)
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  9m    deployment-controller   Scaled up replica set nginx-deploy-85f7d4dd78 from 0 to 3
```

Every value here explained:
- **`Selector`** — printed in the older `key=value` shorthand regardless of
  which syntax you actually wrote (`matchLabels` or `matchExpressions`) —
  `describe` always normalizes to this display form.
- **`Replicas: 3 desired | 3 updated | 3 total | 3 available | 0
  unavailable`** — five separate counters, not one number: `desired` is
  `spec.replicas`; `updated` is how many match the *current* template
  (relevant once updates exist); `total` is every Pod regardless of
  version; `available` have satisfied `minReadySeconds`; `unavailable` is
  the gap still being worked on. In this demo, with no updates yet, all of
  these are identical.
- **`RollingUpdateStrategy: 25% max unavailable, 25% max surge`** — these
  percentages are the *defaults* you get for free even though this demo's
  YAML never set `spec.strategy` at all; full meaning of `maxSurge`/
  `maxUnavailable` is `02-rolling-update-recreate`'s subject, not this
  demo's — noted here only because you'll see it in your own `describe`
  output regardless.
- **`Conditions` → `Available: True` / `Progressing: True`** — two
  independent health signals, not one. `Available` reflects whether enough
  Pods are currently up; `Progressing` reflects whether the controller is
  making forward progress toward the desired state (or has stalled, per
  `progressDeadlineSeconds` above). Both being `True` here just means
  "healthy and stable," not "actively doing something."
- **`OldReplicaSets: <none>` / `NewReplicaSet: nginx-deploy-85f7d4dd78`** —
  this is the exact same mechanism from **Deployment Internals** made
  visible in `describe` output: right now there's only ever one ReplicaSet
  for this Deployment, so `OldReplicaSets` is empty — this pair of fields
  is what actually holds the two ReplicaSets side-by-side during a rollout
  in `02-rolling-update-recreate`.
- **`Events`** — same Events mechanism already covered for Pods in
  `01-core-concepts`, just at the Deployment level: `deployment-controller`
  here is literally the name of the control loop from **End-to-End**
  above, reporting what it did.

```bash
# Get pod names
kubectl get pods

# Describe a specific pod (replace with actual pod name)
kubectl describe pod nginx-deploy-xxxxxxxxx-xxxxx
```

**Key sections:**
- **Labels:** `app=nginx`, `pod-template-hash=xxxxxxxxx`
- **Controlled By:** `ReplicaSet/nginx-deploy-xxxxxxxxx` — this is the owner reference from **End-to-End** above, made visible
- **Containers:** nginx container details
- **Events:** pod lifecycle events, exactly as covered in full in `01-core-concepts`

---

### Step 6: Check pod logs — and logs/exec directly on the Deployment

```bash
# Replace with your pod name
kubectl logs nginx-deploy-xxxxxxxxx-xxxxx
```

Since nginx just started, logs might be minimal. You should see nginx
startup messages — full explanation of nginx's own startup log lines is in
`01-core-concepts/03-pod-container-basics`'s command reference; the
mechanics of `kubectl logs` itself (the CRI path, `--previous`, etc.) are
covered there too and aren't repeated here.

**You don't actually need the pod name at all** — `kubectl logs` and
`kubectl exec` both accept a Deployment (or ReplicaSet) reference directly,
the same way `kubectl port-forward deployment/nginx-deploy` already worked
without naming a specific pod:

```bash
kubectl logs deployment/nginx-deploy
kubectl exec deployment/nginx-deploy -- nginx -v
```

**What's actually happening:** kubectl resolves `deployment/nginx-deploy`
to the Deployment's ReplicaSet, then picks **one arbitrary Pod** from it —
if you have 3 replicas, you get the logs/exec session for whichever one
kubectl happened to pick, not all three. This is genuinely convenient when
you don't care which specific replica you're looking at (e.g. all 3 are
running identical code), but the moment you need a *specific* pod — to
compare replicas, or to debug one that's behaving differently from its
siblings — naming the pod explicitly is still the right tool.

---

### Step 7: Experience self-healing

```bash
# Open a second terminal and watch pods in real-time
kubectl get pods -w

# In the first terminal, delete a pod (use an actual pod name)
kubectl delete pod nginx-deploy-xxxxxxxxx-xxxxx
```

**What you'll observe:**
1. The deleted pod transitions to `Terminating`
2. A new pod is immediately created
3. The new pod goes through: `Pending` → `ContainerCreating` → `Running`
4. Total pod count remains at 3

Press `Ctrl+C` in the second terminal to stop watching.

**Why this happens:** as covered in **End-to-End** above, this is the
ReplicaSet controller's own reconciliation loop — it continuously compares
actual Pod count (now 2, still carrying its `pod-template-hash`) against
desired count (`spec.replicas: 3`) and creates a replacement the moment
they diverge. The Deployment itself isn't involved in this step at all.

---

### Step 8: Scale up and down while watching

```bash
# Terminal 1
kubectl get pods -w

# Terminal 2
kubectl scale deployment nginx-deploy --replicas=5
kubectl get pods
# Scale back down
kubectl scale deployment nginx-deploy --replicas=2
```

**Observation:** scaling up creates new Pods carrying the exact same
`pod-template-hash` as the existing three — this is still the same
ReplicaSet, just told to reconcile against a new number. Scaling down
terminates Pods, again via the same ReplicaSet, not the Deployment acting
on Pods directly.

**A related but different operation — `kubectl rollout restart`:**
```bash
kubectl rollout restart deployment/nginx-deploy
```
This is not scaling and doesn't change `spec.replicas` at all — it
forces every existing Pod to be recreated (one at a time, respecting the
same `RollingUpdateStrategy` shown in Step 5) by patching a
`kubectl.kubernetes.io/restartedAt` timestamp annotation onto
`spec.template.metadata.annotations`. That's a genuine change to the Pod
template, not a bypass of it — and since `pod-template-hash` is computed
from the entire template, including its annotations, this small change
is enough to produce a **new** hash and a **new** ReplicaSet, exactly
like any other template edit covered in **Deployment Internals** above.
Run `kubectl get rs` immediately after a restart and you'll see it: a
fresh ReplicaSet name, not the same one reused.

Useful for picking up a changed ConfigMap/Secret that a Pod only reads at
startup, or simply forcing a fresh set of containers, without touching
the image or any other field a teammate reading the diff would need to
care about. The application-facing spec (image, env, resources) is
unchanged — only the template's metadata differs.

---

### Step 9: Edit the Deployment directly

```bash
kubectl edit deployment nginx-deploy
# Change replicas in the editor, save, and exit
kubectl get pods
```
Pods adjust automatically, via the same ReplicaSet reconciliation covered
above. `kubectl edit` isn't a separate reconciliation mechanism — once you
save, it sends the full modified object back to the API server as an
update (closer to `kubectl replace`'s semantics than `apply`'s 3-way
merge), and everything downstream of that is identical to any other write
to the object.

---

### Step 10: Scale to zero

```bash
kubectl scale deployment nginx-deploy --replicas=0
kubectl get pods
# All pods deleted but the deployment still exists
kubectl get deployments
```
`replicas: 0` deletes every Pod but keeps the Deployment object itself —
useful for temporarily stopping an application without losing its
configuration. Scale back up before continuing:
```bash
kubectl scale deployment nginx-deploy --replicas=3
```

---

### Step 11: Label verification

```bash
# Show pod labels
kubectl get pods --show-labels

# Filter pods by label — matches the Deployment's own selector, not the ReplicaSet's narrower one
kubectl get pods -l app=nginx
```

---

### Step 12: View Deployment as YAML

```bash
kubectl get deployment nginx-deploy -o yaml
```

**Expected output (trimmed to the fields worth understanding):**
```yaml
metadata:
  annotations:
    deployment.kubernetes.io/revision: "1"
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"apps/v1","kind":"Deployment", ...}
  generation: 6
  resourceVersion: "1668750"
  uid: c2f2b57b-0321-4ac3-9fa4-cdb7e6d42825
spec:
  progressDeadlineSeconds: 600
  replicas: 3
  revisionHistoryLimit: 10
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
status:
  availableReplicas: 3
  observedGeneration: 6
  readyReplicas: 3
  replicas: 3
  updatedReplicas: 3
```

Fields worth understanding, none of which you wrote yourself:
- **`kubectl.kubernetes.io/last-applied-configuration`** — kubectl's own
  bookkeeping annotation, storing exactly what you last applied. This is
  what makes `kubectl apply` (as opposed to `kubectl create`/`replace`)
  able to compute a proper 3-way diff on the *next* `apply` — it compares
  this stored version, the live object, and your new file, rather than
  just blindly overwriting.
- **`generation`** — increments every time you change `spec` (this shows
  `6` after this demo's several `scale`/`edit` operations). Compare this
  to `status.observedGeneration`: when they match, the controller has
  fully processed your latest change; a persistent mismatch would mean the
  controller is behind or stuck.
- **`resourceVersion`** — etcd's own internal version counter for this
  object, used for optimistic concurrency control (so two simultaneous
  updates to the same object don't silently clobber each other). Not
  something you ever set yourself.
- **`uid`** — a cluster-wide unique identifier for this exact object
  instance. If you delete `nginx-deploy` and create a new Deployment with
  the identical name, it gets a **new** `uid` — this is the real
  underlying identity, not the name.
- **`spec.strategy` / `spec.revisionHistoryLimit` / `spec.progressDeadlineSeconds`**
  — all three appear here fully populated with their default values, even
  though this demo's own YAML never set any of them — confirms the
  API-server-side defaulting behavior mentioned back in **Minimal and
  Essential Deployment YAML**.
- **`status.availableReplicas` / `readyReplicas` / `replicas` /
  `updatedReplicas`** — the same set of counters `kubectl describe`
  already showed you in Step 5's `Replicas:` line, here as their own
  individual YAML fields instead of one combined summary line.

You can save this to a file:
```bash
kubectl get deployment nginx-deploy -o yaml > deployment-export.yaml
```

---

### Step 13: Cleanup

```bash
kubectl delete -f 01-nginx-deploy.yaml
```

**Expected output:**
```
deployment.apps "nginx-deploy" deleted
```

Verify everything is deleted:
```bash
kubectl get deployments
kubectl get pods
```

**What gets deleted:** the Deployment, and — via the owner-reference
cascade covered in **End-to-End** above — its ReplicaSet and every Pod,
automatically.

---

## What You Learned

In this lab, you:
- ✅ Created your first Kubernetes Deployment with 3 replicas
- ✅ Wrote a Deployment selector using both `matchLabels` and `matchExpressions`, and know when each is appropriate
- ✅ Understood the three-tier hierarchy: Deployment → ReplicaSet → Pods, and the `pod-template-hash` label that actually implements it
- ✅ Explained the full end-to-end flow: Deployment controller creates a ReplicaSet with an owner reference; ReplicaSet controller creates Pods with its own owner reference; from there, Pod creation is exactly what `01-core-concepts` already covered
- ✅ Verified deployment health using `kubectl get` and `kubectl describe`
- ✅ Witnessed self-healing, and correctly attributed it to the ReplicaSet controller, not the Deployment directly
- ✅ Scaled deployments up, down, and to zero using `kubectl scale`, and know how `kubectl rollout restart` differs from scaling
- ✅ Read a ReplicaSet's own `describe` output — its owner reference, and the `desired-replicas`/`max-replicas` annotations the Deployment controller writes onto it
- ✅ Proved that scaling a Deployment-owned ReplicaSet directly does not persist because the Deployment controller reconciles it back to the Deployment's desired state, and understood that while `--cascade=orphan` can preserve running resources during advanced migrations or recovery scenarios, it is not the normal solution for changing an immutable Deployment selector.
- ✅ Properly cleaned up Kubernetes resources, and understood why deletion cascades

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-selector-template-mismatch.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mismatch-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mismatch-demo
  template:
    metadata:
      labels:
        app: mismatch-demo-typo    # doesn't satisfy the selector above
    spec:
      containers:
        - name: nginx
          image: nginx:1.30.4
```

```bash
kubectl apply -f 01-selector-template-mismatch.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `spec.template.metadata.labels` must satisfy `spec.selector` — here it doesn't, and the API rejects the object outright at schema-validation time: `error: Deployment.apps "mismatch-demo" is invalid: spec.template.metadata.labels: Invalid value: ... selector does not match template labels`.

**Fix:** Make the template's label match the selector exactly, then reapply.

**Cascade:** none — this fails at `apply` time, so no ReplicaSet or Pod is ever created. Compare this to Error-2 below, where the failure mode is very different despite looking superficially similar.

</details>

**Cleanup:**
```bash
kubectl delete deployment mismatch-demo 2>/dev/null || true
```

---

### Error-2

**`src/break-fix/02-immutable-selector-patch.yaml`:**

First apply a working Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: immutable-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: immutable-demo
  template:
    metadata:
      labels:
        app: immutable-demo
    spec:
      containers:
        - name: nginx
          image: nginx:1.30.4
```

```bash
kubectl apply -f 02-immutable-selector-patch.yaml
```

Now edit the file and try to change the selector on the already-existing
Deployment:

```bash
vi 02-immutable-selector-patch.yaml
```

Find the line `app: immutable-demo` under:

```yaml
spec:
  selector:
    matchLabels:
```

(**not** the one under `spec.template.metadata.labels` — leave that one
unchanged) and change its value to:

```yaml
app: immutable-demo-typo
```

Save and exit (`:wq` in `vi`), then reapply:

```bash
kubectl apply -f 02-immutable-selector-patch.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `spec.selector` is immutable once a Deployment has been created.
The selector defines the ownership relationship between the Deployment,
its ReplicaSets, and its Pods. Allowing it to change after creation could
make ownership ambiguous and potentially cause a controller to manage the
wrong set of Pods.

The API server rejects the update with a specific immutability error:

```
The Deployment "immutable-demo" is invalid: 
* spec.template.metadata.labels: Invalid value: {"app":"immutable-demo"}: `selector` does not match template `labels`
* spec.selector: Invalid value: {"matchLabels":{"app":"immutable-demo-typo"}}: field is immutable
```

Note there is only one error here, not two. Although the attempted selector
change would also make the selector inconsistent with the existing
`spec.template.metadata.labels`, the API server stops at the immutable
field validation and reports the selector immutability violation.

**Fix:** You cannot patch your way out of this. Once a Deployment selector
exists, it cannot be modified. The available approaches are:

1. Delete and recreate the Deployment with the corrected selector.
2. Create a new Deployment with the desired selector and migrate traffic
   from the old Deployment before removing it.

For production workloads where downtime must be avoided, the second
approach is usually preferred: run the new Deployment alongside the old
one, validate it, and gradually move traffic using Kubernetes deployment
and service migration patterns.

`kubectl delete deployment <name> --cascade=orphan` is **not a general
solution for changing an immutable selector**. It is an advanced
ownership-preservation mechanism that removes the parent object while
leaving child resources (such as ReplicaSets or Pods) running. It is mainly
useful for recovery scenarios, controller migrations, or transferring
ownership of existing resources.

**Cascade:** the failed `apply` does not modify anything. The existing
Deployment, its ReplicaSet, and its Pods remain exactly as they were.
A rejected update means Kubernetes refused the requested change; it does
not partially apply the invalid configuration.

</details>

**Cleanup:**
```bash
kubectl delete deployment immutable-demo 2>/dev/null || true
```

---

### Error-3

```bash
# Assumes nginx-deploy from the main lab is running with 3 replicas
kubectl get rs -l app=nginx
# note the ReplicaSet's name, then bypass the Deployment entirely:
kubectl scale replicaset <replicaset-name> --replicas=1
kubectl get pods -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** This isn't actually broken — it's the **Don't Manage a
Deployment's ReplicaSet Directly** behavior from Concepts, observed live.
For a few seconds, Pod count really does drop toward 1, as the ReplicaSet
controller honors your manual `--replicas=1`. Then the *Deployment*
controller notices the ReplicaSet's `spec.replicas` (1) no longer matches
the Deployment's own `spec.replicas` (3), and reconciles it back — the
ReplicaSet's count snaps back to 3, and the ReplicaSet controller
recreates the Pods you just watched disappear.

**Fix:** There's nothing to fix — this is expected, correct behavior. If
you actually want 1 replica, `kubectl scale deployment nginx-deploy --replicas=1` is the right command; scaling the ReplicaSet directly was
never going to stick.

**Cascade:** briefly, real Pods really were deleted (not just a display
glitch) — if this were a production Deployment mid-request, that's a
real, if short, capacity dip. The trap isn't that anything is technically
wrong; it's assuming the ReplicaSet is a safe, independent lever to pull
when it's actually just a reconciliation target the Deployment controller
is continuously re-asserting itself against.

</details>

**Cleanup:** none needed — the Deployment's own reconciliation already restored the correct state.

---

## Interview Prep

**Q: Why not create pods directly instead of using a Deployment?**
A: Creating pods directly means no self-healing, no easy scaling, and no update management. A standalone Pod that's deleted is simply gone — this was covered directly in `01-core-concepts`. A Deployment gives you a ReplicaSet controller continuously reconciling actual state against desired state, which is what actually provides self-healing.

**Q: When you delete a Pod that's managed by a Deployment, which controller actually recreates it?**
A: The ReplicaSet controller, not the Deployment controller. The Deployment controller's job stops at creating and managing the ReplicaSet itself — it's the ReplicaSet controller, one level down, that watches Pod count and creates replacements.

**Q: What is the pod-template-hash label actually for?**
A: It's what lets a ReplicaSet's selector match *only* the Pods it created, even though the Deployment's own selector (like `app: nginx`) is broader and would otherwise match Pods from any ReplicaSet with that label. It's computed from the pod template, which is exactly why changing the template produces a new hash and therefore a new ReplicaSet — the mechanism `02-rolling-update-recreate` builds on.

**Q: Can you have zero replicas?**
A: Yes — `replicas: 0` deletes all Pods but keeps the Deployment object and its configuration intact. Useful for temporarily stopping an application without losing anything.

**Q: What happens if you manually delete a pod managed by a Deployment?**
A: The ReplicaSet controller immediately detects the pod is missing and creates a new one to maintain the desired count. You cannot reduce pod count by deleting pods manually — only changing `spec.replicas` (on the Deployment, which propagates down) actually changes the target.

**Q: When would you reach for `matchExpressions` over `matchLabels`?**
A: Only when you need `NotIn`, `Exists`, or `DoesNotExist` — none of which `matchLabels` can express at all. For a plain equality match, `matchLabels` is simpler and is what you'll see used throughout the rest of this series.

**Q: How is `kubectl rollout restart` different from `kubectl scale`?**
A: Scaling changes `spec.replicas` — how many Pods exist. `rollout restart` doesn't change the replica count or the pod template at all; it forces every existing Pod to be recreated (via the same rolling strategy) by patching a restart-timestamp annotation. Same ReplicaSet, same `pod-template-hash`, brand new Pod instances — useful for picking up a changed ConfigMap/Secret without editing the Deployment itself.

**Q: If you manually `kubectl scale` a Deployment's ReplicaSet directly, does it stick?**
A: No — the Deployment controller continuously reconciles the ReplicaSet's `spec.replicas` back to match the Deployment's own `spec.replicas`. Your change gets overwritten, typically within seconds. Always scale the Deployment, never its ReplicaSet.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Deployment | CKAD | 20% | Deployment creation, scaling, hierarchy |
| Application Design and Build | CKAD | 20% | Selector syntax (matchLabels/matchExpressions) |
| Workloads & Scheduling | CKA | 15% | Deployment → ReplicaSet → Pod reconciliation |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Selector doesn't match template labels | Deployment is rejected outright at apply time — one of the few Kubernetes errors that's genuinely easy to catch immediately if you know the error message shape |
| Trying to change `spec.selector` on an existing Deployment | Immutable — fails with a clear, single-error message, but the fix (delete/recreate) isn't obvious under time pressure if you don't already know the field is locked |
| Assuming the Deployment itself recreates deleted pods | It's the ReplicaSet controller, one level down — doesn't change what you type on the exam, but matters if a question asks you to reason about *why* something is happening |
| Confusing `matchLabels` and `matchExpressions` syntax under time pressure | `matchExpressions` needs `key`/`operator`/`values` as a list of objects — a syntax slip here produces a schema validation error, not a silent misconfiguration |
| Reaching for `kubectl scale` to force a fresh set of pods | Scaling doesn't recreate existing Pods, it only changes the count — `kubectl rollout restart` is the actual tool for "recreate everything, unchanged template" |
| Scaling or editing a Deployment's ReplicaSet directly | Gets silently reconciled back by the Deployment controller within seconds — always act on the Deployment, never its ReplicaSet |

### Exam Task — Write it from scratch

Create a Deployment named `exam-nginx` running `nginx:1.30.4` with 3 replicas, using `--dry-run=client -o yaml` to generate the skeleton, then verify the ReplicaSet's selector includes `pod-template-hash` in addition to your own label.

Official docs: [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create deployment exam-nginx --image=nginx:1.30.4 --replicas=3 --dry-run=client -o yaml > exam-nginx.yaml
kubectl apply -f exam-nginx.yaml
kubectl get rs -l app=exam-nginx -o jsonpath='{.items[0].spec.selector}'
```

**Key fields to recall:** `spec.replicas`, `spec.selector.matchLabels`, `spec.template.metadata.labels` (must satisfy the selector).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Deployment never touches a Pod directly | It manages a ReplicaSet, which manages Pods — a strict two-hop chain of command, not a single controller doing everything |
| `pod-template-hash` is what makes ReplicaSet ownership precise | Auto-computed from the pod template, added to the ReplicaSet's name, selector, and every Pod it creates |
| Self-healing is the ReplicaSet controller's job, not the Deployment's | Deleting a Deployment-managed pod gets it recreated by the ReplicaSet controller reconciling actual vs. desired count |
| `matchLabels` is the common case; `matchExpressions` is for richer logic | Only `NotIn`/`Exists`/`DoesNotExist` require `matchExpressions` — plain equality should use `matchLabels` |
| `spec.selector` is immutable once a Deployment exists | Same rule already seen for Pod fields — the fix is always delete-and-recreate, never patch |
| Owner references are what make deletion cascade | Deleting a Deployment cascades to its ReplicaSet and Pods because each one declares the level above as its owner |
| Scaling only ever changes `spec.replicas` | The Deployment copies the number to the ReplicaSet; the ReplicaSet controller does the actual Pod creation/deletion |
| `rollout restart` ≠ scaling | Forces every Pod to be recreated with an unchanged template and unchanged `pod-template-hash` — a different operation from changing replica count |
| A Deployment-owned ReplicaSet isn't a safe second control surface | The Deployment controller reconciles any manual scale/edit on it back to match the Deployment's own spec within seconds |
| `--cascade=orphan` is not the zero-downtime alternative to delete-and-recreate | It just Orphans the ReplicaSet/Pods instead of deleting them |
| Everything about Pod creation from `01-core-concepts` still applies unchanged | A Deployment being three levels up the ownership chain doesn't change scheduling, admission control, or how kubelet/the container runtime create the container |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f 01-nginx-deploy.yaml` | Create or update deployment from file |
| `kubectl get deployments` | List all deployments |
| `kubectl get deploy,rs,po` | Check the full hierarchy at once |
| `kubectl get all` | Pods/Services/Deployments/ReplicaSets etc. in one view — see Step 3 for exactly what this does and doesn't cover |
| `kubectl get pods --show-labels` | List pods with their labels, including `pod-template-hash` |
| `kubectl describe deployment <name>` | Show detailed deployment information |
| `kubectl logs deployment/<name>` | Logs from one arbitrary pod in the deployment — see Step 6 |
| `kubectl exec deployment/<name> -- <cmd>` | Exec into one arbitrary pod in the deployment — see Step 6 |
| `kubectl scale deployment <name> --replicas=N` | Scale deployment to N replicas |
| `kubectl rollout restart deployment/<name>` | Recreate all pods with the same template — see Step 8 |
| `kubectl edit deployment <name>` | Edit deployment in default editor |
| `kubectl delete deployment <name>` | Delete deployment and all its pods |
| `kubectl delete -f 01-nginx-deploy.yaml` | Delete resources defined in file |
| `kubectl get pods -w` | Watch pods in real-time (Ctrl+C to exit) |
| `kubectl describe rs <name>` | Full ReplicaSet detail including owner reference and desired/max-replicas annotations — see Step 3 |
| `kubectl delete deployment <name> --cascade=orphan` | Delete only the Deployment, leaving its Pods running orphaned — see Working Around an Immutable Selector |

### Generating YAML skeletons with --dry-run

```bash
kubectl create deployment nginx-deploy --image=nginx:1.30.4 --replicas=3 --dry-run=client -o yaml > deploy.yaml
```

**Not supported** — commands that read, describe, or operate on running objects:
`kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:** generate the skeleton → edit fields the imperative command doesn't support (custom selector logic, `minReadySeconds`, etc.) → `kubectl apply -f deploy.yaml`.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Deployment | `kubectl create deployment NAME --image=IMG --replicas=N` | Generates a `matchLabels` selector automatically — matches this demo's default form |
| Scale (no YAML edit) | `kubectl scale deploy NAME --replicas=N` | Faster than editing YAML for a pure replica-count change |

---

## Troubleshooting

**Pods not starting?**
```bash
kubectl describe deployment nginx-deploy
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```
Look for `ImagePullBackOff` or `CrashLoopBackOff` — both covered in depth in `01-core-concepts/03-pod-container-basics`.

**Deployment stuck?**
```bash
kubectl get events --sort-by='.lastTimestamp'
```
Shows recent cluster events that might explain issues.

**Wrong number of pods?**
```bash
kubectl get deployment nginx-deploy -o jsonpath='{.spec.replicas}'
kubectl get rs -l app=nginx -o jsonpath='{.items[0].spec.replicas}'
```
Confirm the Deployment's desired count actually matches what got propagated to the ReplicaSet — if they differ, the Deployment controller itself may be stuck; if they match but Pod count is still wrong, look at the ReplicaSet controller / Pod events instead.

---

## Appendix — Anki Cards

**`01-basic-deployment-anki.csv`:**

````
#deck:k8s-platform-labs::02-deployments::01-basic-deployment
#separator:Comma
#columns:Front,Back,Tags
"Does a Deployment ever create or delete a Pod directly?","No — it manages a ReplicaSet, which manages Pods. It's a strict two-hop chain, not one controller doing everything","demo01-deployments,deployments,cka-workloads-scheduling"
"What is pod-template-hash and where does it come from?","A hash computed from the pod template by the Deployment controller, added to the ReplicaSet's name, selector, and every Pod it creates","demo01-deployments,internals,pod-template-hash,cka-workloads-scheduling"
"Why does a ReplicaSet's selector include pod-template-hash when the Deployment's own selector doesn't?","So the ReplicaSet only claims the Pods it actually created, even though the Deployment's broader selector (e.g. app: nginx) could otherwise match Pods from a different ReplicaSet too","demo01-deployments,internals,pod-template-hash,cka-workloads-scheduling"
"Which controller actually recreates a manually deleted pod under a Deployment?","The ReplicaSet controller, not the Deployment controller — it reconciles actual Pod count against spec.replicas","demo01-deployments,self-healing,cka-workloads-scheduling"
"When would you use matchExpressions instead of matchLabels?","Only when you need NotIn, Exists, or DoesNotExist — matchLabels can't express any of those","demo01-deployments,selectors,ckad-application-design-build"
"Is spec.selector mutable on an existing Deployment?","No — it's immutable, same rule as several Pod fields. Fix is always delete-and-recreate, never patch","demo01-deployments,deployments,immutability,ckad-application-deployment"
"What mechanism makes deleting a Deployment cascade to its ReplicaSet and Pods?","Owner references — the ReplicaSet declares the Deployment as its owner, and each Pod declares the ReplicaSet as its owner","demo01-deployments,owner-references,cka-workloads-scheduling"
"What does kubectl scale deployment --replicas=N actually change?","Only the Deployment's spec.replicas — the Deployment controller copies that number to the ReplicaSet, which is what actually creates/deletes Pods","demo01-deployments,scaling,cka-workloads-scheduling"
"Does replicas: 0 delete the Deployment itself?","No — it deletes all Pods but keeps the Deployment object and configuration intact","demo01-deployments,scaling,ckad-application-deployment"
"What must spec.template.metadata.labels satisfy?","spec.selector — otherwise the Deployment is rejected outright at apply time with a schema validation error","demo01-deployments,selectors,ckad-application-design-build"
"Why does a Deployment use apiVersion: apps/v1 while a Pod uses apiVersion: v1?","Core, foundational types (Pod, Service, Namespace) live in the core/v1 group; controller types that manage other objects (Deployment, ReplicaSet, StatefulSet, DaemonSet) live in the separate apps group","demo01-deployments,apiversion,cka-cluster-architecture-installation-configuration"
"A pod name is nginx-deploy-85f7d4dd78-29r6g. What do the two suffixes mean?","85f7d4dd78 is the ReplicaSet's pod-template-hash (shared by every sibling pod); 29r6g is a separate random suffix generated per-pod purely for name uniqueness","demo01-deployments,internals,pod-template-hash,cka-workloads-scheduling"
"Does kubectl get all include ConfigMaps, Secrets, or Ingress objects?","No — it only covers a fixed set of common namespaced types (Pods, Services, Deployments, ReplicaSets, etc.); ConfigMaps/Secrets/Ingress/PVCs must be queried individually","demo01-deployments,kubectl-get-all,cka-cluster-architecture-installation-configuration"
"Can kubectl logs and kubectl exec target a Deployment directly instead of a specific pod?","Yes — kubectl resolves deployment/name to the ReplicaSet and picks one arbitrary pod from it; useful when you don't care which specific replica, but not for comparing or isolating one pod","demo01-deployments,debugging,ckad-application-observability-maintenance"
"Which namespace does the built-in service/kubernetes ClusterIP actually live in?","Only the default namespace — it's not present cluster-wide or in every namespace's kubectl get all output","demo01-deployments,kubectl-get-all,cka-cluster-architecture-installation-configuration"
"How does kubectl rollout restart differ from kubectl scale?","rollout restart recreates every existing pod with the same template (same pod-template-hash) via a restart-timestamp annotation; scale only changes the replica count, it never recreates existing pods","demo01-deployments,rollout,ckad-application-deployment"
"If you kubectl scale a Deployment's ReplicaSet directly, does it stick?","No — the Deployment controller reconciles the ReplicaSet's spec.replicas back to match the Deployment's own spec.replicas, typically within seconds","demo01-deployments,replicaset-ownership,cka-workloads-scheduling"
"What do the deployment.kubernetes.io/desired-replicas and max-replicas annotations on a ReplicaSet tell you?","They're written by the Deployment controller, not you — max-replicas is spec.replicas plus the rounded-up maxSurge, the same number behind RollingUpdateStrategy's defaults","demo01-deployments,replicaset-ownership,cka-workloads-scheduling"
````

---

## Appendix — Quiz

**`01-basic-deployment-quiz.md`:**

````markdown
# Quiz — 02-deployments/01-basic-deployment: Basic Deployment

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Does a Deployment ever create or delete a Pod directly?**

- A) Yes, it manages Pods directly with no intermediate object
- B) No — it manages a ReplicaSet, which manages Pods
- C) Only during a rolling update
- D) Only when replicas is set to 0

<details>
<summary>Answer</summary>

**B** — It's a strict two-hop chain of command: Deployment → ReplicaSet → Pod, each level reconciling only its own tier.
Trap: A is the common oversimplified mental model that this demo specifically corrects.

</details>

---

**Q2. What is `pod-template-hash` and where does it come from?**

- A) A random UUID assigned at cluster install time
- B) A hash computed from the pod template, added to the ReplicaSet's name, selector, and Pods
- C) A checksum of the container image
- D) The Deployment's own resourceVersion

<details>
<summary>Answer</summary>

**B** — It's derived from `spec.template`, which is exactly why changing the template produces a new hash and a new ReplicaSet.
Trap: C confuses this with image content — it has nothing to do with the image itself, only the pod template as a whole.

</details>

---

**Q3. Which controller actually recreates a manually deleted pod under a Deployment?**

- A) The Deployment controller
- B) The ReplicaSet controller
- C) kube-scheduler
- D) kubelet

<details>
<summary>Answer</summary>

**B** — The ReplicaSet controller is the one watching actual Pod count against `spec.replicas` and reconciling the difference.
Trap: A is the common but imprecise "the Deployment self-heals" framing — technically it's one level down.

</details>

---

**Q4. When would you actually need `matchExpressions` instead of `matchLabels`?**

- A) Whenever you have more than one label
- B) Only when you need NotIn, Exists, or DoesNotExist
- C) matchExpressions is always required for Deployments
- D) Never — matchLabels can express everything matchExpressions can

<details>
<summary>Answer</summary>

**B** — Those three operators have no `matchLabels` equivalent at all; a plain equality match should just use `matchLabels`.
Trap: D overcorrects — `matchExpressions` genuinely can express things `matchLabels` cannot, it's just unnecessary for simple cases.

</details>

---

**Q5. Can you change `spec.selector` on an existing Deployment with `kubectl apply`?**

- A) Yes, it updates immediately
- B) No — it's immutable; the only fix is delete and recreate
- C) Yes, but only if replicas is 0
- D) Yes, but it requires `--force`

<details>
<summary>Answer</summary>

**B** — Same immutability rule already seen on certain Pod fields, applied here to a different object's field.
Trap: C invents a workaround condition that doesn't exist — immutability isn't conditional on replica count.

</details>

---

**Q6. What mechanism makes deleting a Deployment cascade to its ReplicaSet and Pods automatically?**

- A) A hardcoded cleanup script in kube-controller-manager
- B) Owner references
- C) The pod-template-hash label
- D) Finalizers on the Deployment object itself

<details>
<summary>Answer</summary>

**B** — Each ReplicaSet declares its Deployment as owner, and each Pod declares its ReplicaSet as owner; Kubernetes' garbage collector uses these to cascade deletes.
Trap: C is a real, related mechanism but doesn't drive deletion — it's used for selector precision, not ownership/GC.

</details>

---

**Q7. What does `kubectl scale deployment nginx --replicas=5` actually modify?**

- A) It directly creates 5 pods itself
- B) Only the Deployment's `spec.replicas` — the ReplicaSet controller does the actual Pod work
- C) It modifies the ReplicaSet's pod-template-hash
- D) It triggers a rolling update

<details>
<summary>Answer</summary>

**B** — Scaling never touches Pods directly; it's a one-field change that the Deployment controller propagates down to the ReplicaSet.
Trap: D is wrong for this demo's scope — no template change occurred, so there's nothing for a rolling update to do.

</details>

---

**Q8. A Deployment's `spec.template.metadata.labels` doesn't satisfy `spec.selector`. What happens?**

- A) The Deployment is created but manages zero pods
- B) The apply is rejected outright with a schema validation error
- C) Kubernetes automatically fixes the mismatched label
- D) The ReplicaSet is created but stuck at 0 replicas forever

<details>
<summary>Answer</summary>

**B** — This fails immediately at `apply` time — one of the more catchable Kubernetes errors, provided you recognize the message shape.
Trap: A and D both imagine a partial-success state that doesn't actually happen here — the whole object is rejected, nothing is created.

</details>

---

**Q9. Why does a Deployment use `apiVersion: apps/v1` instead of `v1` like a Pod?**

- A) apps/v1 is just a newer, interchangeable name for v1
- B) Core/foundational types use v1; controller types that manage other objects use the separate apps group
- C) apiVersion doesn't actually matter, kubectl infers it from `kind`
- D) apps/v1 is only used in production clusters

<details>
<summary>Answer</summary>

**B** — Pod, Service, Namespace stay in the core `v1` group; Deployment, ReplicaSet, StatefulSet, DaemonSet live in the separate `apps` group since they're controllers managing other objects.
Trap: C is wrong and dangerous to believe — getting `apiVersion` wrong produces a real schema-validation rejection, not silent inference.

</details>

---

**Q10. A pod is named `nginx-deploy-85f7d4dd78-29r6g`. What does the `29r6g` part represent?**

- A) The same pod-template-hash as `85f7d4dd78`, just truncated
- B) A separate random suffix generated per-pod, purely for name uniqueness among siblings
- C) The node the pod is scheduled on
- D) A checksum of the container's image

<details>
<summary>Answer</summary>

**B** — Every pod from the same ReplicaSet shares `85f7d4dd78` (the pod-template-hash) but gets its own distinct second suffix, which is what keeps sibling pod names unique.
Trap: A conflates the two suffixes as if they were the same thing, which is exactly the confusion this section exists to clear up.

</details>

---

**Q11. Does `kubectl get all` include ConfigMaps and Secrets in its output?**

- A) Yes, along with everything else in the namespace
- B) No — it only covers a fixed set of common types like Pods, Services, Deployments, ReplicaSets
- C) Only if `--all-namespaces` is added
- D) Only ConfigMaps, not Secrets

<details>
<summary>Answer</summary>

**B** — "all" is narrower than it sounds; ConfigMaps, Secrets, Ingress, PVCs, and any CRD-based object all need to be queried separately.
Trap: A is the natural but incorrect assumption the command's name invites.

</details>

---

**Q12. Can `kubectl exec deployment/nginx-deploy -- <cmd>` run without naming a specific pod?**

- A) No — Deployments don't support exec at all
- B) Yes — kubectl resolves it to the ReplicaSet and picks one arbitrary pod
- C) Yes, but it runs the command on every pod simultaneously
- D) Only if the Deployment has exactly one replica

<details>
<summary>Answer</summary>

**B** — Convenient when you don't care which specific replica, but it's still just one pod, not all of them — the same resolution pattern already seen with `kubectl port-forward deployment/...`.
Trap: C assumes fan-out behavior that doesn't exist — it's always exactly one pod, chosen arbitrarily.

</details>

---

**Q13. Which namespace does the built-in `service/kubernetes` ClusterIP actually live in?**

- A) Every namespace, automatically
- B) Only the `default` namespace
- C) Only `kube-system`
- D) Whichever namespace you last ran `kubectl apply` in

<details>
<summary>Answer</summary>

**B** — It's created and pinned to `default` by the control plane. `kubectl get all -n <other-namespace>` will not show it.
Trap: A is the natural but incorrect assumption from seeing it appear in this demo's `get all` output — it only shows up here because the lab stays in `default`.

</details>

---

**Q14. How does `kubectl rollout restart deployment/nginx` differ from `kubectl scale deployment nginx --replicas=N`?**

- A) They're two names for the same operation
- B) `rollout restart` recreates every existing pod with the unchanged template; `scale` only changes the replica count
- C) `scale` recreates pods; `rollout restart` only changes the count
- D) `rollout restart` requires editing the YAML file first

<details>
<summary>Answer</summary>

**B** — `rollout restart` forces a fresh set of Pods (same `pod-template-hash`, same ReplicaSet) via a restart-timestamp annotation — useful for picking up a changed ConfigMap/Secret. `scale` never recreates existing Pods, it only changes how many exist.
Trap: C reverses the two operations' actual behavior.

</details>

---

**Q15. You run `kubectl scale replicaset nginx-deploy-85f7d4dd78 --replicas=1` directly. What happens?**

- A) It stays at 1 replica permanently
- B) The Deployment controller reconciles it back to match the Deployment's own `spec.replicas` within seconds
- C) The Deployment is deleted
- D) It's rejected outright — you can't scale a ReplicaSet directly

<details>
<summary>Answer</summary>

**B** — The ReplicaSet controller briefly honors your value, but the Deployment controller notices the mismatch against its own `spec.replicas` and reconciles it back.
Trap: D assumes a hard restriction that doesn't exist — the command succeeds, it just doesn't stick.

</details>

---

**Q16. What do the `deployment.kubernetes.io/desired-replicas` and `max-replicas` annotations on a ReplicaSet represent?**

- A) Values you're expected to set yourself in the ReplicaSet's YAML
- B) Values written by the Deployment controller — `max-replicas` includes the rounded-up `maxSurge`
- C) The ReplicaSet's own internal scaling limits, unrelated to any Deployment
- D) Historical values from the ReplicaSet's very first revision only

<details>
<summary>Answer</summary>

**B** — Visible via `kubectl describe rs`, these are the Deployment controller's own bookkeeping on the ReplicaSet it owns — `max-replicas` is exactly why `describe deployment`'s `RollingUpdateStrategy` percentages translate into a concrete extra Pod.
Trap: A assumes these are user-configurable fields — they aren't, they're controller-written.

</details>

---

**Q17. What does `kubectl delete deployment nginx-deploy --cascade=orphan` do differently from a plain `kubectl delete deployment nginx-deploy`?**

- A) Nothing — they're identical
- B) It deletes only the Deployment object, leaving the ReplicaSet and Pods running orphaned instead of cascading the delete to them
- C) It deletes the Deployment and ReplicaSet, but keeps the Pods' data in a PersistentVolume
- D) It pauses the Deployment instead of deleting it

<details>
<summary>Answer</summary>

**B** — A plain delete cascades via owner references (per `01-basic-deployment`'s End-to-End section) all the way down to the Pods; `--cascade=orphan` deletes only the top object, leaving everything below it running with no owner.
Trap: A ignores that this flag exists specifically to change cascade behavior — it wouldn't be documented separately if it behaved identically.

</details>

Score guide:
| Score | Action |
|---|---|
| 15-17/17 | Import Anki cards, move to next Demo |
| 12-14/17 | Review the wrong answers, then proceed |
| 9-11/17 | Re-read the relevant section, retry those questions |
| Below 9/17 | Re-read the full demo and redo the walkthrough before proceeding |
````