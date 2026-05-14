# Service Internals — EndpointSlices and kube-proxy

## Lab Overview

When you create a Service in Kubernetes, several components work together
behind the scenes to route traffic from a stable virtual IP to the
correct pod. This demo examines those internal mechanics:

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

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [13-clusterip-nodeport](../01-clusterip-nodeport/README.md)
- Understanding of iptables basics (helpful but not required)

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Inspect EndpointSlices and understand what they contain
2. ✅ Explain why EndpointSlices replaced the deprecated Endpoints API
3. ✅ Verify kube-proxy is running and identify its proxy mode
4. ✅ Inspect iptables rules created by kube-proxy for a Service
5. ✅ Observe how readiness affects endpoint registration
6. ✅ Create a selectorless service with manual EndpointSlice

## Directory Structure

```
02-service-internals/
├── README.md                        # This file
└── src/
    ├── backend-deployment.yaml      # hashicorp/http-echo — 3 replicas
    ├── backend-svc.yaml             # ClusterIP service
    └── selectorless-svc.yaml        # Service without selector + manual EndpointSlice
```

---

## Understanding Service Internals

### EndpointSlices — The Modern Endpoint Tracking API

In Kubernetes, an EndpointSlice contains references to a set of network endpoints. The control plane automatically creates EndpointSlices for any Kubernetes Service that has a selector specified.

EndpointSlices replaced the older Endpoints API (deprecated in v1.33).
The key improvements:

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
> warning. Users should migrate to `kubectl get endpointslices`.

### kube-proxy — The Traffic Routing Engine

Every node in a Kubernetes cluster runs a kube-proxy (unless you have deployed your own alternative component in place of kube-proxy). The kube-proxy component is responsible for implementing a virtual IP mechanism for Services of type other than ExternalName.

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

---

### Step 1: Deploy Backend and Service

```bash
cd 02-service-internals/src
```

**backend-deployment.yaml:**
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

> Note: `$(MY_POD_NAME)` in args injects the pod name into the
> response text — so we can see WHICH pod answered each request.

**backend-svc.yaml:**
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
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-svc.yaml
kubectl rollout status deployment/backend-deploy
kubectl get pods -l app=backend -o wide
```

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

> The Endpoints API is deprecated. Migrate scripts and tooling to use
> EndpointSlices. The older `kubectl get endpoints` still works but
> shows less information and will eventually be removed.

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

Only 1 endpoint — 2 pods were removed, EndpointSlice updated automatically.

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

One kube-proxy pod per node — including control plane.

Check kube-proxy mode:

```bash
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep -i "using\|proxier\|mode"
```

**Expected output:**
```
... "Using iptables Proxier"
```

Or check via the proxy API:

```bash
kubectl proxy &
PROXY_PID=$!

curl -s http://localhost:8001/api/v1/namespaces/kube-system/pods \
  | python3 -m json.tool \
  | grep -A2 "kube-proxy"

kill $PROXY_PID
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

Show actual DNAT rule for one endpoint:

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

> This is how kube-proxy works — no traffic passes through kube-proxy
> itself. The kernel handles all packet rewriting via these rules.
> kube-proxy only manages the rules.

---

### Step 6: Selectorless Service — Manual Endpoint Management

A selectorless service has no selector field. You manually define which
endpoints it routes to. Useful for:
- External databases outside the cluster
- Services in another namespace or cluster
- Legacy systems with static IPs

**selectorless-svc.yaml:**
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
kubectl apply -f selectorless-svc.yaml
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

> Pods can now reach `external-db-svc:5432` and traffic is forwarded
> to `10.240.0.50:5432`. If the external DB moves, update only the
> EndpointSlice — application code and configuration unchanged.

**Cleanup:**

```bash
kubectl delete -f selectorless-svc.yaml
kubectl delete -f backend-svc.yaml
kubectl delete -f backend-deployment.yaml
```

---

## Common Questions

### Q: Is the Endpoints API gone?

**A:** Not yet removed but officially deprecated since v1.33. Using
`kubectl get endpoints` shows a deprecation warning. The plan is to
eventually remove the Endpoints controller but the type itself will
likely remain for compatibility. Migrate tooling to EndpointSlices.

### Q: Does kube-proxy handle every packet?

**A:** No. kube-proxy only programs iptables/nftables rules on each
node. The kernel handles all packet forwarding using those rules.
kube-proxy itself is not in the data path — this is why Kubernetes
networking can handle high throughput.

### Q: What happens to in-flight requests when a pod is deleted?

**A:** When a pod begins terminating, its EndpointSlice entry is
marked `Terminating: true`. kube-proxy removes it from load balancing.
New requests stop going to that pod. In-flight requests complete
because the pod continues running until `terminationGracePeriodSeconds`.

---

## What You Learned

In this lab, you:
- ✅ Inspected EndpointSlices and understood all fields (Ready,
  Serving, Terminating, NodeName)
- ✅ Compared EndpointSlice vs deprecated Endpoints API
- ✅ Observed readiness affecting endpoint registration in real time
- ✅ Verified kube-proxy is running on every node
- ✅ Inspected iptables DNAT rules that kube-proxy creates
- ✅ Understood kube-proxy is NOT in the data path — kernel handles routing
- ✅ Created a selectorless service with manual EndpointSlice

**Key Takeaway:** Services work by programming kernel-level NAT rules
on every node — not by proxying traffic through a central component.
EndpointSlices are the modern, scalable way to track pod endpoints.
The Endpoints API is deprecated — use EndpointSlices in new tooling.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get endpointslices` | List all EndpointSlices |
| `kubectl get endpointslices -l kubernetes.io/service-name=<n>` | EndpointSlices for a specific service |
| `kubectl describe endpointslice <n>` | Show endpoint details including readiness |
| `kubectl get pods -n kube-system \| grep kube-proxy` | Verify kube-proxy pods |
| `kubectl logs -n kube-system -l k8s-app=kube-proxy \| grep -i mode` | Check kube-proxy mode |
| `minikube ssh -p 3node -n <node>` | SSH into minikube node |
| `sudo iptables -t nat -L KUBE-SERVICES -n` | List service NAT rules |

---

## CKA Certification Tips

✅ **EndpointSlices are the current API — Endpoints is deprecated:**
```bash
kubectl get endpointslices   # current
kubectl get endpoints        # deprecated (warning in v1.33+)
```

✅ **EndpointSlice label to find slices for a service:**
```bash
kubectl get endpointslices -l kubernetes.io/service-name=<service-name>
```

✅ **kube-proxy runs on every node including control plane**

✅ **kube-proxy modes on Linux: iptables, nftables, ipvs**

✅ **Selectorless service requires manual EndpointSlice:**
```yaml
# Service with no selector field
# + EndpointSlice with label: kubernetes.io/service-name: <service-name>
```