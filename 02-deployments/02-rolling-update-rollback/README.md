# Demo: 02-deployments/02-rolling-update-rollback — Rolling Updates and Rollbacks

## Lab Overview

This lab teaches you how to update your applications with zero downtime
using Kubernetes rolling updates, and how to quickly recover from failed
updates using rollbacks.

Rolling updates allow you to gradually replace old versions of your
application with new ones, ensuring some instances are always available to
serve traffic. If an update causes issues, Kubernetes' rollback feature
lets you instantly revert to a previous working version. This demo also
makes concrete something `01-basic-deployment` only promised: that changing
a Pod template produces a **new** ReplicaSet with a new `pod-template-hash`
rather than mutating the existing one — you'll watch that happen directly
in Step 4.

**What you'll do:**
- Perform a rolling update by changing the container image
- Control update speed with maxSurge and maxUnavailable parameters
- Monitor rollout progress and status
- Track deployment revision history with annotations
- Rollback to previous versions when updates fail
- Understand the difference between rolling updates and recreate strategy

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
5. ✅ Add change-cause annotations for better tracking
6. ✅ Rollback failed deployments to previous versions
7. ✅ Pause and resume rollouts for controlled deployments
8. ✅ Observe a second ReplicaSet appear with its own `pod-template-hash` during a rollout, and explain why

## Directory Structure

```
02-deployments/02-rolling-update-rollback/
├── README.md
├── src/
│   ├── 01-nginx-deploy-v1.yaml    # Initial deployment (nginx:1.19)
│   ├── 02-nginx-deploy-v2.yaml    # Updated deployment (nginx:1.20)
│   ├── 03-nginx-deploy-v3.yaml    # Bad deployment (nginx:1.100 - doesn't exist)
│   └── break-fix/
│       ├── 01-surge-stall.yaml              # Embedded inline in README — not generated on disk
│       └── 02-undo-missing-revision.yaml    # Embedded inline in README — not generated on disk
├── 02-rolling-update-rollback-anki.csv
└── 02-rolling-update-rollback-quiz.md
```

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
other, with its own `resources.requests` (covered in full in
`01-core-concepts/03-pod-container-basics`) checked against real node
capacity. This demo's Break-Fix Error-1 is built around exactly what
happens when that surge pod can't actually be scheduled.

### Understanding Rollback

Kubernetes keeps a history of deployment revisions. When an update fails or causes issues, you can instantly rollback to any previous revision.

**Revision History:**
```
Revision 1: nginx:1.19 (Initial)  ← Can rollback here
Revision 2: nginx:1.20 (Updated)  ← Can rollback here
Revision 3: nginx:1.21 (Current)  ← Current version
```

### Beyond RollingUpdate and Recreate

