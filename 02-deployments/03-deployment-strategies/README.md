# Demo: 02-deployments/03-deployment-strategies — Deployment Strategies


## Lab Overview

`02-rolling-update-recreate` covered the two strategies every Deployment
can use natively — `RollingUpdate` and `Recreate` — both of which operate
entirely inside a single Deployment's own reconciliation loop. This lab
picks up exactly where that demo's closing section left off: Blue-Green
and Canary, two patterns that step outside a single Deployment and use a
Service's selector to control traffic across **two** Deployments running
side by side.

Blue-Green gives you an instant, all-or-nothing switch between versions
with a near-zero-risk rollback — flip the Service's selector back, and
traffic returns to the old version in about as long as it takes Kubernetes
to recompute Endpoints. Canary takes the opposite approach: a gradual,
percentage-based rollout to a small subset of traffic first, so you can
watch real metrics before committing to a full release.

Both strategies minimize risk in ways `RollingUpdate` and `Recreate`
structurally cannot — neither prior strategy can hold a new version at
partial traffic exposure, or switch back in under a second. You'll build
both patterns using nothing but native Kubernetes objects (two
Deployments, labels, and a Service) entirely by hand — which is exactly
what makes the closing section on Argo Rollouts worth reading once you're
done, since it shows what changes once a tool automates what you just did
manually.

**What you'll do:**

- Implement Blue-Green deployment with instant version switching
- Deploy Canary releases to test with a small percentage of users
- Control traffic distribution between stable and new versions
- Practice zero-risk rollback with Blue-Green strategy
- Gradually increase Canary traffic based on confidence
- Compare Blue-Green and Canary against RollingUpdate and Recreate, and choose the right strategy for a given scenario

## Prerequisites

**Required:**

- Minikube `3node` profile running
- kubectl configured for `3node`
- Completion of `01-basic-deployment` (Deployment→ReplicaSet→Pod hierarchy, `pod-template-hash`)
- Completion of `02-rolling-update-recreate` (rollout mechanics, revision history)

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
8. ✅ Explain, at a basic level, how a Service's selector actually drives traffic routing in both strategies — including why a Service's selector can be edited freely, unlike a Deployment's
9. ✅ Read and write minimal Service YAML confidently — `selector`, `port`, `targetPort`, `type` — before `03-services` covers it in full depth

## Directory Structure

```
02-deployments/03-deployment-strategies/
├── README.md
├── src/
│   ├── blue-green/
│   │   ├── 01-blue-deployment.yaml    # Version 1 (Blue) — http-echo, "BLUE VERSION"
│   │   ├── 02-green-deployment.yaml   # Version 2 (Green) — http-echo, "GREEN VERSION"
│   │   └── 03-service.yaml            # Service for traffic switching
│   ├── canary/
│   │   ├── 01-stable-deployment.yaml  # Stable version — http-echo, "STABLE VERSION"
│   │   ├── 02-canary-deployment.yaml  # Canary version — http-echo, "CANARY VERSION"
│   │   └── 03-service.yaml            # Service routing to both versions
│   └── break-fix/
│       └── 01-canary-bad-image.yaml   # Embedded inline in README — not generated on disk
├── 03-deployment-strategies-anki.csv
└── 03-deployment-strategies-quiz.md
```

---

## Recall Check — 02-rolling-update-recreate

Answer from memory before continuing — no peeking at the previous demo.

1. When a rolling update happens, what actually happens to the existing ReplicaSet?
2. Does `kubectl rollout undo` restore the old revision number, or create a new one?
3. Is `kubectl rollout restart` an instant, all-pods-at-once operation?

<details>
<summary>Answers</summary>

1. A new ReplicaSet is created with a new `pod-template-hash`; the old one scales down to 0 rather than being mutated.
2. It creates a new revision copying the old configuration forward — the old revision number disappears from history.
3. No. `kubectl rollout restart` is not an instant, all-pods-at-once operation. It triggers a normal Deployment rollout and follows the Deployment's configured spec.strategy. With `RollingUpdate`, Pods are replaced gradually according to **maxSurge** and **maxUnavailable**; with `Recreate`, all existing Pods are terminated before new ones are created.

</details>

---

## Concepts

### From Deployment-Native Strategies to Service-Routed Patterns

`02-rolling-update-recreate` covered the only two values
`spec.strategy.type` actually accepts — `RollingUpdate` and `Recreate` —
and both share a defining trait: the entire strategy lives inside a
**single** Deployment's `spec.strategy`, reconciled by the Deployment
controller alone. Neither one involves a Service, a second Deployment, or
any concept of routing a *portion* of traffic anywhere. They control how
Pods within one Deployment get replaced — gradually, or all-at-once —
nothing more.

That's precisely the ceiling both strategies hit. Neither can express
"send exactly 10% of traffic to the new version," because neither
operates below the level of the whole Deployment — there's no partial-
traffic concept anywhere in `spec.strategy`. And neither can switch back
in under a second, because both still have to scale Pods up or down
through the ReplicaSet mechanism to reverse course, which takes time
proportional to `maxSurge`/`maxUnavailable` (RollingUpdate) or a full
terminate-then-create cycle (Recreate).

