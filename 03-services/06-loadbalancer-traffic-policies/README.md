# Demo: 03-services/06-loadbalancer-traffic-policies — LoadBalancer and Traffic Policies

## Lab Overview

`01-clusterip-nodeport` established a nesting ladder — NodePort builds on
ClusterIP, LoadBalancer builds on NodePort — but stopped short of the top
rung, deferring it as needing "a cloud-provider-backed cluster." That
deferral turns out to be unnecessary: `minikube tunnel` genuinely
provisions a real `LoadBalancer` Service with a working `EXTERNAL-IP` on
this exact cluster. This demo closes that gap, then goes further into
territory none of the previous five demos in this chapter touched at
all: **which specific pod actually handles a request, and whether the
real client's identity survives the trip** — `externalTrafficPolicy`,
`sessionAffinity`, and `internalTrafficPolicy`.

None of this is new object types — it's deeper control over Services you
already know how to build, using the exact iptables/kube-proxy mechanics
`02-service-internals` already opened up.

**What this lab covers:**
- LoadBalancer Services and `minikube tunnel` — completing the ladder from `01-clusterip-nodeport`
- `externalTrafficPolicy: Cluster` vs `Local` — source IP preservation, via the SNAT mechanism from `02-service-internals`
- `sessionAffinity: ClientIP` — sticky sessions, resolving the "which pod answered" question from `02-service-internals` in a new direction
- `internalTrafficPolicy` — the ClusterIP-scoped analog of `externalTrafficPolicy`
- Multi-port Services and the port-naming requirement

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of every prior demo in this chapter — this demo assumes the full `01`–`05` Services foundation without re-explaining any of it
- `sudo`/administrator rights on the machine running minikube (needed for `minikube tunnel`)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

**A driver caveat, upfront, not buried in a footnote:** `minikube tunnel`
is confirmed unreliable specifically on **Linux with the Docker driver**
— no tunnel gets created there at all. Check your own setup before
Step 2:
```bash
minikube profile list
# or
cat ~/.minikube/profiles/3node/config.json | grep -i driver
```
If you're on Linux+Docker, skip Step 2's `EXTERNAL-IP` expectation — the
`LoadBalancer` Service itself still creates fine and still gets a
NodePort/ClusterIP underneath (per the nesting ladder), it just won't get
a real routable `EXTERNAL-IP` without the tunnel. **Nothing else in this
demo depends on Step 2 working** — every other step uses NodePort
directly, which works identically regardless of driver.

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create a LoadBalancer Service and provision a real `EXTERNAL-IP` via `minikube tunnel`
2. ✅ Explain `externalTrafficPolicy: Cluster` vs `Local` and demonstrate the source-IP difference directly
3. ✅ Explain `healthCheckNodePort` and why `Local` needs it
4. ✅ Configure `sessionAffinity: ClientIP` and demonstrate sticky routing
5. ✅ Explain `internalTrafficPolicy` as the ClusterIP-scoped analog of `externalTrafficPolicy`
6. ✅ Explain why a Service needs named ports once it has more than one

## Directory Structure

```
03-services/06-loadbalancer-traffic-policies/
├── README.md
├── src/
│   ├── 01-backend-deployment.yaml       # nginx, 3 replicas across nodes
│   ├── 02-loadbalancer-svc.yaml         # LoadBalancer Service
│   ├── 03-nodeport-cluster-policy.yaml  # NodePort, externalTrafficPolicy: Cluster (default)
│   ├── 04-nodeport-local-policy.yaml    # NodePort, externalTrafficPolicy: Local
│   ├── 05-sticky-svc.yaml               # ClusterIP, sessionAffinity: ClientIP
│   └── break-fix/
│       ├── 01-multiport-unnamed.yaml         # Embedded inline in README — not generated on disk
│       └── 02-local-no-local-endpoint.yaml   # Embedded inline in README — not generated on disk
├── 06-loadbalancer-traffic-policies-anki.csv
└── 06-loadbalancer-traffic-policies-quiz.md
```

---

## Recall Check — 05-service-discovery

Answer from memory before continuing — no peeking at the previous demo.

1. What does `ndots:5` actually control?
2. Is `dnsPolicy: Default` actually the default DNS policy for a pod?
3. What's the correct DNS format for resolving a pod directly, without going through a Service?

<details>
<summary>Answers</summary>

1. Whether search domains are tried before querying a name as-is — fewer dots than `ndots` means search domains get tried first.
2. No — `ClusterFirst` is the actual default; `Default` means using the node's own DNS instead.
3. `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>` — dots in the IP become dashes.

</details>

---

## Concepts

### LoadBalancer — Completing the Ladder

`01-clusterip-nodeport` established the nesting pattern: NodePort builds
on ClusterIP, allocating both. LoadBalancer completes it — it builds on
NodePort, which builds on ClusterIP, allocating all three:

```
ClusterIP    → internal virtual IP
NodePort     → + a port on every node
LoadBalancer → + an external, routable IP (EXTERNAL-IP), provisioned by
                whatever's watching for LoadBalancer-type Services
```

