# Basic Deployment - Your First Kubernetes Deployment

## Lab Overview

This lab introduces you to Kubernetes Deployments, the most fundamental way to run applications in Kubernetes. A Deployment manages a set of identical pods, ensuring your application stays running and healthy.

In this hands-on lab, you'll create your first Deployment that runs nginx web servers. You'll learn how Deployments automatically manage pods, provide self-healing capabilities, and maintain your desired state. This is the foundation for all application deployments in Kubernetes.

**What you'll do:**
- Create a Deployment with 3 nginx replicas
- Understand the relationship between Deployments, ReplicaSets, and Pods
- Explore how Kubernetes maintains desired state through self-healing
- Learn essential kubectl commands for managing Deployments
- Examine Deployment specifications and selectors

## Prerequisites

**Required Software:**
- Kubernetes cluster installed and up (minikube, kind, Docker Desktop, or cloud provider)
- kubectl installed and configured
- Text editor

**Knowledge Requirements:**
- Basic understanding of containers and Docker
- Familiarity with YAML syntax
- Basic command-line skills

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create and deploy a basic Kubernetes Deployment
2. ✅ Understand the hierarchy: Deployment → ReplicaSet → Pods
3. ✅ Verify Deployment status and health
4. ✅ Observe Kubernetes self-healing in action
5. ✅ Scale Deployments up and down
6. ✅ Properly clean up Kubernetes resources

## Directory Structure

```
01-basic-deployment/
└── src/
    └── nginx-deploy.yaml    # Basic nginx deployment with 3 replicas
```

## Understanding Deployments

### What is a Deployment?

A Deployment is a Kubernetes object that manages a set of identical pods. It ensures that a specified number of pod replicas are running at all times. If a pod fails or is deleted, the Deployment automatically creates a new one to maintain the desired state.

### The Kubernetes Hierarchy

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
- **Deployment** - Manages updates, rollbacks, and desired state declarations
- **ReplicaSet** - Ensures the specified number of pod replicas are running
- **Pods** - Run the actual containers with your application

### Why Use Deployments Instead of Pods?

Deployments provide:
- **Self-healing** - Automatic pod restart if they crash or are deleted
- **Scaling** - Easy to change the number of replicas
- **Rolling updates** - Update applications with zero downtime
- **Rollback** - Revert to previous versions if updates fail
- **Declarative management** - Describe what you want, Kubernetes makes it happen

## Lab Step-by-Step Guide

### Step 1: Understand the YAML

Let's examine the deployment specification:

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
      name: nginx-pod
      labels:
        app: nginx
    spec:
      containers:
        - name : nginx
          image: nginx
```

**Key YAML Fields Explained:**

- `apiVersion: apps/v1` - API version for Deployment objects
- `kind: Deployment` - Specifies this is a Deployment resource
- `metadata.name: nginx-deploy` - Name of the Deployment
- `spec.replicas: 3` - Kubernetes will maintain exactly 3 pod replicas
- `spec.selector.matchExpressions` - How the Deployment identifies which pods it manages
  - Uses label selector with `In` operator
  - Matches pods with label `app` having value `nginx`
- `template` - Pod template that defines how pods should be created
- `template.metadata.labels` - Labels applied to each pod (`app: nginx`)
- `spec.containers` - Container specifications within the pod
- `image: nginx` - Uses the latest nginx image from Docker Hub

**Understanding matchExpressions:**

The selector uses `matchExpressions` instead of simple `matchLabels`. This provides more flexibility:
- `key: app` - The label key to match
- `operator: In` - Match if the label value is in the provided list
- `values: [nginx]` - List of acceptable values

This is equivalent to `matchLabels: {app: nginx}` but allows for more complex matching logic.

---

### Step 2: Create the Deployment

Navigate to the lab directory and apply the deployment:

```bash
cd 01-basic-deployment/src
kubectl apply -f nginx-deploy.yaml
```

**Expected output:**
```
deployment.apps/nginx-deploy created
```

---

### Step 3: Verify Deployment Creation

Check that the Deployment was created successfully:

```bash
kubectl get deployments
```

**Expected output:**
```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deploy   3/3     3            3           10s
```

**Understanding the columns:**
- `READY` - Number of ready pods / desired pods (3/3 means all 3 are ready)
- `UP-TO-DATE` - Pods updated to the latest specification
- `AVAILABLE` - Pods available to serve requests
- `AGE` - Time since deployment was created

---

### Step 4: View the ReplicaSet

The Deployment automatically creates a ReplicaSet:

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

Notice the ReplicaSet name includes the Deployment name plus a unique hash.

---

### Step 5: View the Pods

Check the pods created by the ReplicaSet:

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

You should see 3 pods, all in `Running` status.

---

### Step 6: Examine Deployment Details

Get detailed information about the Deployment:

```bash
kubectl describe deployment nginx-deploy
```

**Key information to look for:**
- **Replicas:** 3 desired | 3 updated | 3 total | 3 available
- **StrategyType:** RollingUpdate (default strategy for updates)
- **Pod Template:** Shows the container specifications
- **Conditions:** Shows deployment health status
- **Events:** History of what happened (creation, scaling, etc.)

---

### Step 7: View Pod Details

Pick any pod from the list and examine it:

```bash
# Get pod names
kubectl get pods

