# Demo: 03-services/02-service-internals — Service Internals

## Lab Overview

When you create a Service in Kubernetes, several components work together
behind the scenes to route traffic from a stable virtual IP to the
correct pod. This demo examines those internal mechanics — exactly what
`01-clusterip-nodeport` forward-referenced rather than explained in depth.

```
You create a Service
       ↓
API server notifies kube-proxy on every node
       ↓
kube-proxy programs iptables/nftables rules on each node
       ↓
Traffic to ClusterIP is intercepted and redirected to a pod IP
       ↓
EndpointSlice tracks which pod IPs are healthy at any time
```

Understanding these internals helps diagnose service connectivity
issues, understand why traffic rules exist on nodes, and know when
EndpointSlices need attention.

**What this lab covers:**
- EndpointSlices — the modern replacement for Endpoints (deprecated v1.33)
- How kube-proxy programs traffic rules on each node
- kube-proxy modes — iptables, nftables, ipvs
- Verifying iptables rules on a node
- How readiness affects endpoint registration
- Selectorless services — manual endpoint management

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of `01-clusterip-nodeport` (this demo assumes you already understand `port`/`targetPort`, selectors, and NodePort — none of that is re-explained here)
- Understanding of iptables basics (helpful but not required)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Inspect EndpointSlices and understand what they contain
2. ✅ Explain why EndpointSlices replaced the deprecated Endpoints API
3. ✅ Verify kube-proxy is running and identify its proxy mode
4. ✅ Inspect iptables rules created by kube-proxy for a Service
5. ✅ Observe how readiness affects endpoint registration
6. ✅ Create a selectorless service with manual EndpointSlice
7. ✅ Confirm load balancing is genuinely happening — reusing `01-clusterip-nodeport`'s per-pod distinguishing technique, this time to inspect the iptables mechanics actually producing the distribution

## Directory Structure

```
03-services/02-service-internals/
├── README.md
├── src/
│   ├── 01-backend-deployment.yaml    # hashicorp/http-echo — 3 replicas, distinguishable responses
│   ├── 02-backend-svc.yaml           # ClusterIP service
│   ├── 03-selectorless-svc.yaml      # Service without selector + manual EndpointSlice
│   └── break-fix/
│       └── 01-manual-endpointslice-delete.yaml    # Embedded inline in README — not generated on disk
├── 02-service-internals-anki.csv
└── 02-service-internals-quiz.md
```

---

## Recall Check — 01-clusterip-nodeport

Answer from memory before continuing — no peeking at the previous demo.

1. What's the actual difference between `port` and `targetPort`?
2. Does NodePort create a ClusterIP automatically?
3. Does a pod need to be Ready to become a Service Endpoint?

<details>
<summary>Answers</summary>

1. `port` is what clients use to reach the Service; `targetPort` is what the application actually listens on inside the container.
2. Yes — every NodePort Service also gets a ClusterIP automatically.
3. Yes — matching the selector alone isn't sufficient; only Ready pods are added to Endpoints.

</details>

---

## Concepts

### EndpointSlices — The Modern Endpoint Tracking API

An EndpointSlice contains references to a set of network endpoints. The
control plane automatically creates EndpointSlices for any Service that
has a selector specified — this is the actual object behind everything
`01-clusterip-nodeport` observed via the older `kubectl get endpoints`
view.

EndpointSlices replaced the older Endpoints API (deprecated in v1.33). The
key improvements:

```
Endpoints API (deprecated):
  → single object per Service holding ALL pod IPs
  → with 1000 pods: 1 object with 1000 entries
  → any pod change → entire object updated → sent to ALL nodes
  → does not support dual-stack (IPv4 + IPv6)

EndpointSlice API (current):
  → multiple slices per Service, up to 100 endpoints per slice
  → with 1000 pods: 10 slices of 100 entries each
  → pod change → only 1 slice updated → sent to ALL nodes
  → supports dual-stack — separate slices per IP family
  → tracks readiness, topology, node name per endpoint
```
> As of Kubernetes 1.33, `kubectl get endpoints` shows a deprecation
> warning. Migrate scripts and tooling to `kubectl get endpointslices`.

---

### kube-proxy — The Traffic Routing Engine

Every node in a Kubernetes cluster runs a kube-proxy (unless you've
deployed your own alternative in its place). kube-proxy is responsible
for implementing the virtual IP mechanism for Services of any type other
than `ExternalName`.

kube-proxy watches for Service and EndpointSlice changes and programs
traffic rules on each node so that packets sent to a ClusterIP are
redirected to a real pod IP.

**kube-proxy modes (Linux):**
```
iptables  → default mode on most clusters
            creates iptables NAT rules for each Service endpoint
            uses random selection for load balancing
            scales to tens of thousands of rules in large clusters

nftables  → modern replacement for iptables (stable since v1.33)
            better performance than iptables
            currently recommended for new clusters on kernels 5.13+
            still not the default — iptables remains the default mode

ipvs      → Linux kernel IP Virtual Server
            hash table lookup — O(1) vs iptables O(n)
            multiple load balancing algorithms
            DEPRECATED as of Kubernetes v1.35 — do not choose this
            mode for a new cluster; nftables is the direct replacement
            for ipvs's original "scale better than iptables" use case
```

