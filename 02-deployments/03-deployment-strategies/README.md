# Deployment Strategies - Blue-Green and Canary Deployments

## Lab Overview

This lab explores advanced deployment strategies beyond basic rolling updates. You'll learn how to implement Blue-Green deployments for instant switches between versions, and Canary deployments for gradual, risk-controlled rollouts to a small subset of users before full deployment.

These strategies are essential for production environments where you need fine-grained control over deployments. Blue-Green allows instant rollback with zero risk, while Canary deployments let you test new versions with real users before committing to a full rollout. Both strategies minimize risk and give you confidence when deploying critical updates.

Understanding these patterns will help you choose the right deployment strategy based on your application's requirements, risk tolerance, and rollback needs. You'll see how to use Kubernetes native resources (Deployments, Services, labels) to implement these enterprise-grade deployment patterns.

**What you'll do:**
- Implement Blue-Green deployment with instant version switching
- Deploy Canary releases to test with a small percentage of users
- Control traffic distribution between stable and new versions
- Practice zero-risk rollback with Blue-Green strategy
- Gradually increase Canary traffic based on confidence
- Compare different deployment strategies and their use cases

## Prerequisites

**Required Software:**
- Kubernetes cluster (minikube, kind, Docker Desktop, or cloud provider)
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [01-basic-deployment](../01-basic-deployment/)
- **REQUIRED:** Completion of [02-rolling-update-rollback](../02-rolling-update-rollback/)
- Understanding of Kubernetes Services and labels
- Familiarity with pod selectors

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Implement Blue-Green deployment strategy
2. ✅ Switch traffic instantly between Blue and Green versions
3. ✅ Deploy Canary releases with controlled traffic splitting
4. ✅ Gradually increase Canary traffic percentage
5. ✅ Choose the appropriate deployment strategy for different scenarios
6. ✅ Perform zero-risk rollbacks with both strategies
7. ✅ Understand trade-offs between different deployment patterns

## Directory Structure

```
03-deployment-strategies/
└── src/
    ├── blue-green/
    │   ├── blue-deployment.yaml       # Version 1 (Blue)
    │   ├── green-deployment.yaml      # Version 2 (Green)
    │   └── service.yaml               # Service for traffic switching
    └── canary/
        ├── stable-deployment.yaml     # Stable version
        ├── canary-deployment.yaml     # Canary version (new)
        └── service.yaml               # Service routing to both versions
```

## Understanding Deployment Strategies

### Comparison of Strategies

| Strategy | Downtime | Rollback Speed | Resource Usage | Risk | Use Case |
|----------|----------|----------------|----------------|------|----------|
| **Recreate** | Yes (all pods killed) | Slow (recreate all) | Low | High | Development/testing |
| **Rolling Update** | No | Medium (gradual rollback) | Medium | Medium | Most applications |
| **Blue-Green** | No | Instant (switch label) | High (2x resources) | Low | Critical apps, instant rollback needed |
| **Canary** | No | Fast (adjust replicas) | Medium-High | Very Low | Testing with real users |

### Blue-Green Deployment

**Concept:**
- Run two identical production environments: Blue (current) and Green (new)
- All traffic goes to Blue initially
- Deploy new version to Green (while Blue handles traffic)
- Test Green thoroughly
- Switch all traffic to Green instantly by updating Service selector
- Keep Blue running for instant rollback if needed

**Visual Representation:**
```
Phase 1: Initial State
Service → [Blue v1.0] [Blue v1.0] [Blue v1.0]
          [Green: none]

Phase 2: Deploy Green
Service → [Blue v1.0] [Blue v1.0] [Blue v1.0]  ← Still receiving traffic
          [Green v2.0] [Green v2.0] [Green v2.0]  ← Testing, no traffic

Phase 3: Switch Traffic (Update Service selector)
          [Blue v1.0] [Blue v1.0] [Blue v1.0]  ← No traffic
Service → [Green v2.0] [Green v2.0] [Green v2.0]  ← All traffic

Phase 4: Rollback if needed (Update Service selector back)
Service → [Blue v1.0] [Blue v1.0] [Blue v1.0]  ← All traffic back
          [Green v2.0] [Green v2.0] [Green v2.0]  ← No traffic
```