In a real cloud cluster (AKS, EKS, GKE), a cloud-controller-manager
component watches for `LoadBalancer`-type Services and calls out to the
cloud provider's own API to provision a real load balancer. Minikube has
no cloud provider to call — by default, a `LoadBalancer` Service on
minikube sits at `EXTERNAL-IP: <pending>` forever, which is exactly why
`01-clusterip-nodeport` deferred it.

**`minikube tunnel` fills that specific gap**, not by talking to a real
cloud API, but by creating a network route on your own machine to the
cluster's service network, using the cluster's own IP as a gateway. It's
a local simulation, not a production pattern — but it's a completely
genuine `EXTERNAL-IP`, reachable exactly like the real thing, for local
development and — as here — for actually completing this demo's
LoadBalancer objective without a cloud account.

---

### externalTrafficPolicy — Does the Client's Real IP Survive?

`02-service-internals` showed you the iptables DNAT rules kube-proxy
programs for a Service — packets get their destination rewritten from
the ClusterIP to a real pod IP. What that demo didn't show: **the source
IP can get rewritten too**, and whether it does is controlled by
`externalTrafficPolicy` — a field that only applies to `NodePort` and
`LoadBalancer` Services (it has no meaning for plain `ClusterIP`, which
never sees "external" traffic to begin with).

```
externalTrafficPolicy: Cluster (default):
  Traffic hitting ANY node gets routed to ANY matching pod, cluster-wide
  — including pods on a completely different node than the one that
  received the request. Making that cross-node hop work requires
  SNAT'ing the packet's source IP to the receiving node's own IP, so the
  return path knows how to get back. Consequence: the pod sees the
  NODE's IP as the client, never the real one.

externalTrafficPolicy: Local:
  Traffic is only ever routed to a pod on the SAME node that received
  it. No cross-node hop, no SNAT needed — the pod sees the REAL client
  IP. The trade-off: if a node has no local matching pod at all, traffic
  to that node's NodePort is simply dropped, not forwarded elsewhere.
```

This is a genuine trade-off, not a strictly-better option: `Cluster`
gives you even load distribution across every pod regardless of which
node traffic happens to land on; `Local` gives you real client IPs at the
cost of needing traffic to already be landing on a node that actually has
a pod.

**`healthCheckNodePort` — how an external load balancer knows where
`Local` traffic will actually work.** With `externalTrafficPolicy: Local`
on a `LoadBalancer` Service, Kubernetes automatically allocates an extra
port (`healthCheckNodePort`) that a real external load balancer polls to
learn which nodes currently have local matching pods — so it only sends
traffic to nodes where `Local` routing would actually succeed, rather
than nodes where it would silently drop. `minikube tunnel` doesn't
implement this health-checking itself (it's not a real external load
balancer), so this matters conceptually here more than operationally —
but it's exactly why `Local` doesn't just randomly fail in a real cloud
environment.

---

### sessionAffinity — Sticky Sessions

`02-service-internals` demonstrated that repeated requests to a Service
get load-balanced across different pods (that demo's whole point was
making this *observable* via per-pod response text). `sessionAffinity`
is the field that changes that behavior — pinning a given client to the
same pod for a configurable window, instead of round-robining every
request independently.

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800   # default: 3 hours
```

```
sessionAffinity: None (default)      → every request independently
                                        load-balanced — what every prior
                                        demo in this chapter has shown
sessionAffinity: ClientIP            → same source IP → same pod, until
                                        the timeout elapses
```

Kubernetes' own affinity here is IP-based only — there's no cookie-based
or header-based session affinity built into a plain Service (that level
of control needs an Ingress controller or service mesh, outside this
demo's scope). Worth knowing the limitation: if many real users share one
source IP (behind a corporate NAT, for instance), `ClientIP` affinity
pins *all* of them to the same pod, which can concentrate load unevenly.

---

### internalTrafficPolicy — The Same Idea, for ClusterIP Traffic

`externalTrafficPolicy` only governs traffic arriving from *outside* the
cluster (NodePort/LoadBalancer). `internalTrafficPolicy` is the newer,
less commonly needed analog for traffic between pods *inside* the
cluster, via a Service's ClusterIP:

```yaml
spec:
  internalTrafficPolicy: Local   # default: Cluster
```

```
internalTrafficPolicy: Cluster (default) → a pod's request to a Service
                                             can be routed to a matching
                                             pod on ANY node
internalTrafficPolicy: Local              → only routed to a matching pod
                                             on the SAME node as the
                                             caller — reduces cross-node
                                             network hops, at the cost of
                                             failing if no local match
                                             exists