# Describe a specific pod (replace with actual pod name)
kubectl describe pod nginx-deploy-xxxxxxxxx-xxxxx
```

**Key sections:**
- **Labels:** Shows `app=nginx` label
- **Controlled By:** Points to the ReplicaSet
- **Containers:** Shows nginx container details
- **Events:** Pod lifecycle events

---

### Step 8: Check Pod Logs

View the nginx access logs:

```bash
# Replace with your pod name
kubectl logs nginx-deploy-xxxxxxxxx-xxxxx
```

Since nginx just started, logs might be minimal. You should see nginx startup messages.

---

### Step 9: Experience Self-Healing

Kubernetes automatically replaces failed or deleted pods. Let's test this:

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

**Why this happens:**
The ReplicaSet continuously monitors the actual state (number of running pods) and compares it to the desired state (3 replicas). When it detects a missing pod, it automatically creates a replacement.

---

### Step 10: View Deployment as YAML

Export the running Deployment configuration:

```bash
kubectl get deployment nginx-deploy -o yaml
```

This shows the complete deployment specification including:
- Fields you defined
- System-generated fields (status, resourceVersion, etc.)
- Current state information

You can save this to a file:
```bash
kubectl get deployment nginx-deploy -o yaml > deployment-export.yaml
```

---

### Step 11: Cleanup

Remove all resources created in this lab:

```bash
kubectl delete -f nginx-deploy.yaml
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

**What gets deleted:**
- ✅ Deployment
- ✅ ReplicaSet (automatically)
- ✅ All Pods (automatically)

---

## Experiments to Try

1. **Watch real-time updates:**
   ```bash
   # Terminal 1
   kubectl get pods -w
   
   # Terminal 2
   kubectl scale deployment nginx-deploy --replicas=5
   kubectl get pods
   # Scale back down
   kubectl scale deployment nginx-deploy --replicas=2
   ```

2. **Edit deployment directly:**
   ```bash
   kubectl edit deployment nginx-deploy
   # Change replicas in the editor, save, and exit
   # Watch pods adjust automatically
   kubectl get pods
   ```

4. **Test with zero replicas:**
   ```bash
   kubectl scale deployment nginx-deploy --replicas=0
   kubectl get pods
   # All pods deleted but deployment still exists
   kubectl get deployments
   ```

5. **Label verification:**
   ```bash
   # Show pod labels
   kubectl get pods --show-labels
   
   # Filter pods by label
   kubectl get pods -l app=nginx
   ```

## Common Questions

### Q: Why not create pods directly?
**A:** Creating pods directly means no self-healing, no easy scaling, and no update management. Deployments provide all these features automatically. If a standalone pod dies, it's gone forever. A pod managed by a Deployment gets automatically recreated.

### Q: What's the difference between Deployment and ReplicaSet?
**A:** Deployments are higher-level controllers that manage ReplicaSets. When you update a Deployment (like changing the image), it creates a new ReplicaSet and gradually shifts pods from the old ReplicaSet to the new one. This enables rolling updates and rollbacks. You should always use Deployments, not ReplicaSets directly.

