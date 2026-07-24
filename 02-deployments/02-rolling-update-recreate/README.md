# Demo: 02-deployments/02-rolling-update-recreate — Rolling Updates, Recreate Strategy, and Rollback

## Lab Overview

This lab teaches you the two native Kubernetes Deployment strategies —
`RollingUpdate` and `Recreate` — and how to recover from a failed update
using rollback, under either one.

`RollingUpdate` (the default) gradually replaces old Pods with new ones,
keeping the app available throughout. `Recreate` terminates every old Pod
first, then creates new ones — simpler, but with a downtime window. You'll
deploy under both in this demo, so the difference is something you watch
happen, not just a comparison table. This demo also makes concrete
something `01-basic-deployment` only promised: that changing a Pod
template produces a **new** ReplicaSet with a new `pod-template-hash`
rather than mutating the existing one — you'll watch that happen directly
in Step 4.

**What you'll do:**

- Perform a rolling update by changing the container image
- Control update speed with maxSurge and maxUnavailable parameters
- Monitor rollout progress and status
- Track deployment revision history with annotations
- Rollback to previous versions when updates fail
- Deploy using the Recreate strategy and observe its downtime window directly
- Compare rollback behavior across RollingUpdate and Recreate

## Prerequisites

**Required:**

- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-basic-deployment` (this demo assumes you already understand the Deployment→ReplicaSet→Pod hierarchy and the `pod-template-hash` mechanism covered there in full)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Perform zero-downtime rolling updates
2. ✅ Configure rolling update parameters (maxSurge, maxUnavailable)
3. ✅ Monitor rollout status and progress
4. ✅ Track deployment revision history
5. ✅ Add change-cause annotations for better tracking, without relying on the deprecated `--record` flag
6. ✅ Rollback failed deployments to previous versions
7. ✅ Pause and resume rollouts for controlled deployments
8. ✅ Observe a second ReplicaSet appear with its own `pod-template-hash` during a rollout, and explain why
9. ✅ Explain what `kubectl rollout restart` actually does, and why it's governed by the Deployment's own strategy rather than being an instant, unconditional recreate
10. ✅ Explain Rollover — what happens when a second update is applied before the first finishes
11. ✅ Explain proportional scaling — how a mid-rollout scale distributes across old and new ReplicaSets
12. ✅ Detect a genuinely failed rollout (`ProgressDeadlineExceeded`) directly, instead of assuming a slow rollout is still healthy
13. ✅ Configure and deploy using the Recreate strategy, and explain when it's the right choice despite its downtime
14. ✅ Directly observe — and optionally measure — the downtime window Recreate produces, in contrast to RollingUpdate's zero-downtime behavior
15. ✅ Explain why rollback's underlying mechanism is identical across both strategies, while its observed behavior during the rollback itself is not

## Directory Structure

```
02-deployments/02-rolling-update-recreate/
├── README.md
├── src/
│   ├── 01-nginx-deploy-v1.yaml            # Initial deployment (nginx:1.28.3)
│   ├── 02-nginx-deploy-v2.yaml            # Updated deployment (nginx:1.29.5)
│   ├── 03-nginx-deploy-v3.yaml            # Bad deployment (nginx:1.100 - doesn't exist)
│   ├── 04-nginx-deploy-recreate-v1.yaml   # Recreate-strategy deployment (nginx:1.28.3)
│   └── break-fix/
│       ├── 01-surge-stall.yaml            # Error-1
│       ├── 02-zero-zero.yaml              # Error-2 (generated via --dry-run, see Break-Fix)
│       └── 03-recreate-bad-image.yaml     # Error-4
├── 02-rolling-update-recreate-anki.csv
└── 02-rolling-update-recreate-quiz.md
```

> **Note:** `break-fix\Error-3` (--to-revision=99) needs no file — it creates its own throwaway Deployment imperatively, so it doesn't depend on nginx-deploy still existing after Step 15's cleanup.
---

## Recall Check — 01-basic-deployment

Answer from memory before continuing — no peeking at the previous demo.

1. Does a Deployment ever create or delete a Pod directly?
2. What is `pod-template-hash` and where does it come from?
3. Which controller actually recreates a manually deleted pod under a Deployment?

<details>
<summary>Answers</summary>

1. No — it manages a ReplicaSet, which manages Pods. It's a strict two-hop chain, not one controller doing everything.
2. A hash computed from the pod template by the Deployment controller, added to the ReplicaSet's name, selector, and every Pod it creates.
3. The ReplicaSet controller, not the Deployment controller — it reconciles actual Pod count against `spec.replicas`.

</details>

---

## Concepts

### Deployment Strategies Overview

`01-basic-deployment` introduced `spec.strategy` and deferred it entirely —
this demo is where it actually matters. `spec.strategy.type` is the field
that controls *how* the Deployment controller replaces old Pods with new
ones whenever `spec.template` changes. There are exactly two built-in
values:

| `strategy.type`  | One-line mental model                                                          | Default? |
| ----------------- | -------------------------------------------------------------------------------- | -------- |
| `RollingUpdate`    | Gradually swap old Pods for new ones, some of each running at all times          | Yes      |
| `Recreate`         | Terminate every old Pod first, only then create new ones — nothing overlaps      | No       |

Both strategies operate on the exact same mechanism from `01-basic-deployment`:
a changed pod template produces a new `pod-template-hash`, which means a new
ReplicaSet. What differs between the two strategies is purely the *choreography*
of scaling the old ReplicaSet down and the new one up — RollingUpdate
interleaves the two; Recreate does them in strict sequence with a gap in
between.

**Why start with RollingUpdate:** it's the default — every Deployment you
create without explicitly setting `strategy.type` already uses it, including
every Deployment from `01-basic-deployment`. It's also what you'll use for
the overwhelming majority of real applications, since it avoids a downtime
window. The rest of this demo's Concepts and most of its lab steps build out
RollingUpdate in full — `maxSurge`, `maxUnavailable`, rollout monitoring,
rollback. Once that's solid, a dedicated section later in this same demo
(**Recreate Strategy — Deep Dive**) comes back to the second strategy, with
its own hands-on lab, so you can see the downtime window RollingUpdate
exists to avoid, directly, rather than just reading about it in a
comparison table.

**Where RollingUpdate and Recreate Stop:**

RollingUpdate and Recreate are the only two strategies `spec.strategy.type`
actually accepts — there's no third native option. Both are useful, but
both share the same limitation: neither strategy gives you fine-grained traffic control (e.g. "send exactly
10% of traffic to the new version"), hold a new version at partial exposure while you watch real
metrics, or switch back in under a second without waiting on Pod
termination. For that level of control, the pattern shifts from "what does
`spec.strategy` do" to "how do I route traffic between two independent
Deployments using a Service" — which is exactly what `03-deployment-strategies` covers next, with Blue-Green (instant, label-based
switching) and Canary (gradual, percentage-based rollout).

---

### What is a Rolling Update?

A rolling update gradually replaces old pod instances with new ones, ensuring your application remains available throughout the update process.

**Without Rolling Update (Recreate Strategy - Downtime):**

```
[Pod1] [Pod2] [Pod3]  →  💥 ALL DOWN  →  [NewPod1] [NewPod2] [NewPod3]
         ↑
    DOWNTIME WINDOW
```

**With Rolling Update (Zero Downtime):**

```
[Pod1] [Pod2] [Pod3]           # Start: 3 old pods
[Pod1] [Pod2] [Pod3] [NewPod1] # Create 1 new pod (maxSurge)
[Pod1] [Pod2] [NewPod1]        # Terminate 1 old pod
[Pod1] [Pod2] [NewPod1] [NewPod2] # Create another new pod
[Pod1] [NewPod1] [NewPod2]     # Terminate another old pod
[NewPod1] [NewPod2] [NewPod3]  # Complete!
         ↑
    ALWAYS AVAILABLE
```

**What's actually behind "old pods" and "new pods" here:** each side of
this diagram is a *different ReplicaSet*, not just a Pod-level label —
exactly the `01-basic-deployment` mechanism where a changed pod template
produces a new `pod-template-hash`. "Old pods" all share the previous
hash; "new pods" all share a freshly computed one. You'll see both
ReplicaSets side by side in Step 4.

---

### Key Rolling Update Parameters

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1           # Max additional pods during update
      maxUnavailable: 0     # Max pods that can be unavailable
```

**maxSurge: 1** means:

- If replicas=3, can temporarily have 4 pods during update
- Faster updates but uses more resources
- Can be a number (1, 2) or percentage (25%, 50%)

**maxUnavailable: 0** means:

- All original pods must stay running until replacements are ready
- Zero downtime guaranteed, *provided* new pods actually become Ready —
which depends on readiness probes passing, a topic this demo doesn't
cover in depth (full treatment in `05-pod-deep-dive/03-health-probes`).
Without an explicit readiness probe, a container counts as Ready the
moment it starts, which is a much weaker guarantee than most production
Deployments actually rely on.
- Slower updates but maximum availability

**A note on resource requests during a rollout:** `maxSurge` doesn't just
add a pod for free — that extra pod still needs to be scheduled like any
other, with its own `resources.requests` (covered in full in `01-core-concepts/03-pod-container-basics`) checked against real node
capacity. This demo's Break-Fix Error-1 is built around exactly what
happens when that surge pod can't actually be scheduled.

**One combination is rejected outright: `maxSurge: 0` together with
`maxUnavailable: 0`.** Verified against the API's own validation — this
isn't a style warning, it's a hard rejection, because that combination
would leave the rollout with no legal move at all: it couldn't add a pod
(`maxSurge: 0`) and couldn't remove one (`maxUnavailable: 0`) either, so
it could never make progress. At least one of the two has to allow some
movement. This demo's own Break-Fix Error-2 shows the actual rejection
message.

**A related but different tool — `kubectl rollout restart`.** Worth
distinguishing now, before Step 12 puts it into practice: `rollout restart` does **not**
leave the template unchanged. It adds a `kubectl.kubernetes.io/restartedAt`
timestamp annotation to `spec.template.metadata.annotations`. Since
`pod-template-hash` is computed from the entire Pod template, including
its annotations, this small change is enough to produce a genuinely new
hash and a genuinely new ReplicaSet — the same mechanism from
`01-basic-deployment`, not a special case.

Because it's a real template change, `rollout restart` goes through the
exact same rollout machinery as any other update — it doesn't bypass
`spec.strategy`, it's subject to it, **whichever strategy is currently
configured**. If the Deployment is currently `RollingUpdate` (this demo's
default), the restart proceeds gradually, governed by
`maxSurge`/`maxUnavailable` exactly like any other rolling update — Pods
replaced one (or `maxSurge`) at a time, with availability maintained
throughout. If the Deployment were currently `Recreate` instead, a
`rollout restart` would follow *that* strategy just as faithfully — every
existing Pod terminated first, then new ones created, with the same
downtime window covered in this demo's Recreate section. Either way, it is
not a special, strategy-exempt operation, and it is not the same thing as
the `Recreate` strategy type itself — it's simply whatever strategy is
already configured, triggered by a timestamp annotation instead of a spec
edit.

Because it creates a genuinely new ReplicaSet, `rollout restart` also
creates a new revision in the Deployment's history, the same as any other
template change — check `kubectl rollout history` afterward and you'll
see the revision count go up. That entry's `CHANGE-CAUSE` column will show
`<none>`, though, unless you separately set the `kubernetes.io/change-cause`
annotation — `rollout restart` only touches the `restartedAt` annotation,
not that one.

---

### Rollover — Updating Again Mid-Rollout

Everything so far has assumed one clean update at a time: apply, wait,
done. Kubernetes doesn't actually require that — you can apply a second
template change while the first rollout is still in progress, and it
doesn't queue or reject it. This is called **rollover**, and it's worth
knowing before it surprises you: Kubernetes doesn't wait for the
in-flight rollout to finish. It immediately computes a new
`pod-template-hash` for the new template and creates a new ReplicaSet,
then rolls the ReplicaSet it had been scaling up into its list of *old*
ReplicaSets and starts scaling that down too — so, briefly, you can have
three ReplicaSets in play: the original, the one from the abandoned
in-flight update, and the newest one, with the first two both scaling
toward 0 while the third scales up. You'll trigger this directly in
Step 13 below.