---

### How Traffic Reaches a Pod

```
1. Pod A sends request to backend-svc:9090 (ClusterIP)
2. DNS lookup: CoreDNS resolves to 10.96.xxx.xxx
3. Pod A sends packet to 10.96.xxx.xxx:9090
4. Packet hits node's network stack
5. iptables/nftables rule intercepts (DNAT)
6. Destination IP rewritten to a random pod IP (e.g. 10.244.1.5:5678)
7. Packet delivered to pod

kube-proxy does NOT sit in the data path for every packet.
It only programs the rules. The kernel handles all packet forwarding.
```

---

## Lab Step-by-Step Guide

By the end of this walkthrough you'll have redeployed the same
backend + ClusterIP pairing from `01-clusterip-nodeport`, but this time
inspecting every layer underneath it directly: the EndpointSlice object
tracking pod readiness, the actual iptables rules kube-proxy programs on
a node, and — separately — a selectorless Service with a hand-written
EndpointSlice pointing at something outside normal pod selection
entirely. Steps 1–3 rebuild and inspect the standard case; Steps 4–5 go
under the hood into kube-proxy and iptables; Step 6 covers the
selectorless variant.

### Step 1: Deploy Backend and Service

This step rebuilds the same shape of backend + Service from
`01-clusterip-nodeport` — nothing new in the objects themselves — since
every later step in this demo needs a working Service to inspect.

```bash
cd 03-services/02-service-internals/src
```

#### Backend Deployment

Identical pattern to `01-clusterip-nodeport`'s backend, injecting the
pod's own name into the response via the Downward API — see the note
below the manifest for why this technique is reused here rather than
being this demo's own contribution.

**`01-backend-deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: backend
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Hello from backend pod $(MY_POD_NAME)"
          env:
            - name: MY_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```
> `$(MY_POD_NAME)` in `args` injects the pod's own name into the response
> text via the Downward API — the same technique `01-clusterip-nodeport`
> already used for both its backend and frontend, reused here for the
> same reason: it makes load balancing directly observable in the
> response, not just assumed from a successful request.

#### Backend ClusterIP Service

A plain ClusterIP Service selecting these pods — nothing different from
`01-clusterip-nodeport`'s own backend Service. This demo's genuinely new
content starts in Step 2, inspecting what's actually behind this
familiar object.

**`02-backend-svc.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 9090
      targetPort: 5678
```

```bash
kubectl apply -f 01-backend-deployment.yaml
kubectl apply -f 02-backend-svc.yaml
kubectl rollout status deployment/backend-deploy
kubectl get pods -l app=backend -o wide
```

**Confirm load balancing is genuinely happening:**
```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- sh -c 'for i in $(seq 1 6); do curl -s backend-svc:9090; echo; done'
```
**Expected output — different pod names across responses:**
```
Hello from backend pod backend-deploy-xxxxxxxxx-aaaaa
Hello from backend pod backend-deploy-xxxxxxxxx-bbbbb
Hello from backend pod backend-deploy-xxxxxxxxx-aaaaa
Hello from backend pod backend-deploy-xxxxxxxxx-ccccc
Hello from backend pod backend-deploy-xxxxxxxxx-bbbbb
Hello from backend pod backend-deploy-xxxxxxxxx-aaaaa
```
Same confirmation `01-clusterip-nodeport` already gave you — requests
genuinely are being distributed across different pods, not just
succeeding repeatedly against one. Worth re-confirming here since the
rest of this demo is about to explain exactly *how*.

---

### Step 2: Inspect EndpointSlices

This step looks at the actual object behind everything
`01-clusterip-nodeport` observed only indirectly through `kubectl get
endpoints` — the EndpointSlice, including fields (readiness, node
placement, ownership) that older view never exposed.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
```

**Expected output:**
```
NAME                ADDRESSTYPE   PORTS   ENDPOINTS                            AGE
backend-svc-xxxxx   IPv4          5678    10.244.1.x,10.244.1.x,10.244.2.x    10s
```

```bash
kubectl describe endpointslice -l kubernetes.io/service-name=backend-svc
```

**Expected output:**
```
Name:         backend-svc-xxxxx
Namespace:    default
Labels:       endpointslice.kubernetes.io/managed-by=endpointslice-controller.k8s.io
              kubernetes.io/service-name=backend-svc
AddressType:  IPv4
Ports:
  Name   Port  Protocol
  ----   ----  --------
  <unset> 5678  TCP
Endpoints:
  - Addresses:  10.244.1.x
    Conditions:
      Ready:    true          ← pod is healthy → included in load balancing
      Serving:  true
      Terminating: false
    NodeName:   3node-m02
    TargetRef:  Pod/backend-deploy-xxxxxxxxx-aaaaa

  - Addresses:  10.244.2.x
    Conditions:
      Ready:    true
    NodeName:   3node-m03
