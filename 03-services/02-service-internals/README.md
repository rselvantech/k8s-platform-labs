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
7. ✅ Distinguish which pod actually answered a request — resolving the exact limitation `01-clusterip-nodeport` ran into

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

nftables  → modern replacement for iptables (v1.29+)
            better performance than iptables
            recommended for new clusters on modern kernels

ipvs      → Linux kernel IP Virtual Server
            hash table lookup — O(1) vs iptables O(n)
            multiple load balancing algorithms
            better at very large scale (tens of thousands of Services)
            not recommended for new clusters — nftables is preferred
```

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

### Step 1: Deploy Backend and Service

```bash
cd 03-services/02-service-internals/src
```

**01-backend-deployment.yaml:**
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
          image: hashicorp/http-echo:0.2.3
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
> text via the Downward API — so you can see exactly **which** pod
> answered each request. This is the direct fix for the limitation
> `01-clusterip-nodeport` ran into: every pod there returned the
> identical static text, so load balancing was happening but genuinely
> impossible to verify from response content alone. This demo's backend
> is deliberately built to make it observable.

**02-backend-svc.yaml:**
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

**Now verify load balancing is actually observable:**
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
This is the confirmation `01-clusterip-nodeport` couldn't give you —
requests genuinely are being distributed across different pods, not just
succeeding repeatedly against one.

---

### Step 2: Inspect EndpointSlices

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

### Step 6: Selectorless Service — Manual Endpoint Management

A selectorless service has no `selector` field. You manually define which
endpoints it routes to. Useful for:
- External databases outside the cluster
- Services in another namespace or cluster
- Legacy systems with static IPs

**03-selectorless-svc.yaml:**
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
    kubernetes.io/service-name: external-db-svc
addressType: IPv4
protocol: TCP
ports:
  - port: 5432
    protocol: TCP
endpoints:
  - addresses:
      - "10.240.0.50"    # IP of external database server
    conditions:
      ready: true
```

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
- ✅ Verified load balancing is genuinely happening, using distinguishable per-pod responses — resolving that demo's exact observability limitation
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

### Error-1

```bash
# Assumes backend-deploy and backend-svc from the main lab are still running
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

### Error-2

```bash
# Assumes backend-svc's EndpointSlice from the main lab still exists
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
# Delete it directly
kubectl delete endpointslice -l kubernetes.io/service-name=backend-svc
kubectl get endpointslices -l kubernetes.io/service-name=backend-svc
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** For a selector-based Service, EndpointSlices aren't
authored by you — they're owned and continuously reconciled by the
`endpointslice-controller`, the same `managed-by` label you saw in Step
2's `describe` output. Deleting one doesn't leave the Service without
endpoints; the controller notices the mismatch (Service has a selector,
matching Ready pods exist, but no EndpointSlice reflects them) and
recreates it, typically within seconds.

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

**Cleanup:** none needed — the endpointslice-controller already restored normal state for the selector-based case.

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
"What kube-proxy modes exist on Linux, and which is currently recommended for new clusters?","iptables, nftables, and ipvs — nftables is the currently recommended mode for new clusters on modern kernels","demo02-services,kube-proxy,cka-services-networking"
````

---

## Appendix — Quiz

**`02-service-internals-quiz.md`:**

````markdown
# Quiz — 03-services/02-service-internals: Service Internals

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Does kube-proxy sit in the data path, processing every packet sent to a Service?**

- A) Yes, every packet passes through kube-proxy
- B) No — it only programs rules; the kernel forwards packets using them
- C) Only in ipvs mode
- D) Only for NodePort, not ClusterIP

<details>
<summary>Answer</summary>

**B** — kube-proxy's job ends at programming iptables/nftables/IPVS rules; the kernel does all actual packet forwarding from that point on.
Trap: C invents an exception that doesn't exist — this is true across all three modes, it's the fundamental design.

</details>

---

**Q2. You delete the kube-proxy pod running on one node. What happens to existing Service traffic through that node while it's being recreated?**

- A) All traffic through that node stops immediately
- B) Existing routing continues uninterrupted — already-programmed rules don't disappear when the pod is deleted
- C) Only NodePort traffic is affected, ClusterIP keeps working
- D) The node is automatically cordoned