---

### Proportional Scaling During a Rollout

A related, separately-documented behavior: if you `kubectl scale` a
Deployment while a RollingUpdate is actively in progress — two
ReplicaSets both partway to their target counts — the additional
replicas aren't simply added to the newest ReplicaSet. The Deployment
controller distributes them **proportionally** across every ReplicaSet
still in play (that still has at least one replica), weighted by each
one's current share of the total — bigger proportions go to the
ReplicaSet with more replicas, smaller to the one with fewer, with any
leftover going to the ReplicaSet with the most replicas. This keeps the
surge/unavailable ratio from **Key Rolling Update Parameters** above
roughly honored throughout, rather than letting a mid-rollout scale
silently violate it. You'll trigger this directly in Step 13 below.

---

### When a Rollout Actually Fails — `ProgressDeadlineExceeded`

`01-basic-deployment` introduced `spec.progressDeadlineSeconds` (default
600s) as "a stuck-rollout detector," without showing what detection
actually looks like. Here's the concrete version: if a rollout makes no
forward progress for longer than that deadline, the Deployment controller
sets its `Progressing` condition to `False` with
`Reason: ProgressDeadlineExceeded` — a genuinely different state from
"still going," and one `kubectl rollout status` surfaces directly rather
than blocking forever:

```bash
kubectl rollout status deployment/nginx-deploy
# error: deployment "nginx-deploy" exceeded its progress deadline
```

The command itself **exits non-zero** once this happens — worth knowing
if you're ever scripting around it, since a naive "wait for rollout status
to finish" loop needs to treat this as a failure, not just a slow success.
You can also check the condition directly, without waiting on `rollout status` at all:

```bash
kubectl get deployment nginx-deploy -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'
```

Two things worth being precise about: a `ProgressDeadlineExceeded`
Deployment does **not** automatically roll back — the stalled ReplicaSet
keeps existing exactly as it was, waiting for you to intervene (`kubectl rollout undo`, fix the underlying resource/scheduling problem, or scale
appropriately). And the deadline resets on any progress at all, not just
completion — a rollout that's slow but genuinely still advancing (a new
pod becomes Ready every few minutes, say) never trips this, no matter how
long the whole rollout eventually takes.

---

### What is the Recreate Strategy?

`.spec.strategy.type` accepts exactly two values: `RollingUpdate` (the
default, covered above) and `Recreate`. Where RollingUpdate replaces Pods
gradually so some are always available, Recreate takes the opposite
approach: **all existing Pods are killed before any new ones are
created.**

```
Recreate Strategy — All Old Pods Killed, Then All New Pods Created

[Pod1 v1] [Pod2 v1] [Pod3 v1]     # Step 1: old Pods running
        ↓ (all terminated together)
        💥 ZERO Pods running 💥
        ↓ (new ReplicaSet scales up from 0)
[Pod1 v2] [Pod2 v2] [Pod3 v2]     # Step 3: new Pods running
         ↑
   DOWNTIME WINDOW — no Pod, old or new, is available during this gap
```

Compare this to the RollingUpdate diagram in **What is a Rolling Update?**
above: RollingUpdate always keeps *some* ReplicaSet's Pods up throughout;
Recreate deliberately drives the old ReplicaSet to 0 **before** the new one
starts scaling up at all. This isn't a bug or an edge case — it's the
entire strategy.

The guarantee Recreate provides is specifically about **ordering**, not
about zero downtime — it's the inverse guarantee of RollingUpdate. Old
Pods are always fully terminated before any Pod carrying the new template
is created, with no point at which old and new Pods coexist. This
guarantee applies specifically to **upgrades** — that is, to Pods being
replaced because the Pod template changed. It does not extend to Pods
you delete manually: if you delete a Pod by hand while a Deployment is
using Recreate, the ReplicaSet controller replaces it immediately, the
same as it would under any other strategy, even while an old Pod is still
mid-Terminating. If an application genuinely needs an "at most one
instance at a time" guarantee stronger than what Recreate provides here,
a StatefulSet is the more appropriate object.

### Key Recreate Parameters

```yaml
spec:
  strategy:
    type: Recreate
```

That's the entire configuration surface for this strategy. Worth being
explicit about what's *not* there:

- **No `rollingUpdate:` block at all** — `maxSurge` and `maxUnavailable`
  are RollingUpdate-only fields. Setting `spec.strategy.rollingUpdate`
  alongside `type: Recreate` is accepted by the schema but has **zero
  effect** — the Recreate strategy never reads those fields.
- **No partial state, ever.** With RollingUpdate you can have, say, 2 old
  + 1 new Pod mid-rollout. With Recreate, at any point in time you have
  either *all old* Pods, *zero* Pods, or *all new* Pods — never a mix.
  This is also why Recreate has nothing equivalent to Step 4's
  "two ReplicaSets visible side by side, scaling in opposite directions"
  — the old ReplicaSet fully reaches 0 before the new one is scaled up at
  all, so you'll only ever see one ReplicaSet with nonzero replicas at a
  time.
