# StatefulSet Scaling and Updates — Ordered Scaling, RollingUpdate, Partition

## Lab Overview

This lab covers the operational lifecycle of a running StatefulSet: scaling up
and down with ordering guarantees, rolling updates that replace pods in reverse
ordinal order, and the `partition` field that enables canary-style staged rollouts
for stateful applications.

Labs 01 and 02 established what a StatefulSet is and how storage works. This lab
answers: how do you safely change a running StatefulSet without losing data or
disrupting the cluster?

**What you'll do:**
- Scale a StatefulSet up and down — observe strict ordering
- Perform a rolling update — pods updated highest-ordinal first
- Use `partition` to update only a subset of pods (canary rollout)
- Roll back a StatefulSet update
- Understand `OnDelete` update strategy for manual control
- Annotate revisions for meaningful rollout history

## Prerequisites

**Required Software:**
- Minikube `3node` profile
- kubectl installed and configured

**Apply the control-plane taint (if not already set):**
```bash
kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-basic-statefulset`
- **REQUIRED:** Completion of `02-statefulset-with-persistent-storage`

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Scale a StatefulSet up — pods added in ascending ordinal order
2. ✅ Scale a StatefulSet down — pods removed in descending ordinal order
3. ✅ Explain why ordering matters for scale-up and scale-down in stateful apps
4. ✅ Perform a RollingUpdate — pods updated from highest ordinal to lowest
5. ✅ Explain why StatefulSet rolling updates go highest-to-lowest (opposite to scale-up)
6. ✅ Use `partition` to update a single pod (canary) before committing to full rollout
7. ✅ Roll back a StatefulSet using `kubectl rollout undo`
8. ✅ Use `OnDelete` update strategy for fully manual update control
9. ✅ Annotate revisions with `change-cause` — apply the correct workflow from Lab 01

## Directory Structure

```
03-statefulset-scaling-updates/
└── src/
    ├── nginx-headless-service.yaml       # Headless Service (same as Labs 01 and 02)
    ├── nginx-statefulset-v1.yaml         # Base StatefulSet — nginx:1.27, replicas: 3
    ├── nginx-statefulset-v2.yaml         # Updated image — nginx:1.28 (triggers RollingUpdate)
    └── nginx-statefulset-ondelete.yaml   # Same base — updateStrategy: OnDelete
```

---

## Understanding StatefulSet Ordering Rules

### Scale-Up Ordering (ascending)

When `replicas` increases, new pods are created in ascending ordinal order.
Each new pod must be Running and Ready before the next ordinal is created:

```
replicas: 1 → 3

Step 1: web-1 created (web-0 already exists and is Ready)
        web-1 must be Ready before web-2 is created
Step 2: web-2 created
        Done — replicas: 3 satisfied

Reason: In a database cluster, replicas join one at a time.
        Each new replica finds the primary (web-0) and existing replicas.
        If two replicas join simultaneously, they might fight over the same
        replication slot or cause split-brain during initialisation.
```

### Scale-Down Ordering (descending)

When `replicas` decreases, pods are terminated in descending ordinal order.
Each pod must be fully terminated before the next lower ordinal is removed:

```
replicas: 3 → 1

Step 1: web-2 terminated and fully gone
Step 2: web-1 terminated and fully gone
Step 3: web-0 stays (target is replicas: 1)

Reason: In a database cluster, the highest replica ordinals are removed first.
        Replicas are typically less critical than the primary (web-0).
        Removing web-2 before web-1 avoids the situation where web-1 (which
        might be a promoted secondary) is removed while web-2 still exists.
```

### Rolling Update Ordering (highest-first)

When the pod template changes, pods are updated from highest ordinal to lowest:

```
Update: nginx:1.27 → nginx:1.28

Step 1: web-2 replaced (old pod terminated, new pod with 1.28 created)
Step 2: web-1 replaced
Step 3: web-0 replaced last

Reason: In a database cluster, the primary is typically web-0.
        Updating replicas first (web-2, web-1) before the primary (web-0)
        ensures replicas are on the new version before the primary restarts.
        If the primary is updated first and crashes, replicas on the old version
        cannot replicate from a new-version primary — split-brain risk.
        Updating primary last is the safest pattern.
```