<details>
<summary>Answer</summary>

**B** — Since kube-proxy already programmed the kernel's rules and isn't in the data path, those rules keep working independent of whether the kube-proxy pod itself is currently running.
Trap: A assumes kube-proxy is actively involved in ongoing traffic, contradicting the fundamental "only programs rules" design already established.

</details>

---

**Q3. You delete the EndpointSlice for a Service that has a selector. What happens?**

- A) The Service permanently loses all endpoints
- B) The endpointslice-controller recreates it almost immediately, since it's continuously reconciled
- C) Nothing — EndpointSlices for selector-based Services can't be deleted
- D) The Service automatically converts to selectorless

<details>
<summary>Answer</summary>

**B** — Selector-based EndpointSlices are owned and reconciled by the endpointslice-controller — deleting one is a self-healing scenario, not permanent damage.
Trap: A assumes no reconciliation exists for this object, which contradicts the ownership model already shown via the `managed-by` label in Step 2.

</details>

---

**Q4. Is that same self-healing true for a selectorless Service's manually-created EndpointSlice?**

- A) Yes, identical behavior
- B) No — nothing reconciles it automatically; it's entirely your own responsibility
- C) Only if the Service has a LoadBalancer type
- D) Only in production clusters

<details>
<summary>Answer</summary>

**B** — There's no selector for a controller to reconcile against, so a selectorless Service's EndpointSlice is unmanaged — a critical distinction from the selector-based case in Q3.
Trap: A assumes uniform behavior across both cases when they're actually fundamentally different in ownership.

</details>

---

**Q5. Three backend pods all return the identical response text to every request. Does this prove load balancing is broken?**

- A) Yes, identical responses mean one pod is answering everything
- B) No — without distinguishing data per pod, you can't tell which pod answered from content alone
- C) Yes, because kube-proxy should randomize response content
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — This is precisely the gap `01-clusterip-nodeport` ran into and this demo's backend was specifically built to resolve, by injecting the pod's own name into the response.
Trap: C invents a responsibility for kube-proxy (modifying response content) that it has no role in at all — it only routes packets.

</details>

---

**Q6. Why does kube-proxy run on the control-plane node even though a taint blocks regular workload scheduling there?**

- A) Taints don't apply to system components at all
- B) kube-proxy is a DaemonSet with its own explicit toleration for that taint
- C) The control-plane taint is automatically removed after cluster setup
- D) kube-proxy runs outside the cluster's normal scheduling entirely

<details>
<summary>Answer</summary>

**B** — Taints only block pods that don't explicitly tolerate them; kube-proxy's DaemonSet spec includes a toleration for exactly this taint.
Trap: A overgeneralizes — taints absolutely can affect system components; it's specifically having a matching toleration that exempts a given pod, not being "system" in some general sense.

</details>

---

**Q7. In the iptables chain for a 3-pod Service, what do the cascading `probability 0.333`, `0.500`, and implicit-last values achieve?**

- A) They prioritize the first pod listed to receive more traffic
- B) Roughly equal distribution across all 3 pods, computed via cascading probability of the remainder
- C) They're vestigial and have no functional effect
- D) They represent CPU usage per pod

<details>
<summary>Answer</summary>

**B** — 1/3 for the first, 1/2 of the remaining 2/3 (= 1/3) for the second, everything left (= 1/3) for the third — netting out to equal distribution despite each individual probability looking different.
Trap: A misreads the first probability as favoring that pod, without accounting for how the cascading remainder math actually works out equal in the end.

</details>

---

**Q8. Which kube-proxy mode is currently recommended for new clusters on modern kernels?**

- A) iptables, because it's the default
- B) ipvs, because it scales best
- C) nftables — better performance than iptables, the modern recommended choice
- D) All three are equally recommended with no preference

<details>
<summary>Answer</summary>

**C** — nftables is explicitly the currently recommended mode for new clusters, per this demo's own Concepts section.
Trap: B is a plausible-sounding distractor since ipvs does scale well at very large size, but it's explicitly noted as not recommended for new clusters in favor of nftables.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````