- **`minReadySeconds` and `progressDeadlineSeconds`** (from
  `01-basic-deployment`'s Anatomy section) still apply exactly as
  described there — Recreate doesn't change their meaning, only what
  happens to Pod count while the controller works toward satisfying them.

---

### Understanding Rollback

By default, all of a Deployment's rollout history is kept in the system,
which is what makes rollback possible at any time. That history isn't
stored in a separate log — it's stored **in the ReplicaSets the Deployment
controls**. Each ReplicaSet a Deployment ever created represents one
revision, and each revision only ever captures one thing: the Pod template
(`.spec.template`) at the moment that revision was created.

This is also why a revision is created if and only if the Pod template
changes. Scaling a Deployment, for instance, does not create a new
revision — it's not a template change, so there's nothing new to version.
This matters directly for rollback: since only the template is versioned,
rolling back to an earlier revision only ever restores the Pod template
part of the Deployment. Nothing else about the Deployment's current
configuration is touched.

**What `kubectl rollout undo` actually does** is not a separate rollback
mechanism — it's the same update path used by any other change, pointed
backward. It looks up the target revision (the previous one by default,
or a specific one via `--to-revision=N`), takes that revision's stored Pod
template, and writes it back onto the Deployment's live `.spec.template`.
From that point on, the Deployment controller reconciles the change
exactly as it would any other template edit: it emits a
`DeploymentRollback` event, then the same sequence of `ScalingReplicaSet`
events already familiar from Step 4 — scaling the target ReplicaSet up
while scaling the currently-active one down.

One consequence follows directly from this: rollback does not restore the
old revision number. Rolling back to "revision 2" doesn't put the
Deployment back at revision 2 — it advances the Deployment to a **new**,
higher revision number that happens to carry revision 2's template
forward. The number 2 itself disappears from history afterward, which is
exactly what you'll observe for yourself in this demo's Step 9.

**Which strategy governs the rollback itself** follows directly from what
gets rolled back and what doesn't. Since only the Pod template is
versioned, `spec.strategy` is never part of what a rollback restores — it
stays whatever is currently live on the Deployment object, completely
independent of which strategy was active when the revision being restored
was originally created. Practically, this means the exact same strategy
that governs a forward rollout also governs a rollback:

- If the Deployment is currently `RollingUpdate`, the rollback proceeds
gradually — the target ReplicaSet scales up while the current one scales
down, throttled by `spec.strategy.rollingUpdate.maxSurge` and
`spec.strategy.rollingUpdate.maxUnavailable`, the same two fields and
the same 25%/25% defaults that govern any forward rolling update. There
is nothing rollback-specific about these fields; they simply apply again
because a rollback is, mechanically, just another rollout.
- If the Deployment is currently `Recreate`, the rollback terminates
every currently running Pod first, and only then creates Pods for the
target revision — the same downtime window covered in this demo's
Recreate section, regardless of which strategy originally produced the
revision being restored. `maxSurge` and `maxUnavailable` don't apply at
all here; those fields only exist under `strategy.rollingUpdate` and are
only read when `strategy.type` is `RollingUpdate`.

Two further conditions govern whether a rollback can proceed at all,
independent of strategy: `spec.revisionHistoryLimit` (default 10) bounds
how many old ReplicaSets — and therefore how many past revisions — still
exist to roll back to; targeting a revision that's aged out fails
outright. And a paused Deployment (`spec.paused: true`) cannot be rolled
back until it's resumed — `rollout undo` is blocked by pause the same way
any other rollout is.

**Does rollback create a new ReplicaSet, or reuse an existing one?** This
is worth being precise about, because it's easy to conflate with "rollback
creates a new revision" — those are two different objects. The revision
*number* always advances (confirmed above). The **ReplicaSet object**
behaves differently: since old ReplicaSets aren't deleted when they're
scaled to 0 — they're kept around, up to `revisionHistoryLimit`, precisely
so rollback has something to scale back up — a rollback to a revision
whose ReplicaSet still exists **reuses that same object** rather than
creating a new one. Its `pod-template-hash` doesn't change, because its
Pod template doesn't change; only its replica count and its
`deployment.kubernetes.io/revision` annotation get updated. A brand-new
ReplicaSet is only created if no existing one still matches the target
template's hash — for example, if it was already garbage-collected past
`revisionHistoryLimit`.

You'll see direct evidence of this reuse in this demo's own Step 8 (the
rollback target is found already sitting at full replica count, having
never been scaled to 0 in the first place) and Step 15 (the Recreate
rollback brings back Pods carrying the *exact same* hash as the original
ReplicaSet, not a new one) — both are called out explicitly at those
steps.

**Revision History:**

```
Revision 1: nginx:1.28.3 (Initial)  ← Can rollback here
Revision 2: nginx:1.29.5 (Updated)  ← Can rollback here
Revision 3: nginx:1.30.4 (Current)  ← Current version
```

---

### Beyond RollingUpdate and Recreate

RollingUpdate and Recreate are the only two strategies `spec.strategy.type`
accepts natively, and both operate entirely within a single Deployment —
no other object is involved. Neither gives you fine-grained traffic
control (e.g. "send exactly 10% of traffic to the new version and watch
metrics before continuing"), because both replace Pods at the
whole-Deployment level, not the per-request level — there's no concept of
"some requests go one way, some go another" anywhere in this demo's
mechanism.

Blue-Green and Canary, covered next in `03-deployment-strategies`, solve
that by stepping outside a single Deployment entirely: each pattern runs
**two separate Deployments** side by side, and uses a **Service's
selector** to decide which one actually receives traffic. That's the
fundamental difference between the two groups — RollingUpdate/Recreate
are Deployment-native strategies with no Service involved at all; Blue-Green/Canary are Service-routing patterns built on top of two ordinary
Deployments, where the traffic split (instant switch, or a gradual
percentage) is controlled entirely by what the Service's selector
currently matches, not by anything inside `spec.strategy`.

---

## Lab Step-by-Step Guide

```bash
cd 02-deployments/02-rolling-update-recreate/src
```

### Step 1: Deploy Initial Version (v1)

Create the first version of our deployment:

**01-nginx-deploy-v1.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
  annotations:
    kubernetes.io/change-cause: "Initial deployment with nginx:1.28.3"
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
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
        image: nginx:1.28.3
        ports:
        - containerPort: 80
```

**Key Configuration Fields:**

- `annotations.kubernetes.io/change-cause` - Records why this revision was created (shows in rollout history)
- `strategy.type: RollingUpdate` - Use rolling update strategy (default)
- `maxSurge: 1` - Allow 1 extra pod during update (can have 4 pods when replicas=3)
- `maxUnavailable: 0` - No pods can be unavailable (zero downtime)
- `image: nginx:1.28.3` - Starting with an older nginx stable release, on purpose — this demo's whole point is watching it progress

```bash
kubectl apply -f 01-nginx-deploy-v1.yaml
```

**Expected output:**

```
deployment.apps/nginx-deploy created
```

---

### Step 2: Verify Initial Deployment

```bash
# Check deployment
kubectl get deployments

# Check pods, and which node/IP each landed on
kubectl get pods -o wide

# Verify the image version
kubectl describe deployment nginx-deploy | grep Image
```

**Expected output:**

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deploy   3/3     3            3           20s
```

**Now capture the ReplicaSet-level baseline — this is what you'll directly
compare Step 4's output against, to see exactly what a rolling update
changes and what it doesn't:**

```bash
# List ReplicaSets — note there's exactly one right now
kubectl get rs

# Full detail on that ReplicaSet — note the revision annotation
kubectl describe rs -l app=nginx

# Full detail on one pod
kubectl describe pod -l app=nginx
```

**Expected output:**

```
NAME                     DESIRED   CURRENT   READY   AGE
nginx-deploy-df4f544ff   3         3         3       20s
```

```
Name:           nginx-deploy-df4f544ff
Selector:       app=nginx,pod-template-hash=df4f544ff
Annotations:    deployment.kubernetes.io/desired-replicas: 3
                deployment.kubernetes.io/max-replicas: 4
                deployment.kubernetes.io/revision: 1
                kubernetes.io/change-cause: Initial deployment with nginx:1.28.3
Controlled By:  Deployment/nginx-deploy
Replicas:       3 current / 3 desired
```

Two things worth noticing now, before Step 4 changes anything:

- `deployment.kubernetes.io/max-replicas: 4` already appears here, even
  though nothing is surging yet. It's precomputed once, up front, from
  `replicas (3) + maxSurge (1)` — not something that only shows up
  mid-rollout. If you see it for the first time during Step 4's rollout
  and wonder whether something's wrong, it isn't — it was here the whole
  time.
- `deployment.kubernetes.io/revision: 1` and the `change-cause` annotation
  are both on the **ReplicaSet**, not just the Deployment — this is the
  concrete evidence for "revision history is stored in the ReplicaSets,"
  covered in full in **Understanding Rollback** below.

---

### Step 3: Check Initial Rollout History

```bash
kubectl rollout history deployment nginx-deploy
```

**Expected output:**

```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.28.3
```

The `CHANGE-CAUSE` comes from the annotation we added in the YAML.

---

### Step 4: Perform Rolling Update to v2

Now let's update to nginx 1.29.5. Open **three** terminal windows to watch
the update happen at both the Pod and ReplicaSet level simultaneously —
this is exactly where you'll see the `pod-template-hash` mechanism from `01-basic-deployment` produce a second, distinct ReplicaSet.

**02-nginx-deploy-v2.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
  annotations:
    kubernetes.io/change-cause: "Updated to nginx:1.29.5"
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
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
        image: nginx:1.29.5   # Changed from 1.28.3 to 1.29.5
        ports:
        - containerPort: 80
```

**Terminal 1 - Watch pods in real-time:**

```bash
kubectl get pods -w
```

**Terminal 2 - Watch ReplicaSets in real-time:**

```bash
kubectl get rs -w
```

**Terminal 3 - Apply the update:**

```bash
kubectl apply -f 02-nginx-deploy-v2.yaml
```



**What you'll observe in Terminal 1:**

1. New pod created (maxSurge allows 4th pod)
2. New pod becomes `Running`
3. One old pod goes to `Terminating`
4. Process repeats until all 3 pods are updated
5. Total pods never drops below 3 (maxUnavailable: 0)

**What you'll observe in Terminal 2 — this is the payoff of `01-basic-deployment`'s forward reference:**

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6f8b9d7c5     2         2         2       2m    ← OLD ReplicaSet, scaling DOWN
nginx-deploy-7d4c8a9f2     2         2         2       15s   ← NEW ReplicaSet, scaling UP
```

Two ReplicaSets, two different `pod-template-hash` values, existing
simultaneously — the old one's replica count counts down to 0 as the new
one counts up to 3. Neither Deployment nor either ReplicaSet ever mutates
a Pod's image in place; the old ReplicaSet's Pods are deleted and the new
ReplicaSet's Pods are created, exactly per the ownership model from `01-basic-deployment`'s End-to-End section.

Press `Ctrl+C` in Terminals 1 and 2 to stop watching.

**Now check the rollout status directly, and compare against Step 2's
baseline to see exactly what changed:**

```bash
kubectl rollout status deployment nginx-deploy
kubectl describe deployment nginx-deploy
```

**Expected output (trimmed to the parts that matter for this comparison):**

```
Annotations:            deployment.kubernetes.io/revision: 2
                        kubernetes.io/change-cause: Updated to nginx:1.29.5
RollingUpdateStrategy:  0 max unavailable, 1 max surge
OldReplicaSets:  nginx-deploy-df4f544ff (0/0 replicas created)
NewReplicaSet:   nginx-deploy-67cff8db4 (3/3 replicas created)
Events:
  Normal  ScalingReplicaSet  ...  Scaled up replica set nginx-deploy-67cff8db4 from 0 to 1
  Normal  ScalingReplicaSet  ...  Scaled down replica set nginx-deploy-df4f544ff from 3 to 2
  Normal  ScalingReplicaSet  ...  Scaled up replica set nginx-deploy-67cff8db4 from 1 to 2
  Normal  ScalingReplicaSet  ...  Scaled down replica set nginx-deploy-df4f544ff from 2 to 1
  Normal  ScalingReplicaSet  ...  Scaled up replica set nginx-deploy-67cff8db4 from 2 to 3
  Normal  ScalingReplicaSet  ...  Scaled down replica set nginx-deploy-df4f544ff from 1 to 0
```

Compare this directly against Step 2's baseline. Exactly three things
changed, and nothing else: `deployment.kubernetes.io/revision` (1 → 2),
the `kubernetes.io/change-cause` text, and which ReplicaSet is now listed
as `NewReplicaSet` vs `OldReplicaSets`. The old ReplicaSet
(`nginx-deploy-df4f544ff`) isn't deleted when a rollout finishes — it's
parked at `0/0 replicas created`, still holding its own revision-1
annotation, ready to be reused if you ever roll back to it. The `Events`
list is the ScalingReplicaSet sequence referenced throughout this demo's
Concepts section — surge up one, retire one, repeat, until fully swapped.

**Monitor the rollout status directly (blocks until complete):**

```bash
kubectl rollout status deployment nginx-deploy
```

**Expected output:**

```
Waiting for deployment "nginx-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

**Verify the update landed correctly:**

```bash
kubectl get deployment nginx-deploy
kubectl describe deployment nginx-deploy | grep Image
kubectl rollout history deployment nginx-deploy
```

**Expected rollout history:**

```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.28.3
2         Updated to nginx:1.29.5
```

---

### Step 5: Alternative Update Methods

Besides applying a new YAML file, you can update using kubectl commands.

**A note before you start — don't reach for `--record`.** You may see
`kubectl set image ... --record` in older tutorials as "the fast way" to
set a change-cause. Don't use it: the official Deployments documentation
states plainly that this flag is deprecated and slated for removal in a
future release, and multiple current reports show it's already fully
**unrecognized** on recent kubectl versions — meaning the command can fail
outright with `unknown flag: --record` rather than just printing a
deprecation warning. The reliable, current approach is `kubectl set image`
**plus** a separate `kubectl annotate` (or setting the annotation directly
in YAML, as Step 1 already does).

**Method 1: `kubectl set image` + `kubectl annotate`**

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.30.4
kubectl annotate deployment/nginx-deploy \
  kubernetes.io/change-cause="Updated to nginx:1.30.4" --overwrite
```

**Method 2: Using `kubectl edit`**

Do the image change and the change-cause annotation update **in the same
edit session**, not two separate edits — this keeps them as a single
revision, the same way Step 1's YAML and Method 1 both do it in one shot.

```bash
kubectl edit deployment nginx-deploy
```

Inside the editor, before saving:
1. Find `spec.template.spec.containers[].image` and change the tag
2. Find (or add) `metadata.annotations.kubernetes.io/change-cause` at the
   top level and set it to describe this change
3. Save and exit once — both edits land as one revision

If you only change the image and skip the annotation, the new revision
inherits whatever `change-cause` was already on the Deployment, carried
forward unchanged — not blank, but stale and misleading. (This is exactly
the trap Step 11 falls into later, since it never sets a new annotation
before its update.)

For this lab, let's use Method 1 (already run above). Check history:

```bash
kubectl rollout history deployment nginx-deploy
```

**Expected output:**

```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.28.3
2         Updated to nginx:1.29.5
3         Updated to nginx:1.30.4
```

---

### Step 6: View Specific Revision Details

See what changed in a specific revision:

```bash
# View revision 2 details
kubectl rollout history deployment nginx-deploy --revision=2

# View revision 3 details
kubectl rollout history deployment nginx-deploy --revision=3
```

This shows the pod template for that revision, including the image
version.

**Expected output:**

```
deployment.apps/nginx-deploy with revision #2
Pod Template:
  Labels:       app=nginx
        pod-template-hash=67cff8db4
  Annotations:  kubernetes.io/change-cause: Updated to nginx:1.29.5
  Containers:
   nginx:
    Image:      nginx:1.29.5

deployment.apps/nginx-deploy with revision #3
Pod Template:
  Labels:       app=nginx
        pod-template-hash=75c57f599f
  Annotations:  kubernetes.io/change-cause: Updated to nginx:1.30.4
  Containers:
   nginx:
    Image:      nginx:1.30.4
```

**Observe:** each revision carries its own `pod-template-hash` — this is
the same hash you saw live on the ReplicaSets in Step 4, just archived
here per-revision. This is exactly what "revision history is stored in
the ReplicaSets" means concretely: `rollout history --revision=N` isn't
reading from some separate log, it's showing you one specific
ReplicaSet's stored template, identified by its revision annotation.

**Not to be confused with `kubectl rollout restart`** (introduced in
Concepts above) — that command *does* create a new template revision,
the same as any other change to `spec.template`. It patches a
`restartedAt` timestamp onto `spec.template.metadata.annotations`, which
is enough of a template change to produce a new `pod-template-hash`, a
new ReplicaSet, and a new row in `kubectl rollout history`. The
difference from the revisions in this step isn't "no new row" — it's
that the new row's `CHANGE-CAUSE` will show `<none>` (unless you
separately set the `kubernetes.io/change-cause` annotation), since
`rollout restart` never touches that annotation, and the image/spec you'd
see if you ran `kubectl rollout history --revision=<N>` on it will be
identical to the revision before it — only the `restartedAt` annotation
differs.

---

### Step 7: Simulate a Failed Update

Deploy a bad version that doesn't exist:

**03-nginx-deploy-v3.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
  annotations:
    kubernetes.io/change-cause: "Bad update - nginx:1.100 doesn't exist"
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
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
        image: nginx:1.100   # This version doesn't exist!
        ports:
        - containerPort: 80
```


```bash
kubectl apply -f 03-nginx-deploy-v3.yaml
```

Watch what happens:

```bash
kubectl get pods
```

**Expected output:**

```
NAME                            READY   STATUS             RESTARTS   AGE
nginx-deploy-6f8b9d7c5-xxxxx    1/1     Running            0          5m
nginx-deploy-6f8b9d7c5-xxxxx    1/1     Running            0          5m
nginx-deploy-6f8b9d7c5-xxxxx    1/1     Running            0          5m
nginx-deploy-9a1e3f8b7-xxxxx    0/1     ImagePullBackOff   0          30s
```

**What happened:** notice the new pod's name carries a **fourth**,
distinct `pod-template-hash` (`9a1e3f8b7`) — a fourth ReplicaSet was
created for this fourth template change on `nginx-deploy`, exactly as the
mechanism predicts. Confirm it directly:

```bash
kubectl get rs
```

**Expected output:**

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-56694c5fff   1         1         0       53s   ← NEW, bad image, stuck
nginx-deploy-67cff8db4    0         0         0       35m   ← revision 2, parked
nginx-deploy-75c57f599f   3         3         3       4m6s  ← revision 3, currently active
nginx-deploy-df4f544ff    0         0         0       43m   ← revision 1, parked
```

**Observe:** all **four** ReplicaSets this Deployment has ever created
still exist simultaneously — none of them get deleted as the Deployment
progresses, only scaled to 0. Three are parked at `0/0/0`, one (`75c57f599f`,
still on the working `nginx:1.30.4`) is fully active at `3/3/3`. This is
the direct evidence behind the rollback mechanism covered in Concepts:
every one of these parked ReplicaSets is a candidate for reuse the moment
you roll back to its revision. That ReplicaSet's one pod can't pull
`nginx:1.100` (it doesn't exist), so:

- Rolling update started
- New pod created but can't pull nginx:1.100 (doesn't exist)
- Pod stuck in `ImagePullBackOff` or `ErrImagePull` — full explanation of
this state in `01-core-concepts/03-pod-container-basics`
- Old pods still running (because maxUnavailable: 0)
- **Application remains available!**

Check the failing pod:

```bash
kubectl describe pod <pod-with-ImagePullBackOff>
```

**Expected error, verbatim:**

```
Warning  Failed  ...  kubelet  Failed to pull image "nginx:1.100": Error response from daemon: manifest for nginx:1.100 not found: manifest unknown: manifest unknown
```

---

### Step 8: Rollback to Previous Version

Since the update failed, let's rollback:

```bash
# Rollback to the previous revision (revision 3, nginx:1.30.4)
kubectl rollout undo deployment nginx-deploy
```

**Expected output:**

```
deployment.apps/nginx-deploy rolled back
```

Watch the rollback:

```bash
kubectl get pods -w
```

**What you'll see:**

- Failed pod(s) terminated
- Pods with working version (1.30.4) remain
- Rollback completes instantly

Press `Ctrl+C` to stop watching.

**Now confirm which ReplicaSet actually served the rollback:**

```bash
kubectl get rs
```

**Observe — this is the reuse mechanism from Concepts, made concrete:**
the rollback target here is revision 3's ReplicaSet (`nginx-deploy-75c57f599f`),
and because `nginx-deploy-df4f544ff`/`67cff8db4` were the only ones ever
scaled to 0, and `75c57f599f` had been the *active* ReplicaSet right up
until the bad update, it was **already sitting at `3/3/3`** — never
scaled down at all. So this particular rollback didn't even need to scale
anything up; it only had to scale the bad ReplicaSet
(`nginx-deploy-56694c5fff`) down to 0 and delete its failed pod. That's a
narrower, faster operation than the general "scale target up, scale
current down" description — worth knowing, since not every rollback looks
identical: how much scaling actually happens depends entirely on how far
the target ReplicaSet had already drifted from its desired count.

---

### Step 9: Verify Rollback

```bash
# Check deployment status
kubectl rollout status deployment nginx-deploy

# Verify image version is back to 1.30.4
kubectl describe deployment nginx-deploy | grep Image

# Rollback/Undo
kubectl rollout history deployment nginx-deploy

# Check rollout history
kubectl rollout history deployment nginx-deploy
```

**Important:** Notice in the history:

```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.28.3
2         Updated to nginx:1.29.5
4         Bad update - nginx:1.100 doesn't exist
5         Updated to nginx:1.30.4
```

Revision 3 is gone! When you rollback to a revision, that revision becomes the new current revision.

**Observe:** the jump from revision 4 straight to 5 — skipping neither
number nor reusing 3 — confirms the revision counter only ever moves
forward, regardless of which ReplicaSet actually served the rollback.
Compare this against Step 8's `get rs` output: the Deployment's
*revision annotation* advanced to a brand-new number, but the *ReplicaSet
object* underneath it (`nginx-deploy-75c57f599f`) is the same one that's
existed since Step 7 — its `deployment.kubernetes.io/revision` annotation
is what got bumped to `5`, not its identity or its `pod-template-hash`.

---

### Step 10: Rollback to Specific Revision

You can rollback to any previous revision:

```bash
# Rollback to revision 2 (nginx:1.29.5)
kubectl rollout undo deployment nginx-deploy --to-revision=2
```

Verify:

```bash
kubectl describe deployment nginx-deploy | grep Image
```

Should show: `Image: nginx:1.29.5`

**Capture this live before moving on:**

```bash
kubectl rollout history deployment nginx-deploy
kubectl get rs
```

Predict both outputs before running them, using the same logic as Steps
8–9: which existing ReplicaSet (by hash) will this rollback reuse, what
new revision number will it land on, and will anything actually need to
scale up this time, or is the target already at full count like Step 8
was? Confirm your prediction against the real output.

---

### Step 11: Pause and Resume Rollouts

For advanced control, you can pause rollouts:

```bash
# Start an update
kubectl set image deployment/nginx-deploy nginx=nginx:1.31.3

# Pause immediately
kubectl rollout pause deployment nginx-deploy
```

Check pods:

```bash
kubectl get pods
```

You'll see a mix of old and new versions (canary-style deployment) —
a manual, coarse-grained preview of what `03-deployment-strategies`'
Canary pattern automates properly.

**A timing caveat worth knowing:** on a small, fast local cluster, this
race can be lost entirely — all 3 pods may already finish updating before
`kubectl rollout pause` takes effect, so you might see 3/3 already on the
new image with nothing left to pause. If that happens, it doesn't mean
pause is broken; it means the rollout simply outran the command.Also
note this step never sets a new `change-cause` annotation, so the
resulting revision's `CHANGE-CAUSE` will show whatever text was already
on the Deployment from the previous step — stale, not blank, and not a
sign of anything wrong either.

**Confirm the stale-annotation effect directly:**

```bash
kubectl rollout history deployment nginx-deploy
```

**Real captured output:**

```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.28.3
4         Bad update - nginx:1.100 doesn't exist
5         Updated to nginx:1.30.4
6         Updated to nginx:1.29.5
7         Updated to nginx:1.29.5
```

**Observe:** revision 7 is this step's update to `nginx:1.31.3` — but its
`CHANGE-CAUSE` reads `"Updated to nginx:1.29.5"`, word-for-word identical
to revision 6. This step never calls `kubectl annotate`, so the Deployment
simply kept whatever `change-cause` annotation was already sitting on it
from the previous step and carried it forward onto the new revision. This
is exactly the failure mode Step 5's Method 2 note warns about — it isn't
hypothetical, it's what happens the moment a step forgets the annotation.

Resume when ready:

```bash
kubectl rollout resume deployment nginx-deploy
```

The rollout continues to completion.

---

### Step 12: `kubectl rollout restart` — Force a Fresh Rollout

Concepts above explained what `rollout restart` actually does — worth
seeing it live before this Deployment gets cleaned up in a couple of
steps.

**Check the current revision count first:**

```bash
kubectl rollout history deployment nginx-deploy
```

**Trigger the restart:**

```bash
kubectl rollout restart deployment/nginx-deploy
kubectl rollout status deployment/nginx-deploy
```

**Check history again:**

```bash
kubectl rollout history deployment nginx-deploy
```

**Observe:** exactly one new revision appears — one higher than whatever
you were on — with `CHANGE-CAUSE` showing `<none>`, since `rollout restart`
never touches that annotation. Confirm the mechanism directly:

```bash
kubectl get rs
kubectl describe deployment nginx-deploy | grep -A3 "Pod Template"
```

You'll see a brand-new ReplicaSet with a new `pod-template-hash`, and a
`kubectl.kubernetes.io/restartedAt` timestamp annotation under the Pod
Template's `Annotations` — that annotation is the entire "change" that
triggered this rollout. Everything else (image, resources, labels) is
byte-for-byte identical to the revision before it.

---

### Step 13: Rollover and Proportional Scaling

This step covers two related behaviors — Rollover and Proportional
Scaling — both proven on a disposable Deployment kept isolated from the
main lab's revision history.

**Part A: Trigger a Rollover**

This part proves **Rollover** from Concepts above.

> **Uses a separate, disposable Deployment.** This step (and Part B) run
> several extra `kubectl set image` calls in quick succession purely to
> trigger the behavior — each one is a real template change, and each
> creates a real revision. Running these against `nginx-deploy` would
> throw off every hardcoded revision number in this demo's main
> walkthrough (Steps 4–11). So this
> step spins up a throwaway `nginx-rollover-demo` Deployment instead —
> `nginx-deploy`'s revision history stays exactly as clean as the main
> walkthrough expects it to be.

```bash
kubectl create deployment nginx-rollover-demo --image=nginx:1.28.3 --replicas=3
kubectl rollout status deployment/nginx-rollover-demo
```

**Terminal 2 (new) — watch ReplicaSets for this Deployment:**

```bash
kubectl get rs -l app=nginx-rollover-demo -w
```

**Terminal 3 — trigger two updates back to back, without waiting:**

```bash
kubectl set image deployment/nginx-rollover-demo nginx=nginx:1.31.3
# don't wait for this to finish — immediately apply again:
kubectl set image deployment/nginx-rollover-demo nginx=nginx:1.30.4
```

**What you'll observe in Terminal 2:** briefly, **three** ReplicaSets at
once — the original, the `1.31.3` one that never got to finish, and a new
one for `1.30.4` — with the first two both scaling toward 0 together
while the third scales up. Nothing waited for the `1.31.3` rollout to
complete before starting the next one; Kubernetes computed a new
`pod-template-hash` the instant it saw a new template, regardless of what
was already in flight.

**Real captured output, showing the moment all three overlap:**

```
NAME                              DESIRED   CURRENT   READY   AGE
nginx-rollover-demo-698484b6      3         3         3       16s   ← original
nginx-rollover-demo-5fc57d5b96    1         1         1       3s    ← 1.31.3, abandoned mid-rollout
nginx-rollover-demo-698484b6      2         3         3       71s
...
nginx-rollover-demo-698484b6      0         0         0       74s   ← original fully retired
nginx-rollover-demo-8cf6977f4     1         1         1       2s    ← 1.30.4, the actual target
nginx-rollover-demo-5fc57d5b96    2         3         3       8s    ← abandoned RS still scaling DOWN
...
nginx-rollover-demo-5fc57d5b96    0         0         0       10s   ← abandoned RS reaches 0
nginx-rollover-demo-8cf6977f4     3         3         3       4s    ← 1.30.4 fully up
```

```bash
kubectl rollout status deployment/nginx-rollover-demo
kubectl rollout history deployment/nginx-rollover-demo
```

**Expected output:**

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>
```

**Observe:** revision 2 (the abandoned `1.31.3` change) is a permanent,
real entry in history — even though its ReplicaSet never finished scaling
up before revision 3 superseded it. Also notice `CHANGE-CAUSE` reads
`<none>` for every revision here: this Deployment was created imperatively
with `kubectl create deployment`, and every update used `kubectl set
image` alone, with no annotation ever set — this is the "blank
CHANGE-CAUSE" case referenced in Step 5's note, seen live rather than just
described.

---

**Part B: Trigger Proportional Scaling Mid-Rollout**

This part proves **Proportional Scaling** from Concepts above — also
against the disposable `nginx-rollover-demo` Deployment from Part A, for
the same reason.

```bash
# Terminal 2, still watching: kubectl get rs -l app=nginx-rollover-demo -w

# Terminal 3
kubectl set image deployment/nginx-rollover-demo nginx=nginx:1.29.5
# immediately, while the rollout above is still in progress:
kubectl scale deployment nginx-rollover-demo --replicas=6
```

**What you'll observe in Terminal 2:** both the old and new ReplicaSets
gain replicas, not just the new one — the additional 3 pods (from 3 to 6)
get distributed across both ReplicaSets in roughly the same proportion
they already held, rather than all 3 landing on the newest ReplicaSet
alone.

**Real captured output — watch the DESIRED column on both ReplicaSets
jump together, right at the scale command:**

```
NAME                              DESIRED   CURRENT   READY   AGE
nginx-rollover-demo-8cf6977f4     2         3         3       2m36s   ← old, mid-rollout
nginx-rollover-demo-5f559449fc    2         1         1       2s      ← new, mid-rollout
nginx-rollover-demo-5f559449fc    4         2         1       2s      ← scale to 6 lands HERE
nginx-rollover-demo-8cf6977f4     4         2         2       2m36s   ← both jump together
...
nginx-rollover-demo-5f559449fc    6         6         6       6s      ← new settles at 6
nginx-rollover-demo-8cf6977f4     0         0         0       3m37s   ← old fully retired
```

**Observe:** the instant `kubectl scale --replicas=6` lands, **both**
ReplicaSets' `DESIRED` counts jump in the same tick — `8cf6977f4` from 2
to 4, `5f559449fc` from 2 to 4 — before either finishes converging. Note
this isn't a strict "same proportion as before" split (2:2 stayed 4:4
only briefly); the controller recalculates the proportional split on
every reconcile as the rollout continues advancing underneath the scale,
so the exact intermediate numbers move around before settling at the
final 0:6. The point to take away isn't the precise ratio at every tick —
it's that **both** ReplicaSets visibly react to the scale command
together, which is the part a naive "all new capacity goes to the newest
ReplicaSet" assumption gets wrong.

```bash
kubectl rollout status deployment/nginx-rollover-demo
```

**Cleanup for Step 13:**

```bash
kubectl delete deployment nginx-rollover-demo
```

---

### Step 14: Cleanup

```bash
kubectl delete -f 01-nginx-deploy-v1.yaml
```

Verify deletion:

```bash
kubectl get deployments
kubectl get pods
```

---

### Step 15: Recreate Strategy — Deep Dive

Every step so far in this demo used `RollingUpdate` — the default, and the
strategy you'll use for almost everything. This section covers the other
built-in strategy: `Recreate`. The concept is intentionally simple —
**terminate every existing Pod first, then create every new Pod** — but
"simple" is exactly why it's worth doing hands-on: the downtime window it
produces is easy to describe and easy to *actually watch happen*, which
is the point.

**04-nginx-deploy-recreate-v1.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-recreate-demo
  annotations:
    kubernetes.io/change-cause: "Initial Recreate-strategy deployment with nginx:1.28.3"
spec:
  replicas: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nginx-recreate-demo
  template:
    metadata:
      labels:
        app: nginx-recreate-demo
    spec:
      containers:
        - name: nginx
          image: nginx:1.28.3
          ports:
            - containerPort: 80
```

```bash
cd 02-deployments/02-rolling-update-recreate/src
kubectl apply -f 04-nginx-deploy-recreate-v1.yaml
kubectl get pods -l app=nginx-recreate-demo
# Expect 3/3 Running before continuing
```

**Watch the downtime window directly.** Open two terminals.

**Terminal 1 — watch pods in real time:**

```bash
kubectl get pods -l app=nginx-recreate-demo -w
```

**Terminal 2 — trigger the update:**

```bash
kubectl set image deployment/nginx-recreate-demo nginx=nginx:1.29.5
```

**What you'll observe in Terminal 1 — contrast this directly against
Step 4's RollingUpdate output:**

```
NAME                                   READY   STATUS        AGE
nginx-recreate-demo-<old-hash>-xxxxx   1/1     Terminating   2m
nginx-recreate-demo-<old-hash>-xxxxx   1/1     Terminating   2m
nginx-recreate-demo-<old-hash>-xxxxx   1/1     Terminating   2m
#  ← all 3 old pods gone — zero pods matching this Deployment exist right now
nginx-recreate-demo-<new-hash>-xxxxx   0/1     Pending       0s
nginx-recreate-demo-<new-hash>-xxxxx   0/1     ContainerCreating   0s
nginx-recreate-demo-<new-hash>-xxxxx   1/1     Running       2s
nginx-recreate-demo-<new-hash>-xxxxx   1/1     Running       2s
nginx-recreate-demo-<new-hash>-xxxxx   1/1     Running       2s
```

Press `Ctrl+C` to stop watching.

**Confirm the gap with `kubectl get rs`:**

```bash
kubectl get rs -l app=nginx-recreate-demo
```

Unlike Step 4's RollingUpdate output — where two ReplicaSets briefly
showed nonzero `CURRENT` counts simultaneously — here you'll only ever
catch the old ReplicaSet at `0/0/0` *before* the new one starts scaling,
never both with Pods at once. If you're fast enough with a second
`watch kubectl get rs -l app=nginx-recreate-demo` running in a third
terminal during the update, you can catch that exact 0-Pod moment.

**Measure the actual downtime (optional, illustrative):**

```bash
# In a loop, hit the service while triggering an update in another terminal
kubectl expose deployment nginx-recreate-demo --port=80 --target-port=80 --type=NodePort
minikube service nginx-recreate-demo --url
# In one terminal:
while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" <service-url>; sleep 0.5; done
# In another terminal, trigger the update again:
kubectl set image deployment/nginx-recreate-demo nginx=nginx:1.30.4
```

You'll see a run of connection failures (or a timed-out `curl`) during the
gap where zero Pods exist — this is the concrete, measurable version of
the "💥 ALL DOWN 💥" line in the diagram above, not just a theoretical
claim.

**Rollback works identically to RollingUpdate** — Recreate doesn't change
anything about revision history or `kubectl rollout undo`:

```bash
kubectl rollout undo deployment nginx-recreate-demo
```

This rollback itself *also* goes through the full terminate-then-create
sequence, since the Deployment's `strategy.type` is still `Recreate` —
worth predicting before you run it: expect another downtime window on the
way back down, not an instant switch.

**Confirm which ReplicaSet comes back:**

```bash
kubectl get rs -l app=nginx-recreate-demo
kubectl rollout history deployment nginx-recreate-demo
```

**Real captured output:**

```
NAME                             DESIRED   CURRENT   READY   AGE
nginx-recreate-demo-5dd5497877   0         0         0       2m38s
nginx-recreate-demo-75c9488c86   3         3         3       76s
```
```
REVISION  CHANGE-CAUSE
2         Initial Recreate-strategy deployment with nginx:1.28.3
3         Initial Recreate-strategy deployment with nginx:1.28.3
```

**Observe — this is the ReplicaSet-reuse mechanism from Concepts, seen
directly under Recreate:** watch the pods that come back after the
rollback — they carry hash `5dd5497877`, the **exact same** hash as the
very first ReplicaSet this Deployment ever created, not a new one. The
rollback didn't build a fresh ReplicaSet for revision 1's template; it
found `5dd5497877` still parked at 0 (never garbage-collected, since it's
well within `revisionHistoryLimit`) and scaled it back up in place. This
is also why the `CHANGE-CAUSE` text looks identical on both revision 2
and 3 above — the annotation carried forward with the reused object,
exactly as Step 11 demonstrated for RollingUpdate.

**When Recreate is actually the right choice:**

- The application genuinely cannot run two versions simultaneously — e.g.
  a schema-incompatible database migration where old and new Pods hitting
  the same database at once would corrupt data
- Dev/test environments where a downtime window is a non-issue and the
  simplicity (no `maxSurge`/`maxUnavailable` tuning at all) is worth more
  than availability
- Singleton-style workloads that can't tolerate two instances existing at
  once for correctness reasons, and aren't a good fit for a
  `StatefulSet` either

**Cleanup:**

```bash
kubectl delete deployment nginx-recreate-demo
kubectl delete service nginx-recreate-demo 2>/dev/null || true
```

---

## What You Learned

In this lab, you:

- ✅ Performed zero-downtime rolling updates by changing container images
- ✅ Configured maxSurge and maxUnavailable for controlled updates
- ✅ Monitored rollout progress with kubectl rollout status
- ✅ Tracked deployment history with change-cause annotations, without depending on the deprecated (and possibly already-removed) `--record` flag
- ✅ Rolled back failed deployments to previous working versions
- ✅ Used specific revision rollbacks with --to-revision flag
- ✅ Paused and resumed rollouts for advanced deployment control
- ✅ Understood the difference between RollingUpdate and Recreate strategies, and where `kubectl rollout restart` actually fits (it follows whichever strategy is already configured, and does change the template via a `restartedAt` annotation — not an instant, strategy-exempt recreate)
- ✅ Watched a second (and later, a third and fourth) ReplicaSet appear with its own `pod-template-hash` during rollouts, confirming the mechanism from `01-basic-deployment`
- ✅ Triggered a Rollover — a second update applied before the first finished — and watched three ReplicaSets converge at once, on a disposable Deployment kept isolated from the main lab's revision history
- ✅ Triggered proportional scaling and watched a mid-rollout scale distribute across both old and new ReplicaSets, not just the new one
- ✅ Confirmed `maxSurge`+`maxUnavailable` both `0` is rejected outright, and know why
- ✅ Detected a genuinely stalled rollout via `ProgressDeadlineExceeded` directly, and know it doesn't trigger an automatic rollback
- ✅ Deployed using the `Recreate` strategy and directly observed its downtime window, in contrast to RollingUpdate's zero-downtime behavior
- ✅ Identified when `Recreate` is the appropriate choice despite its downtime cost

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**Scenario:** A routine image update to a Deployment with tight resource
requests never seems to finish. Investigate why, before revealing the
cause.

**`src/break-fix/01-surge-stall.yaml`:**

First apply a working Deployment with modest resource requests:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: surge-stall-demo
spec:
  replicas: 3
  progressDeadlineSeconds: 30   # lowered from the 600s default purely so
                                 # ProgressDeadlineExceeded is observable
                                 # in this exercise without a long wait
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: surge-stall-demo
  template:
    metadata:
      labels:
        app: surge-stall-demo
    spec:
      containers:
        - name: nginx
          image: nginx:1.28.3
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
```

```bash
kubectl apply -f 01-surge-stall.yaml
kubectl get pods -l app=surge-stall-demo
# should show 3/3 Running
```

Now edit the file to trigger an update that also bumps the CPU request far
beyond what any node in this cluster has free:

```bash
vi 01-surge-stall.yaml
```

Change `image: nginx:1.28.3` to `image: nginx:1.29.5`, **and** change `cpu: "100m"` (under `resources.requests`) to `cpu: "8"` — 8 whole CPU
cores, not 8 millicores. Save and exit, then reapply:

```bash
kubectl apply -f 01-surge-stall.yaml
kubectl rollout status deployment surge-stall-demo
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `maxSurge: 1` means the rollout needs to schedule one additional
pod before it can retire an old one — but that surge pod now requests 8
full CPU cores, which no node in this cluster has free. The scheduler can
never place it, so the rollout stalls indefinitely with `kubectl rollout status` reporting `Waiting for deployment "surge-stall-demo" rollout to finish: 0 out of 3 new replicas have been updated...` and never
progressing further.

**Fix:** `kubectl describe pod <surge-pod-name>` shows a `FailedScheduling` event citing insufficient CPU — the fix is either lowering the resource
request back to something the cluster can actually satisfy, or (in a real
cluster) adding node capacity. You can also `kubectl rollout undo` to
abandon the stuck rollout entirely.

**Cascade:** all 3 original pods keep running the whole time — because `maxUnavailable: 0`, nothing old is ever torn down until a replacement is
ready, and the replacement is never ready. This looks alarming
("rollout stuck!") but is actually the safety mechanism working exactly as
designed — the real bug is the resource request, not the rollout
mechanism itself.

**Wait past 30 seconds, and check `ProgressDeadlineExceeded` directly —
this is the concrete version of the Concepts section above:**
```bash
kubectl get deployment surge-stall-demo -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'
# ProgressDeadlineExceeded
kubectl rollout status deployment surge-stall-demo
# error: deployment "surge-stall-demo" exceeded its progress deadline
```
Notice `kubectl rollout status` now returns an error and a non-zero exit
code instead of continuing to wait — and notice the 3 original pods are
*still* running even now. `ProgressDeadlineExceeded` is a reporting state,
not an automatic rollback; the stuck rollout stays exactly as stuck as it
was until you `rollout undo` or fix the resource request.

</details>

**Cleanup:**

```bash
kubectl delete deployment surge-stall-demo 2>/dev/null || true
```

---

### Error-2

**Scenario:** A teammate wants "maximum safety" during rollouts and sets
both surge and unavailable knobs to their most conservative values. The
Deployment won't even apply. Investigate why, before revealing the cause.

```bash
kubectl create deployment zero-zero-demo --image=nginx:1.30.4 --replicas=3 \
  --dry-run=client -o yaml > 02-zero-zero.yaml
```

Edit `02-zero-zero.yaml` to add, under `spec`:
```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 0
```

```bash
kubectl apply -f 02-zero-zero.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `maxSurge: 0` and `maxUnavailable: 0` together are invalid —
verified against the API's own validation, not just a lint warning
(the exact rejection reads `spec.strategy.rollingUpdate.maxUnavailable:
Invalid value: 0: may not be 0 when \`maxSurge\` is 0`). With neither
allowed to add a pod nor remove one, a rollout using this Deployment
could never make progress at all, so Kubernetes rejects the object
outright at `apply` time rather than accepting a configuration that
would deadlock the first real update.