This demo covers the two update strategies every Deployment can use.
Neither one gives you fine-grained traffic control (e.g. "send exactly 10%
of traffic to the new version and watch metrics before continuing") —
Blue-Green and Canary patterns, built on top of what you're learning here,
are covered fully in `03-deployment-strategies`.

---

## Lab Step-by-Step Guide

### Step 1: Deploy Initial Version (v1)

Create the first version of our deployment:

```bash
cd 02-deployments/02-rolling-update-rollback/src
kubectl apply -f 01-nginx-deploy-v1.yaml
```

**01-nginx-deploy-v1.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deploy
  annotations:
    kubernetes.io/change-cause: "Initial deployment with nginx:1.19"
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
        image: nginx:1.19
        ports:
        - containerPort: 80
```

**Key Configuration Fields:**

- `annotations.kubernetes.io/change-cause` - Records why this revision was created (shows in rollout history)
- `strategy.type: RollingUpdate` - Use rolling update strategy (default)
- `maxSurge: 1` - Allow 1 extra pod during update (can have 4 pods when replicas=3)
- `maxUnavailable: 0` - No pods can be unavailable (zero downtime)
- `image: nginx:1.19` - Starting with nginx version 1.19

**Expected output:**
```
deployment.apps/nginx-deploy created
```

---

### Step 2: Verify Initial Deployment

```bash
# Check deployment
kubectl get deployments

# Check pods and their image versions
kubectl get pods -o wide

# Verify the image version
kubectl describe deployment nginx-deploy | grep Image
```

**Expected output:**
```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deploy   3/3     3            3           20s
```

---

### Step 3: Check Initial Rollout History

```bash
kubectl rollout history deployment nginx-deploy
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.19
```

The `CHANGE-CAUSE` comes from the annotation we added in the YAML.

---

### Step 4: Perform Rolling Update to v2

Now let's update to nginx 1.20. Open **three** terminal windows to watch
the update happen at both the Pod and ReplicaSet level simultaneously —
this is exactly where you'll see the `pod-template-hash` mechanism from
`01-basic-deployment` produce a second, distinct ReplicaSet.

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

**02-nginx-deploy-v2.yaml** (changes from v1):
```yaml
metadata:
  annotations:
    kubernetes.io/change-cause: "Updated to nginx:1.20"
spec:
  # ... same configuration ...
  template:
    spec:
      containers:
      - name: nginx
        image: nginx:1.20  # Changed from 1.19 to 1.20
```

**What you'll observe in Terminal 1:**
1. New pod created (maxSurge allows 4th pod)
2. New pod becomes `Running`
3. One old pod goes to `Terminating`
4. Process repeats until all 3 pods are updated
5. Total pods never drops below 3 (maxUnavailable: 0)

**What you'll observe in Terminal 2 — this is the payoff of
`01-basic-deployment`'s forward reference:**
```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6f8b9d7c5     2         2         2       2m    ← OLD ReplicaSet, scaling DOWN
nginx-deploy-7d4c8a9f2     2         2         2       15s   ← NEW ReplicaSet, scaling UP
```
Two ReplicaSets, two different `pod-template-hash` values, existing
simultaneously — the old one's replica count counts down to 0 as the new
one counts up to 3. Neither Deployment nor either ReplicaSet ever mutates
a Pod's image in place; the old ReplicaSet's Pods are deleted and the new
ReplicaSet's Pods are created, exactly per the ownership model from
`01-basic-deployment`'s End-to-End section.

Press `Ctrl+C` in Terminals 1 and 2 to stop watching.

---

### Step 5: Monitor Rollout Status

Check the rollout progress:

```bash
# Watch rollout status (blocks until complete)
kubectl rollout status deployment nginx-deploy
```

**Expected output:**
```
Waiting for deployment "nginx-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

---

### Step 6: Verify the Update

```bash
# Check deployment
kubectl get deployment nginx-deploy

# Verify new image version
kubectl describe deployment nginx-deploy | grep Image

# Check rollout history
kubectl rollout history deployment nginx-deploy
```

**Expected rollout history:**
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.19
2         Updated to nginx:1.20
```

---

### Step 7: Alternative Update Methods

Besides applying a new YAML file, you can update using kubectl commands:

**Method 1: Using kubectl set image**
```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.21 --record
```

The `--record` flag automatically adds the command as the change-cause annotation.

**Method 2: Using kubectl edit**
```bash
kubectl edit deployment nginx-deploy
# Change image version in the editor
# Save and exit
```

For this lab, let's use Method 1:

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.21 --record
```

Check history:
```bash
kubectl rollout history deployment nginx-deploy
```

**Expected output:**
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.19
2         Updated to nginx:1.20
3         kubectl set image deployment/nginx-deploy nginx=nginx:1.21 --record=true
```

**Note on `--record`:**
- The `--record` flag has been deprecated since Kubernetes 1.15 and will be removed in a future version.
- Current best practice is to use the `kubernetes.io/change-cause` annotation directly instead.
- Two ways to set that annotation without `--record`:
  - **Recommended:** add it directly in the YAML (as Step 1's file already does)
  - **Alternative:** use `kubectl annotate` after the fact:
    ```bash
    kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="Updated to nginx:1.21" --overwrite
    ```

---

### Step 8: View Specific Revision Details

See what changed in a specific revision:

```bash
# View revision 2 details
kubectl rollout history deployment nginx-deploy --revision=2

# View revision 3 details
kubectl rollout history deployment nginx-deploy --revision=3
```

This shows the pod template for that revision, including the image version.

---

### Step 9: Simulate a Failed Update

Deploy a bad version that doesn't exist:

```bash
kubectl apply -f 03-nginx-deploy-v3.yaml
```

**03-nginx-deploy-v3.yaml:**
```yaml
metadata:
  annotations:
    kubernetes.io/change-cause: "Bad update - nginx:1.100 doesn't exist"
spec:
  # ... same configuration ...
  template:
    spec:
      containers:
      - name: nginx
        image: nginx:1.100  # This version doesn't exist!
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

**What happened:** notice the new pod's name carries a **third**, distinct
`pod-template-hash` (`9a1e3f8b7`) — a third ReplicaSet was created for this
third template change, exactly as the mechanism predicts. That ReplicaSet's
one pod can't pull `nginx:1.100` (it doesn't exist), so:
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

