# Demo: 02-deployments/03-deployment-strategies — Deployment Strategies

## Lab Overview

This lab explores advanced deployment strategies beyond basic rolling updates. You'll learn how to implement Blue-Green deployments for instant switches between versions, and Canary deployments for gradual, risk-controlled rollouts to a small subset of users before full deployment.

These strategies are essential for production environments where you need fine-grained control over deployments. Blue-Green allows instant rollback with zero risk, while Canary deployments let you test new versions with real users before committing to a full rollout. Both strategies minimize risk and give you confidence when deploying critical updates.

Understanding these patterns will help you choose the right deployment strategy based on your application's requirements, risk tolerance, and rollback needs. You'll see how to use Kubernetes native resources (Deployments, Services, labels) to implement these enterprise-grade deployment patterns — entirely by hand, which is exactly what makes the closing section on Argo Rollouts worth reading once you're done.

**What you'll do:**
- Implement Blue-Green deployment with instant version switching
- Deploy Canary releases to test with a small percentage of users
- Control traffic distribution between stable and new versions
- Practice zero-risk rollback with Blue-Green strategy
- Gradually increase Canary traffic based on confidence
- Compare different deployment strategies and their use cases

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-basic-deployment` (Deployment→ReplicaSet→Pod hierarchy, `pod-template-hash`)
- Completion of `02-rolling-update-rollback` (rollout mechanics, revision history)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Implement Blue-Green deployment strategy
2. ✅ Switch traffic instantly between Blue and Green versions
3. ✅ Deploy Canary releases with controlled traffic splitting
4. ✅ Gradually increase Canary traffic percentage
5. ✅ Choose the appropriate deployment strategy for different scenarios
6. ✅ Perform zero-risk rollbacks with both strategies
7. ✅ Understand trade-offs between different deployment patterns
8. ✅ Explain, at a basic level, how a Service's selector actually drives traffic routing in both strategies

## Directory Structure

```
02-deployments/03-deployment-strategies/
├── README.md
├── src/
│   ├── blue-green/
│   │   ├── 01-blue-deployment.yaml    # Version 1 (Blue)
│   │   ├── 02-green-deployment.yaml   # Version 2 (Green)
│   │   └── 03-service.yaml            # Service for traffic switching
│   ├── canary/
│   │   ├── 01-stable-deployment.yaml  # Stable version
│   │   ├── 02-canary-deployment.yaml  # Canary version (new)
│   │   └── 03-service.yaml            # Service routing to both versions
│   └── break-fix/
│       └── 01-canary-bad-image.yaml   # Embedded inline in README — not generated on disk
├── 03-deployment-strategies-anki.csv
└── 03-deployment-strategies-quiz.md
```

---

## Recall Check — 02-rolling-update-rollback

Answer from memory before continuing — no peeking at the previous demo.

1. When a rolling update happens, what actually happens to the existing ReplicaSet?
2. Does `kubectl rollout undo` restore the old revision number, or create a new one?
3. Why might a rollout with `maxSurge: 1` stall indefinitely?

<details>
<summary>Answers</summary>

1. A new ReplicaSet is created with a new `pod-template-hash`; the old one scales down to 0 rather than being mutated.
2. It creates a new revision copying the old configuration forward — the old revision number disappears from history.
3. The surge pod is scheduled like any other pod — if its resource requests can't be satisfied by any node, it never schedules and the rollout never progresses.

</details>

---

## Concepts

### Just Enough Services — Selector-to-Pod Matching

Both strategies in this demo lean entirely on a Kubernetes object you
haven't been formally introduced to yet — `Service`. Full depth (ClusterIP
vs NodePort vs LoadBalancer, DNS names, how kube-proxy actually implements
routing) is `03-services`' entire subject; here's just enough to
understand what's driving the traffic behavior you're about to observe.

A Service doesn't run anything itself — it's a stable address plus a
live-updated list of matching Pod IPs (called **Endpoints**). Kubernetes
continuously recomputes that Endpoints list the moment matching Pods
change, using the exact same label-selector mechanism you already know
from Deployments. That's the entire mechanism both strategies below
depend on:

- **Blue-Green** works because changing the Service's
  `spec.selector.version` field instantly recomputes which Pods count as
  matching — from Blue's labels to Green's — and the Endpoints list flips
  accordingly, with **no change to either Deployment at all**.
- **Canary** works because the Service's selector deliberately *omits* the
  `track` label, so it matches Pods from both the stable and canary
  Deployments simultaneously — each request gets load-balanced across
  every currently-matching Pod.

One more thing worth knowing now rather than being surprised by it later:
a Pod only becomes an Endpoint once it's actually `Ready` — a Pod stuck in
`ImagePullBackOff` (this demo's own Break-Fix scenario) never gets added
to the Endpoints list at all, regardless of what its labels say.

### Comparison of Strategies

| Strategy | Downtime | Rollback Speed | Resource Usage | Risk | Use Case |
|----------|----------|----------------|----------------|------|----------|
| **Recreate** | Yes (all pods killed) | Slow (recreate all) | Low | High | Development/testing |
| **Rolling Update** | No | Medium (gradual rollback) | Medium | Medium | Most applications |
| **Blue-Green** | No | Instant (switch label) | High (2x resources) | Low | Critical apps, instant rollback needed |
| **Canary** | No | Fast (adjust replicas) | Medium-High | Very Low | Testing with real users |

Recreate and Rolling Update were covered in full in `01-basic-deployment`
and `02-rolling-update-rollback` — this demo covers the two rows that
actually need a Service to implement at all.

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

**src/blue-green/01-blue-deployment.yaml:**
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

**src/blue-green/02-green-deployment.yaml:**
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

**src/blue-green/03-service.yaml:**
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
- **No changes to deployments needed** for traffic switch — see **Just Enough Services** above for exactly why this works

---

### Step 2: Deploy Blue Version (Initial Production)

```bash
cd 02-deployments/03-deployment-strategies/src/blue-green

