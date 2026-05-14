# Rolling Updates and Rollbacks - Zero-Downtime Deployments

## Lab Overview

This lab teaches you how to update your applications with zero downtime using Kubernetes rolling updates, and how to quickly recover from failed updates using rollbacks. 

Rolling updates allow you to gradually replace old versions of your application with new ones, ensuring some instances are always available to serve traffic. If an update causes issues, Kubernetes' rollback feature lets you instantly revert to a previous working version.

**What you'll do:**
- Perform a rolling update by changing the container image
- Control update speed with maxSurge and maxUnavailable parameters
- Monitor rollout progress and status
- Track deployment revision history with annotations
- Rollback to previous versions when updates fail
- Understand the difference between rolling updates and recreate strategy

## Prerequisites

**Required Software:**
- Kubernetes cluster (minikube, kind, Docker Desktop, or cloud provider)
- kubectl installed and configured
- Text editor

**Knowledge Requirements:**
- **REQUIRED:** Completion of [01-basic-deployment](../01-basic-deployment/)
- Understanding of Deployments, ReplicaSets, and Pods
- Familiarity with kubectl commands

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Perform zero-downtime rolling updates
2. ✅ Configure rolling update parameters (maxSurge, maxUnavailable)
3. ✅ Monitor rollout status and progress
4. ✅ Track deployment revision history
5. ✅ Add change-cause annotations for better tracking
6. ✅ Rollback failed deployments to previous versions
7. ✅ Pause and resume rollouts for controlled deployments

## Directory Structure

```
02-rolling-update-rollback/
└── src/
    ├── nginx-deploy-v1.yaml    # Initial deployment (nginx:1.19)
    ├── nginx-deploy-v2.yaml    # Updated deployment (nginx:1.20)
    └── nginx-deploy-v3.yaml    # Bad deployment (nginx:1.100 - doesn't exist)
```

## Understanding Rolling Updates

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
- Zero downtime guaranteed (if health checks pass)
- Slower updates but maximum availability

### Understanding Rollback

Kubernetes keeps a history of deployment revisions. When an update fails or causes issues, you can instantly rollback to any previous revision.

**Revision History:**
```
Revision 1: nginx:1.19 (Initial)  ← Can rollback here
Revision 2: nginx:1.20 (Updated)  ← Can rollback here
Revision 3: nginx:1.21 (Current)  ← Current version
```

## Lab Step-by-Step Guide

### Step 1: Deploy Initial Version (v1)

Create the first version of our deployment:

```bash
cd 02-rolling-update-rollback/src
kubectl apply -f nginx-deploy-v1.yaml
```

**nginx-deploy-v1.yaml:**
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

Now let's update to nginx 1.20. Open two terminal windows to watch the update happen:

**Terminal 1 - Watch pods in real-time:**
```bash
kubectl get pods -w
```

**Terminal 2 - Apply the update:**
```bash
kubectl apply -f nginx-deploy-v2.yaml
```

**nginx-deploy-v2.yaml** (changes from v1):
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

Press `Ctrl+C` to stop watching.

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

**Note:** 
- The `--record` flag has been deprecated since Kubernetes 1.15 and will be removed in a future version.
- Current Best Practice is to use `kubernetes.io/change-cause` annotation
- Methods to add annotation
    - Method 1: Add annotation in YAML (Recommended)
    - Method 2: Use `kubectl annotate` command
```
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="Updated to nginx:1.21" --overwrite`
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
kubectl apply -f nginx-deploy-v3.yaml
```

**nginx-deploy-v3.yaml:**
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
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running            0          5m
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running            0          5m
nginx-deploy-xxxxxxxxx-xxxxx    1/1     Running            0          5m
nginx-deploy-yyyyyyyyy-yyyyy    0/1     ImagePullBackOff   0          30s
```

**What happened:**
- Rolling update started
- New pod created but can't pull nginx:1.100 (doesn't exist)
- Pod stuck in `ImagePullBackOff` or `ErrImagePull`
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