Blue-Green and Canary solve this by changing the unit of control
entirely. Instead of one Deployment governing its own replacement
strategy, each pattern runs **two independent Deployments side by side** —
old version and new version, both fully deployed and both capable of
serving traffic at once — and puts a **Service's selector** in charge of
deciding which one actually receives requests at any given moment. The
switch (or gradual shift) isn't a Deployment reconciling its own Pods
differently; it's a Service's Endpoints list being recomputed against a
changed or broadened selector. That's a fundamentally different
mechanism from anything `spec.strategy` does, which is why it needs a new
Kubernetes object — Service — to work at all.

### Services — Quick Primer

Both patterns in this demo depend entirely on a Kubernetes object you
haven't formally used yet: `Service`. Full depth (ClusterIP vs NodePort
vs LoadBalancer, DNS names, how kube-proxy actually implements routing,
headless Services) is `03-services`' entire subject — this is
deliberately just enough to read, write, and reason about the Service
YAML this demo uses, before that dedicated demo covers the rest.

**What a Service actually is:** not a running process — a stable network
identity (a ClusterIP and/or DNS name) plus a live-updated list of
matching Pod IPs, called **Endpoints**. Kubernetes recomputes that list
continuously, the instant matching Pods change, using the exact same
label-selector mechanism you already know from Deployments.

**Minimal YAML structure:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app: myapp          # label query — same mechanism as a Deployment's selector
  ports:
    - port: 80            # the port the Service itself exposes
      targetPort: 8080     # the port on the Pod traffic actually forwards to
  type: NodePort           # ClusterIP (default, internal-only) | NodePort | LoadBalancer
```

**Field cheat-sheet:**

| Field | Meaning |
|---|---|
| `spec.selector` | Label query determining which Pods back this Service |
| `spec.ports[].port` | Port the Service itself exposes |
| `spec.ports[].targetPort` | Port on the Pod that traffic actually gets forwarded to |
| `spec.type` | `ClusterIP` (internal-only, default) / `NodePort` (also exposes a port on every Node, what this demo uses so `curl` can reach it from outside the cluster) / `LoadBalancer` (provisions a cloud load balancer — not directly applicable on minikube) |

**Commands you'll use throughout this demo:**

| Command | Purpose |
|---|---|
| `kubectl get svc` | List Services, see type/ClusterIP/NodePort |
| `kubectl describe svc NAME` | See the current selector and a summary of Endpoints |
| `kubectl get endpoints NAME` | See exactly which Pod IPs currently back this Service |
| `kubectl edit svc NAME` | Live-edit the selector — this is Blue-Green's entire switch mechanism |

### Just Enough Services — Selector-to-Pod Matching

With the basic shape of a Service established above, here's specifically
how that selector mechanism drives the two patterns in this demo:

- **Blue-Green** works because changing the Service's
`spec.selector.version` field instantly recomputes which Pods count as
matching — from Blue's labels to Green's — and the Endpoints list flips
accordingly, with **no change to either Deployment at all**.
- **Canary** works because the Service's selector deliberately *omits* the
`track` label, so it matches Pods from both the stable and canary
Deployments simultaneously — each request gets load-balanced across
every currently-matching Pod.

One more thing worth knowing now rather than being surprised by it later:
a Pod only becomes an Endpoint once it's actually `Ready` — a Pod stuck in `ImagePullBackOff` (this demo's own Break-Fix scenario) never gets added
to the Endpoints list at all, regardless of what its labels say.

**Worth stating explicitly, given how much emphasis prior demos put on
the opposite case:** a **Service's** `spec.selector` is *not* immutable —
you can `kubectl edit` it as many times as you like, and every edit
instantly and completely recomputes the Endpoints list. This is the exact
opposite of a **Deployment's** `spec.selector`, which `01-basic-deployment`
established is locked forever after creation. That asymmetry is not an
inconsistency in Kubernetes — it's *the* reason Blue-Green works at all:
if Service selectors were as locked-down as Deployment selectors, an
instant traffic switch by editing a selector simply wouldn't be possible,
and you'd need to delete and recreate the Service every time, which is
neither instant nor "zero risk."


### A note on the images used in this lab

Every YAML in this demo runs `hashicorp/http-echo` instead of plain `nginx`. It's a tiny, purpose-built image that does one thing — respond to every request with a fixed text string you set via `-text`. That matters here specifically because a
plain `nginx` image serves the same generic welcome page regardless of
version, which makes `curl` useless for actually *seeing* which version
answered. With `http-echo`, a `curl` during Blue-Green literally prints
`BLUE VERSION` or `GREEN VERSION`, and during Canary it prints `STABLE`
or `CANARY` — the visible proof this demo is built around. (Object names
like `nginx-blue` are kept as-is despite this switch, purely so command
examples stay short — what's actually running is `http-echo`, not nginx.)

### Comparison of Strategies

| Strategy | Downtime | Rollback Speed | Resource Usage | Risk | Use Case |
|----------|----------|----------------|----------------|------|----------|
| **Recreate** | Yes (all pods killed) | Slow (recreate all) | Low | High | Development/testing |
| **Rolling Update** | No | Medium (gradual rollback) | Medium | Medium | Most applications |
| **Blue-Green** | No | Instant (switch label) | High (2x resources) | Low | Critical apps, instant rollback needed |
| **Canary** | No | Fast (adjust replicas) | Medium-High | Very Low | Testing with real users |

Recreate and Rolling Update were covered in full in `01-basic-deployment` and `02-rolling-update-recreate` — this demo covers the two rows that
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
Service → [Blue: "BLUE VERSION"] × 3
          [Green: none]

Phase 2: Deploy Green
Service → [Blue: "BLUE VERSION"] × 3     ← Still receiving traffic
          [Green: "GREEN VERSION"] × 3   ← Testing, no traffic

Phase 3: Switch Traffic (Update Service selector)
          [Blue: "BLUE VERSION"] × 3     ← No traffic
Service → [Green: "GREEN VERSION"] × 3   ← All traffic

Phase 4: Rollback if needed (Update Service selector back)
Service → [Blue: "BLUE VERSION"] × 3     ← All traffic back
          [Green: "GREEN VERSION"] × 3   ← No traffic
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
Service → [Stable: "STABLE VERSION"] × 4   ← 100% traffic

Phase 2: Deploy Canary (~80% Stable, ~20% Canary)
Service → [Stable: "STABLE VERSION"] × 4   ← ~80% traffic
          [Canary: "CANARY VERSION"] × 1   ← ~20% traffic

Phase 3: Increase Canary (50% Stable, 50% Canary)
Service → [Stable: "STABLE VERSION"] × 2   ← 50% traffic
          [Canary: "CANARY VERSION"] × 2   ← 50% traffic

Phase 4: Full Canary (100% New Version)
Service → [Canary: "CANARY VERSION"] × 4   ← 100% traffic
          (Stable deployment removed)
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

## Lab Step-by-Step Guide

## Part 1: Blue-Green Deployment

### Step 1: Understand the Blue-Green YAML Files

This step introduces the three files that make Blue-Green work, before
applying anything: two nearly-identical Deployments — differing only in
their `version` label, and the text each one echoes back — and a Service
whose selector is the single switch between them. `nginx-blue` and
`nginx-green` are otherwise structurally identical Deployments; the only
things that actually distinguish "Blue" from "Green" anywhere in
Kubernetes are that `version` label and the `-text` argument.

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
      - name: app
        image: hashicorp/http-echo:latest
        args:
          - "-text=BLUE VERSION - v1.0"
          - "-listen=:5678"
        ports:
        - containerPort: 5678
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
      - name: app
        image: hashicorp/http-echo:latest
        args:
          - "-text=GREEN VERSION - v2.0"
          - "-listen=:5678"
        ports:
        - containerPort: 5678
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
    targetPort: 5678
  type: NodePort         # Or LoadBalancer for cloud
```