# Deploy Blue version
kubectl apply -f 01-blue-deployment.yaml

# Deploy Service (pointing to Blue)
kubectl apply -f 03-service.yaml
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
kubectl apply -f 02-green-deployment.yaml
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

**Important:** Green pods are running but receiving **zero traffic** — the
Service's Endpoints list only includes Pods matching its current selector
(`version: blue`), per **Just Enough Services** above.

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
```
Find `selector.version: blue` and change it to `selector.version: green`.
Save and exit.

**Expected output:**
```
service/nginx-service edited
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
- Kubernetes recomputed the Endpoints list immediately — all traffic instantly routed to Green pods
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
```
Change `selector.version: green` back to `selector.version: blue`. Save
and exit.

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
kubectl delete -f 01-blue-deployment.yaml
kubectl delete -f 02-green-deployment.yaml
kubectl delete -f 03-service.yaml
```

---

## Part 2: Canary Deployment

### Step 1: Understand the Canary YAML Files

**src/canary/01-stable-deployment.yaml:**
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

**src/canary/02-canary-deployment.yaml:**
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

**src/canary/03-service.yaml:**
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
- This routes traffic to **both stable and canary** pods — see **Just Enough Services** above
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
cd 02-deployments/03-deployment-strategies/src/canary

# Deploy stable version
kubectl apply -f 01-stable-deployment.yaml

# Deploy service
kubectl apply -f 03-service.yaml
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
kubectl apply -f 02-canary-deployment.yaml
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

### Step 10: "Promoting" Canary to Stable — What This Actually Requires

Once confident, remove the old stable deployment:

```bash
kubectl delete deployment nginx-stable
```

At this point it's tempting to just relabel `nginx-canary` as the new
"stable" — but it's worth being precise about what that would and wouldn't
actually accomplish, given what you already know from
`01-basic-deployment`:

```bash
kubectl label deployment nginx-canary track=stable --overwrite
```

This only changes the **Deployment object's own** `metadata.labels` — a
bookkeeping label that would let you find it later with `kubectl get
deploy -l track=stable`. It does **not** touch `spec.selector` or
`spec.template.metadata.labels`, both of which are immutable once set
(exactly the rule from `01-basic-deployment`) — so every Pod this
Deployment actually manages keeps its real `track=canary` label,
completely unaffected by the relabel. Nothing about traffic routing
changes either, since this demo's Service selector never referenced
`track` in the first place.

If you genuinely need a Deployment named/labeled `nginx-stable` going
forward, the honest options are: keep running this Deployment under its
current name (`nginx-canary`) as your new baseline and update your own
team's documentation/tooling accordingly, or delete it and recreate a
proper `nginx-stable` Deployment with the new image — the same
delete-and-recreate pattern already required any time a selector-level
identity genuinely needs to change.

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
kubectl delete -f 01-stable-deployment.yaml
kubectl delete -f 02-canary-deployment.yaml
kubectl delete -f 03-service.yaml
```

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
- ✅ Understood exactly what a Service selector change does and doesn't affect — including why a Deployment-level relabel doesn't actually change Pod identity

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-canary-bad-image.yaml`:**