**Advantages:**
- ✅ Instant rollback (change Service selector)
- ✅ Zero downtime
- ✅ Test new version in production environment
- ✅ Simple to understand and implement

**Disadvantages:**
- ❌ Requires 2x resources (both versions running)
- ❌ Database migrations can be complex
- ❌ All traffic switches at once (no gradual rollout)

---

### Canary Deployment

**Concept:**
- Deploy new version (Canary) alongside stable version
- Route small percentage of traffic to Canary (e.g., 10%)
- Monitor metrics (errors, latency, user feedback)
- Gradually increase Canary traffic if healthy (10% → 25% → 50% → 100%)
- Rollback by deleting Canary if issues detected

**Visual Representation:**
```
Phase 1: Initial State (100% Stable)
Service → [Stable v1.0] [Stable v1.0] [Stable v1.0] [Stable v1.0]  ← 100% traffic

Phase 2: Deploy Canary (90% Stable, 10% Canary)
Service → [Stable v1.0] [Stable v1.0] [Stable v1.0] [Stable v1.0]  ← 90% traffic
          [Canary v2.0]  ← 10% traffic (1 pod)

Phase 3: Increase Canary (50% Stable, 50% Canary)
Service → [Stable v1.0] [Stable v1.0]  ← 50% traffic
          [Canary v2.0] [Canary v2.0]  ← 50% traffic

Phase 4: Full Canary (100% New Version)
Service → [Canary v2.0] [Canary v2.0] [Canary v2.0] [Canary v2.0]  ← 100% traffic
          (Delete Stable deployment)
```

**Advantages:**
- ✅ Minimal risk (only small % of users affected)
- ✅ Real user testing in production
- ✅ Gradual rollout with monitoring
- ✅ Easy rollback (delete Canary)

**Disadvantages:**
- ❌ More complex to implement
- ❌ Requires good monitoring/metrics
- ❌ Traffic split is approximate (not exact percentage)
- ❌ Takes longer than Blue-Green

---

## Part 1: Blue-Green Deployment

### Step 1: Understand the Blue-Green YAML Files

**blue-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-blue
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
      version: blue
  template:
    metadata:
      labels:
        app: nginx
        version: blue      # Blue label
    spec:
      containers:
      - name: nginx
        image: nginx:1.19
        ports:
        - containerPort: 80
```

**green-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-green
  labels:
    app: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
      version: green
  template:
    metadata:
      labels:
        app: nginx
        version: green     # Green label
    spec:
      containers:
      - name: nginx
        image: nginx:1.20  # Different version
        ports:
        - containerPort: 80
```

**service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx
    version: blue        # Initially points to Blue
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: NodePort         # Or LoadBalancer for cloud
```

**Key Configuration Points:**

- Both deployments use **same `app: nginx` label**
- Each has **unique `version` label** (blue or green)
- Service selector uses **both labels** to control traffic
- Switching traffic = changing Service's `version` selector
- **No changes to deployments needed** for traffic switch

---

### Step 2: Deploy Blue Version (Initial Production)

```bash
cd 3/src/blue-green

# Deploy Blue version
kubectl apply -f blue-deployment.yaml

# Deploy Service (pointing to Blue)
kubectl apply -f service.yaml
```

**Expected output:**
```
deployment.apps/nginx-blue created
service/nginx-service created
```

---

### Step 3: Verify Blue Deployment

```bash
# Check deployments
kubectl get deployments

# Check pods with labels
kubectl get pods --show-labels

# Check service
kubectl get svc nginx-service

# Describe service to see selector
kubectl describe svc nginx-service
```

**Expected output:**
```
NAME         TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
nginx-service NodePort  10.96.100.100   <none>        80:30080/TCP   30s

Selector: app=nginx,version=blue  ← Traffic goes to Blue pods only
```

---

### Step 4: Test Blue Version

```bash
# Get the NodePort
kubectl get svc nginx-service

# If using minikube
minikube service nginx-service --url