Look for the error message showing the image doesn't exist.

---

### Step 10: Rollback to Previous Version

Since the update failed, let's rollback:

```bash
# Rollback to previous revision (from revision 4 to revision 3)
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
- Pods with working version (1.21) remain
- Rollback completes instantly

Press `Ctrl+C` to stop watching.

---

### Step 11: Verify Rollback

```bash
# Check deployment status
kubectl rollout status deployment nginx-deploy

# Verify image version is back to 1.21
kubectl describe deployment nginx-deploy | grep Image

# Check rollout history
kubectl rollout history deployment nginx-deploy
```

**Important:** Notice in the history:
```
REVISION  CHANGE-CAUSE
1         Initial deployment with nginx:1.19
2         Updated to nginx:1.20
4         Bad update - nginx:1.100 doesn't exist
5         kubectl set image deployment/nginx-deploy nginx=nginx:1.21 --record=true
```

Revision 3 is gone! When you rollback to a revision, that revision becomes the new current revision.

---

### Step 12: Rollback to Specific Revision

You can rollback to any previous revision:

```bash
# Rollback to revision 2 (nginx:1.20)
kubectl rollout undo deployment nginx-deploy --to-revision=2
```

Verify:
```bash
kubectl describe deployment nginx-deploy | grep Image
```

Should show: `Image: nginx:1.20`

---

### Step 13: Pause and Resume Rollouts

For advanced control, you can pause rollouts:

```bash
# Start an update
kubectl set image deployment/nginx-deploy nginx=nginx:1.22

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

Resume when ready:
```bash
kubectl rollout resume deployment nginx-deploy
```

The rollout continues to completion.

---

### Step 14: Understanding Update Strategies

**RollingUpdate (Default):**
- Gradual replacement
- Zero downtime (if configured correctly)
- More complex

**Recreate:**
- Kill all old pods first
- Then create new pods
- Simple but has downtime

To use Recreate strategy:
```yaml
spec:
  strategy:
    type: Recreate
```

---

### Step 15: Cleanup

```bash
kubectl delete -f 01-nginx-deploy-v1.yaml
```

Verify deletion:
```bash
kubectl get deployments
kubectl get pods
```

---

## What You Learned

In this lab, you:
- ✅ Performed zero-downtime rolling updates by changing container images
- ✅ Configured maxSurge and maxUnavailable for controlled updates
- ✅ Monitored rollout progress with kubectl rollout status
- ✅ Tracked deployment history with change-cause annotations
- ✅ Rolled back failed deployments to previous working versions
- ✅ Used specific revision rollbacks with --to-revision flag
- ✅ Paused and resumed rollouts for advanced deployment control
- ✅ Understood the difference between RollingUpdate and Recreate strategies
- ✅ Watched a second (and third) ReplicaSet appear with its own `pod-template-hash` during rollouts, confirming the mechanism from `01-basic-deployment`

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-surge-stall.yaml`:**

First apply a working Deployment with modest resource requests:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: surge-stall-demo
spec:
  replicas: 3
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
          image: nginx:1.19
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
Change `image: nginx:1.19` to `image: nginx:1.20`, **and** change
`cpu: "100m"` (under `resources.requests`) to `cpu: "8"` — 8 whole CPU
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
never place it, so the rollout stalls indefinitely with `kubectl rollout
status` reporting `Waiting for deployment "surge-stall-demo" rollout to
finish: 0 out of 3 new replicas have been updated...` and never
progressing further.

**Fix:** `kubectl describe pod <surge-pod-name>` shows a `FailedScheduling`
event citing insufficient CPU — the fix is either lowering the resource
request back to something the cluster can actually satisfy, or (in a real
cluster) adding node capacity. You can also `kubectl rollout undo` to
abandon the stuck rollout entirely.

**Cascade:** all 3 original pods keep running the whole time — because
`maxUnavailable: 0`, nothing old is ever torn down until a replacement is
ready, and the replacement is never ready. This looks alarming
("rollout stuck!") but is actually the safety mechanism working exactly as
designed — the real bug is the resource request, not the rollout
mechanism itself.

</details>

**Cleanup:**
```bash
kubectl delete deployment surge-stall-demo 2>/dev/null || true
```

---

### Error-2

```bash
# Assumes nginx-deploy from the main lab is still around with a handful of revisions
kubectl rollout undo deployment nginx-deploy --to-revision=99
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Revision `99` was never created, or (in a longer-lived
Deployment) has already aged out of history because it exceeds
`spec.revisionHistoryLimit` (default 10). Either way, kubectl reports:
```
error: unable to find specified revision 99 in history
```