**Key Configuration Points:**

- Both deployments use **same `app: nginx` label**
- Each has **unique `version` label** (blue or green)
- Service selector uses **both labels** to control traffic
- Switching traffic = changing Service's `version` selector
- **No changes to deployments needed** for traffic switch, and the Service
  selector itself is freely editable — see **Just Enough Services** above
  for exactly why this works
- `targetPort: 5678` matches `http-echo`'s default listen port (set
  explicitly via `-listen=:5678` above for clarity) — this is the one
  field that has to agree exactly between the Deployment's
  `containerPort` and the Service's `targetPort`, or requests will hang

---

### Step 2: Deploy Blue Version (Initial Production)

Deploys the first version and its Service in one go — Blue immediately
starts receiving 100% of traffic, since it's the only thing the Service's
selector matches yet.

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

Confirms Blue is fully up, and — more importantly — inspects exactly
which labels the Service is currently matching, since that's the entire
mechanism this whole demo runs on.

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

**Real captured output:**

```
NAME                              READY   STATUS    RESTARTS   AGE   LABELS
pod/nginx-blue-5856f8c4b5-7lbtj   1/1     Running   0          65s   app=nginx,pod-template-hash=5856f8c4b5,version=blue
pod/nginx-blue-5856f8c4b5-sd6rw   1/1     Running   0          65s   app=nginx,pod-template-hash=5856f8c4b5,version=blue
pod/nginx-blue-5856f8c4b5-slvkj   1/1     Running   0          65s   app=nginx,pod-template-hash=5856f8c4b5,version=blue

NAME                    TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
service/nginx-service   NodePort   10.111.109.16   <none>        80:31722/TCP   58s
```

```
Name:              nginx-service
Selector:          app=nginx,version=blue
Type:               NodePort
Port:               <unset>  80/TCP
TargetPort:          5678/TCP
NodePort:            <unset>  31722/TCP
Endpoints:           10.244.2.90:5678,10.244.2.89:5678,10.244.1.40:5678
```

**Observe:** the Service's `Endpoints` field already lists three real Pod
IPs, each on port `5678` — not `80`. This is the `targetPort` translation
in action: clients hit the Service on port `80` (or the NodePort,
`31722`), and Kubernetes forwards to whichever port the Pods actually
listen on. Also notice the Deployment itself never appears anywhere in
this output — everything here is Service and Pod state, exactly as
**Just Enough Services** predicted.