# Test with curl (replace URL with your cluster's URL)
curl http://<node-ip>:<node-port>
```

You should see nginx 1.19 default page.

---

### Step 5: Deploy Green Version (New Version)

While Blue is handling all traffic, deploy Green:

```bash
# Deploy Green version (doesn't receive traffic yet)
kubectl apply -f green-deployment.yaml
```

**Expected output:**
```
deployment.apps/nginx-green created
```

Check all pods:
```bash
kubectl get pods -l app=nginx --show-labels
```

**Expected output:**
```
NAME                           READY   STATUS    LABELS
nginx-blue-xxxxxxxxx-xxxxx     1/1     Running   app=nginx,version=blue
nginx-blue-xxxxxxxxx-xxxxx     1/1     Running   app=nginx,version=blue
nginx-blue-xxxxxxxxx-xxxxx     1/1     Running   app=nginx,version=blue
nginx-green-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,version=green
nginx-green-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,version=green
nginx-green-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,version=green
```

**Important:** Green pods are running but receiving **zero traffic** (Service selector still points to Blue).

---

### Step 6: Test Green Version Directly (Optional)

Before switching traffic, you can test Green directly:

```bash
# Port-forward to a Green pod for testing
kubectl port-forward deployment/nginx-green 8080:80

# In another terminal, test
curl http://localhost:8080
```

This verifies Green version works before switching production traffic.

Press `Ctrl+C` to stop port-forward.

---

### Step 7: Switch Traffic from Blue to Green

**The critical moment - switching all traffic instantly:**

```bash
# Edit Service and change version selector
kubectl edit svc nginx-service
# Change: version: blue
# To:     version: green
# Save and exit
```

**Expected output:**
```
service/nginx-service patched
```

---

### Step 8: Verify Traffic Switch

```bash
# Check Service selector
kubectl describe svc nginx-service | grep Selector

# Test the service
curl http://<node-ip>:<node-port>
```

**What happened:**
- Service selector changed from `version: blue` to `version: green`
- All traffic instantly routed to Green pods
- Blue pods still running but receiving zero traffic
- **Zero downtime - instant switch!**

Check endpoints:
```bash
kubectl get endpoints nginx-service
```

Should show Green pod IPs only.

---

### Step 9: Monitor Green Version

Keep Green and Blue running for a while to monitor:

```bash
# Watch pods
kubectl get pods -l app=nginx -w

# Check logs
kubectl logs -l version=green --tail=50

# Monitor for errors (in another terminal)
watch kubectl get pods -l app=nginx
```

If everything looks good, Green is your new production version!

---

### Step 10: Rollback to Blue (If Needed)

If Green has issues, instant rollback:

```bash
# Switch back to Blue
kubectl edit svc nginx-service
# Change: version: green
# To:     version: blue
# Save and exit
```

**Rollback complete in ~1 second!** All traffic back to Blue.

---

### Step 11: Cleanup Old Version

Once confident in Green, remove Blue:

```bash
# Delete Blue deployment
kubectl delete deployment nginx-blue

# Verify
kubectl get deployments
kubectl get pods -l app=nginx
```

Only Green pods should remain.

---

### Step 12: Cleanup Blue-Green Demo

```bash
kubectl delete -f blue-deployment.yaml
kubectl delete -f green-deployment.yaml
kubectl delete -f service.yaml
```

---

## Part 2: Canary Deployment

### Step 1: Understand the Canary YAML Files

**stable-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-stable
  labels:
    app: nginx
spec:
  replicas: 4           # Stable version has more pods
  selector:
    matchLabels:
      app: nginx
      track: stable
  template:
    metadata:
      labels:
        app: nginx
        track: stable    # Stable label
    spec:
      containers:
      - name: nginx
        image: nginx:1.19
        ports:
        - containerPort: 80
```

**canary-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-canary
  labels:
    app: nginx
spec:
  replicas: 1           # Canary starts with fewer pods (10% traffic)
  selector:
    matchLabels:
      app: nginx
      track: canary
  template:
    metadata:
      labels:
        app: nginx
        track: canary    # Canary label
    spec:
      containers:
      - name: nginx
        image: nginx:1.20  # New version
        ports:
        - containerPort: 80
```

**service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app: nginx         # Matches BOTH stable and canary
    # No track label here - routes to both!
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: NodePort
```

**Key Configuration Points:**

- Service selector uses **only `app: nginx`** (no track label)
- This routes traffic to **both stable and canary** pods
- Traffic distribution is **approximate** based on pod count ratio
- 4 stable pods + 1 canary pod = ~80% stable, ~20% canary
- Adjust canary replicas to change traffic percentage