**Fix:** Run `kubectl rollout history deployment nginx-deploy` first to
see which revision numbers actually still exist, then target one of those.

**Cascade:** none — this is a read-attempt against history that doesn't
exist; the Deployment's current running state is completely unaffected by
the failed `undo` command.

</details>

**Cleanup:** none needed — no objects created by this error.

---

## Interview Prep

**Q: What happens if I rollback during an active rollout?**
A: Kubernetes stops the current rollout and starts rolling back immediately. The deployment reverts to the target revision.

**Q: How many revisions does Kubernetes keep?**
A: By default, the last 10. You can change this with `spec.revisionHistoryLimit` — the field itself was already introduced (deferred) in `01-basic-deployment`; this is where it actually matters.

**Q: Can I rollback to any revision?**
A: Yes, use `--to-revision=N` where N is a revision number from `kubectl rollout history` — but only if that revision still exists. Targeting a pruned or nonexistent revision fails outright, as this demo's Break-Fix Error-2 shows.

**Q: What if maxUnavailable is set to 1 instead of 0?**
A: During updates, 1 pod can be unavailable at a time. For replicas=3, you might temporarily have only 2 pods running. This speeds up rollouts but reduces availability during the update window.

**Q: Does rollback create a new revision, or restore the old one in place?**
A: It creates a new revision, copying the old revision's configuration forward — the old revision number itself disappears from history, exactly as you saw in Step 11.

**Q: A rollout seems stuck with `maxUnavailable: 0`. What's the very first thing you'd check?**
A: Whether the surge pod can actually be scheduled and become Ready — check `kubectl describe pod` on the new pod for `FailedScheduling` events (resource requests too high) or a readiness probe that's never passing, rather than assuming the rollout mechanism itself is broken.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Deployment | CKAD | 20% | Rolling updates, rollbacks, revision history |
| Application Deployment | CKA | — | `kubectl rollout` command family |
| Workloads & Scheduling | CKA | 15% | maxSurge/maxUnavailable interaction with scheduling |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Editing YAML for a pure image change | `kubectl set image deployment/name container=image` is far faster than editing and reapplying a whole file — know it cold for the exam |
| Forgetting `--to-revision=N` needs a revision that still exists | Fails with a clear error, but only if you already ran `rollout history` to know which numbers are valid |
| Assuming a stuck rollout means something is "broken" | Often it's `maxSurge`/scheduling capacity or a readiness probe never passing — check `describe pod` on the new pod before assuming a Kubernetes bug |
| Confusing rollback with "restoring revision N in place" | Rollback creates a *new* revision copying the old config — the old revision number is gone afterward, not restored |
| Using `--record` and expecting it to work forever | Deprecated since 1.15 — use the `kubernetes.io/change-cause` annotation directly in YAML instead |

### Exam Task — Write it from scratch

Update `nginx-deploy`'s image to `nginx:1.21` using `kubectl set image`, add a `change-cause` annotation without using the deprecated `--record` flag, then roll it back to the previous revision.

Official docs: [Performing a Rolling Update](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/), [Rolling Back a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment)