**Fix:** At least one of the two needs to allow movement — `maxSurge: 1, maxUnavailable: 0` (this demo's own default throughout) is the
zero-downtime-safe choice; `maxSurge: 0, maxUnavailable: 1` is the
resource-frugal alternative that briefly drops capacity instead.

**Cascade:** none — this fails validation before the object is ever
persisted, so nothing is created at all.

</details>

**Cleanup:** none needed — the `apply` never succeeded.

---

### Error-3

**Scenario:** Someone tries to roll back a Deployment to a revision number
they remember seeing a while ago, on a Deployment that's been through
several updates since. Investigate what happens and why, before revealing
the cause.

This error is self-contained on its own throwaway Deployment — it doesn't
depend on `nginx-deploy` from the main lab still existing, since Step 14
already deleted it.

```bash
kubectl create deployment revision-test-demo --image=nginx:1.28.3 --replicas=2
kubectl set image deployment/revision-test-demo nginx=nginx:1.29.5
kubectl rollout status deployment/revision-test-demo
kubectl rollout undo deployment revision-test-demo --to-revision=99
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Revision `99` was never created — this Deployment only has 2
real revisions (the initial create, and the one image update). More
generally, on a longer-lived Deployment, a requested revision can also
fail to exist because it's aged out of history past `spec.revisionHistoryLimit` (default 10). Either way, kubectl reports:

```
error: unable to find specified revision 99 in history
```

**Fix:** Run `kubectl rollout history deployment revision-test-demo` first
to see which revision numbers actually still exist, then target one of
those.

**Cascade:** none — this is a read-attempt against history that doesn't
exist; the Deployment's current running state is completely unaffected by
the failed `undo` command.

</details>

**Cleanup:**

```bash
kubectl delete deployment revision-test-demo 2>/dev/null || true
```

---

### Error-4

**Scenario:** A typo'd image tag gets deployed to a Recreate-strategy
Deployment. Compare what happens here to the identical typo under
RollingUpdate back in Step 9, and investigate why the outcome differs,
before revealing the cause.

**`src/break-fix/03-recreate-bad-image.yaml`:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recreate-stall-demo
spec:
  replicas: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: recreate-stall-demo
  template:
    metadata:
      labels:
        app: recreate-stall-demo
    spec:
      containers:
        - name: nginx
          image: nginx:1.28.3
```

```bash
kubectl apply -f 03-recreate-bad-image.yaml
kubectl get pods -l app=recreate-stall-demo
# should show 3/3 Running
```

Now trigger an update to a nonexistent tag:

```bash
kubectl set image deployment/recreate-stall-demo nginx=nginx:1.999-does-not-exist
kubectl get pods -l app=recreate-stall-demo -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** With `Recreate`, the controller doesn't wait to confirm the new
Pods actually come up healthy before it's already too late to avoid
downtime — it terminates every old Pod *unconditionally* first. Only
*then* does it try to create the new ones, which immediately hit
`ImagePullBackOff` because the tag doesn't exist. The result: **zero
healthy Pods, indefinitely** — not a brief gap, but a sustained outage,
since there's no old version left to fall back to and the new version can
never become Ready.

**Fix:** `kubectl rollout undo deployment recreate-stall-demo` — but note
this rollback *itself* uses `Recreate` too, so even the fix involves
another full terminate-then-create cycle, not an instant restoration.

**Cascade:** compare this directly to `02-rolling-update-recreate`'s own
Step 7 (Simulate a Failed Update) earlier in this same demo, which used
RollingUpdate: there, `maxUnavailable: 0` kept all 3 old Pods running
throughout, so the app stayed fully available despite the bad image.
Here, with Recreate, the exact same bad-image mistake produces a full
outage with no safety net — this is the single clearest concrete argument
for why RollingUpdate is the default and Recreate is the exception, not
the other way around.

</details>

**Cleanup:**

```bash
kubectl delete deployment recreate-stall-demo 2>/dev/null || true
```

---

## Interview Prep

**Q: What happens if I rollback during an active rollout?**
A: Kubernetes stops the current rollout and starts rolling back immediately. The deployment reverts to the target revision.

**Q: How many revisions does Kubernetes keep?**
A: By default, the last 10. You can change this with `spec.revisionHistoryLimit` — the field itself was already introduced (deferred) in `01-basic-deployment`; this is where it actually matters.

**Q: Can I rollback to any revision?**
A: Yes, use `--to-revision=N` where N is a revision number from `kubectl rollout history` — but only if that revision still exists. Targeting a pruned or nonexistent revision fails outright, as this demo's Break-Fix Error-3 shows.

**Q: What if maxUnavailable is set to 1 instead of 0?**
A: During updates, 1 pod can be unavailable at a time. For replicas=3, you might temporarily have only 2 pods running. This speeds up rollouts but reduces availability during the update window.

**Q: Does rollback create a new revision, or restore the old one in place?**
A: It creates a new revision, copying the old revision's configuration forward — the old revision number itself disappears from history, exactly as you saw in Step 11.

**Q: A rollout seems stuck with `maxUnavailable: 0`. What's the very first thing you'd check?**
A: Whether the surge pod can actually be scheduled and become Ready — check `kubectl describe pod` on the new pod for `FailedScheduling` events (resource requests too high) or a readiness probe that's never passing, rather than assuming the rollout mechanism itself is broken.

**Q: Is `kubectl rollout restart` an instant, all-at-once operation?**
A: No — it follows whichever strategy is currently configured (RollingUpdate or Recreate) and it does change the template, via a `restartedAt` annotation, which is exactly why it triggers a real rollout at all. It's easy to confuse with the `Recreate` strategy type because the word "recreate" comes up in both contexts, but they're unrelated: `Recreate` kills every pod first and is a `spec.strategy.type` value; `rollout restart` respects whatever strategy is already configured, RollingUpdate included.

**Q: Should you still use `kubectl set image ... --record`?**
A: No — the official Deployments documentation marks it deprecated and slated for removal, and current reports show it may already be a fully unrecognized flag on recent kubectl versions. Set `kubernetes.io/change-cause` directly, either in the YAML annotation or via a follow-up `kubectl annotate --overwrite`.

**Q: You apply a second update to a Deployment while the first rollout is still in progress. Does Kubernetes wait for the first one to finish?**
A: No — this is Rollover. Kubernetes immediately computes a new `pod-template-hash` for the second update and creates a new ReplicaSet, rolling the ReplicaSet it had been scaling up into its list of old ReplicaSets and scaling both down together while the newest one scales up. There's no queue.

**Q: You scale a Deployment while a rollout is still converging. Do all the new replicas go to the newest ReplicaSet?**
A: No — this is proportional scaling. The additional replicas are distributed across every ReplicaSet still in play, weighted by each one's current share, which keeps the configured surge/unavailable ratio roughly honored throughout rather than letting a mid-rollout scale silently violate it.

**Q: Can you configure `maxSurge: 0` and `maxUnavailable: 0` together?**
A: No — the API rejects it outright. That combination would leave a rollout with no way to add or remove a pod, so it could never make progress; at least one of the two has to allow movement.

**Q: A rollout shows `ProgressDeadlineExceeded`. Did Kubernetes automatically roll it back?**
A: No — this condition is purely a report that the rollout hasn't made progress within `progressDeadlineSeconds`. The stalled ReplicaSet keeps existing exactly as it was; nothing reverts automatically. You still have to `kubectl rollout undo` or fix the underlying problem yourself.

**Q: Why would a team ever choose `Recreate` over `RollingUpdate`?** A: When two versions genuinely cannot coexist — most commonly a breaking database schema migration — or in low-stakes dev/test environments where the downtime is a non-issue and the reduced configuration surface (no `maxSurge`/`maxUnavailable` tuning) is worth more than availability.

**Q: If a bad image is deployed under `Recreate`, can you fall back to the old version instantly?** A: No — by the time the bad image fails to pull, the old ReplicaSet has already been scaled to 0. Recovery requires `kubectl rollout undo`, which itself runs through another full Recreate cycle (terminate, then create), so there's a second downtime window on the way back too.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Deployment | CKAD | 20%    | Rolling updates, rollbacks, revision history        |
| Application Deployment | CKA  | —      | `kubectl rollout` command family                    |
| Application Deployment | CKAD | —      | Recreate strategy, Rollover, proportional scaling, `ProgressDeadlineExceeded` |
| Workloads & Scheduling | CKA  | 15%    | maxSurge/maxUnavailable interaction with scheduling |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Editing YAML for a pure image change                            | `kubectl set image deployment/name container=image` is far faster than editing and reapplying a whole file — know it cold for the exam |
| Forgetting `--to-revision=N` needs a revision that still exists | Fails with a clear error, but only if you already ran `rollout history` to know which numbers are valid |
| Assuming a stuck rollout means something is "broken" | Often it's `maxSurge`/scheduling capacity or a readiness probe never passing — check `describe pod` on the new pod before assuming a Kubernetes bug |
| Confusing rollback with "restoring revision N in place" | Rollback creates a *new* revision copying the old config — the old revision number is gone afterward, not restored |
| Reaching for `--record` from memory or an old tutorial | Officially deprecated and possibly already unrecognized on current kubectl — use the `kubernetes.io/change-cause` annotation directly instead |
| Assuming `kubectl rollout restart` only works under RollingUpdate, or leaves the template unchanged | It follows whichever strategy is currently configured, RollingUpdate or Recreate, and it does change the template — a `restartedAt` annotation — which is what triggers the rollout at all |
| Assuming a second update queues behind the first | It doesn't — Rollover means a new ReplicaSet appears immediately, with the previously-newest one rolled into the old list and scaled down alongside the rest |
| Assuming a mid-rollout scale only adds to the new ReplicaSet | Proportional scaling distributes the additional replicas across every ReplicaSet still in play, weighted by current share |
| Setting `maxSurge: 0` and `maxUnavailable: 0` together | Rejected outright by the API — that combination leaves no way to ever make progress |
| Assuming `ProgressDeadlineExceeded` means Kubernetes rolled back automatically | It's purely a reported condition — the stalled ReplicaSet stays exactly as stuck as it was until you intervene |

### Exam Task — Write it from scratch

Update `nginx-deploy`'s image to `nginx:1.30.4` using `kubectl set image`, add a `change-cause` annotation without using the deprecated `--record` flag, then roll it back to the previous revision.

Official docs: [Performing a Rolling Update](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/), [Rolling Back a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment)

<details>
<summary>Reveal solution</summary>

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.30.4
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="Updated to nginx:1.30.4" --overwrite
kubectl rollout undo deployment/nginx-deploy
```

**Key fields/commands to recall:** `kubectl set image`, `kubernetes.io/change-cause` annotation, `kubectl rollout undo` (no arguments = previous revision).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A rolling update creates a new ReplicaSet, it never mutates the existing one | Confirms `01-basic-deployment`'s `pod-template-hash` mechanism directly — old and new ReplicaSets coexist during the transition |
| `maxSurge` and `maxUnavailable` control the trade-off between speed and availability | Higher surge = faster but more resource usage; lower unavailable = safer but slower |
| A surge pod is scheduled like any other pod | If its resource requests can't be satisfied, the rollout stalls indefinitely — not a rollout bug, the scheduling safety mechanism working as designed |
| `maxUnavailable: 0` only guarantees zero downtime if new pods actually become Ready | Without a real readiness probe, "Ready" happens the instant the container starts, which is a much weaker guarantee |
| Rollback creates a new revision, it doesn't restore the old one in place | The old revision number disappears from history after a rollback |
| `revisionHistoryLimit` bounds how far back you can roll back | Targeting a pruned or nonexistent revision fails outright with a clear error |
| `--record` is officially deprecated, and possibly already non-functional | Current reports show recent kubectl may already reject it outright — use the `kubernetes.io/change-cause` annotation directly instead |
| `kubectl rollout restart` follows whichever strategy is currently configured, and does change the template | Governed by the same `maxSurge`/`maxUnavailable` as any other rollout under RollingUpdate — or the same terminate-then-create sequence under Recreate; a `restartedAt` annotation is what makes it a real template change |
| Pause/resume gives manual, coarse control over a rollout | A hand-operated preview of what Canary deployments (`03-deployment-strategies`) automate properly — and on a fast local cluster, pause can lose the race entirely if the rollout finishes before it takes effect |
| A second update doesn't queue behind an in-progress rollout (Rollover) | A new ReplicaSet appears immediately, with the previously-newest ReplicaSet rolled into the old list and scaled down alongside the rest |
| A mid-rollout scale distributes proportionally, not just onto the newest ReplicaSet | Keeps the configured surge/unavailable ratio roughly honored throughout, rather than letting a scale silently violate it |
| `maxSurge: 0` + `maxUnavailable: 0` is rejected outright | That combination would leave a rollout with no way to ever make progress |
| `ProgressDeadlineExceeded` is a report, not an automatic rollback | The stalled ReplicaSet stays exactly as stuck as it was until you intervene — `kubectl rollout status` also exits non-zero once this fires |
| `Recreate` has no `maxSurge`/`maxUnavailable` equivalent | It's all-or-nothing by design — old Pods fully terminate before any new Pod is created, with no partial-overlap state ever possible |
| A bad image under `Recreate` causes a full outage, not a contained failure | Unlike RollingUpdate with `maxUnavailable: 0`, there's no surviving old Pod to fall back on once the old ReplicaSet has already scaled to 0 |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f deployment.yaml` | Create or update deployment |
| `kubectl set image deploy/<name> <container>=<image>` | Update container image (fastest exam technique for this demo) |
| `kubectl rollout status deploy/<name>` | Watch rollout progress |
| `kubectl rollout history deploy/<name>` | View revision history |
| `kubectl rollout history deploy/<name> --revision=N` | View specific revision details |
| `kubectl rollout undo deploy/<name>` | Rollback to previous revision |
| `kubectl rollout undo deploy/<name> --to-revision=N` | Rollback to specific revision |
| `kubectl rollout pause deploy/<name>` | Pause ongoing rollout |
| `kubectl rollout resume deploy/<name>` | Resume paused rollout |
| `kubectl rollout restart deploy/<name>` | Trigger a fresh rollout (adds a `restartedAt` annotation) under whichever strategy is already configured — see Step 12/Concepts |
| `kubectl describe deploy/<name>` | Detailed deployment info |
| `kubectl get rs -w` | Watch ReplicaSets during a rollout — see Step 4 |
| `kubectl get deploy NAME -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}'` | Check for `ProgressDeadlineExceeded` directly, without waiting on `rollout status` |
| `kubectl get rs -l <selector> ` (during a Recreate update) | Confirm only one ReplicaSet ever has nonzero replicas at a time — contrast with `-w` on `kubectl get rs` during Step 4's RollingUpdate |

### Previewing an Update with --dry-run

`--dry-run=client -o yaml` isn't only for generating brand-new objects
from scratch (that use case is already covered in `01-basic-deployment`'s
Quick Commands Reference, since this demo never creates a Deployment from
nothing) — it also works on commands that *modify* an existing object,
letting you see exactly what would change before it actually happens:

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.30.4 --dry-run=client -o yaml
```

This prints the full resulting Deployment YAML with the new image already
substituted in, without touching the live cluster or triggering a real
rollout — useful for catching a typo'd image tag or confirming you're
targeting the right container name before committing to an actual update.

### Imperative Quick-Update Commands

| Action | Imperative command | Notes |
|---|---|---|
| Update image | `kubectl set image deploy/NAME container=IMG` | Fastest exam technique for a pure image change — see Step 5 |
| Add/update change-cause | `kubectl annotate deploy/NAME kubernetes.io/change-cause="..." --overwrite` | Do this right after `set image` — don't rely on the removed `--record` flag |
| Rollback | `kubectl rollout undo deploy/NAME [--to-revision=N]` | No `--to-revision` = previous revision |
| Force a fresh rollout, unchanged application config | `kubectl rollout restart deploy/NAME` | Adds a `restartedAt` annotation to the template — still governed by whichever strategy is currently configured, see Concepts above |

---

## Troubleshooting

**Rollout stuck in progress?**

```bash
kubectl rollout status deployment nginx-deploy
kubectl describe deployment nginx-deploy
kubectl get events --sort-by='.lastTimestamp'
```

Also check `kubectl describe pod` on the new pod specifically for `FailedScheduling` (resource capacity, per Break-Fix Error-1) — a stuck
rollout is very often a Pod-level problem, not a Deployment-level one.

**Can't find revision history?**

```bash
# Check revisionHistoryLimit
kubectl get deployment nginx-deploy -o yaml | grep revisionHistoryLimit
```

**Want to see both old and new ReplicaSets?**

```bash
kubectl get rs
# During rollout, you'll see two ReplicaSets
# Old one scaling down, new one scaling up
```

**`kubectl set image ... --record` failed with `unknown flag`?**

That's expected on current kubectl — see the note at the top of Step 5.
Use `kubectl set image` followed by a separate `kubectl annotate ... --overwrite` instead.

---

## Appendix — Anki Cards

**`02-rolling-update-recreate-anki.csv`:**

````
#deck:k8s-platform-labs::02-deployments::02-rolling-update-recreate
#separator:Comma
#columns:Front,Back,Tags
"When a rolling update happens, does the existing ReplicaSet get mutated in place?","No — a new ReplicaSet is created with a new pod-template-hash; the old one scales down to 0 rather than being changed","demo02-deployments,rolling-update,pod-template-hash,ckad-application-deployment"
"What does maxSurge control?","How many extra pods beyond the desired replica count can exist during a rollout","demo02-deployments,rolling-update,ckad-application-deployment"
"What does maxUnavailable: 0 actually guarantee?","Zero downtime, but only if new pods actually pass readiness — without a real readiness probe, Ready happens the instant the container starts","demo02-deployments,rolling-update,readiness,ckad-application-deployment"
"Why might a rollout with maxSurge:1 stall indefinitely?","The surge pod is scheduled like any other pod — if its resource requests can't be satisfied by any node, it never schedules and the rollout never progresses","demo02-deployments,rolling-update,scheduling,cka-workloads-scheduling"
"Does kubectl rollout undo restore the old revision number, or create a new one?","It creates a new revision copying the old configuration forward — the old revision number disappears from history","demo02-deployments,rollback,ckad-application-deployment"
"What happens if you kubectl rollout undo --to-revision=N and N doesn't exist?","kubectl fails outright: 'error: unable to find specified revision N in history'","demo02-deployments,rollback,ckad-application-deployment"
"What bounds how far back you can roll back a Deployment?","spec.revisionHistoryLimit (default 10) — revisions beyond that are pruned and can no longer be targeted","demo02-deployments,rollback,revisionhistorylimit,ckad-application-deployment"
"Is the --record flag still safe to rely on for tracking change-cause?","No — officially deprecated per the Kubernetes documentation, and current kubectl versions may already reject it outright as an unrecognized flag. Use the kubernetes.io/change-cause annotation directly instead","demo02-deployments,change-cause,ckad-application-deployment"
"What does kubectl rollout pause actually freeze?","The Deployment controller stops acting on further template changes mid-rollout, leaving a mix of old and new pods until resumed","demo02-deployments,pause-resume,ckad-application-deployment"
"What's the practical difference between RollingUpdate and Recreate strategies?","RollingUpdate replaces pods gradually with no downtime (if configured well); Recreate kills all old pods first, then creates new ones, causing a downtime window","demo02-deployments,strategy,ckad-application-deployment"
"Does kubectl rollout restart only work under the RollingUpdate strategy, and does it leave the pod template unchanged?","No to both — it follows whichever strategy is currently configured (RollingUpdate or Recreate), and it does change the template by adding a restartedAt annotation, which is exactly what triggers the rollout","demo02-deployments,rollout-restart,ckad-application-deployment"
"If you apply a second Deployment update while the first rollout is still in progress, does Kubernetes wait?","No — this is Rollover. A new ReplicaSet is created immediately from the new template, while the previously-newest ReplicaSet is rolled into the old list and scaled down alongside the rest","demo02-deployments,rollover,ckad-application-deployment"
"If you scale a Deployment mid-rollout, do all new replicas go to the newest ReplicaSet?","No — proportional scaling distributes the additional replicas across every ReplicaSet still in play, weighted by current share","demo02-deployments,proportional-scaling,cka-workloads-scheduling"
"Can maxSurge and maxUnavailable both be set to 0?","No — rejected outright by the API, since that combination would leave a rollout with no way to ever make progress","demo02-deployments,rollout-parameters,cka-workloads-scheduling"
"Does ProgressDeadlineExceeded trigger an automatic rollback?","No — it's purely a reported condition on the Deployment; the stalled ReplicaSet stays exactly as stuck as it was until you intervene manually","demo02-deployments,progress-deadline,ckad-application-deployment"
"What does spec.strategy.type: Recreate actually guarantee?","Old pods are all terminated before any new pod is created — no overlap between old and new, ever","demo02-deployments,recreate,ckad-application-deployment"
"Does spec.strategy.rollingUpdate have any effect when type is Recreate?","No — it's accepted by the schema but silently ignored; maxSurge/maxUnavailable are RollingUpdate-only fields","demo02-deployments,recreate,ckad-application-deployment"
"Under Recreate, can two ReplicaSets ever both have nonzero replicas at once?","No — the old ReplicaSet always reaches 0 before the new one starts scaling up, unlike RollingUpdate where both briefly coexist","demo02-deployments,recreate,pod-template-hash,cka-workloads-scheduling"
"A bad image is deployed under Recreate. What happens to availability?","Full outage — the old ReplicaSet has already scaled to 0 before the new, broken ReplicaSet fails to become Ready, leaving no fallback pod","demo02-deployments,recreate,break-fix,ckad-application-deployment"
"Does kubectl rollout undo behave differently depending on the current strategy?","The mechanism (revision history, undo target) is identical either way — but a Recreate rollback still goes through a full terminate-then-create cycle, unlike a RollingUpdate rollback","demo02-deployments,rollback,recreate,ckad-application-deployment"
"When is Recreate actually the right strategy choice?","When two versions genuinely can't coexist (e.g. a breaking DB migration), or in dev/test environments where downtime is a non-issue and configuration simplicity matters more","demo02-deployments,recreate,ckad-application-deployment"
"How does a bad-image rollout differ in outcome between RollingUpdate (maxUnavailable:0) and Recreate?","RollingUpdate stays fully available since old pods are never removed until a replacement is Ready; Recreate causes a full outage since the old ReplicaSet is already gone","demo02-deployments,strategy-comparison,break-fix,ckad-application-deployment"
````

---

## Appendix — Quiz

**`02-rolling-update-recreate-quiz.md`:**

````markdown
# Quiz — 02-deployments/02-rolling-update-recreate: Rolling Updates, Recreate Strategy, and Rollback

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. When a rolling update happens, what actually happens to the existing ReplicaSet?**

- A) It's mutated in place with the new pod template
- B) A new ReplicaSet is created with a new pod-template-hash; the old one scales to 0
- C) It's deleted immediately
- D) It's renamed to match the new image version

<details>
<summary>Answer</summary>

**B** — This is the same mechanism from `01-basic-deployment` made concrete: changing the template produces a new hash and therefore a new ReplicaSet.
Trap: A assumes in-place mutation, which contradicts the immutable, hash-based design covered previously.

</details>

---

**Q2. What does `maxSurge: 1` allow during a rollout with `replicas: 3`?**

- A) Exactly 3 pods at all times, no more
- B) Temporarily up to 4 pods
- C) Temporarily down to 2 pods
- D) Unlimited additional pods

<details>
<summary>Answer</summary>

**B** — `maxSurge` adds to the desired count temporarily; with `replicas: 3` and `maxSurge: 1`, you can briefly have 4.
Trap: C describes `maxUnavailable`'s effect, not `maxSurge`'s — easy to mix up which knob does which.

</details>

---

**Q3. Does `maxUnavailable: 0` guarantee zero downtime unconditionally?**

- A) Yes, always, regardless of anything else
- B) No — it depends on new pods actually becoming Ready, which depends on readiness probes
- C) No — it only works with the Recreate strategy
- D) Yes, but only for stateless applications

<details>
<summary>Answer</summary>

**B** — Without a real readiness probe, a container is considered Ready the instant it starts, which is a much weaker signal than most production setups actually rely on.
Trap: A treats this as an unconditional guarantee, ignoring what "Ready" actually depends on.

</details>

---

**Q4. Why might a rollout with `maxSurge: 1` stall indefinitely?**

- A) Kubernetes has a hard limit of 3 replicas per Deployment
- B) The surge pod's resource requests may exceed what any node can satisfy, so it never schedules
- C) maxSurge only works with Recreate strategy
- D) Rollouts always stall after exactly 1 pod

<details>
<summary>Answer</summary>

**B** — The surge pod is scheduled exactly like any other pod — if nothing has room for it, it stays Pending forever and the rollout never completes.
Trap: A invents a limit that doesn't exist — replica counts aren't capped at 3.

</details>

---

**Q5. Does `kubectl rollout undo` restore the old revision number, or create a new one?**

- A) It restores the exact old revision number
- B) It creates a new revision copying the old configuration forward
- C) It deletes all revision history
- D) It merges the old and current revisions

<details>
<summary>Answer</summary>

**B** — The old revision number disappears from history; what you get is a new revision with the old config.
Trap: A is the intuitive but incorrect assumption — revision numbers only ever increase, never get reused.

</details>

---

**Q6. What happens if you run `kubectl rollout undo --to-revision=99` and revision 99 was never created?**

- A) It rolls back to the closest available revision automatically
- B) It fails with an explicit "unable to find specified revision" error
- C) It creates revision 99 from the current state
- D) It silently does nothing

<details>
<summary>Answer</summary>

**B** — kubectl fails outright rather than guessing at your intent — check `kubectl rollout history` first to know which revisions actually exist.
Trap: A imagines a fallback behavior that doesn't exist — there's no "closest match" logic.

</details>

---

**Q7. What bounds how far back in history you can roll back a Deployment?**

- A) There's no limit, ever
- B) `spec.revisionHistoryLimit` (default 10) — older revisions get pruned
- C) Exactly 3 revisions, hardcoded
- D) `spec.replicas`

<details>
<summary>Answer</summary>

**B** — This field was introduced (deferred) back in `01-basic-deployment`'s Anatomy section — this is where it actually becomes relevant.
Trap: C invents a fixed number that isn't accurate — the real default is 10, and it's configurable.

</details>

---

**Q8. Is `--record` a reliable way to track why a Deployment changed on a current cluster?**

- A) Yes, it's the current best practice
- B) No — the official Deployments documentation marks it deprecated and slated for removal, and it may already be an unrecognized flag on recent kubectl
- C) `--record` was never a real flag
- D) It's required for `kubectl rollout history` to work at all

<details>
<summary>Answer</summary>

**B** — `--record` is officially deprecated, and current reports show it may already fail outright as an unrecognized flag; setting the `change-cause` annotation directly (in YAML or via `kubectl annotate`) is the current, reliable approach.
Trap: D overstates its necessity — `rollout history` works fine without any change-cause tracking, it just shows a blank `CHANGE-CAUSE` column.

</details>

---

**Q9. What does `kubectl rollout pause` actually do?**

- A) Stops all pods immediately
- B) Freezes the Deployment controller from acting on further changes, leaving a mix of old and new pods until resumed
- C) Deletes the current ReplicaSet
- D) Reverts to the previous revision automatically

<details>
<summary>Answer</summary>

**B** — It's a controlled stop, not a rollback — pods already updated stay updated, pods not yet touched stay as they were, until `kubectl rollout resume`.
Trap: D confuses pausing with rolling back — pause never changes the target revision, it just stops progress toward it.

</details>

---

**Q10. Is `kubectl rollout restart` the same thing as switching a Deployment to the `Recreate` strategy?**

- A) Yes, they behave identically
- B) No — `rollout restart` follows whichever strategy is already configured (RollingUpdate or Recreate) and does change the template via a `restartedAt` annotation; `Recreate` is a separate `spec.strategy.type` value that always kills all pods first, regardless of what triggered the update
- C) `rollout restart` only works if the strategy is already `Recreate`
- D) `rollout restart` changes the strategy to `Recreate` temporarily

<details>
<summary>Answer</summary>

**B** — `rollout restart` and `Recreate` are unrelated beyond sharing the word "recreate" in casual conversation: one is a way to *trigger* a rollout (via a template annotation change), the other is a `strategy.type` value that governs *how* any rollout — triggered by anything — replaces Pods.
Trap: D imagines `rollout restart` temporarily borrows the `Recreate` strategy — it never does; it always respects whatever strategy is already configured.

</details>

---

**Q11. You apply a second Deployment update while the first rollout is still in progress. What happens?**

- A) The second update queues and waits for the first to finish
- B) Kubernetes immediately creates a new ReplicaSet and rolls the previously-newest one into the old list, scaling it down alongside the rest — this is Rollover
- C) The second update is rejected until the first completes
- D) Both updates merge into a single ReplicaSet

<details>
<summary>Answer</summary>

**B** — There's no queue. A new `pod-template-hash` is computed the instant a new template is seen, regardless of what's already mid-rollout.
Trap: A assumes Kubernetes serializes updates for safety — it doesn't; Rollover is deliberate, not an edge case to guard against.

</details>

---

**Q12. You scale a Deployment while a rollout is still converging between two ReplicaSets. Where do the new replicas go?**

- A) All to the newest ReplicaSet
- B) All to the oldest ReplicaSet
- C) Distributed proportionally across every ReplicaSet still in play
- D) Evenly split 50/50 regardless of current state

<details>
<summary>Answer</summary>

**C** — Proportional scaling weights the distribution by each ReplicaSet's current share, keeping the configured surge/unavailable ratio roughly honored throughout.
Trap: A is the intuitive but incorrect assumption — it feels like new capacity should go to the new version, but Kubernetes spreads it proportionally instead.

</details>

---

**Q13. Can a Deployment be configured with `maxSurge: 0` and `maxUnavailable: 0` at the same time?**

- A) Yes, this is the safest possible configuration
- B) No — the API rejects it outright, since neither pod addition nor removal would ever be allowed
- C) Yes, but only with the Recreate strategy
- D) Only if `replicas` is also 0

<details>
<summary>Answer</summary>

**B** — With neither knob allowed to move, a rollout using this Deployment could never make progress at all, so Kubernetes rejects the configuration rather than accepting a guaranteed deadlock.
Trap: A assumes "zero everything" means "maximally safe" — it actually means "impossible," not safe.

</details>

---

**Q14. A Deployment shows `Progressing: False, Reason: ProgressDeadlineExceeded`. Did Kubernetes automatically roll it back?**

- A) Yes, automatically, to the previous revision
- B) No — this is purely a reported condition; the stalled ReplicaSet stays exactly as it was until you intervene
- C) Yes, but only if `revisionHistoryLimit` allows it
- D) It automatically scales the Deployment to 0

<details>
<summary>Answer</summary>

**B** — `ProgressDeadlineExceeded` is diagnostic, not corrective — `kubectl rollout status` also exits non-zero once it fires, but nothing reverts on its own; you still need `kubectl rollout undo` or to fix the underlying problem yourself.
Trap: A assumes Kubernetes protects you automatically from a stuck rollout — it only reports the problem, it doesn't fix it.

</details>

**Q15. What does `spec.strategy.type: Recreate` guarantee about Pod overlap?**

- A) New pods are always created before old ones are removed
- B) Old pods are always fully removed before any new pod is created
- C) Exactly 50% of pods are replaced at a time
- D) It behaves identically to RollingUpdate with `maxUnavailable: 100%`

<details>
<summary>Answer</summary>

**B** — Recreate strictly sequences termination then creation; there's never a moment with both old and new Pods present.
Trap: D sounds plausible but `maxUnavailable` doesn't apply to Recreate at all — it's a RollingUpdate-only field.

</details>

---

**Q16. A Deployment sets `strategy.type: Recreate` and also `strategy.rollingUpdate.maxSurge: 1`. What happens?**

- A) The API rejects the object as invalid
- B) `maxSurge` is silently ignored — Recreate never reads `rollingUpdate` fields
- C) Kubernetes automatically switches the strategy to RollingUpdate
- D) One pod is surged despite the Recreate setting

<details>
<summary>Answer</summary>

**B** — schema validation allows the field to be present; Recreate's controller logic simply never consults it.
Trap: A assumes stricter validation than actually exists.

</details>

---

**Q17. A bad image is rolled out under Recreate. Compared to the same mistake under RollingUpdate with `maxUnavailable: 0`, what's different?**

- A) Nothing — both result in full outages
- B) Recreate causes a full outage since the old ReplicaSet already scaled to 0; RollingUpdate keeps old pods running until the replacement is Ready
- C) RollingUpdate causes the outage instead
- D) Both stay fully available regardless of strategy

<details>
<summary>Answer</summary>

**B** — this is the clearest practical argument for why RollingUpdate is the default, not Recreate.
Trap: A ignores that `maxUnavailable: 0` specifically exists to prevent exactly this outage.

</details>

---

**Q18. Does `kubectl rollout undo` behave differently depending on whether the Deployment currently uses RollingUpdate or Recreate?**

- A) The command itself is different for each strategy
- B) The mechanism is identical, but Recreate rollback still causes a downtime window on the way back — RollingUpdate rollback doesn't
- C) Rollback isn't supported under Recreate
- D) Rollback always forces the strategy back to RollingUpdate

<details>
<summary>Answer</summary>

**B** — same command, same revision-history mechanism; only the replacement choreography during the rollback differs.
Trap: C wrongly assumes strategy limits rollback capability — only *how* the rollback plays out changes.

</details>

Score guide:
| Score | Action |
|---|---|
| 16-18/18 | Import Anki cards, move to next Demo |
| 14-15/18 | Review the wrong answers, then proceed |
| 11-13/18 | Re-read the relevant section, retry those questions |
| Below 11/18 | Re-read the full demo and redo the walkthrough before proceeding |
````