---

### Step 4: Test Blue Version

Confirms end-to-end connectivity through the actual NodePort, and is the
first place you'll see the visible text difference this demo is built
around.

```bash
# Get the NodePort
kubectl get svc nginx-service

# If using minikube
minikube service nginx-service --url

# Test with curl (replace URL with your cluster's URL)
curl http://<node-ip>:<node-port>
```

**Expected output:**

```
BLUE VERSION - v1.0
```

Compare this against what a plain `nginx` image would have given you
here: the generic "Welcome to nginx!" page, identical regardless of
version — no way to tell from `curl` alone which Deployment actually
answered. `http-echo`'s whole purpose is closing that gap.

---

### Step 5: Deploy Green Version (New Version)

While Blue is handling all traffic, deploy Green — it starts running
immediately, but per **Just Enough Services**, it won't receive a single
real request until the Service's selector is changed in Step 7.

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

**Real captured output:**

```
NAME                              READY   STATUS    LABELS
pod/nginx-blue-5856f8c4b5-7lbtj   1/1     Running   app=nginx,pod-template-hash=5856f8c4b5,version=blue
pod/nginx-blue-5856f8c4b5-sd6rw   1/1     Running   app=nginx,pod-template-hash=5856f8c4b5,version=blue
pod/nginx-blue-5856f8c4b5-slvkj   1/1     Running   app=nginx,pod-template-hash=5856f8c4b5,version=blue
pod/nginx-green-6bcdfc6c8-4bsfc   1/1     Running   app=nginx,pod-template-hash=6bcdfc6c8,version=green
pod/nginx-green-6bcdfc6c8-jmpcf   1/1     Running   app=nginx,pod-template-hash=6bcdfc6c8,version=green
pod/nginx-green-6bcdfc6c8-tf8nb   1/1     Running   app=nginx,pod-template-hash=6bcdfc6c8,version=green
```

**Important — verify the Service didn't move:**

```bash
kubectl describe svc nginx-service
```

**Real captured output (unchanged from Step 3):**

```
Selector:    app=nginx,version=blue
Endpoints:   10.244.2.90:5678,10.244.2.89:5678,10.244.1.40:5678
```

**Observe:** all six Pods now exist — three Blue, three Green, both
`Running` and both `Ready` — but the Service's `Endpoints` list still
contains exactly the same three Blue IPs as Step 3, nothing from Green.
Green pods matching `app: nginx` isn't enough; they also need
`version: blue` to be picked up by *this* Service's current selector, and
they don't have it. This is the calm-before-the-switch moment the whole
pattern depends on.

**Also worth noticing — the Deployment's own default strategy:**

```bash
kubectl describe deployment nginx-blue | grep RollingUpdateStrategy
```

**Real captured output:**

```
RollingUpdateStrategy:  25% max unavailable, 25% max surge
```

Neither Blue-Green YAML in this demo sets `spec.strategy` at all — this
is `RollingUpdate`'s built-in default (`25%`/`25%`), not the explicit
`0`/`1` values `02-rolling-update-recreate` used throughout. Worth
noticing since it means updates to `nginx-blue` or `nginx-green`
themselves (not the Blue-Green *pattern*, just an ordinary image bump on
one of them) would briefly allow a pod or two unavailable — this demo
never triggers that path, but it's there if you ever update Blue/Green
directly instead of switching between them.

---

### Step 6: Test Green Version Directly (Optional)

Before switching production traffic, confirm Green actually works,
completely bypassing the Service.

```bash
# Port-forward to a Green pod for testing
kubectl port-forward deployment/nginx-green 8080:5678

# In another terminal, test
curl http://localhost:8080
```

**Expected output:**

```
GREEN VERSION - v2.0
```

This verifies Green works correctly before switching production traffic
— and note port-forward talks directly to a Green Pod, completely
bypassing the Service and its selector, which is exactly why this step
can safely happen before Step 7's switch.

Press `Ctrl+C` to stop port-forward.

---

### Step 7: Switch Traffic from Blue to Green

**The critical moment — switching all traffic instantly:**

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

This works with a plain `kubectl edit` — no error, no immutability
rejection — precisely because a Service's `spec.selector` is mutable,
unlike the Deployment `spec.selector` field you've seen rejected for the
same kind of edit in earlier demos.

---

### Step 8: Verify Traffic Switch

Confirms the switch actually took effect at both the selector level and
the real-traffic level.

```bash
# Check Service selector
kubectl describe svc nginx-service | grep Selector

# Test the service
curl http://<node-ip>:<node-port>
```

**Real captured output:**

```
Selector:   app=nginx,version=green
```

**Expected `curl` output:**

```
GREEN VERSION - v2.0
```

**What happened:**

- Service selector changed from `version: blue` to `version: green`
- Kubernetes recomputed the Endpoints list immediately — all traffic instantly routed to Green pods
- Blue pods still running but receiving zero traffic
- **Zero downtime — instant switch, and now actually visible in the response text**

Check endpoints:

```bash
kubectl get endpoints nginx-service
```