<details>
<summary>Reveal solution</summary>

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.21
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="Updated to nginx:1.21" --overwrite
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
| `--record` is deprecated | Use the `kubernetes.io/change-cause` annotation directly instead |
| Pause/resume gives manual, coarse control over a rollout | A hand-operated preview of what Canary deployments (`03-deployment-strategies`) automate properly |

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
| `kubectl rollout restart deploy/<name>` | Restart all pods (recreate) |
| `kubectl describe deploy/<name>` | Detailed deployment info |
| `kubectl get rs -w` | Watch ReplicaSets during a rollout — see Step 4 |

For generating a Deployment's YAML skeleton via `--dry-run=client -o yaml`,
see `01-basic-deployment`'s Quick Commands Reference — this demo only
covers *updating* an existing Deployment, not creating one from scratch.

---

## Troubleshooting

**Rollout stuck in progress?**
```bash
kubectl rollout status deployment nginx-deploy
kubectl describe deployment nginx-deploy
kubectl get events --sort-by='.lastTimestamp'
```
Also check `kubectl describe pod` on the new pod specifically for
`FailedScheduling` (resource capacity, per Break-Fix Error-1) — a stuck
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

---

## Appendix — Anki Cards

**`02-rolling-update-rollback-anki.csv`:**

````
#deck:k8s-platform-labs::02-deployments::02-rolling-update-rollback
#separator:Comma
#columns:Front,Back,Tags
"When a rolling update happens, does the existing ReplicaSet get mutated in place?","No — a new ReplicaSet is created with a new pod-template-hash; the old one scales down to 0 rather than being changed","demo02-deployments,rolling-update,pod-template-hash,ckad-application-deployment"
"What does maxSurge control?","How many extra pods beyond the desired replica count can exist during a rollout","demo02-deployments,rolling-update,ckad-application-deployment"
"What does maxUnavailable: 0 actually guarantee?","Zero downtime, but only if new pods actually pass readiness — without a real readiness probe, Ready happens the instant the container starts","demo02-deployments,rolling-update,readiness,ckad-application-deployment"
"Why might a rollout with maxSurge:1 stall indefinitely?","The surge pod is scheduled like any other pod — if its resource requests can't be satisfied by any node, it never schedules and the rollout never progresses","demo02-deployments,rolling-update,scheduling,cka-workloads-scheduling"
"Does kubectl rollout undo restore the old revision number, or create a new one?","It creates a new revision copying the old configuration forward — the old revision number disappears from history","demo02-deployments,rollback,ckad-application-deployment"
"What happens if you kubectl rollout undo --to-revision=N and N doesn't exist?","kubectl fails outright: 'error: unable to find specified revision N in history'","demo02-deployments,rollback,ckad-application-deployment"
"What bounds how far back you can roll back a Deployment?","spec.revisionHistoryLimit (default 10) — revisions beyond that are pruned and can no longer be targeted","demo02-deployments,rollback,revisionhistorylimit,ckad-application-deployment"
"Is the --record flag still recommended for tracking change-cause?","No — deprecated since Kubernetes 1.15. Use the kubernetes.io/change-cause annotation directly in YAML or via kubectl annotate instead","demo02-deployments,change-cause,ckad-application-deployment"
"What does kubectl rollout pause actually freeze?","The Deployment controller stops acting on further template changes mid-rollout, leaving a mix of old and new pods until resumed","demo02-deployments,pause-resume,ckad-application-deployment"
"What's the practical difference between RollingUpdate and Recreate strategies?","RollingUpdate replaces pods gradually with no downtime (if configured well); Recreate kills all old pods first, then creates new ones, causing a downtime window","demo02-deployments,strategy,ckad-application-deployment"
````

---

## Appendix — Quiz

**`02-rolling-update-rollback-quiz.md`:**

````markdown
# Quiz — 02-deployments/02-rolling-update-rollback: Rolling Updates and Rollbacks

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

**Q8. Is `--record` still the recommended way to track why a Deployment changed?**

- A) Yes, it's the current best practice
- B) No — deprecated since Kubernetes 1.15; use the `kubernetes.io/change-cause` annotation instead
- C) `--record` was never a real flag
- D) It's required for `kubectl rollout history` to work at all

<details>
<summary>Answer</summary>

**B** — `--record` still works but is deprecated; setting the `change-cause` annotation directly (in YAML or via `kubectl annotate`) is the current recommended approach.
Trap: D overstates its necessity — `rollout history` works fine without any change-cause tracking, it just shows a blank `CHANGE-CAUSE` column.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````