```

Unlike `externalTrafficPolicy`, there's no source-IP motivation here
(pod-to-pod traffic inside the cluster was never SNAT'd in the first
place) — the value here is purely reducing cross-node network hops for
latency/cost reasons, at real production scale. Included here for
completeness rather than as a full hands-on exercise — the mechanics
mirror `externalTrafficPolicy` closely enough that a full second lab
wouldn't teach much new.

---

### Multi-Port Services Require Named Ports

Every Service YAML across this entire chapter so far has used exactly
one port. The moment a Service needs more than one, each entry in
`spec.ports[]` needs its own unique `name`:

```yaml
spec:
  ports:
    - name: http       # required once there's more than one port
      port: 80
      targetPort: 80
    - name: metrics
      port: 9090
      targetPort: 9090
```

Without `name`, a multi-port Service is rejected outright at `apply`
time — this demo's own Break-Fix Error-1 shows the actual rejection.
Single-port Services (everything you've built so far) never needed this,
which is exactly why it hasn't come up until now.

---

## Lab Step-by-Step Guide

By the end of this walkthrough you'll have provisioned a real
`LoadBalancer` Service via `minikube tunnel`, then used plain `NodePort`
Services to directly observe `externalTrafficPolicy`'s source-IP
trade-off and `sessionAffinity`'s sticky routing — all against the same
backend Deployment. Steps 1–2 build the backend and complete the
LoadBalancer ladder; Steps 3–4 contrast the two traffic policies; Steps
5–6 cover session affinity and the internal-traffic analog.

### Step 1: Deploy a Backend Distinguishable by Source IP

This step deploys the one backend every later step in this demo reuses
— across a plain LoadBalancer test, two different `externalTrafficPolicy`
Services, and a `sessionAffinity` Service, all pointed at the same 3 pods.

#### Backend Deployment

```bash
cd 03-services/06-loadbalancer-traffic-policies/src
```

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
        - name: nginx
          image: nginx:1.30.4
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```
> Using `nginx` deliberately, not `hashicorp/http-echo` — nginx's
> official image logs its access log to stdout by default, in the
> standard `combined` format, whose **first field is the client's
> source IP as nginx actually saw it**. That's the exact signal this
> demo's `externalTrafficPolicy` demonstration needs, and it comes free
> from `kubectl logs`, no extra tooling required.

```bash
kubectl apply -f 01-backend-deployment.yaml
kubectl rollout status deployment/backend-deploy
kubectl get pods -l app=backend -o wide
```
**Expected output — pods spread across worker nodes:**
```
NAME                              READY   STATUS    NODE
backend-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
backend-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m03
backend-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m02
```
Note which pods landed on which node — this matters directly for
Step 4's `Local` policy demonstration below.

---

### Step 2: LoadBalancer Service via minikube tunnel

This step completes the ladder `01-clusterip-nodeport` deferred —
provisioning a real, externally-routable `EXTERNAL-IP` for a
`LoadBalancer` Service on this exact cluster.

#### LoadBalancer Service

The only new field relative to every prior Service in this chapter is
`spec.type: LoadBalancer` itself — everything else here is the same
selector/ports shape already covered repeatedly.

**`02-loadbalancer-svc.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-lb
spec:
  type: LoadBalancer
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.type` | Yes (must be `LoadBalancer` explicitly) | Never a default — the field that requests provisioning of a real external IP |
| `spec.selector` | Yes | Same role as any selector-based Service |
| `spec.ports[]` | Yes | Same shape as ClusterIP/NodePort — `targetPort` still defaults to `port` if omitted |

```bash
kubectl apply -f 02-loadbalancer-svc.yaml
kubectl get svc backend-lb
```
**Expected output — EXTERNAL-IP starts pending:**
```
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
backend-lb   LoadBalancer   10.96.xxx.xxx   <pending>     80:3xxxx/TCP   5s
```
Notice `PORT(S)` already shows a NodePort (`3xxxx`) — confirming the
nesting ladder from Concepts: the ClusterIP and NodePort layers are
already fully provisioned, only the `EXTERNAL-IP` is still pending.

**In a separate terminal, run the tunnel (leave it running):**
```bash
minikube tunnel -p 3node
```
This requires elevated privileges and will prompt for your password —
it's creating a real network route on your machine.

**Back in your original terminal:**
```bash
kubectl get svc backend-lb
```
**Expected output — EXTERNAL-IP now populated:**
```
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)        AGE
backend-lb   LoadBalancer   10.96.xxx.xxx   192.168.58.10   80:3xxxx/TCP   45s
```

```bash
curl http://192.168.58.10
```
**Expected output:**
```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```
No port number needed — unlike NodePort, a working LoadBalancer's
`EXTERNAL-IP` is reachable on the Service's own `port` directly (`80`
here), the same way a real cloud load balancer would be.

**Stop the tunnel** (Ctrl+C in its terminal) before continuing — the
remaining steps don't need it.

---

### Step 3: externalTrafficPolicy: Cluster (Default) — Source IP Lost

This step demonstrates the SNAT trade-off from Concepts directly — curl
any node, including one with no local backend pod, and check what
source IP nginx actually logged.

#### NodePort Service — externalTrafficPolicy: Cluster