**Real captured output (three fresh IPs — all Green now, all Blue IPs gone):**

```
NAME            ENDPOINTS                                      AGE
nginx-service   10.244.1.41:5678,10.244.2.91:5678,10.244.2.92:5678   12m
```

**Observe:** compare this IP list directly against Step 3's Endpoints —
every single IP is different, and the Service object's own `AGE` (`12m`)
hasn't reset. This is the concrete evidence that switching traffic never
recreated the Service; it only ever recomputed which three IPs currently
qualify.

---

### Step 9: Monitor Green Version

Keep Green and Blue running for a while to monitor, using labels to
target logs at exactly one version at a time.

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

If Green has issues, instant rollback — same mechanism as Step 7, just
pointed the other way.

```bash
# Switch back to Blue
kubectl edit svc nginx-service
```

Change `selector.version: green` back to `selector.version: blue`. Save
and exit.

**Rollback complete in ~1 second!** All traffic back to Blue — confirm
with `curl` and you should see `BLUE VERSION - v1.0` again immediately.

---

### Step 11: Cleanup Old Version

Once confident in Green, remove Blue entirely — a genuine deletion, not
just a traffic reroute.

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

Same `http-echo` approach as Blue-Green, but the label that separates the
two versions is called `track` instead of `version`, and — critically —
the Service's selector below deliberately **omits** `track` entirely, so
it matches both Deployments' Pods at once. That single omission is the
whole mechanism that makes Canary traffic-splitting possible, versus
Blue-Green's all-or-nothing switch.

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
      - name: app
        image: hashicorp/http-echo:latest
        args:
          - "-text=STABLE VERSION - v1.0"
          - "-listen=:5678"
        ports:
        - containerPort: 5678
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
  replicas: 1           # Canary starts with fewer pods (10-20% traffic)
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
      - name: app
        image: hashicorp/http-echo:latest
        args:
          - "-text=CANARY VERSION - v2.0-beta"
          - "-listen=:5678"
        ports:
        - containerPort: 5678
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
    targetPort: 5678
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

Deploys the baseline version and its Service — behaves exactly like 100%
of a normal, single-version app until Step 5 introduces a second track.

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

Confirms the baseline is healthy, and shows the selector's deliberately
narrower shape compared to Blue-Green's — no `track` key at all.

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
Endpoints: <4 pod IPs>  ← Only stable pods currently, since canary doesn't exist yet
```

---

### Step 4: Test Stable Version

```bash
# Get service URL
kubectl get svc nginx-service

# Test (replace with your URL)
curl http://<node-ip>:<node-port>
```

**Expected output:**

```
STABLE VERSION - v1.0
```

Every request returns identical text right now, since only Stable exists.

---

### Step 5: Deploy Canary Version (10-20% Traffic)

This is the moment traffic-splitting actually begins — unlike Blue-Green,
nothing needs editing on the Service at all; adding a second Deployment
that matches the existing broad selector is the entire trigger.

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

Confirm the Service picked up the new Pod without any edit at all:

```bash
kubectl get endpoints nginx-service
```

**Expected output:** 5 IPs total — 4 belonging to `nginx-stable`, 1 to
`nginx-canary` — appearing automatically the moment the canary Pod became
`Ready`, with zero changes made to the Service itself.

---

### Step 6: Verify Traffic Split

Confirms the split is genuinely approximate — you should see mostly
`STABLE VERSION`, occasionally `CANARY VERSION`, in no fixed pattern.

```bash
# Run 10 requests
for i in {1..10}; do
  curl -s http://<node-ip>:<node-port>
  echo
done
```

**Expected output (exact order will vary — that's the point):**

```
STABLE VERSION - v1.0
STABLE VERSION - v1.0
CANARY VERSION - v2.0-beta
STABLE VERSION - v1.0
STABLE VERSION - v1.0
STABLE VERSION - v1.0
CANARY VERSION - v2.0-beta
STABLE VERSION - v1.0
STABLE VERSION - v1.0
STABLE VERSION - v1.0
```

Roughly 1-in-5 responses should read `CANARY`, matching the 4:1 pod
ratio — but not on a fixed schedule, since it's round-robin over
whatever the Endpoints list currently contains, not a guaranteed
percentage. (The original version of this demo used plain `nginx` here
and piped through `grep -i nginx` — which would have matched *every*
response identically, stable or canary, and never actually proven the
split was happening. The `http-echo` text is what makes this loop
meaningful.)

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

If canary looks good, increase its share purely by scaling replicas —
still no Service edit required.

```bash
# Scale canary to match stable (50/50 split)
kubectl scale deployment nginx-canary --replicas=4
```

**New traffic split:** 4 stable + 4 canary = 8 total → 50% each

Verify:

```bash
kubectl get pods -l app=nginx --show-labels
```

Should see 4 stable + 4 canary pods. Re-run the Step 6 loop and you
should now see roughly half `STABLE`, half `CANARY`.

---

### Step 9: Full Canary Rollout (100%)

If canary performs well at 50%, go to 100% — again purely via scaling.

```bash
# Scale down stable to 0
kubectl scale deployment nginx-stable --replicas=0