**This is opposite to scale-up** — and intentional:

| Operation | Ordering | Reason |
|-----------|---------|--------|
| Scale-up | Ascending (0 → 1 → 2) | New replicas join from lowest available slot |
| Scale-down | Descending (2 → 1 → 0) | Remove highest replicas first |
| Rolling update | Descending (2 → 1 → 0) | Update replicas before primary |

---

## The Partition Field — Canary Updates for StatefulSets

`partition` is the most important StatefulSet-specific update concept.
It does not exist in Deployments.

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: N   # Only pods with ordinal >= N are updated when template changes
```

```
partition: 2  → only web-2 is updated (web-0 and web-1 stay on old version)
partition: 1  → web-1 and web-2 are updated (web-0 stays)
partition: 0  → all pods updated (default — full rollout)

Workflow for a safe database update:

Step 1: Set partition: 2, change image to nginx:1.28
        → Only web-2 updates (the least critical replica)
        → Monitor web-2 for errors, replication lag, performance

Step 2: If web-2 looks good, set partition: 1
        → web-1 now updates
        → Monitor web-1

Step 3: If web-1 looks good, set partition: 0
        → web-0 (primary) now updates
        → Full rollout complete

Step 4 (rollback): If any step fails, rollback the image
        → Only pods already updated (ordinal >= partition) revert
        → Pods below partition were never touched — no rollback needed for them
```

---

## Manifest — Every Field Explained

### nginx-statefulset-v1.yaml

**nginx-statefulset-v1.yaml:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: default
  labels:
    app: nginx
  annotations:
    # Set change-cause BEFORE applying — it is captured at revision creation time.
    # Annotating after apply does NOT update the already-created ControllerRevision.
    # See 01-basic-daemonset Lab for the full change-cause workflow explanation.
    kubernetes.io/change-cause: "Initial deploy — nginx:1.27"
spec:
  serviceName: nginx
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0        # Update all pods on template change
  revisionHistoryLimit: 10
  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app: nginx
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: standard
        resources:
          requests:
            storage: 256Mi
```

### nginx-statefulset-v2.yaml

**nginx-statefulset-v2.yaml:**
```yaml
# Identical to v1 except:
#   image: nginx:1.27 → nginx:1.28
#   annotation: change-cause updated
#
# Apply with: kubectl apply -f nginx-statefulset-v2.yaml
# This triggers a RollingUpdate: web-2 → web-1 → web-0 (highest ordinal first)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: default
  labels:
    app: nginx
  annotations:
    kubernetes.io/change-cause: "Update nginx:1.27 → nginx:1.28"
spec:
  serviceName: nginx
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0
  revisionHistoryLimit: 10
  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: nginx
          image: nginx:1.28     # ← Only change from v1
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app: nginx
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: standard
        resources:
          requests:
            storage: 256Mi
```

### nginx-statefulset-ondelete.yaml

**nginx-statefulset-ondelete.yaml:**
```yaml
# Same base spec as v1 but with updateStrategy: OnDelete.
# Template changes do NOT automatically replace any pods.
# A pod is only replaced with the new template when manually deleted.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: default
  labels:
    app: nginx
spec:
  serviceName: nginx
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: OnDelete
    # No rollingUpdate sub-field — OnDelete has no automatic behaviour
  revisionHistoryLimit: 10
  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          app: nginx
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: standard
        resources:
          requests:
            storage: 256Mi
```

---

## Lab Step-by-Step Guide

### Step 1: Deploy Headless Service and StatefulSet v1

```bash
cd 03-statefulset-scaling-updates/src
kubectl apply -f nginx-headless-service.yaml
kubectl apply -f nginx-statefulset-v1.yaml
```

Wait for all pods to be Ready:
```bash
kubectl get sts web
# NAME   READY   AGE
# web    3/3     30s
```

Check rollout history — revision 1 has the change-cause annotation:
```bash
kubectl rollout history statefulset/web
# REVISION  CHANGE-CAUSE
# 1         Initial deploy — nginx:1.27
```

---

### Step 2: Scale Up — Observe Ascending Order