This is the demo's first genuinely new field: `externalTrafficPolicy`,
here set to `Cluster` (the default — set explicitly for contrast against
Step 4's `Local`).

**`03-nodeport-cluster-policy.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-traffic-cluster
spec:
  type: NodePort
  externalTrafficPolicy: Cluster   # explicit, though it's the default
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
      nodePort: 31100
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.externalTrafficPolicy` | No — defaults to `Cluster` | Set explicitly here for contrast against Step 4's `Local`; only meaningful on `NodePort`/`LoadBalancer` Services |
| `spec.ports[].nodePort` | No — auto-assigned if omitted | Set explicitly (`31100`) so it's predictable for the curl commands below |

```bash
kubectl apply -f 03-nodeport-cluster-policy.yaml
kubectl get nodes -o wide
```
Pick a worker node IP — deliberately **any** of them, including one that
might not have a backend pod locally (per Step 1's placement):
```bash
curl http://<any-worker-node-ip>:31100
kubectl logs -l app=backend --tail=5
```
**Expected output — access log shows a node IP, not your real source:**
```
192.168.58.3 - - [date] "GET / HTTP/1.1" 200 615 "-" "curl/8.x.x"
```
`192.168.58.3` here is the receiving node's own IP — SNAT rewrote the
real client's source address, exactly as Concepts predicted. This works
identically no matter which node you curl — that uniform reachability is
`Cluster` policy's whole point, at the cost of losing the real source IP.

---

### Step 4: externalTrafficPolicy: Local — Source IP Preserved

This step repeats Step 3's exact setup with one field flipped to
`Local`, then curls both a node *with* a local pod and one *without* —
directly demonstrating both halves of the trade-off from Concepts.

#### NodePort Service — externalTrafficPolicy: Local

Same shape as Step 3's Service — only `externalTrafficPolicy`'s value
changed, so no repeat table here. One new, auto-allocated field is worth
inspecting once it exists: `status.healthCheckNodePort`, allocated
specifically because this Service is `Local`.

**`04-nodeport-local-policy.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-traffic-local
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
      nodePort: 31200
```

```bash
kubectl apply -f 04-nodeport-local-policy.yaml
kubectl get svc backend-traffic-local -o yaml | grep healthCheckNodePort
```
**Expected output — an extra port was auto-allocated, per Concepts above:**
```
healthCheckNodePort: 3xxxx
```

**Curl a node that HAS a local backend pod** (from Step 1's placement):
```bash
curl http://<node-with-a-local-pod-ip>:31200
kubectl logs -l app=backend --tail=5
```
**Expected output — your actual source IP this time:**
```
<your-real-source-IP> - - [date] "GET / HTTP/1.1" 200 615 "-" "curl/8.x.x"
```

**Now curl a node that does NOT have a local backend pod:**
```bash
curl --max-time 5 http://<node-without-a-local-pod-ip>:31200
```
**Expected output — times out or connection refused, not routed elsewhere:**
```
curl: (28) Connection timed out after 5000 milliseconds
```
This is `Local` policy's real trade-off, made concrete: no cross-node
forwarding happens at all, so a node with nothing local to serve the
request just drops it, rather than reaching across to a node that could.

---

### Step 5: sessionAffinity: ClientIP — Sticky Routing

This step is a deliberate callback to `02-service-internals`'s
round-robin demonstration — same kind of repeated-request test, opposite
result, because of one new field.

#### ClusterIP Service — sessionAffinity: ClientIP

`sessionAffinity` and `sessionAffinityConfig` are both new fields for
this chapter — the mechanism that pins repeated requests from one client
to the same pod.

**`05-sticky-svc.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-sticky
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.sessionAffinity` | No — defaults to `None` | `ClientIP` is the only other valid value on a plain Service — no cookie/header-based affinity exists here |
| `spec.sessionAffinityConfig.clientIP.timeoutSeconds` | No — defaults to `10800` (3 hours) | Set explicitly here for clarity; how long a client stays pinned to the same pod after its last request |

```bash
kubectl apply -f 05-sticky-svc.yaml

# Without affinity, for contrast — reuse the default ClusterIP behavior
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- sh -c 'for i in $(seq 1 5); do curl -s -o /dev/null -w "%{remote_ip}\n" backend-sticky; done'
```
Then check the access log:
```bash
kubectl logs -l app=backend --tail=10
```
**Expected output — all 5 requests hit the SAME pod's log, unlike
`02-service-internals`'s round-robin demonstration:**
```
10.244.x.x - - [date] "GET / HTTP/1.1" 200 615
10.244.x.x - - [date] "GET / HTTP/1.1" 200 615
10.244.x.x - - [date] "GET / HTTP/1.1" 200 615
10.244.x.x - - [date] "GET / HTTP/1.1" 200 615
10.244.x.x - - [date] "GET / HTTP/1.1" 200 615
```
All five requests come from the same netshoot pod (same source IP), and
with `sessionAffinity: ClientIP` set, they all land in the *same*
backend pod's log — a direct contrast with `02-service-internals`'s
`backend-svc` (no affinity set), where identical requests spread across
different pods.

---

### Step 6: internalTrafficPolicy — Quick Inspection

The last new field in this demo — checked by inspection only, not a
full hands-on exercise, since its mechanics mirror
`externalTrafficPolicy` closely enough that a second full walkthrough
wouldn't teach much new (see Concepts above for why).

```bash
kubectl get svc backend-sticky -o jsonpath='{.spec.internalTrafficPolicy}'
```
**Expected output:**
```
Cluster
```
The default, even though this demo's YAML never set it explicitly —
confirming the same API-server-defaulting behavior already seen
repeatedly for other fields throughout this series (e.g.
`spec.strategy` on Deployments, back in `02-deployments/01-basic-deployment`).

---

### Step 7: Cleanup

Tear down every Service and the backend Deployment created across
Steps 1–5, in reverse order.

```bash
kubectl delete -f 05-sticky-svc.yaml
kubectl delete -f 04-nodeport-local-policy.yaml
kubectl delete -f 03-nodeport-cluster-policy.yaml
kubectl delete -f 02-loadbalancer-svc.yaml
kubectl delete -f 01-backend-deployment.yaml

kubectl get svc
kubectl get pods
```

---

## What You Learned

In this lab, you:
- ✅ Provisioned a real `EXTERNAL-IP` for a `LoadBalancer` Service using `minikube tunnel`, completing the ladder `01-clusterip-nodeport` started
- ✅ Demonstrated `externalTrafficPolicy: Cluster` losing the real client IP to SNAT, directly in nginx's own access log
- ✅ Demonstrated `externalTrafficPolicy: Local` preserving the real client IP, and its trade-off (dropped traffic on nodes with no local pod)
- ✅ Inspected `healthCheckNodePort` and understand why `Local` needs it in a real cloud environment
- ✅ Demonstrated `sessionAffinity: ClientIP` pinning repeated requests to the same pod, in direct contrast to `02-service-internals`'s round-robin behavior
- ✅ Confirmed `internalTrafficPolicy`'s default value and understand its narrower, latency-focused purpose
- ✅ Understand why multi-port Services require named ports

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1 — "A second port was added, and the apply just failed"

**The scenario:** a teammate added a metrics port to an existing
single-port Service, copying the pattern from every other Service in
this chapter. `kubectl apply` rejected it outright. Every prior Service
in this series applied fine with one port — find what's different now.

**`src/break-fix/01-multiport-unnamed.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: multiport-broken
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
    - port: 9090
      targetPort: 9090
```

```bash
kubectl apply -f 01-multiport-unnamed.yaml
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Once `spec.ports[]` has more than one entry, every entry needs
a unique `name` — this Service has two ports and neither is named, which
the API rejects outright at `apply` time:
```
error: Service "multiport-broken" is invalid: spec.ports[1].name:
Required value
```

**Fix:** Add a unique `name` to each port entry (e.g. `http` and
`metrics`).

**Cascade:** none — this fails validation before the object is ever
persisted, so nothing is created at all. Compare this to every
single-port Service built throughout this entire chapter, none of which
ever needed a `name` — this requirement only activates once a second port
exists.

</details>

**Cleanup:**
```bash
kubectl delete svc multiport-broken 2>/dev/null || true
```

---

### Error-2 — "Local policy times out from every single node, not just some"

**The scenario:** you understand `Local` policy's trade-off (traffic
drops on nodes with no local pod) — but this Service is timing out from
*every* node, not the handful you'd expect to lack local pods. Before
assuming `Local` itself is broken, check what it's actually a symptom of.

**`src/break-fix/02-local-no-local-endpoint.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: local-policy-trap
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    app: nonexistent-app   # matches no pods at all, anywhere
  ports:
    - port: 80
      targetPort: 80
      nodePort: 31300
```

```bash
kubectl apply -f 02-local-no-local-endpoint.yaml
kubectl get endpointslices -l kubernetes.io/service-name=local-policy-trap
curl --max-time 5 http://<any-node-ip>:31300
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** This isn't really about `externalTrafficPolicy` at all — the
selector matches zero pods anywhere in the cluster (the same class of
mistake as `01-clusterip-nodeport`'s own selector-typo Break-Fix). With
no Endpoints on *any* node, `Local` policy has nothing to route to
regardless of which node receives the traffic — every node behaves like
Step 4's "no local pod" case, everywhere, because there's genuinely no
pod for this Service at all.

**Fix:** Correct the selector to match real pods (`app: backend`).

**Cascade:** `kubectl get endpointslices` returns an empty result — the
same diagnostic signal `01-clusterip-nodeport` taught you to check first
for any "Service isn't working" symptom. `externalTrafficPolicy` is a
red herring here; the actual root cause is one chapter behind this demo.

</details>

**Cleanup:**
```bash
kubectl delete svc local-policy-trap 2>/dev/null || true
```

---

## Interview Prep

**Q: Why does `externalTrafficPolicy: Cluster` lose the client's real IP?**
A: Because traffic can be routed to a pod on a different node than the one that received it — making that cross-node hop work requires SNAT'ing the source IP to the receiving node's own address, so return traffic knows its way back. The pod only ever sees the node's IP, never the original client's.

**Q: What's the practical cost of switching to `externalTrafficPolicy: Local`?**
A: Traffic hitting a node with no local matching pod is simply dropped, not forwarded elsewhere — you lose the even, cluster-wide load distribution `Cluster` policy gives you for free. In a real cloud environment, `healthCheckNodePort` mitigates this by letting the external load balancer avoid sending traffic to nodes that would drop it.

**Q: Does `sessionAffinity: ClientIP` guarantee perfectly even load distribution?**
A: No — it deliberately trades that away for stickiness. If many real users share a source IP (common behind corporate NAT), they all get pinned to the same pod, which can concentrate load unevenly. It's IP-based only; no cookie or header-based affinity exists at the plain Service level.

**Q: What's the difference between `externalTrafficPolicy` and `internalTrafficPolicy`?**
A: `externalTrafficPolicy` governs traffic arriving from outside the cluster (NodePort/LoadBalancer) and exists primarily to control source-IP preservation. `internalTrafficPolicy` governs pod-to-pod traffic via a Service's ClusterIP — there's no SNAT concern there since that traffic was never externally sourced; the motivation is purely reducing cross-node network hops at scale.

**Q: Is `minikube tunnel` provisioning a real cloud load balancer?**
A: No — it simulates one by creating a network route on your own machine to the cluster's service network. It's a genuine, working `EXTERNAL-IP` for local development purposes, but nothing like it exists in a real cloud deployment, where a cloud-controller-manager calls out to an actual cloud provider API instead.

**Q: A `NodePort` Service returns connection timeouts from some nodes but not others, and you've confirmed `externalTrafficPolicy: Local` is set intentionally. Is this a bug?**
A: Not necessarily — check `kubectl get endpointslices` for that Service first. If pods genuinely exist on some nodes but not others, this is exactly `Local` policy's designed trade-off. If there are no Endpoints at all anywhere, the real problem is the selector, not the traffic policy — this demo's own Break-Fix Error-2 is built around exactly that distinction.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | LoadBalancer, externalTrafficPolicy, sessionAffinity, multi-port Services |
| Troubleshooting | CKA | 30% | Distinguishing a traffic-policy trade-off from an actual selector/Endpoints problem |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Assuming `LoadBalancer` always gets a real `EXTERNAL-IP` | Only true with something watching for it — a cloud provider, or `minikube tunnel` locally; otherwise it stays `<pending>` forever |
| Assuming `externalTrafficPolicy: Local` is strictly better than `Cluster` | It's a genuine trade-off — real client IPs vs. guaranteed even routing regardless of pod placement |
| Forgetting multi-port Services need named ports | Single-port Services never require this — easy to forget once you add a second port |
| Blaming `externalTrafficPolicy` for a Service that has zero Endpoints anywhere | Check `kubectl get endpointslices` first — a selector problem looks identical to a traffic-policy trade-off from the outside |
| Assuming `sessionAffinity` and `externalTrafficPolicy` solve the same problem | They don't — one is about which client reaches which pod repeatedly; the other is about whether the pod even sees the real client at all |

### Exam Task — Write it from scratch

Create a NodePort Service for an existing Deployment with `externalTrafficPolicy: Local`, then verify its `healthCheckNodePort` was auto-allocated.

Official docs: [Service — externalTrafficPolicy](https://kubernetes.io/docs/concepts/services-networking/service/#external-traffic-policy)

<details>
<summary>Reveal solution</summary>

```bash
kubectl expose deployment backend-deploy --name=local-check --type=NodePort --port=80 --target-port=80 --dry-run=client -o yaml > svc.yaml
# edit svc.yaml to add: spec.externalTrafficPolicy: Local
kubectl apply -f svc.yaml
kubectl get svc local-check -o yaml | grep healthCheckNodePort
```

**Key fields to recall:** `spec.externalTrafficPolicy`, `spec.healthCheckNodePort` (read-only/auto-allocated, not something you set yourself).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `minikube tunnel` genuinely completes the LoadBalancer ladder locally | Unreliable specifically on Linux+Docker driver — check your setup before relying on it |
| `externalTrafficPolicy: Cluster` (default) SNATs the source IP | Cross-node routing requires it; the pod only ever sees the node's IP |
| `externalTrafficPolicy: Local` preserves the real client IP | At the cost of dropping traffic on any node with no local matching pod |
| `healthCheckNodePort` is auto-allocated for `Local` policy | Lets a real external load balancer avoid sending traffic where it would be dropped |
| `sessionAffinity: ClientIP` pins a source IP to one pod | A direct contrast to the round-robin behavior every earlier demo in this chapter demonstrated |
| `internalTrafficPolicy` is `externalTrafficPolicy`'s ClusterIP-scoped analog | No SNAT concern for internal traffic — the motivation is reducing cross-node hops, not IP preservation |
| Multi-port Services require unique `name` per port | Rejected outright at `apply` time otherwise — single-port Services never hit this |
| A traffic-policy trade-off can look identical to a selector bug from outside | Always check `kubectl get endpointslices` first before assuming `externalTrafficPolicy` is the cause |

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `minikube tunnel -p 3node` | Provision a real EXTERNAL-IP for LoadBalancer Services (run in a separate terminal) |
| `kubectl get svc <name> -o jsonpath='{.spec.externalTrafficPolicy}'` | Check current traffic policy |
| `kubectl get svc <name> -o yaml \| grep healthCheckNodePort` | Find the auto-allocated health-check port |
| `kubectl logs -l <selector> --tail=N` | Check nginx access logs for observed source IPs — see Steps 3-4 |
| `kubectl get svc <name> -o jsonpath='{.spec.internalTrafficPolicy}'` | Check internal traffic policy default |

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| LoadBalancer Service | `kubectl expose deployment NAME --port=P --type=LoadBalancer` | `externalTrafficPolicy`/`sessionAffinity` aren't settable via flags — use `--dry-run=client -o yaml` then edit |

---

## Troubleshooting

**LoadBalancer stuck at `<pending>`:**
```bash
# Is minikube tunnel actually running, in its own terminal?
# On Linux+Docker driver, this is expected — see Prerequisites
minikube tunnel -p 3node
```

**`Local` policy Service times out from some nodes:**
```bash
# Expected if those nodes have no local matching pod — check placement:
kubectl get pods -l <selector> -o wide
# If EVERY node fails, check Endpoints exist at all:
kubectl get endpointslices -l kubernetes.io/service-name=<name>
```

**Multi-port Service rejected at apply:**
```bash
# Add a unique name to every entry in spec.ports[]
kubectl apply -f service.yaml
```

---

## Appendix — Anki Cards

**`06-loadbalancer-traffic-policies-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::06-loadbalancer-traffic-policies
#separator:Comma
#columns:Front,Back,Tags
"Does minikube tunnel provision a real cloud load balancer?","No — it simulates one via a network route on your own machine to the cluster's service network; genuinely working EXTERNAL-IP, but not a real cloud load balancer","demo06-services,loadbalancer,minikube,cka-services-networking"
"Why does externalTrafficPolicy: Cluster lose the real client IP?","Cross-node routing requires SNAT'ing the source IP to the receiving node's own address so return traffic can find its way back — the pod only ever sees the node's IP","demo06-services,externaltrafficpolicy,cka-services-networking"
"What's the trade-off of externalTrafficPolicy: Local?","Preserves the real client IP, but traffic to a node with no local matching pod is simply dropped, not forwarded elsewhere","demo06-services,externaltrafficpolicy,cka-services-networking"
"What is healthCheckNodePort for?","Auto-allocated when externalTrafficPolicy: Local is set on a LoadBalancer Service — lets a real external load balancer learn which nodes have local endpoints, avoiding nodes that would drop traffic","demo06-services,externaltrafficpolicy,cka-services-networking"
"What does sessionAffinity: ClientIP change about Service routing?","Pins a given source IP to the same pod for a configurable window, instead of independently load-balancing every request","demo06-services,sessionaffinity,cka-services-networking"
"Is sessionAffinity cookie-based or IP-based at the plain Service level?","IP-based only — cookie or header-based affinity needs an Ingress controller or service mesh, not available on a plain Service","demo06-services,sessionaffinity,cka-services-networking"
"What's the difference between externalTrafficPolicy and internalTrafficPolicy?","externalTrafficPolicy governs traffic from outside the cluster and controls source-IP preservation via SNAT; internalTrafficPolicy governs pod-to-pod ClusterIP traffic and is purely about reducing cross-node hops, no SNAT concern","demo06-services,internaltrafficpolicy,cka-services-networking"
"When does a Service require named ports?","Once spec.ports[] has more than one entry — every port needs a unique name, or the apply is rejected outright","demo06-services,multiport,ckad-application-deployment"
"A NodePort Service with externalTrafficPolicy: Local times out from every single node. What's the likely real cause?","Not the traffic policy itself — check kubectl get endpointslices first; a selector matching zero pods anywhere produces this exact symptom","demo06-services,troubleshooting,cka-troubleshooting"
"What's the default timeout for sessionAffinity: ClientIP if sessionAffinityConfig isn't set?","10800 seconds (3 hours) — a client stays pinned to the same pod for that long since its last request","demo06-services,sessionaffinity,cka-services-networking"
````

---

## Appendix — Quiz

**`06-loadbalancer-traffic-policies-quiz.md`:**

````markdown
# Quiz — 03-services/06-loadbalancer-traffic-policies: LoadBalancer and Traffic Policies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.

**Q1. Does `minikube tunnel` provision a real cloud load balancer?**

- A) Yes, identical to a cloud provider's implementation
- B) No — it simulates one via a network route on your own machine
- C) Only on cloud-hosted minikube instances
- D) Only for NodePort Services, not LoadBalancer

<details>
<summary>Answer</summary>

**B** — It's a genuine, working `EXTERNAL-IP` for local development, but the mechanism is entirely local — nothing like it exists in a real cloud deployment.
Trap: A overstates the similarity; the *result* (a working EXTERNAL-IP) is real, but the *mechanism* is completely different from a cloud load balancer.

</details>

---

**Q2. Why does `externalTrafficPolicy: Cluster` (the default) cause a pod to see a node's IP instead of the real client's?**

- A) Kubernetes hides client IPs for privacy by default
- B) Cross-node routing requires SNAT so return traffic can find its way back
- C) It only happens with LoadBalancer Services, not NodePort
- D) DNS resolution replaces the client IP

<details>
<summary>Answer</summary>

**B** — SNAT is what makes routing to a pod on a different node than the one that received the traffic actually work — the trade-off is losing the original source IP.
Trap: C is factually wrong — this demo demonstrates the exact same SNAT behavior on a plain NodePort Service, no LoadBalancer required.

</details>

---

**Q3. What happens with `externalTrafficPolicy: Local` when a node has no local matching pod?**

- A) Traffic is forwarded to a node that does have one
- B) Traffic is dropped — no cross-node forwarding happens under `Local`
- C) The Service automatically switches to `Cluster` policy for that node
- D) The request succeeds but with a warning header

<details>
<summary>Answer</summary>

**B** — This is `Local` policy's real trade-off — no cross-node hop occurs at all, so a node with nothing local to serve the request just drops it.
Trap: A describes `Cluster` policy's behavior, the exact thing `Local` is specifically designed not to do.

</details>

---

**Q4. What is `healthCheckNodePort` for?**

- A) A port you configure manually to check pod health
- B) Auto-allocated with `externalTrafficPolicy: Local`, letting an external load balancer avoid nodes that would drop traffic
- C) A liveness probe endpoint for the Service object itself
- D) Only relevant for ClusterIP Services

<details>
<summary>Answer</summary>

**B** — It's automatically allocated, not something you set — a real external load balancer polls it to learn which nodes currently have local endpoints under `Local` policy.
Trap: A assumes manual configuration is required; it's auto-allocated the moment `Local` is set.

</details>

---

**Q5. What does `sessionAffinity: ClientIP` change about how a Service routes requests?**

- A) It encrypts traffic to that client
- B) It pins a given source IP to the same pod for a configurable window, instead of independently load-balancing each request
- C) It only affects DNS resolution, not actual routing
- D) It requires an Ingress controller to function

<details>
<summary>Answer</summary>

**B** — A direct contrast to every prior demo in this chapter's round-robin behavior — same client, same pod, until the timeout elapses.
Trap: D confuses this with cookie/header-based affinity, which genuinely does need an Ingress controller — plain `sessionAffinity: ClientIP` works on any Service.

</details>

---

**Q6. What's the key difference between `externalTrafficPolicy` and `internalTrafficPolicy`?**

- A) They're identical fields with different names
- B) `externalTrafficPolicy` controls source-IP preservation for traffic from outside the cluster; `internalTrafficPolicy` reduces cross-node hops for internal ClusterIP traffic, with no SNAT concern
- C) `internalTrafficPolicy` only applies to headless Services
- D) `externalTrafficPolicy` is deprecated in favor of `internalTrafficPolicy`

<details>
<summary>Answer</summary>

**B** — Different problems entirely: one is about whether the real client identity survives (external traffic was SNAT'd), the other is purely about network efficiency (internal traffic was never SNAT'd to begin with).
Trap: A treats them as redundant, missing that they solve genuinely different problems for genuinely different traffic sources.

</details>

---

**Q7. When does a Service need every port entry to have a `name`?**

- A) Always, even for a single port
- B) Only once `spec.ports[]` has more than one entry
- C) Only for LoadBalancer-type Services
- D) Only when `externalTrafficPolicy: Local` is set

<details>
<summary>Answer</summary>

**B** — Single-port Services (everything built earlier in this chapter) never needed this — it activates specifically once a second port is added.
Trap: A overstates the rule — a single unnamed port is completely valid, as every prior demo in this series has shown.

</details>

---

**Q8. A `NodePort` Service with `externalTrafficPolicy: Local` times out from every single node, not just some. What's the most likely actual cause?**

- A) `externalTrafficPolicy: Local` is fundamentally broken
- B) The selector likely matches zero pods anywhere — check `kubectl get endpointslices` before blaming the traffic policy
- C) `Local` policy requires at least 5 nodes to function
- D) The NodePort range is misconfigured

<details>
<summary>Answer</summary>

**B** — `Local` policy dropping traffic from *some* nodes (with no local pod) is expected; timing out from *every* node points at a more fundamental problem — no Endpoints exist for this Service at all, the same class of mistake as a selector typo.
Trap: A assumes the well-documented, intentional trade-off of `Local` policy is itself a bug — the actual symptom pattern (all nodes, not just some) rules that explanation out.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, chapter complete |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````