Assumes the Canary demo's `01-stable-deployment.yaml` and `03-service.yaml` are already applied.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-canary
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
      track: canary
  template:
    metadata:
      labels:
        app: nginx
        track: canary
    spec:
      containers:
      - name: nginx
        image: nginx:invalid-tag   # doesn't exist
        ports:
        - containerPort: 80
```

```bash
kubectl apply -f 01-canary-bad-image.yaml
kubectl get pods -l app=nginx --show-labels
kubectl get endpoints nginx-service
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `nginx:invalid-tag` doesn't exist, so the canary pod sits in
`ImagePullBackOff` and never becomes `Ready` — the same failure mode
covered fully in `01-core-concepts/03-pod-container-basics`.

**Fix:** Correct the tag to a real one (e.g. `nginx:1.20`) and reapply.

**Cascade — this is the interesting part, and it's actually good news:**
`kubectl get endpoints nginx-service` shows **only the 4 stable pod IPs**,
never the broken canary pod. Per **Just Enough Services** above, a Pod
only becomes an Endpoint once it's `Ready` — so this "canary" receives
**zero real user traffic** despite existing and despite the Service's
selector technically matching its labels. The failure is completely
invisible to end users; the only way to know something's wrong is to
check the canary pod's own status directly (`kubectl get pods -l
track=canary`), not to infer it from traffic/error patterns. This is
exactly the kind of gap real canary monitoring exists to catch —
`kubectl get pods` looking fine at a glance doesn't mean the canary is
actually being exercised by traffic.

</details>

**Cleanup:**
```bash
kubectl delete deployment nginx-canary 2>/dev/null || true
```

---

### Error-2

```bash
# Assumes the Blue-Green demo's Service is deployed and pointed at "blue"
kubectl edit svc nginx-service
```
Introduce a deliberate typo — change `version: blue` to `versoin: blue`
(note the misspelled key, not value). Save and exit, then:
```bash
kubectl describe svc nginx-service | grep Selector
kubectl get endpoints nginx-service
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `versoin` is a different key from `version` as far as Kubernetes
is concerned — this isn't rejected as invalid YAML (any key name is
syntactically legal in a selector map), it just silently creates a
selector that matches **no Pods at all**, since no Pod has a label
literally named `versoin`.

**Fix:** Correct the key back to `version` and save.

**Cascade:** `kubectl get endpoints nginx-service` shows an **empty**
Endpoints list — not an error, just nothing. Every request to the Service
fails or hangs, with no Kubernetes-level error message pointing at the
real cause. This is deliberately similar to Demo 03's own Troubleshooting
note ("common issue: typo in version label") — reproduced here as a real,
diagnosable scenario instead of just a warning.

</details>

**Cleanup:** re-edit `nginx-service` back to a correct selector, or reapply `03-service.yaml`.

---

## Interview Prep

**Q: When should I use Blue-Green vs Canary?**
A: Blue-Green when you need instant rollback, have resources for a 2x environment, and want an all-or-nothing switch. Canary when you want to test with real users first, minimize blast radius, have good monitoring, and can tolerate a more gradual rollout.

**Q: How does Kubernetes distribute traffic in Canary?**
A: The Service uses round-robin load balancing across all matching, Ready pods. The split is approximate, driven purely by pod count ratio — for exact percentages you need something beyond native Kubernetes Services, like a service mesh or Argo Rollouts (see the closing section below).

**Q: What happens to in-flight requests during a Blue-Green switch?**
A: New requests immediately go to the new version's Endpoints. In-flight requests to the old version complete normally, and old pods are terminated gracefully, respecting `terminationGracePeriodSeconds` exactly as covered in `01-core-concepts`.

**Q: If you relabel a canary Deployment's `metadata.labels` to say `track: stable`, does that actually promote it?**
A: No — it only changes the Deployment object's own bookkeeping label. `spec.selector` and `spec.template.metadata.labels` are immutable, so the Pods it manages keep their real labels unchanged, and nothing about Service routing changes either. Genuine promotion means keeping the Deployment running under a new understanding, or recreating it properly under a new name.

**Q: Does a canary pod stuck in `ImagePullBackOff` receive any real traffic?**
A: No — a Pod only becomes a Service Endpoint once it's `Ready`. A broken canary is invisible to traffic entirely, which is exactly why you have to check the pod's own status directly rather than infer health from request patterns.