```bash
# Terminal 1 — watch
kubectl get pods -l app=nginx -w

# Terminal 2 — scale up
kubectl scale statefulset web --replicas=5
```

**Terminal 1 — expected sequence:**
```
NAME    READY   STATUS    AGE
web-0   1/1     Running   2m
web-1   1/1     Running   2m
web-2   1/1     Running   2m

web-3   0/1     Pending             0s   ← web-3 created first
web-3   0/1     ContainerCreating   1s
web-3   1/1     Running             8s   ← web-3 Ready ✅ → web-4 starts
web-4   0/1     Pending             8s
web-4   0/1     ContainerCreating   9s
web-4   1/1     Running             16s  ← web-4 Ready ✅
```

Key: web-3 must be Ready before web-4 is created. Both PVCs `data-web-3`
and `data-web-4` are also created automatically.

```bash
kubectl get pvc -l app=nginx
# Shows data-web-0 through data-web-4
```

---

### Step 3: Scale Down — Observe Descending Order

```bash
# Terminal 1 — watch
kubectl get pods -l app=nginx -w

# Terminal 2 — scale down
kubectl scale statefulset web --replicas=3
```

**Terminal 1 — expected sequence:**
```
web-4   1/1     Terminating   2m   ← highest ordinal first
web-4   0/0     Terminating   2m
                                    ← web-4 fully terminated
web-3   1/1     Terminating   2m   ← next
web-3   0/0     Terminating   2m
                                    ← web-3 fully terminated
                                    ← web-0, web-1, web-2 untouched
```

```bash
kubectl get sts web
# NAME   READY   AGE
# web    3/3     5m

kubectl get pvc -l app=nginx
# data-web-0, data-web-1, data-web-2 remain
# data-web-3, data-web-4 ALSO remain (whenScaled: Retain)
```

**The PVCs for web-3 and web-4 survive** — this is the `whenScaled: Retain`
default. If you scale back to 5, the new `web-3` and `web-4` pods would
reattach to `data-web-3` and `data-web-4` with their previous data intact.

Clean up the unused PVCs now:
```bash
kubectl delete pvc data-web-3 data-web-4
```

---

### Step 4: Perform a RollingUpdate — Full Rollout

Apply the v2 manifest (nginx:1.28):

```bash
# Terminal 1 — watch pods
kubectl get pods -l app=nginx -w

# Terminal 2 — apply update
kubectl apply -f nginx-statefulset-v2.yaml
```

**Terminal 1 — expected sequence (highest ordinal first):**
```
NAME    READY   STATUS    IMAGE
web-0   1/1     Running   1.27   ← stays running during update
web-1   1/1     Running   1.27
web-2   1/1     Running   1.27

web-2   1/1     Terminating   1.27   ← highest ordinal updated FIRST
web-2   0/1     Pending       1.28
web-2   0/1     ContainerCreating   1.28
web-2   1/1     Running       1.28   ← web-2 Ready on new version ✅
                                        → web-1 now updates

web-1   1/1     Terminating   1.27
web-1   1/1     Running       1.28   ✅
                                        → web-0 (primary) updates last

web-0   1/1     Terminating   1.27
web-0   1/1     Running       1.28   ✅  rollout complete
```

```bash
kubectl rollout status statefulset/web
# partitioned roll out complete: 3 new pods have been updated...

kubectl rollout history statefulset/web
# REVISION  CHANGE-CAUSE
# 1         Initial deploy — nginx:1.27
# 2         Update nginx:1.27 → nginx:1.28
```

Verify all pods on new image:
```bash
kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.28
# web-1   nginx:1.28
# web-2   nginx:1.28
```

---

### Step 5: Rollback with kubectl rollout undo

```bash
kubectl rollout undo statefulset/web
kubectl rollout status statefulset/web
```

Rollback updates pods in the same order as a forward update — highest ordinal
first. After rollback:

```bash
kubectl rollout history statefulset/web
# REVISION  CHANGE-CAUSE
# 2         Update nginx:1.27 → nginx:1.28
# 3         <none>              ← rollback is a new revision
```