**Traffic Split Calculation:**
```
Total pods = Stable pods + Canary pods
Canary traffic % = Canary pods / Total pods × 100

Example:
4 stable + 1 canary = 5 total
Canary traffic = 1/5 × 100 = 20%
```

---

### Step 2: Deploy Stable Version

```bash
cd 3/src/canary

# Deploy stable version
kubectl apply -f stable-deployment.yaml

# Deploy service
kubectl apply -f service.yaml
```

**Expected output:**
```
deployment.apps/nginx-stable created
service/nginx-service created
```

---

### Step 3: Verify Stable Deployment

```bash
# Check deployments
kubectl get deployments

# Check pods
kubectl get pods -l app=nginx --show-labels

# Check service
kubectl describe svc nginx-service
```

**Expected output:**
```
Selector: app=nginx  ← Routes to all pods with app=nginx label
Endpoints: <4 pod IPs>  ← Only stable pods currently
```

---

### Step 4: Test Stable Version

```bash
# Get service URL
kubectl get svc nginx-service

# Test (replace with your URL)
curl http://<node-ip>:<node-port>
```

All requests go to nginx:1.19 (stable version).

---

### Step 5: Deploy Canary Version (10-20% Traffic)

```bash
# Deploy canary with 1 replica (out of 5 total = ~20% traffic)
kubectl apply -f canary-deployment.yaml
```

**Expected output:**
```
deployment.apps/nginx-canary created
```

Check all pods:
```bash
kubectl get pods -l app=nginx --show-labels
```

**Expected output:**
```
NAME                            READY   STATUS    LABELS
nginx-stable-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,track=stable
nginx-stable-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,track=stable
nginx-stable-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,track=stable
nginx-stable-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,track=stable
nginx-canary-xxxxxxxxx-xxxxx    1/1     Running   app=nginx,track=canary
```

**Traffic split:** 4 stable + 1 canary = 5 total → ~20% canary traffic

---

### Step 6: Verify Traffic Split

Check service endpoints:

```bash
kubectl get endpoints nginx-service
```

Should show **5 pod IPs** (4 stable + 1 canary).

Test multiple times to see traffic distribution:

```bash
# Run 10 requests
for i in {1..10}; do
  curl -s http://<node-ip>:<node-port> | grep -i "nginx"
done
```

Most responses from stable (nginx:1.19), occasionally from canary (nginx:1.20).

---

### Step 7: Monitor Canary

**Monitor for errors, latency, metrics:**

```bash
# Watch pods
kubectl get pods -l app=nginx -w

# Check canary logs
kubectl logs -l track=canary --tail=50 -f

# Check stable logs (compare)
kubectl logs -l track=stable --tail=50
```

**In production, you'd monitor:**
- Error rates (canary vs stable)
- Response times (P50, P95, P99)
- CPU/Memory usage
- Business metrics (conversion rate, etc.)

---

### Step 8: Increase Canary Traffic (50%)

If canary looks good, increase traffic:

```bash
# Scale canary to match stable (50/50 split)
kubectl scale deployment nginx-canary --replicas=4
```

**New traffic split:** 4 stable + 4 canary = 8 total → 50% each

Verify:
```bash
kubectl get pods -l app=nginx --show-labels
```

Should see 4 stable + 4 canary pods.

---

### Step 9: Full Canary Rollout (100%)

If canary performs well at 50%, go to 100%:

```bash
# Scale down stable to 0
kubectl scale deployment nginx-stable --replicas=0

# Scale up canary to desired count
kubectl scale deployment nginx-canary --replicas=4
```

**New traffic split:** 0 stable + 4 canary = 4 total → 100% canary

All traffic now goes to new version!

---

### Step 10: Cleanup Stable Deployment

Once confident, remove stable:

```bash
kubectl delete deployment nginx-stable
```

Rename canary to stable for next deployment cycle:

```bash
# Optional: Make canary the new stable
kubectl label deployment nginx-canary track=stable --overwrite
kubectl annotate deployment nginx-canary kubernetes.io/change-cause="Promoted canary to stable"
```

---

### Step 11: Rollback Canary (If Needed)

If canary has issues, rollback quickly:

```bash
# Delete canary deployment
kubectl delete deployment nginx-canary

# Scale up stable (if still running)
kubectl scale deployment nginx-stable --replicas=4
```