# Scale up canary to desired count
kubectl scale deployment nginx-canary --replicas=4
```

**New traffic split:** 0 stable + 4 canary = 4 total → 100% canary

All traffic now goes to new version! (Canary was already at 4 replicas
from Step 8 — this step is purely about removing stable's share, not
adding more canary capacity.) Confirm with `curl` — every response should
now read `CANARY VERSION - v2.0-beta`, with zero `STABLE` responses left.

---

### Step 10: "Promoting" Canary to Stable — What This Actually Requires

Once confident, remove the old stable deployment:

```bash
kubectl delete deployment nginx-stable
```

At this point it's tempting to just relabel `nginx-canary` as the new
"stable" — but it's worth being precise about what that would and wouldn't
actually accomplish, given what you already know from `01-basic-deployment`:

```bash
kubectl label deployment nginx-canary track=stable --overwrite
```

This only changes the **Deployment object's own** `metadata.labels` — a
bookkeeping label that would let you find it later with `kubectl get deploy -l track=stable`. It does **not** touch `spec.selector` or `spec.template.metadata.labels`, both of which are immutable once set
(exactly the rule from `01-basic-deployment`) — so every Pod this
Deployment actually manages keeps its real `track=canary` label,
completely unaffected by the relabel. Nothing about traffic routing
changes either, since this demo's Service selector never referenced `track` in the first place.

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
- ✅ Switched traffic instantly by changing Service selector labels — and know why that's possible: Service selectors are mutable, unlike Deployment selectors
- ✅ Performed zero-risk rollback by switching Service selector back
- ✅ Deployed Canary releases alongside stable versions
- ✅ Controlled traffic distribution using replica counts
- ✅ Gradually increased Canary traffic from 20% to 50% to 100%
- ✅ Understood trade-offs between Blue-Green and Canary strategies
- ✅ Practiced both rollback scenarios for each strategy
- ✅ Understood exactly what a Service selector change does and doesn't affect — including why a Deployment-level relabel doesn't actually change Pod identity
- ✅ Read and wrote minimal Service YAML (`selector`, `port`, `targetPort`, `type`) confidently, and used `curl` output that actually proves which version answered, rather than a generic page that looks the same either way

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
      - name: app
        image: hashicorp/http-echo:99.99.99-does-not-exist   # doesn't exist
        args:
          - "-text=CANARY VERSION - v2.0-beta"
        ports:
        - containerPort: 5678
```

```bash
kubectl apply -f 01-canary-bad-image.yaml
kubectl get pods -l app=nginx --show-labels
kubectl get endpoints nginx-service
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `hashicorp/http-echo:99.99.99-does-not-exist` doesn't exist, so
the canary pod sits in `ImagePullBackOff` and never becomes `Ready` — the
same failure mode covered fully in `01-core-concepts/03-pod-container-basics`.

**Fix:** Correct the tag to a real one (`hashicorp/http-echo:latest`) and
reapply.

**Cascade — this is the interesting part, and it's actually good news:** `kubectl get endpoints nginx-service` shows **only the 4 stable pod IPs**,
never the broken canary pod. Per **Just Enough Services** above, a Pod
only becomes an Endpoint once it's `Ready` — so this "canary" receives **zero real user traffic** despite existing and despite the Service's
selector technically matching its labels. The failure is completely
invisible to end users — run the Step 6-style `curl` loop from Part 2 and
every single response will read `STABLE VERSION`, never `CANARY`, with no
error anywhere in that output. The only way to know something's wrong is
to check the canary pod's own status directly
(`kubectl get pods -l track=canary`), not to infer it from traffic/error
patterns. This is exactly the kind of gap real canary monitoring exists
to catch.

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

Introduce a deliberate typo — change `version: blue` to `versoin: blue` (note the misspelled key, not value). Save and exit, then:

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

**Cascade:** `kubectl get endpoints nginx-service` shows an **empty** Endpoints list — not an error, just nothing. Every request to the Service
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

**Q: Why does editing a Service's selector work instantly with no error, when the same kind of edit on a Deployment's selector is rejected outright?**
A: Because they're governed by completely different mutability rules. A Deployment's `spec.selector` is locked at creation specifically because it's tied to ownership of ReplicaSets and Pods. A Service's `spec.selector` has no such ownership relationship to protect — it's just a live filter over Endpoints — so Kubernetes lets you change it freely, and that's exactly the mechanism Blue-Green depends on.

**Q: In a Service's `ports` block, what's the difference between `port` and `targetPort`, and why does it matter for debugging?**
A: `port` is what the Service itself exposes to clients; `targetPort` is the port traffic actually gets forwarded to on the Pod. They don't have to match — this demo sets `port: 80` but `targetPort: 5678`, since that's where `http-echo` actually listens. Mismatching `targetPort` against the container's real listening port is a classic silent-failure cause: no error anywhere, requests just hang or connection-refuse.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Application Deployment | CKAD | 20% | Blue-Green and Canary implementation patterns |
| Services & Networking | CKA | 20% | Selector-driven traffic routing, `port`/`targetPort` (just enough for this demo — full depth in `03-services`) |
| Application Deployment | CKAD | — | Trade-off reasoning between deployment strategies |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Assuming Canary traffic split is exact | It's approximate, driven by pod-count ratio and round-robin — 4:1 doesn't guarantee exactly 20%/80% on any given sample of requests |
| A selector key typo (`versoin` vs `version`) | Syntactically valid YAML, but silently matches zero pods — no error message points at the actual cause |
| Assuming a relabeled Deployment changes its Pods' labels | `metadata.labels` on the Deployment and `spec.template.metadata.labels` on its Pods are two separate label sets — relabeling one never touches the other |
| Forgetting Endpoints require Ready, not just matching labels | A broken pod can match a Service's selector perfectly and still receive zero traffic if it's never Ready |
| Mismatching `targetPort` against the container's real listen port | No error at apply time — requests just silently fail once traffic actually flows |
| Underestimating Blue-Green's resource cost | "No downtime" reads as free — it isn't; budget for 2x capacity for the overlap window |
| Assuming a Service's selector is locked like a Deployment's  | It isn't — Service selectors are freely editable at any time, which is the entire mechanism Blue-Green depends on |

### Exam Task — Write it from scratch

Create a Blue-Green setup: two Deployments (`app-blue`, `app-green`), each running `hashicorp/http-echo` with a distinct `-text` value and a distinct `version` label, and a Service initially selecting `version: blue`. Switch the Service to `green`, then verify via Endpoints — and via `curl` output — that only Green pods are receiving traffic.

Official docs: [Services](https://kubernetes.io/docs/concepts/services-networking/service/), [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create deployment app-blue --image=hashicorp/http-echo --replicas=2 --dry-run=client -o yaml > blue.yaml
# edit blue.yaml: add version: blue to both metadata.labels and spec.template.metadata.labels,
# and to spec.selector.matchLabels; add args: ["-text=BLUE", "-listen=:5678"] and containerPort: 5678
kubectl apply -f blue.yaml

# repeat for app-green with version: green, args ["-text=GREEN", "-listen=:5678"]

kubectl expose deployment app-blue --name=app-svc --port=80 --target-port=5678 --selector="app=app-blue,version=blue"
kubectl edit svc app-svc   # change selector's version to green
kubectl get endpoints app-svc
curl <node-ip>:<nodeport>   # should now read GREEN
```