```bash
# Verify all pods reverted to nginx:1.27
kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.27
# web-1   nginx:1.27
# web-2   nginx:1.27
```

---

### Step 6: Partition-Based Canary Update

Reset to revision 2 (nginx:1.28) first, then demonstrate partition:

```bash
kubectl apply -f nginx-statefulset-v2.yaml
kubectl rollout status statefulset/web
# All pods on nginx:1.28 now
```

Now prepare a hypothetical v3 update using partition.

**Step 6a — Set partition=2, apply new image:**
```bash
# Patch the partition to 2 (only web-2 will update)
kubectl patch statefulset web --type='merge' \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}},"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27"}]}}}}'
```

> Note: This patches both the partition AND the image simultaneously.
> In production you would apply a new YAML file. The patch is used here
> for brevity.

**Observe — only web-2 updates:**
```bash
kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.28   ← unchanged (ordinal 0 < partition 2)
# web-1   nginx:1.28   ← unchanged (ordinal 1 < partition 2)
# web-2   nginx:1.27   ← updated   (ordinal 2 >= partition 2) ✅
```

**StatefulSet status shows UP-TO-DATE partially:**
```bash
kubectl describe sts web | grep -A3 "Update Strategy\|Pods Status"
# Update Strategy: RollingUpdate
#   Partition:     2
# Pods Status:    3 Running / 0 Waiting
```

**Step 6b — Monitor web-2, then expand partition to 1:**
```bash
# web-2 looks healthy — expand rollout to include web-1
kubectl patch statefulset web --type='merge' \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}}}'

kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.28   ← unchanged (ordinal 0 < partition 1)
# web-1   nginx:1.27   ← updated   (ordinal 1 >= partition 1)
# web-2   nginx:1.27   ← already updated
```

**Step 6c — Expand partition to 0 — full rollout:**
```bash
kubectl patch statefulset web --type='merge' \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'

kubectl rollout status statefulset/web

kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.27   ← all pods now on new version
# web-1   nginx:1.27
# web-2   nginx:1.27
```

**If web-2 had shown problems at Step 6a — rollback partition update:**
```bash
# Just revert the image — only web-2 was ever updated
kubectl patch statefulset web --type='merge' \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.28"}]}}}}'
# Only web-2 reverts (partition was 2 — only web-2 was affected)
# web-0 and web-1 were never touched — no rollback needed for them
```

---

### Step 7: OnDelete Strategy — Manual Update Control

`OnDelete` gives you complete manual control — no pods are replaced until
you explicitly delete them. Used for stateful applications where you need
to run application-level validation before each pod update.

```bash
# Delete current StatefulSet (keep PVCs)
kubectl delete statefulset web

# Deploy with OnDelete strategy
kubectl apply -f nginx-statefulset-ondelete.yaml
kubectl get sts web
# web    3/3  ← all running with nginx:1.27
```

**Patch the image — NO pods update automatically:**
```bash
kubectl set image statefulset/web nginx=nginx:1.28

kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.27   ← still old image
# web-1   nginx:1.27   ← still old image
# web-2   nginx:1.27   ← still old image
```

```bash
kubectl get sts web
# NAME   READY   AGE
# web    3/3     2m
# UP-TO-DATE column: 0   ← zero pods on new template
```

**Manually trigger update on web-2 only:**
```bash
kubectl delete pod web-2
# Controller recreates web-2 with new template (nginx:1.28)

kubectl get pods -l app=nginx \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-0   nginx:1.27
# web-1   nginx:1.27
# web-2   nginx:1.28   ← updated
```

**Validate web-2, then update web-1, then web-0:**
```bash
kubectl delete pod web-1
kubectl delete pod web-0
# Each pod is recreated with nginx:1.28 after deletion
```

**When to use OnDelete:**

| Scenario | Why OnDelete |
|----------|-------------|
| Database with complex failover | Each pod update requires a manual failover step in the application before the pod is deleted |
| Compliance-gated rollouts | Policy requires manual approval per pod before update proceeds |
| Coordinated multi-cluster updates | Update pod in cluster A, validate, then manually proceed to cluster B |

---

### Step 8: Cleanup