```
```
Ready: true   → pod is passing readiness probe → receives traffic
Ready: false  → pod is unhealthy → NOT included in load balancing
Terminating   → pod is shutting down → traffic drained gracefully
NodeName      → which node this pod is on — useful for topology routing
```
> Notice the `managed-by=endpointslice-controller.k8s.io` label — a
> separate control loop, distinct from both the Deployment and
> ReplicaSet controllers from `02-deployments`, owns this object.
> This demo's Break-Fix Error-2 puts that ownership to the test directly.

**Compare with deprecated Endpoints (shows warning in v1.33+):**
```bash
kubectl get endpoints backend-svc
```
**Expected output:**
```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME          ENDPOINTS
backend-svc   10.244.1.x:5678,10.244.1.x:5678,10.244.2.x:5678
```
> This is the exact object `01-clusterip-nodeport` used via `kubectl get
> endpoints` throughout — same underlying data, older and less detailed
> API. The Endpoints API isn't removed, just deprecated; migrate tooling
> to EndpointSlices going forward.

---

### Step 3: Observe Readiness Affecting Endpoints

Scale down to 1 replica and observe EndpointSlice update:

```bash
kubectl scale deployment backend-deploy --replicas=1
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
```

**Expected output:**
```
NAME                ADDRESSTYPE   PORTS   ENDPOINTS     AGE
backend-svc-xxxxx   IPv4          5678    10.244.x.x    ...
```

Only 1 endpoint — 2 pods were removed, EndpointSlice updated
automatically, exactly the same self-updating mechanism
`01-clusterip-nodeport` observed via the older Endpoints view.

```bash
kubectl scale deployment backend-deploy --replicas=3
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
# Wait a moment — 3 endpoints restored
```

---

### Step 4: Verify kube-proxy is Running

Before inspecting the actual iptables rules in Step 5, this step
confirms the component that programs them is running on every node and
identifies which mode it's using.

```bash
kubectl get pods -n kube-system | grep kube-proxy
```

**Expected output:**
```
kube-proxy-xxxxx    1/1   Running   0   3node
kube-proxy-yyyyy    1/1   Running   0   3node-m02
kube-proxy-zzzzz    1/1   Running   0   3node-m03
```

One kube-proxy pod per node — including the control plane (worth noting:
scheduling taints per `01-clusterip-nodeport`'s Step 1 affect user
workload pods; kube-proxy is a DaemonSet with its own toleration for the
control-plane taint, which is why it still runs there while your own
workloads don't).

Check kube-proxy mode:
```bash
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep -i "using\|proxier\|mode"
```
**Expected output:**
```
... "Using iptables Proxier"
```

---

### Step 5: Inspect iptables Rules for a Service

SSH into a worker node and inspect the iptables rules kube-proxy created:

```bash
# Get the ClusterIP of backend-svc
CLUSTER_IP=$(kubectl get svc backend-svc -o jsonpath='{.spec.clusterIP}')
echo "ClusterIP: $CLUSTER_IP"

# SSH into node
minikube ssh -p 3node -n 3node-m02

# Show iptables rules for this service
sudo iptables -t nat -L KUBE-SERVICES -n | grep $CLUSTER_IP
```

**Expected output:**
```
KUBE-SVC-xxx  tcp  --  0.0.0.0/0  10.96.xxx.xxx  tcp dpt:9090
                                   ↑ ClusterIP    ↑ service port
```

Show the full chain for this service:
```bash
sudo iptables -t nat -L KUBE-SVC-xxx -n
```
**Expected output:**
```
Chain KUBE-SVC-xxx (1 references)
target      prot opt source  destination
KUBE-SEP-aaa   all  -- ...   ...   /* default/backend-svc */ statistic mode random probability 0.33333
KUBE-SEP-bbb   all  -- ...   ...   /* default/backend-svc */ statistic mode random probability 0.50000
KUBE-SEP-ccc   all  -- ...   ...   /* default/backend-svc */
```
```
3 endpoint chains — one per pod
probability 0.333... → first pod gets 1/3 of traffic
probability 0.500... → second pod gets 1/2 of remaining (= 1/3 total)
last pod → gets all remaining (= 1/3 total)
Result: equal distribution across 3 pods ✅
```

Show the actual DNAT rule for one endpoint:
```bash
sudo iptables -t nat -L KUBE-SEP-aaa -n
```
**Expected output:**
```
Chain KUBE-SEP-aaa
DNAT  tcp  -- 0.0.0.0/0  0.0.0.0/0  to:10.244.1.x:5678
             ↑ destination NAT — rewrites ClusterIP to pod IP