**Q: What's the real cost of Blue-Green's "instant rollback"?**
A: Running two full production-sized environments simultaneously — 2x the compute cost for however long both versions coexist, plus the complexity of anything stateful (database migrations especially) needing to work correctly against both versions at once.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Deployment | CKAD | 20% | Blue-Green and Canary implementation patterns |
| Services & Networking | CKA | 20% | Selector-driven traffic routing (just enough for this demo — full depth in `03-services`) |
| Application Deployment | CKAD | — | Trade-off reasoning between deployment strategies |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Assuming Canary traffic split is exact | It's approximate, driven by pod-count ratio and round-robin — 4:1 doesn't guarantee exactly 20%/80% on any given sample of requests |
| A selector key typo (`versoin` vs `version`) | Syntactically valid YAML, but silently matches zero pods — no error message points at the actual cause |
| Assuming a relabeled Deployment changes its Pods' labels | `metadata.labels` on the Deployment and `spec.template.metadata.labels` on its Pods are two separate label sets — relabeling one never touches the other |
| Forgetting Endpoints require Ready, not just matching labels | A broken pod can match a Service's selector perfectly and still receive zero traffic if it's never Ready |
| Underestimating Blue-Green's resource cost | "No downtime" reads as free — it isn't; budget for 2x capacity for the overlap window |

### Exam Task — Write it from scratch

Create a Blue-Green setup: two Deployments (`app-blue`, `app-green`) each with a distinct `version` label, and a Service initially selecting `version: blue`. Switch the Service to `green`, then verify via Endpoints that only Green pods are receiving traffic.