All traffic returns to stable version immediately.

---

### Step 12: Cleanup Canary Demo

```bash
kubectl delete -f stable-deployment.yaml
kubectl delete -f canary-deployment.yaml
kubectl delete -f service.yaml
```

---

## Experiments to Try

### Blue-Green Experiments

1. **Different replica counts:**
   ```bash
   # Try unequal replicas
   kubectl scale deployment nginx-blue --replicas=2
   kubectl scale deployment nginx-green --replicas=5
   # Does traffic switch still work? (Yes!)
   ```

### Canary Experiments

1. **Simulate canary failure:**
   ```yaml
   # Edit canary-deployment.yaml
   image: nginx:invalid-tag  # This will fail
   ```
   Deploy and watch how you'd detect and rollback.

---

## Common Questions

### Q: When should I use Blue-Green vs Canary?
**A:** 
- **Blue-Green:** When you need instant rollback, have resources for 2x environment, want all-or-nothing deployment
- **Canary:** When you want to test with real users first, minimize risk, have good monitoring, can tolerate gradual rollout

### Q: How does Kubernetes distribute traffic in Canary?
**A:** Kubernetes Service uses round-robin load balancing across all matching pods. Traffic split is **approximate** based on pod count ratio. For exact percentages, use service mesh (Istio, Linkerd).

### Q: Can I have multiple canaries at once?
**A:** Yes! You can have stable + canary-v1 + canary-v2 all receiving traffic simultaneously. Just ensure Service selector matches all of them.

### Q: What happens to in-flight requests during Blue-Green switch?
**A:** 
- New requests immediately go to new version
- In-flight requests to old version complete normally
- Kubernetes gracefully terminates pods (respects `terminationGracePeriodSeconds`)

### Q: Is Canary traffic split exact?
**A:** No, it's approximate. 4 stable + 1 canary doesn't guarantee exactly 20% traffic. For precise control, use:
- Service mesh (Istio, Linkerd)
- Ingress controllers with traffic splitting
- Flagger (automated canary deployments)

### Q: What if canary and stable have different resource requirements?
**A:** No problem! Each deployment can have different resource requests/limits. Just ensure Service selector matches both.

### Q: Can I use Blue-Green and Canary together?
**A:** Yes! For example:
- Use Canary to test new version with 10% traffic
- Once confident, use Blue-Green to switch remaining 90%
- Gives you both gradual testing and instant full rollout

---

## What You Learned

In this lab, you:
- ✅ Implemented Blue-Green deployment with two full environments
- ✅ Switched traffic instantly by changing Service selector labels
- ✅ Performed zero-risk rollback by switching Service selector back
- ✅ Deployed Canary releases alongside stable versions
- ✅ Controlled traffic distribution using replica counts
- ✅ Gradually increased Canary traffic from 20% to 50% to 100%
- ✅ Understood trade-offs between Blue-Green and Canary strategies
- ✅ Practiced both rollback scenarios for each strategy

**Key Takeaway:** Blue-Green and Canary deployment strategies give you fine-grained control over production deployments, enabling you to deploy confidently with minimal risk and instant rollback capabilities when needed.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f blue-deployment.yaml` | Deploy Blue version |
| `kubectl apply -f green-deployment.yaml` | Deploy Green version |
| `kubectl describe svc nginx-service \| grep Selector` | Check which version receives traffic |
| `kubectl delete deployment nginx-blue` | Remove old version |

---

## CKA Certification Tips

**For Deployment Strategy questions:**

✅ **Know the four main strategies:**
1. Recreate - All pods killed, then recreated (downtime)
2. RollingUpdate - Gradual replacement (default, no downtime)
3. Blue-Green - Two full environments, instant switch
4. Canary - Gradual rollout to subset of users

---

## Troubleshooting

**Blue-Green: Traffic not switching?**
```bash
# Check Service selector
kubectl describe svc nginx-service | grep Selector

# Verify deployment labels match
kubectl get pods --show-labels | grep version

# Common issue: typo in version label
```

**General: Want exact traffic percentages?**
- Kubernetes native Service gives approximate split
- For exact control, use:
  - Nginx Ingress with traffic splitting annotations
  - Istio/Linkerd virtual services
  - Flagger (automated progressive delivery)