**Key fields to recall:** the Service's `spec.selector` must include the
label that actually distinguishes the two versions (`version`), not just
the shared `app` label — otherwise it matches both simultaneously,
behaving like Canary instead of Blue-Green. And `targetPort` must match
wherever the container actually listens, or the switch will "succeed"
with an empty response.

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Service's Endpoints list is recomputed live from its selector | This is the entire mechanism behind Blue-Green's instant switch — no Deployment ever changes, only what the Service currently matches |
| A Service's `spec.selector` is mutable; a Deployment's is not | This asymmetry is the actual reason Blue-Green's instant switch is possible at all — a Service has no ownership relationship to protect the way a Deployment's ReplicaSet chain does |
| `port` vs `targetPort` are independent | `port` is client-facing, `targetPort` is where the Pod actually listens — they don't have to match, and mismatching them fails silently |
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
| `curl <svc-url>` | With `http-echo`, directly shows which version answered — no guessing from a generic page |

### Generating YAML skeletons with --dry-run

This demo's own Lab steps apply pre-written YAML directly rather than
generating it — the teaching focus here is the Service-selector mechanism,
not object creation. But the Exam Task above does use the technique, to
scaffold `app-blue`/`app-green` from scratch:

```bash
kubectl create deployment app-blue --image=hashicorp/http-echo --replicas=2 --dry-run=client -o yaml > blue.yaml
```

Full treatment of this technique — what it does and doesn't support, and
the exam workflow around it — is `01-basic-deployment`'s Quick Commands
Reference; nothing about it changes for this demo.

### Imperative Quick-Create Commands

Neither Blue-Green nor Canary was built imperatively in this demo — both
used full YAML so the `version`/`track` labels, `args`, and `targetPort`
could be set precisely on every field that needs them (Deployment
selector, template labels, container args, and Service selector/ports all
have to align, which is fiddlier to get right with flags alone). For
imperative creation of the underlying object types:

| Object | Imperative command | Notes |
|---|---|---|
| Deployment | `kubectl create deployment NAME --image=IMG --replicas=N` | Full coverage in `01-basic-deployment`; doesn't let you set `args` or container port directly — needs a follow-up edit for `http-echo`'s `-text` flag |
| Service (ClusterIP) | `kubectl expose deployment NAME --port=P --target-port=P` | Full coverage in `01-clusterip-nodeport` — note `kubectl expose` derives its selector from the Deployment automatically, so it can't easily express Blue-Green/Canary's deliberately partial selectors (`app` only, omitting `version`/`track`) — YAML is the more reliable choice for this demo's specific pattern |
| Relabel a Deployment object | `kubectl label deployment NAME key=value --overwrite` | Only changes the Deployment's own `metadata.labels` — never its Pods, see Step 10 |

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

**`curl` hangs or connection-refuses, even though pods are Running and Ready?**