```bash
kubectl delete statefulset web
kubectl delete service nginx
kubectl delete pvc -l app=nginx  # PVCs must be deleted manually
```

**Verify:**
```bash
kubectl get sts
kubectl get pvc -l app=nginx
kubectl get pv
# All empty
```

---

## Experiments to Try

1. **Observe what happens with Parallel + RollingUpdate:**
   ```bash
   kubectl patch statefulset web \
     --type='merge' \
     -p '{"spec":{"podManagementPolicy":"Parallel"}}'
   # Note: podManagementPolicy is immutable — delete and recreate
   # With Parallel, scale-up creates all pods simultaneously
   # Scale from 1 to 3: web-1 and web-2 appear at the same time
   ```

2. **Watch partition in action with rollout history:**
   ```bash
   # Set partition=2 and apply update
   # Then check: kubectl get sts web — note READY column
   # Then check: image on each pod — only web-2 shows new image
   ```

3. **Rollback to a specific revision:**
   ```bash
   kubectl rollout history statefulset/web
   kubectl rollout undo statefulset/web --to-revision=1
   # Rolls all pods back to revision 1's template
   ```

---

## Common Questions

### Q: Why does StatefulSet rolling update go highest-to-lowest while scale-up goes lowest-to-highest?
**A:** They solve different problems. Scale-up grows the cluster from a known
good state — new replicas join after existing ones are ready. Rolling update
replaces existing pods — you want to test the new version on a replica (high
ordinal) before risking the primary (ordinal 0). The ordering is designed
to protect the most critical pod (primary) by updating it last.

### Q: What happens to running StatefulSet pods if I change `partition` without changing the image?
**A:** Nothing — changing `partition` alone has no effect. The partition only
matters when the pod template has changed. If the current template matches what
all pods are running, `partition` is irrelevant.

### Q: Can I use `kubectl rollout pause` on a StatefulSet like a Deployment?
**A:** No — `kubectl rollout pause` is not supported for StatefulSets. Use
`partition` instead. Set `partition` to `N+1` (where N is the highest existing
ordinal) before applying a template change — no pods will be updated. When ready
to proceed, lower the partition value.

### Q: Does `OnDelete` work with `kubectl rollout undo`?
**A:** Yes — `kubectl rollout undo` changes the pod template back to a previous
revision. But with `OnDelete`, no pods are automatically replaced. You still
need to manually delete each pod to trigger it to restart with the rolled-back
template.

---

## What You Learned

In this lab, you:
- ✅ Scaled up a StatefulSet — pods created in ascending ordinal order (0 → N)
- ✅ Scaled down a StatefulSet — pods terminated in descending ordinal order (N → 0)
- ✅ Explained why ordering matters: replicas join/leave before the primary
- ✅ Performed a full RollingUpdate — pods replaced highest-ordinal first (N → 0)
- ✅ Explained why updates go highest-to-lowest: protect the primary (ordinal 0) until last
- ✅ Used `partition` to update only `web-2` (canary), then expanded to `web-1`, then `web-0`
- ✅ Rolled back a StatefulSet with `kubectl rollout undo`
- ✅ Used `OnDelete` strategy — manual pod deletion triggers update, full control per pod

**Key Takeaway:** StatefulSet ordering is always intentional. Scale-up is
ascending (new replicas join after existing ones are ready). Scale-down and
rolling updates are descending (replicas updated/removed before the primary).
The `partition` field is the StatefulSet-specific tool for staged canary
updates — it has no Deployment equivalent and is essential for safely rolling
out changes to production databases.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl scale sts web --replicas=N` | Scale StatefulSet (ordered) |
| `kubectl rollout status sts/web` | Watch rolling update progress |
| `kubectl rollout history sts/web` | Show revision history |
| `kubectl rollout undo sts/web` | Rollback to previous revision |
| `kubectl rollout undo sts/web --to-revision=1` | Rollback to specific revision |
| `kubectl patch sts web --type=merge -p '...'` | Change partition or other fields |
| `kubectl set image sts/web nginx=nginx:1.28` | Update image imperatively |
| `kubectl get sts web` | StatefulSet status — READY column |
| `kubectl describe sts web` | Full detail including partition value |