Official docs: [Services](https://kubernetes.io/docs/concepts/services-networking/service/), [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create deployment app-blue --image=nginx:1.19 --replicas=2 --dry-run=client -o yaml > blue.yaml
# edit blue.yaml: add version: blue to both metadata.labels and spec.template.metadata.labels,
# and to spec.selector.matchLabels
kubectl apply -f blue.yaml

# repeat for app-green with version: green

kubectl expose deployment app-blue --name=app-svc --port=80 --selector="app=app-blue,version=blue"
kubectl edit svc app-svc   # change selector's version to green
kubectl get endpoints app-svc
```

**Key fields to recall:** the Service's `spec.selector` must include the
label that actually distinguishes the two versions (`version`), not just
the shared `app` label — otherwise it matches both simultaneously,
behaving like Canary instead of Blue-Green.

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Service's Endpoints list is recomputed live from its selector | This is the entire mechanism behind Blue-Green's instant switch — no Deployment ever changes, only what the Service currently matches |
| Blue-Green switches all traffic at once; Canary splits it gradually | Different risk profiles: Blue-Green is all-or-nothing with instant rollback, Canary is gradual with a smaller blast radius |
| Canary traffic percentage is only approximate | Driven by pod-count ratio and round-robin load balancing, not an exact guarantee — exact control needs something beyond native Services |
| Only `Ready` pods become Service Endpoints | A broken canary pod (e.g. bad image tag) matches the selector but receives zero real traffic — invisible to users, but also invisible to naive "is it broken" checks based on traffic alone |
| Relabeling a Deployment's own `metadata.labels` doesn't touch its Pods | `spec.selector` and `spec.template.metadata.labels` are immutable and separate — a cosmetic relabel changes nothing about what's actually running |
| A selector key typo matches nothing, silently | No error, just an empty Endpoints list — worth knowing the failure signature by sight |
| Blue-Green's "zero risk" comes with a real resource cost | 2x compute for the overlap window, plus added complexity for anything stateful |
| Both strategies here are entirely manual | No automated analysis, no precise traffic percentages, no automatic rollback — see below for what changes that |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl apply -f 01-blue-deployment.yaml` | Deploy Blue version |
| `kubectl apply -f 02-green-deployment.yaml` | Deploy Green version |
| `kubectl edit svc nginx-service` | Change the Service selector to switch traffic |
| `kubectl describe svc nginx-service \| grep Selector` | Check which version currently receives traffic |
| `kubectl get endpoints nginx-service` | See exactly which pod IPs are currently receiving traffic |
| `kubectl scale deployment nginx-canary --replicas=N` | Adjust canary traffic share by changing its pod count |
| `kubectl logs -l track=canary --tail=50 -f` | Follow logs from only the canary track |
| `kubectl delete deployment nginx-blue` | Remove the old version once confident in the new one |

---

## Troubleshooting

**Blue-Green: Traffic not switching?**
```bash
# Check Service selector
kubectl describe svc nginx-service | grep Selector

# Verify deployment labels match
kubectl get pods --show-labels | grep version

# Common issue: typo in version label — see this demo's Break-Fix Error-2
```

**Canary pod exists but never seems to get traffic?**
```bash
# Check if it's actually Ready — only Ready pods become Endpoints
kubectl get pods -l track=canary
kubectl get endpoints nginx-service
# See this demo's Break-Fix Error-1
```

**General: Want exact traffic percentages?**
- Kubernetes native Service gives approximate split only
- For exact control: Nginx Ingress with traffic-splitting annotations, Istio/Linkerd virtual services, or Argo Rollouts — see below

---

## Beyond Manual Blue-Green and Canary

Everything in this demo was implemented entirely by hand: editing Service
selectors yourself, scaling replica counts yourself, watching pods and
logs yourself to decide when to proceed or roll back. That manual nature
is exactly the source of every limitation already listed above:

| Limitation from this demo | What it actually costs you |
|---|---|
| Canary traffic split is approximate, pod-count-based | No way to say "exactly 5% of traffic" — only "roughly 1 pod's worth" |
| No automated analysis | You watched `kubectl logs` yourself and made the call — nothing evaluates error rates or latency against a threshold for you |
| No automatic rollback | If something goes wrong at 2am, this setup does nothing until a human notices and runs `kubectl delete`/`kubectl edit` |
| Rollback checks are all-or-nothing | There's no built-in "pause and observe before continuing" step beyond what you manually chose to do in Step 7/8 of the Canary flow |

A companion GitOps series covers the production-grade version of these
same patterns — precise traffic-percentage control, automated metric
analysis, and automatic rollback without anyone watching a dashboard:
**`gitops-labs/argo-rollouts-basics-to-prod`** (a separate, external repo
— not part of this series' own `NN-topic` numbering). Worth a look once
this demo feels comfortable, specifically to see the same Blue-Green and
Canary concepts you just built by hand, automated properly.

---

## Appendix — Anki Cards

**`03-deployment-strategies-anki.csv`:**

````
#deck:k8s-platform-labs::02-deployments::03-deployment-strategies
#separator:Comma
#columns:Front,Back,Tags
"What makes a Service's Endpoints list update instantly when you change its selector?","Kubernetes continuously recomputes Endpoints from the selector against currently Ready, matching pods — this is the entire mechanism behind Blue-Green's instant switch","demo03-deployments,services,endpoints,cka-services-networking"
"Why does Blue-Green require no changes to either Deployment when switching traffic?","Only the Service's selector changes — both Deployments keep running unmodified the whole time","demo03-deployments,blue-green,ckad-application-deployment"
"Why is Canary traffic split only approximate?","It's driven by pod-count ratio and round-robin load balancing, not a guaranteed percentage","demo03-deployments,canary,ckad-application-deployment"
"Does a pod that matches a Service's selector but isn't Ready receive traffic?","No — only Ready pods become Endpoints, regardless of label match","demo03-deployments,services,endpoints,cka-services-networking"
"Does relabeling a Deployment's metadata.labels change its Pods' labels?","No — metadata.labels on the Deployment and spec.template.metadata.labels on its Pods are separate, and the Pod-affecting one is immutable","demo03-deployments,immutability,ckad-application-deployment"
"What happens if a Service selector has a typo'd key (e.g. versoin instead of version)?","It's valid YAML, so it's silently accepted — but it matches zero pods, with no error pointing at the cause","demo03-deployments,services,troubleshooting,cka-troubleshooting"
"What's the real resource cost of Blue-Green's instant rollback capability?","Roughly 2x compute — both full environments run simultaneously for the overlap window","demo03-deployments,blue-green,cka-workloads-scheduling"
"What does native Kubernetes Service-based canary lack compared to a tool like Argo Rollouts?","Precise traffic percentages, automated metric analysis, and automatic rollback — everything here was done manually","demo03-deployments,argo-rollouts,ckad-application-deployment"
"When would Recreate strategy actually be preferable to RollingUpdate?","When downtime is acceptable and simplicity matters more — e.g. dev/test environments — covered fully in 02-rolling-update-rollback","demo03-deployments,strategy-comparison,ckad-application-deployment"
````

---

## Appendix — Quiz

**`03-deployment-strategies-quiz.md`:**

````markdown
# Quiz — 02-deployments/03-deployment-strategies: Deployment Strategies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What makes Blue-Green's traffic switch instant?**

- A) Both Deployments are updated simultaneously
- B) The Service's selector changes, and its Endpoints list is recomputed immediately — no Deployment changes at all
- C) kubectl restarts all pods
- D) DNS propagation completes instantly in Kubernetes