```bash
# Check that targetPort actually matches where the container listens
kubectl get svc nginx-service -o jsonpath='{.spec.ports[0].targetPort}'
kubectl describe pod -l app=nginx | grep -A2 "Port:"
# http-echo listens on 5678 by default — a Service targetPort of 80
# here would silently fail to reach anything
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
analysis, and automatic rollback without anyone watching a dashboard: **`gitops-labs/argo-rollouts-basics-to-prod`** (a separate, external repo
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
"Is a Service's spec.selector immutable, like a Deployment's?","No — a Service's selector is freely mutable at any time; this asymmetry is exactly what makes Blue-Green's instant switch possible","demo03-deployments,services,immutability,cka-services-networking"
"In a Service's ports block, what's the difference between port and targetPort?","port is what the Service exposes to clients; targetPort is the port on the Pod that traffic is actually forwarded to — they don't have to match","demo03-deployments,services,ports,cka-services-networking"
"What happens if a Service's targetPort doesn't match the port the container actually listens on?","Requests silently fail (hang or connection-refuse) — there's no apply-time error, since the mismatch is only a runtime problem","demo03-deployments,services,troubleshooting,cka-troubleshooting"
"Why is Canary traffic split only approximate?","It's driven by pod-count ratio and round-robin load balancing, not a guaranteed percentage","demo03-deployments,canary,ckad-application-deployment"
"Does a pod that matches a Service's selector but isn't Ready receive traffic?","No — only Ready pods become Endpoints, regardless of label match","demo03-deployments,services,endpoints,cka-services-networking"
"Does relabeling a Deployment's metadata.labels change its Pods' labels?","No — metadata.labels on the Deployment and spec.template.metadata.labels on its Pods are separate, and the Pod-affecting one is immutable","demo03-deployments,immutability,ckad-application-deployment"
"What happens if a Service selector has a typo'd key (e.g. versoin instead of version)?","It's valid YAML, so it's silently accepted — but it matches zero pods, with no error pointing at the cause","demo03-deployments,services,troubleshooting,cka-troubleshooting"
"What's the real resource cost of Blue-Green's instant rollback capability?","Roughly 2x compute — both full environments run simultaneously for the overlap window","demo03-deployments,blue-green,cka-workloads-scheduling"
"What does native Kubernetes Service-based canary lack compared to a tool like Argo Rollouts?","Precise traffic percentages, automated metric analysis, and automatic rollback — everything here was done manually","demo03-deployments,argo-rollouts,ckad-application-deployment"
"Why does Canary's Service selector omit the track label entirely?","So it matches Pods from both the stable and canary Deployments simultaneously, instead of picking just one — that omission is the entire Canary mechanism","demo03-deployments,canary,services,cka-services-networking"
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

**Q8. In a Service's `ports` block, what happens if `targetPort` doesn't match the port the container actually listens on?**

- A) Kubernetes rejects the Service as invalid
- B) Requests silently fail — no apply-time error, since it's only a runtime mismatch
- C) Kubernetes automatically detects and corrects the correct port
- D) The Service falls back to using `port` as the target too

<details>
<summary>Answer</summary>

**B** — There's nothing invalid about the YAML itself — a `targetPort` is just a number Kubernetes doesn't verify against what's actually listening inside the container, so a mismatch only shows up as a runtime failure (a hang or connection-refuse), not a rejected `apply`.
Trap: C imagines automatic detection that doesn't exist — Kubernetes has no visibility into what a container is actually listening on unless a probe explicitly checks it.

</details>

---

**Q9. Why does Canary's Service selector deliberately omit the `track` label, when Blue-Green's selector includes `version`?**

- A) It's a mistake in the YAML that happens to work anyway
- B) Omitting `track` makes the selector match both stable and canary Pods at once, which is the entire mechanism that enables traffic splitting
- C) `track` isn't a valid label key
- D) The Service type determines whether `track` is needed

<details>
<summary>Answer</summary>

**B** — Blue-Green needs the selector to match exactly one version at a time, so it includes the differentiating label; Canary needs the selector to match both at once, so it deliberately leaves that label out. Same mechanism, opposite selector shape, on purpose.
Trap: A dismisses a deliberate design choice as an accident — the omission is exactly what makes Canary's traffic-splitting possible.

</details>

---

**Q10. Why does editing a Service's selector work instantly with no error, when the same kind of edit on a Deployment's selector is rejected outright?**

- A) Services don't validate YAML the way Deployments do
- B) A Service's selector has no ownership relationship to protect, unlike a Deployment's, which is tied to its ReplicaSet chain
- C) It can't — both are equally immutable
- D) Only NodePort-type Services allow selector edits

<details>
<summary>Answer</summary>

**B** — Deployment selector immutability exists specifically to protect the Deployment→ReplicaSet→Pod ownership chain; a Service has no such structure to protect, so Kubernetes places no such restriction on it.
Trap: C assumes symmetry between two mechanisms that are actually deliberately different — this demo's entire Blue-Green pattern depends on that difference existing.

</details>

Score guide:
| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next Demo |
| 7-8/10 | Review the wrong answer(s), then proceed |
| 6/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
````