```

```bash
exit
```
> This is the mechanical confirmation of what `01-clusterip-nodeport`
> already told you: no traffic passes through kube-proxy itself. The
> kernel handles all packet rewriting via these rules — kube-proxy only
> manages them.

---

### Step 6: Selectorless Service — Manual EndpointSlice Management

A selectorless Service has no `selector` field — you manually define
which endpoints it routes to, via a hand-written EndpointSlice instead
of one the endpointslice-controller generates for you. Useful for
external databases outside the cluster, Services in another namespace or
cluster, and legacy systems with static IPs. This is the genuinely new
object pairing this demo introduces, in contrast to Step 1's rebuild of
already-familiar objects.

**`03-selectorless-svc.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db-svc
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: external-db-svc-endpoints
  labels:
    kubernetes.io/service-name: external-db-svc   # links this slice to the Service above
addressType: IPv4
protocol: TCP
ports:
  - port: 5432
    protocol: TCP
endpoints:
  - addresses:
      - "10.240.0.50"    # IP of external database server
    conditions:
      ready: true         # must be explicit — nothing computes this for you
```

| Object | Field | Required / Default | Description |
|---|---|---|---|
| Service | `spec.selector` | Omitted entirely | The defining feature of this pattern — no selector means no automatic EndpointSlice generation |
| Service | `spec.ports[]` | Yes | Must match the EndpointSlice's own `ports[]` below for routing to work |
| EndpointSlice | `metadata.labels.kubernetes.io/service-name` | Yes | The only thing linking this EndpointSlice to the Service — get this wrong and the Service has no endpoints at all, with no error |
| EndpointSlice | `addressType` | Yes | `IPv4` here; also supports `IPv6` and `FQDN` |
| EndpointSlice | `endpoints[].addresses` | Yes | The actual external IP(s) — this is what you update if the external target moves |
| EndpointSlice | `endpoints[].conditions.ready` | No — but effectively required | Unlike a selector-based EndpointSlice, nothing computes this for you; omitting it is not the same as `true` |

```bash
kubectl apply -f 03-selectorless-svc.yaml
kubectl describe svc external-db-svc
kubectl get endpointslices -l kubernetes.io/service-name=external-db-svc
```

**Expected output:**
```
Name:              external-db-svc
Type:              ClusterIP
IP:                10.96.xxx.xxx
Port:              <unset>  5432/TCP

NAME                           ADDRESSTYPE   PORTS   ENDPOINTS
external-db-svc-endpoints      IPv4          5432    10.240.0.50
```
> Pods can now reach `external-db-svc:5432` and traffic is forwarded to
> `10.240.0.50:5432`. If the external DB moves, update only the
> EndpointSlice — application code and configuration unchanged. Note
> the `03-externalname` demo later in this chapter covers a related but
> distinct pattern (DNS aliasing instead of IP-based routing) for a
> similar "point at something outside the cluster" need.

**Cleanup:**
```bash
kubectl delete -f 03-selectorless-svc.yaml
kubectl delete -f 02-backend-svc.yaml
kubectl delete -f 01-backend-deployment.yaml
```

---

## What You Learned

In this lab, you:
- ✅ Inspected EndpointSlices and understood all fields (Ready, Serving, Terminating, NodeName)
- ✅ Compared EndpointSlice vs the deprecated Endpoints API `01-clusterip-nodeport` used
- ✅ Reconfirmed load balancing using the same distinguishable per-pod responses from `01-clusterip-nodeport`, this time explaining the iptables mechanics that actually produce it
- ✅ Observed readiness affecting endpoint registration in real time
- ✅ Verified kube-proxy is running on every node, including the control plane, and why
- ✅ Inspected iptables DNAT rules that kube-proxy creates
- ✅ Understood kube-proxy is NOT in the data path — the kernel handles routing
- ✅ Created a selectorless service with manual EndpointSlice

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1 — "A node's Services stop responding — is routing down?"

**The scenario:** something on `3node-m02` looks wrong — a teammate
reports Services routing through that node feel unreliable, and you
notice `kube-proxy`'s pod on that node isn't the one that's been running
since cluster start. Before assuming outages, investigate what's
actually happening.

This scenario needs nothing from the main lab still running — kube-proxy
is a cluster-wide system DaemonSet that exists regardless of what
application Services you've built.

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
# Pick the kube-proxy pod running on 3node-m02 and delete it
kubectl delete pod -n kube-system <kube-proxy-pod-on-3node-m02>
kubectl get pods -n kube-system -l k8s-app=kube-proxy -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** kube-proxy runs as a DaemonSet — deleting one of its pods is
exactly the same self-healing scenario from `01-basic-deployment`, just
applied to a system-managed DaemonSet instead of a user Deployment. The
DaemonSet controller notices the missing pod on `3node-m02` and recreates
it immediately.

**Fix:** Nothing to fix — this is the system working as designed. Watch
`kubectl get pods -n kube-system -l k8s-app=kube-proxy -w` to see the
replacement pod go through `Pending` → `ContainerCreating` → `Running`.

**Cascade:** While the replacement pod is starting (a few seconds,
typically), the iptables rules already programmed on `3node-m02` **don't
disappear** — kube-proxy programs the kernel's rules, it doesn't sit in
the data path serving them. So Services routing through that node
continue working uninterrupted during the brief gap, even though the
kube-proxy pod itself is temporarily down — a direct, practical
confirmation of "kube-proxy only programs rules, the kernel enforces
them" from this demo's own Concepts.

</details>

**Cleanup:** none needed — the DaemonSet controller already restored normal state.

---

### Error-2 — "The Service's Endpoints just vanished — did something delete my pods?"

**The scenario:** `kubectl get endpointslices` for a Service you were
just using suddenly returns nothing. Your first instinct might be that
the backing pods crashed or were deleted — check that assumption before
acting on it.

```bash
# Self-contained: deploy a throwaway backend + Service for this scenario
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: breakfix-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: breakfix-backend
  template:
    metadata:
      labels:
        app: breakfix-backend
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: backend
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Hello from breakfix backend"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: breakfix-backend-svc
spec:
  type: ClusterIP
  selector:
    app: breakfix-backend
  ports:
    - port: 9090
      targetPort: 5678