You'll see a mix of old and new versions (canary-style deployment).

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
kubectl delete -f nginx-deploy-v1.yaml
```

Verify deletion:
```bash
kubectl get deployments
kubectl get pods
```

---

## Experiments to Try

1. **Different maxSurge and maxUnavailable values:**
   ```yaml
   # Fast updates (more resources)
   maxSurge: 2
   maxUnavailable: 1
   
   # Slow, safe updates
   maxSurge: 1
   maxUnavailable: 0
   
   # Percentage-based
   maxSurge: 50%
   maxUnavailable: 25%
   ```

2. **Watch rollout in detail:**
   ```bash
   # Terminal 1
   kubectl get pods -w
   
   # Terminal 2
   kubectl get rs -w
   
   # Terminal 3
   kubectl rollout status deployment nginx-deploy
   ```

3. **Multiple rollbacks:**
   - Update to v2, then v3, then v4
   - Rollback to v2
   - Check revision history
   - Rollback to v1

## Common Questions

### Q: What happens if I rollback during an active rollout?
**A:** Kubernetes stops the current rollout and starts rolling back immediately. The deployment reverts to the target revision.

### Q: How many revisions does Kubernetes keep?
**A:** By default, Kubernetes keeps the last 10 revisions. You can change this with:
```yaml
spec:
  revisionHistoryLimit: 5  # Keep only 5 revisions
```

### Q: Can I rollback to any revision?
**A:** Yes, use `--to-revision=N` where N is the revision number from `kubectl rollout history`.

### Q: What if maxUnavailable is set to 1?
**A:** During updates, 1 pod can be unavailable at a time. For replicas=3, you might temporarily have only 2 pods running. This speeds up rollouts but reduces availability.

### Q: What's the difference between --record and kubernetes.io/change-cause annotation?
**A:** `--record` automatically adds the kubectl command as the change-cause. Manual annotation in YAML gives you custom, descriptive messages. The `--record` flag is deprecated but still works.

### Q: Does rollback create a new revision?
**A:** Yes! Rollback takes the configuration from an old revision and applies it as a new revision. The old revision number disappears from history.

### Q: What happens to services during rolling updates?
**A:** Services automatically route traffic to healthy pods. As old pods terminate and new pods become ready, the service seamlessly switches traffic. Users experience no downtime.

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

**Key Takeaway:** Rolling updates and rollbacks give you the confidence to deploy frequently while maintaining high availability, and the safety net to quickly recover from failed deployments.

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f deployment.yaml` | Create or update deployment |
| `kubectl set image deploy/<name> <container>=<image> --record` | Update container image |
| `kubectl rollout status deploy/<name>` | Watch rollout progress |
| `kubectl rollout history deploy/<name>` | View revision history |
| `kubectl rollout history deploy/<name> --revision=N` | View specific revision details |
| `kubectl rollout undo deploy/<name>` | Rollback to previous revision |
| `kubectl rollout undo deploy/<name> --to-revision=N` | Rollback to specific revision |
| `kubectl rollout pause deploy/<name>` | Pause ongoing rollout |
| `kubectl rollout resume deploy/<name>` | Resume paused rollout |
| `kubectl rollout restart deploy/<name>` | Restart all pods (recreate) |
| `kubectl describe deploy/<name>` | Detailed deployment info |

## CKA Certification Tips

**For Rolling Update questions:**

✅ **Know the two update strategies:**
- `RollingUpdate` (default) - zero downtime
- `Recreate` - all pods killed first, then new ones created

✅ **Fast update using kubectl (don't edit YAML):**
```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.21 --record
```

✅ **Quick rollback:**
```bash
kubectl rollout undo deployment/nginx-deploy
```

✅ **Check if rollout is complete before moving on:**
```bash
kubectl rollout status deployment/nginx-deploy
# Wait for "successfully rolled out" message
```

✅ **Revision history is your friend:**
```bash
kubectl rollout history deployment/nginx-deploy
# See all revisions and their change-cause
```

✅ **Exam scenario - rollback to specific version:**
If question says "rollback to revision 2", use:
```bash
kubectl rollout undo deployment/nginx-deploy --to-revision=2
```

✅ **maxUnavailable: 0 = zero downtime** - Remember this for exam questions about high availability

✅ **Watch rollouts without blocking:**
```bash
kubectl get pods -w  # In separate terminal
```

**Time saver:** Use `kubectl set image` (10 seconds) vs editing and applying YAML (2 minutes)

## Troubleshooting

**Rollout stuck in progress?**
```bash
kubectl rollout status deployment nginx-deploy
kubectl describe deployment nginx-deploy
kubectl get events --sort-by='.lastTimestamp'
```

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