### Q: Can I have zero replicas?
**A:** Yes! Setting `replicas: 0` will delete all pods but keep the Deployment definition. This is useful for temporarily stopping an application without losing its configuration.

### Q: What happens if I manually delete a pod?
**A:** The ReplicaSet immediately detects the pod is missing and creates a new one to maintain the desired count. You cannot reduce the number of pods by deleting them manually - you must change the `replicas` field.

### Q: Why use matchExpressions instead of matchLabels?
**A:** `matchLabels` works for simple equality matching. `matchExpressions` allows advanced operators like:
- `In` - value is in a list
- `NotIn` - value is not in a list  
- `Exists` - key exists (any value)
- `DoesNotExist` - key doesn't exist

For basic use cases, `matchLabels` is simpler. Use `matchExpressions` when you need complex matching logic.

### Q: What does the hash in ReplicaSet and Pod names mean?
**A:** The hash uniquely identifies the pod template version. When you update a Deployment, the hash changes, creating a new ReplicaSet. This allows Kubernetes to manage multiple versions during updates and rollbacks.

## What You Learned

In this lab, you:
- ✅ Created your first Kubernetes Deployment with 3 replicas
- ✅ Understood the three-tier hierarchy: Deployment → ReplicaSet → Pods
- ✅ Verified deployment health using `kubectl get` and `kubectl describe`
- ✅ Witnessed Kubernetes self-healing by deleting and watching pod recreation
- ✅ Scaled deployments up and down using `kubectl scale`
- ✅ Learned about label selectors and matchExpressions
- ✅ Properly cleaned up Kubernetes resources

**Key Takeaway:** Deployments are the foundation of running applications in Kubernetes, providing self-healing, scaling, and declarative management that makes your applications resilient and easy to manage.

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f nginx-deploy.yaml` | Create or update deployment from file |
| `kubectl get deployments` | List all deployments |
| `kubectl get deploy -o wide` | List deployments with additional details |
| `kubectl get pods` | List all pods |
| `kubectl get pods --show-labels` | List pods with their labels |
| `kubectl describe deployment <name>` | Show detailed deployment information |
| `kubectl describe pod <pod-name>` | Show detailed pod information |
| `kubectl logs <pod-name>` | View pod logs |
| `kubectl scale deployment <name> --replicas=N` | Scale deployment to N replicas |
| `kubectl edit deployment <name>` | Edit deployment in default editor |
| `kubectl delete deployment <name>` | Delete deployment and all its pods |
| `kubectl delete -f nginx-deploy.yaml` | Delete resources defined in file |
| `kubectl get pods -w` | Watch pods in real-time (Ctrl+C to exit) |

## Troubleshooting

**Pods not starting?**
```bash
kubectl describe deployment nginx-deploy
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```
Look for `ImagePullBackOff` or `CrashLoopBackOff` errors.

**Deployment stuck?**
```bash
kubectl get events --sort-by='.lastTimestamp'
```
Shows recent cluster events that might explain issues.

**Wrong number of pods?**
```bash
kubectl get deployment nginx-deploy -o yaml | grep replicas
```
Verify the replicas setting matches your expectation.

## CKA Certification Tips

**For Deployment questions:**

✅ **Fast deployment creation:**
```bash
# Generate deployment YAML instantly
kubectl create deployment nginx-deploy --image=nginx --replicas=3 --dry-run=client -o yaml > deploy.yaml
```

✅ **Quick scaling (don't edit YAML):**
```bash
kubectl scale deploy nginx-deploy --replicas=5
```

✅ **Verify the 3-tier hierarchy:**
```bash
kubectl get deploy,rs,po  # Check all at once
(OR)
kubectl get all
```

✅ **Selector must match labels:**
- Exam will test if you know selector must match pod template labels
- Mismatched labels = deployment won't manage pods

✅ **Use short name:**
```bash
kubectl get deploy  # Not 'deployments'
```

**Time saver:** Creating deployment imperatively (30 seconds) vs writing YAML from scratch (5 minutes)