EOF
kubectl rollout status deployment/breakfix-backend

# Confirm the EndpointSlice exists, then delete it directly
kubectl get endpointslices -l kubernetes.io/service-name=breakfix-backend-svc
kubectl delete endpointslice -l kubernetes.io/service-name=breakfix-backend-svc
kubectl get endpointslices -l kubernetes.io/service-name=breakfix-backend-svc
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** For a selector-based Service, EndpointSlices aren't
authored by you — they're owned and continuously reconciled by the
`endpointslice-controller`, the same `managed-by` label you saw in Step
2's `describe` output. Deleting one doesn't leave the Service without
endpoints; the controller notices the mismatch (Service has a selector,
matching Ready pods exist, but no EndpointSlice reflects them) and
recreates it, typically within seconds. The pods were never touched at
all.

**Fix:** Nothing to fix — expected self-healing, the same reconciliation
pattern you've now seen at the Pod/ReplicaSet layer (`01-basic-deployment`),
the DaemonSet layer (this demo's Error-1), and now the EndpointSlice
layer.

**Cascade:** Traffic continues flowing throughout — the iptables rules
kube-proxy already programmed from the *previous* EndpointSlice don't
vanish just because the Kubernetes object was deleted; they get
reprogrammed once the new EndpointSlice is created and kube-proxy
observes it. This is a genuinely different failure mode from Error-1
(a missing *pod*) — here the *object describing the pods* was removed,
not a pod itself.

**Important distinction from the selectorless case (Step 6):** this
self-healing only applies to Services **with a selector**. A
selectorless Service's EndpointSlice is *not* owned by the
endpointslice-controller — if you delete `external-db-svc-endpoints`
manually, nothing recreates it, because there's no selector for a
controller to reconcile against. That EndpointSlice is entirely your
own responsibility to maintain.

</details>

**Cleanup:**
```bash
kubectl delete svc breakfix-backend-svc 2>/dev/null || true
kubectl delete deployment breakfix-backend 2>/dev/null || true
```

---

## Interview Prep

**Q: Is the Endpoints API gone?**
A: Not removed, but officially deprecated since v1.33. `kubectl get endpoints` shows a deprecation warning; migrate tooling to EndpointSlices. The type itself will likely remain for compatibility even after the controller behind it is eventually retired.

**Q: Does kube-proxy handle every packet?**
A: No. kube-proxy only programs iptables/nftables/IPVS rules on each node — the kernel handles all packet forwarding using those rules. kube-proxy itself is never in the data path, which is exactly why deleting a kube-proxy pod (this demo's Break-Fix Error-1) doesn't interrupt already-established routing.

**Q: What happens to in-flight requests when a pod is deleted?**
A: When a pod begins terminating, its EndpointSlice entry is marked `Terminating: true`. kube-proxy removes it from load balancing for new requests, but the pod keeps running (and in-flight requests keep completing) until `terminationGracePeriodSeconds` elapses — the same graceful-shutdown timing already covered in `01-core-concepts`.

**Q: If you delete an EndpointSlice for a Service with a selector, does the Service go dark?**
A: No — the endpointslice-controller recreates it almost immediately, since it continuously reconciles EndpointSlices against the Service's selector and currently-Ready pods. This is not true for a selectorless Service's manually-created EndpointSlice, which nothing reconciles automatically.

**Q: Why does kube-proxy run on the control-plane node even though a taint prevents regular workloads from scheduling there?**
A: kube-proxy is deployed as a DaemonSet with its own toleration for the control-plane taint — taints only block scheduling for pods that don't explicitly tolerate them, and system DaemonSets like kube-proxy are built to tolerate exactly this one.

**Q: Should a new cluster be set up with `ipvs` mode for scale?**
A: No — `ipvs` mode was formally deprecated in Kubernetes v1.35. `nftables` is the current, actively-developed answer to the same "scale better than iptables" problem `ipvs` originally solved, and is what's now recommended for new clusters on kernels that support it (5.13+).

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | EndpointSlices, kube-proxy modes, iptables rule structure |
| Troubleshooting | CKA | 30% | Diagnosing whether a Service problem is selector-level or routing-level |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Using `kubectl get endpoints` out of habit | Still works but deprecated since v1.33 — know the EndpointSlice equivalent by heart |
| Assuming kube-proxy processes every packet | It only programs rules; the kernel forwards packets — a common but incorrect mental model |
| Assuming a deleted EndpointSlice breaks a Service permanently | Only true for selectorless Services — selector-based ones self-heal via the endpointslice-controller |
| Forgetting the `kubernetes.io/service-name` label for filtering EndpointSlices | Without it, `kubectl get endpointslices` returns every slice in the namespace, not just the one you care about |
| Assuming kube-proxy doesn't run on the control plane | It does — as a DaemonSet with a toleration for the control-plane taint |
| Assuming `ipvs` is still a safe choice for a new cluster | It was deprecated in Kubernetes v1.35 — `nftables` is the current recommendation for the same scale use case |

### Exam Task — Write it from scratch

Given a Service `backend-svc` with 3 backing pods, find its EndpointSlice, confirm all 3 endpoints show `Ready: true`, then identify which kube-proxy mode the cluster is running.

Official docs: [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/), [kube-proxy](https://kubernetes.io/docs/reference/networking/virtual-ips/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
kubectl describe endpointslice -l kubernetes.io/service-name=backend-svc | grep Ready
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep -i proxier
```

**Key fields/commands to recall:** the `kubernetes.io/service-name` label for filtering, `Conditions.Ready` in `describe endpointslice` output, and the kube-proxy log line naming its active proxier mode.

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| Services work via kernel-level NAT rules, not a central proxy | kube-proxy programs iptables/nftables/IPVS rules; the kernel does the actual packet forwarding |
| EndpointSlices are the current API, Endpoints is deprecated | Multiple slices per Service (up to 100 endpoints each), dual-stack support, readiness/topology tracking — none of which the old Endpoints API had |
| A selector-based Service's EndpointSlice is self-healing | The endpointslice-controller reconciles it continuously — deleting it just gets it recreated |
| A selectorless Service's EndpointSlice is NOT self-healing | No controller owns it — you maintain it entirely yourself |
| kube-proxy is a DaemonSet, and self-heals the same way any DaemonSet does | Deleting one kube-proxy pod doesn't break routing on that node — existing rules stay programmed until the replacement takes over |
| kube-proxy runs on every node, including the control plane | Via a DaemonSet-level toleration for the control-plane taint, distinct from how regular workload scheduling is blocked there |
| iptables load balancing uses cascading probabilities | `probability 0.333`, then `0.500` of the remainder, then everything left — the math behind "equal distribution across 3 pods" |
| Identical responses don't prove load balancing is broken | You need distinguishing data per pod (like this demo's `$(MY_POD_NAME)`) to actually observe routing, not just successful requests |
| `ipvs` mode is deprecated (v1.35), not just "not recommended" | `nftables` is the current, actively-developed replacement for `ipvs`'s original large-scale use case |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get endpointslices` | List all EndpointSlices |
| `kubectl get endpointslices -l kubernetes.io/service-name=<name>` | EndpointSlices for a specific service |
| `kubectl describe endpointslice -l kubernetes.io/service-name=<name>` | Show endpoint details including readiness |
| `kubectl get pods -n kube-system \| grep kube-proxy` | Verify kube-proxy pods |
| `kubectl logs -n kube-system -l k8s-app=kube-proxy \| grep -i mode` | Check kube-proxy mode |
| `minikube ssh -p 3node -n <node>` | SSH into a minikube node |
| `sudo iptables -t nat -L KUBE-SERVICES -n` | List service NAT rules |

This demo is entirely inspection/diagnosis-focused — no new object type is
created imperatively (the selectorless Service + manual EndpointSlice in
Step 6 specifically requires YAML, since `kubectl expose` has no
selectorless mode). See `01-clusterip-nodeport`'s Quick Commands Reference
for imperative Service creation.

---

## Appendix — Anki Cards

**`02-service-internals-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::02-service-internals
#separator:Comma
#columns:Front,Back,Tags
"Does kube-proxy process every packet sent to a Service?","No — it only programs iptables/nftables/IPVS rules; the kernel handles all actual packet forwarding using those rules","demo02-services,kube-proxy,cka-services-networking"
"What replaced the deprecated Endpoints API?","EndpointSlices — multiple slices per Service (up to 100 endpoints each), with dual-stack support and readiness/topology tracking the old API lacked","demo02-services,endpointslices,cka-services-networking"
"For a Service WITH a selector, is its EndpointSlice self-healing if deleted?","Yes — the endpointslice-controller continuously reconciles it against the selector and currently-Ready pods, and recreates it almost immediately","demo02-services,endpointslices,self-healing,cka-services-networking"
"For a selectorless Service, is its manually-created EndpointSlice self-healing?","No — nothing reconciles it automatically; you're fully responsible for keeping it accurate yourself","demo02-services,endpointslices,selectorless,cka-services-networking"
"Does deleting a kube-proxy pod interrupt existing Service routing on that node?","No — the iptables rules it already programmed stay in place; kube-proxy isn't in the data path, only the rule-programming path","demo02-services,kube-proxy,cka-services-networking"
"Why does kube-proxy run on the control-plane node despite the scheduling taint there?","It's a DaemonSet with its own toleration for the control-plane taint — taints only block pods that don't explicitly tolerate them","demo02-services,kube-proxy,taints,cka-cluster-architecture-installation-configuration"
"What does Ready: false on an EndpointSlice entry mean for that pod?","It's excluded from load balancing — matching the Service's selector alone isn't enough, only Ready endpoints receive traffic","demo02-services,endpointslices,readiness,cka-services-networking"
"How does iptables achieve roughly equal load distribution across 3 pod endpoints?","Cascading statistic-mode probabilities: 0.333 for the first, 0.500 of the remainder for the second, everything left for the third — netting out to roughly 1/3 each","demo02-services,iptables,load-balancing,cka-services-networking"
"If every backend pod returns identical response text, does that prove load balancing isn't working?","No — it just means you can't observe it from response content; distinguishing data per pod (like an injected pod name) is needed to actually verify routing","demo02-services,load-balancing,debugging,cka-troubleshooting"
"What kube-proxy modes exist on Linux, and what is ipvs's current status?","iptables, nftables, and ipvs — ipvs was formally deprecated in Kubernetes v1.35; nftables is the currently recommended mode for new clusters on modern kernels","demo02-services,kube-proxy,cka-services-networking"
"What field actually links a manually-created EndpointSlice to its Service?","The metadata.labels[kubernetes.io/service-name] label — get it wrong and the Service has no endpoints at all, with no error","demo02-services,endpointslices,selectorless,cka-services-networking"
"Does a manually-created EndpointSlice need conditions.ready set explicitly?","Yes — unlike a selector-based EndpointSlice where the controller computes it, nothing computes readiness for a manual one; omitting it is not the same as setting it true","demo02-services,endpointslices,selectorless,cka-services-networking"
````

---

## Appendix — Quiz

**`02-service-internals-quiz.md`:**

````markdown
# Quiz — 03-services/02-service-internals: Service Internals

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. kube-proxy watches for changes to both Services and EndpointSlices. Why does it need to watch EndpointSlices specifically, separate from watching Services?**

- A) It doesn't — watching Services alone is sufficient
- B) A Service's own spec rarely changes, but which pods back it changes constantly (scaling, restarts, readiness) — EndpointSlice changes are what actually drive re-programming the iptables rules
- C) EndpointSlices are watched only during initial cluster setup
- D) Services and EndpointSlices are the same object internally

<details>
<summary>Answer</summary>

**B** — The Service object (port, selector, type) is comparatively static; the EndpointSlice is what changes moment to moment as pods come and go, which is exactly what the DNAT rules need to stay current with.
Trap: D conflates two genuinely separate API objects that just happen to be linked by a label.

</details>

---

**Q2. An EndpointSlice entry shows `Terminating: true`. Does the pod immediately stop handling any traffic at that instant?**

- A) Yes, immediately — no further requests are processed
- B) No — it's removed from new load-balancing selection, but the pod keeps running and finishing in-flight requests until its grace period elapses
- C) `Terminating: true` only appears after the pod is already fully gone
- D) It has no effect on traffic at all, only on `kubectl get pods` display

<details>
<summary>Answer</summary>

**B** — This mirrors the graceful-shutdown timing already covered for Pods generally — kube-proxy stops sending it *new* requests, but the pod itself isn't force-killed just because this condition flipped.
Trap: A assumes an instant hard cutover, ignoring that graceful termination is specifically designed to avoid dropping in-flight work.

</details>

---

**Q3. Both a Deployment-managed Pod (`01-basic-deployment`) and a DaemonSet-managed kube-proxy pod (this demo's Break-Fix Error-1) get recreated automatically when deleted. Is the underlying mechanism the same?**

- A) No — DaemonSets use a completely different reconciliation system from Deployments/ReplicaSets
- B) Yes in principle — both are controllers continuously reconciling actual state (pods that exist) against desired state (one pod per node, for a DaemonSet), just with different desired-state rules
- C) DaemonSets don't self-heal; only Deployments do
- D) Only true if the DaemonSet is in `kube-system`

<details>
<summary>Answer</summary>

**B** — The general reconciliation pattern (watch → compare actual vs. desired → correct the gap) is the same shape across ReplicaSet, DaemonSet, and EndpointSlice controllers — only what "desired" means differs per controller type.
Trap: D invents a namespace-based exception — self-healing has nothing to do with which namespace a DaemonSet's pods run in.

</details>

---

**Q4. This demo's Break-Fix Error-1 (kube-proxy pod deleted) and Error-2 (EndpointSlice deleted) both result in no lasting disruption. What's the key structural difference between what actually got removed in each case?**

- A) There's no difference — both are the same failure
- B) Error-1 removes a controller *pod* whose job is to program rules; Error-2 removes the *data object* describing which pods should receive traffic — different layers, both self-healing for different reasons
- C) Error-1 is DNS-related, Error-2 is scheduling-related
- D) Error-2 can only happen on selectorless Services

<details>
<summary>Answer</summary>

**B** — Error-1 is "the thing that programs rules briefly went away, but the rules it already wrote still work." Error-2 is "the object describing current pod IPs went away, but the controller that owns that object rebuilds it." Different objects, different owners, same theme of resilience through reconciliation.
Trap: D contradicts the demo directly — Error-2's scenario specifically uses a *selector-based* Service to demonstrate self-healing; the selectorless case is explicitly called out as the exception, not the rule, in that same Break-Fix's closing note.

</details>

---

**Q5. `nftables` has been stable since Kubernetes v1.33. Is it currently the default kube-proxy mode?**

- A) Yes, as of v1.33 it replaced iptables as the default
- B) No — `iptables` remains the default mode even though `nftables` is the current recommendation for new clusters on supported kernels
- C) The default depends entirely on which CNI plugin is installed
- D) There is no default; it must always be set explicitly

<details>
<summary>Answer</summary>

**B** — "Stable" and "recommended for new clusters" aren't the same as "default" — this demo's Concepts are explicit that `iptables` is still what you get without configuring otherwise.
Trap: A conflates stability/recommendation with being the actual default setting.

</details>

---

**Q6. In the EndpointSlice output, each endpoint has a `TargetRef` pointing to a specific `Pod/backend-deploy-xxxxx-aaaaa`. What does this give you that just having the IP address wouldn't?**

- A) Nothing — the IP alone is sufficient for all purposes
- B) A direct link back to the actual Pod object, letting you `kubectl describe` or `kubectl logs` that exact backing pod instead of having to guess which pod owns a given IP
- C) `TargetRef` is only informational and can't be used to look anything up
- D) It's required for kube-proxy to function at all

<details>
<summary>Answer</summary>

**B** — When you're debugging a specific misbehaving endpoint, `TargetRef` is what turns "10.244.1.x is acting up" into "which pod is that, so I can `kubectl logs` it" without a separate IP-to-pod lookup.
Trap: D overstates its necessity — kube-proxy's actual rule-programming works from addresses and ports, not from needing to resolve `TargetRef` back to a Pod object.

</details>

---

**Q7. As of Kubernetes v1.33+, what specifically happens when you run `kubectl get endpoints` (the old API)?**

- A) The command fails outright with an error
- B) It still works and returns the same underlying data, but prints a deprecation warning pointing to EndpointSlices
- C) It silently returns an empty result
- D) It's automatically translated into `kubectl get endpointslices` output

<details>
<summary>Answer</summary>

**B** — Deprecated means "still functions, but you're told to migrate" — not removed and not silently broken.
Trap: A and C both assume deprecation means broken/non-functional, which overstates what "deprecated" actually means here.

</details>

---

**Q8. A selectorless Service's manually-written EndpointSlice must include its own `ports[]` list, separate from the Service's own `spec.ports[]`. Why is this duplication necessary?**

- A) It isn't necessary — the EndpointSlice inherits ports from the Service automatically
- B) For a selector-based Service, the endpointslice-controller derives the EndpointSlice's ports from the Service automatically; for a selectorless one, nothing does that derivation, so you must state it yourself
- C) EndpointSlice ports are purely cosmetic and never actually used
- D) Only the Service's `ports[]` matters; the EndpointSlice's copy is ignored

<details>
<summary>Answer</summary>

**B** — This is the same theme as `conditions.ready` needing to be explicit on a manual EndpointSlice — anything the endpointslice-controller normally computes for you has to be written by hand once there's no controller doing that computation.
Trap: D assumes one of the two duplicated fields is simply dead weight, when in fact the EndpointSlice's own values are what's actually used for routing in the selectorless case.

</details>

---

**Q9. Why does this demo re-run the "distinguishable per-pod response" check from `01-clusterip-nodeport` in its own Step 1, before introducing anything new?**

- A) It's unnecessary repetition with no purpose
- B) To reconfirm load balancing is genuinely happening before this demo goes on to explain the exact iptables mechanics producing it — establishing the "what" again right before diving into the "how"
- C) Because the backend image changed since the last demo
- D) It's required for EndpointSlices to be created at all

<details>
<summary>Answer</summary>

**B** — Step 1 explicitly frames this as re-confirmation before Steps 4-5 explain the underlying mechanism — establishing the observed behavior first, then explaining it, rather than assuming it's still true from the last demo.
Trap: D invents a dependency between response content and EndpointSlice creation — EndpointSlices are created based on Service selectors and pod readiness, completely independent of what a pod's application actually returns.

</details>

Score guide:

| Score | Action |
|---|---|
| 8-9/9 | Import Anki cards, move to next Demo |
| 7/9 | Review the wrong answer, then proceed |
| 6/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
````