<details>
<summary>Answer</summary>

**B** — Neither Deployment is touched; only the Service's selector changes, and Endpoints recompute against whichever Pods currently match.
Trap: A assumes both Deployments need coordinated changes, which defeats the entire point of the pattern.

</details>

---

**Q2. Is Canary traffic split ever an exact percentage with native Kubernetes Services?**

- A) Yes, always exact
- B) No — it's approximate, based on pod-count ratio and round-robin balancing
- C) Only if replicas are a multiple of 10
- D) Only with a LoadBalancer type Service

<details>
<summary>Answer</summary>

**B** — 4 stable + 1 canary is "roughly" 20%, not a guaranteed percentage — exact control requires something beyond native Services.
Trap: C invents a mathematical condition that doesn't actually change how load balancing works.

</details>

---

**Q3. A canary pod is stuck in `ImagePullBackOff`. Does it receive any real user traffic?**

- A) Yes, a small amount, since it matches the selector
- B) No — only Ready pods become Service Endpoints
- C) Yes, but only error responses
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — Matching a selector isn't sufficient; a pod must also be `Ready` to become an Endpoint, so a broken canary is invisible to real traffic entirely.
Trap: A assumes label matching alone determines traffic eligibility, ignoring the Ready requirement.

</details>

---

**Q4. Does `kubectl label deployment nginx-canary track=stable --overwrite` change what its Pods are labeled?**

- A) Yes, immediately
- B) No — it only changes the Deployment object's own labels, not `spec.template.metadata.labels`
- C) Yes, but only after the next rollout
- D) It deletes and recreates the Pods with new labels

<details>
<summary>Answer</summary>

**B** — The Deployment's own `metadata.labels` and its Pods' labels (via `spec.template.metadata.labels`) are two separate, independently-set fields — relabeling one never touches the other.
Trap: C imagines a delayed effect that doesn't exist — there's no mechanism that would eventually propagate this relabel to Pods.

</details>

---

**Q5. What happens if a Service selector has a typo'd key, like `versoin` instead of `version`?**

- A) Kubernetes rejects the YAML as invalid
- B) It's accepted as valid YAML but matches zero pods, with no error message
- C) Kubernetes auto-corrects the typo
- D) It falls back to matching all pods

<details>
<summary>Answer</summary>

**B** — Any key name is syntactically legal in a selector map, so this is silently accepted — the failure is a Service matching nothing, not a rejected apply.
Trap: D imagines a permissive fallback that doesn't exist — an empty match stays empty, it doesn't broaden.

</details>

---

**Q6. What is the real resource cost of Blue-Green deployment?**

- A) None — it's completely free
- B) Roughly 2x compute, since both environments run simultaneously during the overlap
- C) Only the cost of the Service object itself
- D) Cost scales with the number of rollbacks performed

<details>
<summary>Answer</summary>

**B** — "Zero downtime" doesn't mean zero cost — running two full production-sized environments at once is genuinely 2x the compute footprint for that window.
Trap: A treats "no downtime" and "no cost" as the same thing, which they aren't.

</details>

---

**Q7. What does native Kubernetes Service-based Canary lack compared to a tool like Argo Rollouts?**

- A) The ability to route traffic to more than one version at all
- B) Precise traffic percentages, automated analysis, and automatic rollback
- C) Support for more than 2 replicas
- D) The ability to use labels

<details>
<summary>Answer</summary>

**B** — Native Services can route to multiple versions, but everything about *when* and *how much* traffic shifts, and whether to roll back, is manual with plain Kubernetes objects.
Trap: A overstates the limitation — basic multi-version routing is exactly what this demo already achieved natively.

</details>

---

**Q8. When would `Recreate` strategy actually make sense over `RollingUpdate`?**

- A) Never — RollingUpdate is strictly better in all cases
- B) When downtime is acceptable and simplicity matters more, e.g. dev/test environments
- C) Only for stateless applications
- D) Only when using Blue-Green

<details>
<summary>Answer</summary>

**B** — Recreate's simplicity (kill everything, then start everything new) is a genuine advantage when a downtime window is acceptable and you don't need RollingUpdate's added complexity.
Trap: A treats RollingUpdate as unconditionally superior, ignoring that simplicity itself has value in lower-stakes environments.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````