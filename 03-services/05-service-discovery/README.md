# Demo: 03-services/05-service-discovery — Service Discovery and CoreDNS

## Lab Overview

Kubernetes uses DNS for service discovery — every service gets a DNS
name automatically, and pods can find each other by name without
knowing IP addresses. CoreDNS is the DNS server that runs inside every
Kubernetes cluster and handles all name resolution.

```
Pod A (namespace: frontend) wants to reach backend-svc (namespace: backend)

DNS resolution chain:
  1. Pod sends DNS query to 10.96.0.10 (CoreDNS)
  2. CoreDNS checks if name matches a Service
  3. Returns A record (ClusterIP) or CNAME (ExternalName)
  4. Pod connects using the resolved IP
```

This is the demo `01-clusterip-nodeport` promised you back at the start
of this chapter — every DNS detail that demo deliberately kept brief
(`/etc/resolv.conf`, `ndots`, search domains) gets full depth here,
alongside CoreDNS's own internals and a systematic debugging approach.

**What this lab covers:**
- DNS naming format — short name, FQDN, cross-namespace
- `/etc/resolv.conf` — search domains and `ndots`, in full
- CoreDNS architecture — ConfigMap, plugins, Corefile
- Cross-namespace service communication
- Service environment variables (the other discovery method)
- DNS policies — ClusterFirst, Default, None, and ClusterFirstWithHostNet
- Debugging DNS resolution systematically

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of `04-headless` (this demo assumes you already understand headless-service DNS behavior and the general Service DNS mechanics from every demo in this chapter)
- Understanding of DNS basics (A records, CNAME, search domains)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the full DNS naming format for Kubernetes services
2. ✅ Read `/etc/resolv.conf` and explain search domains and `ndots` precisely — resolving what `01-clusterip-nodeport` left at an introductory level
3. ✅ Inspect CoreDNS configuration (Corefile) via ConfigMap
4. ✅ Resolve services across namespaces using full DNS names
5. ✅ Use service environment variables for discovery, and explain why DNS is preferred
6. ✅ Apply all four DNS policies to pods, including `None` with a manual `dnsConfig`
7. ✅ Resolve an individual pod directly by DNS (not through a Service), and explain why this is rarely used directly but underpins headless-Service DNS
7. ✅ Debug DNS resolution issues systematically

## Directory Structure

```
03-services/05-service-discovery/
├── README.md
├── src/
│   ├── 01-backend-namespace.yaml    # Namespace + deployment + service
│   ├── 02-frontend-namespace.yaml   # Namespace + deployment
│   └── break-fix/
│       ├── 01-dnspolicy-none-broken.yaml       # Embedded inline in README — not generated on disk
│       └── 02-corefile-syntax-error.yaml       # Embedded inline in README — not generated on disk
├── 05-service-discovery-anki.csv
└── 05-service-discovery-quiz.md
```

---

## Recall Check — 04-headless

Answer from memory before continuing — no peeking at the previous demo.

1. What's the difference between `clusterIP: None` and `clusterIP: ""`?
2. Does StatefulSet give pods a stable IP address?
3. Is `spec.serviceName` validated against a real, existing Service at apply time?

<details>
<summary>Answers</summary>

1. `None` explicitly creates a headless Service; `""` (empty string) means auto-assign a normal ClusterIP — identical to omitting the field entirely.
2. No — pod IPs stay ephemeral; StatefulSet gives a stable *name*, and a headless Service's DNS record is what stays current as the IP changes.
3. No — a typo or nonexistent target still lets the StatefulSet and its pods create successfully; only per-pod DNS resolution silently fails.

</details>

---

## Concepts

### DNS Naming Format

Every Service gets a DNS name in this format:

```
<service-name>.<namespace>.svc.<cluster-domain>

Examples:
  backend-svc.default.svc.cluster.local
  database-svc.production.svc.cluster.local
  redis.caching.svc.cluster.local
```

**Short name resolution — how it works:**

When a pod uses a short name like `backend-svc`, CoreDNS and the
resolver try the search domains in `/etc/resolv.conf`:

```
Short name: backend-svc
Search domains: default.svc.cluster.local svc.cluster.local cluster.local

Attempts:
  1. backend-svc.default.svc.cluster.local → found → return IP ✅

If not found, tries next:
  2. backend-svc.svc.cluster.local
  3. backend-svc.cluster.local
  4. backend-svc (external DNS)
```

---

### /etc/resolv.conf — The Key to DNS

Every pod gets an `/etc/resolv.conf` injected by Kubernetes:

```
nameserver 10.96.0.10         ← CoreDNS IP
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

```
nameserver  → CoreDNS IP — all DNS queries go here first

search      → search domain list — appended to short names
              default.svc.cluster.local → for services in same namespace
              svc.cluster.local         → for services in any namespace
              cluster.local             → for cluster-scoped names

ndots:5     → if name has fewer than 5 dots, try search domains first
              "backend-svc" has 0 dots < 5 → try search domains first
              "www.google.com" has 2 dots < 5 → try search domains first
              "a.b.c.d.e.f" has 5 dots → query directly, no search domains
```
> This is the complete mechanics behind what `01-clusterip-nodeport`
> showed you without fully explaining — that demo's own "Test 4" walked
> through this same file with a one-line summary and a promise to cover
> it here in full.

---

### CoreDNS Architecture

```
CoreDNS runs as a Deployment in kube-system namespace:
  kubectl get pods -n kube-system | grep coredns

Service: kube-dns (ClusterIP: 10.96.0.10)
  → stable IP — all pods use this as their nameserver

Configuration: ConfigMap coredns in kube-system
  → Corefile format — defines DNS plugins and behaviour
```

**Key CoreDNS plugins:**

```
kubernetes  → serves DNS for Kubernetes services and pods
              handles: *.svc.cluster.local, *.pod.cluster.local

forward     → forwards non-cluster DNS to node's /etc/resolv.conf
              handles: google.com, internal.company.com etc.

cache       → caches DNS responses (TTL 30s default for cluster DNS)

loadbalance → randomizes order of A/AAAA records for headless services
              — this is exactly the mechanism behind the multiple-A-record
              behavior `04-headless` demonstrated

reload      → watches the coredns ConfigMap and reloads automatically
              on changes — this demo's Break-Fix Error-2 puts this to
              the test directly
```

---

### Service Environment Variables

Kubernetes also injects environment variables into pods for every
service that exists when the pod starts:

```
{SVCNAME}_SERVICE_HOST  → ClusterIP of the service
{SVCNAME}_SERVICE_PORT  → port of the service
```

For a service named `backend-svc` with ClusterIP 10.96.74.12 on port 9090:

```
BACKEND_SVC_SERVICE_HOST=10.96.74.12
BACKEND_SVC_SERVICE_PORT=9090
```

**Important limitation:** These variables are only injected for services
that exist BEFORE the pod starts. Services created after the pod starts
are NOT in the environment. This is why DNS is preferred over environment
variables for service discovery.

---

### DNS Policies

```
ClusterFirst (default):
  → DNS queries go to CoreDNS first
  → cluster services resolved by CoreDNS
  → non-cluster names forwarded to upstream DNS

Default:
  → pod inherits DNS config from the node
  → CoreDNS is NOT the nameserver
  → useful for pods that should use node DNS (infrastructure pods)

ClusterFirstWithHostNet:
  → for pods running with hostNetwork: true
  → normally, hostNetwork pods would otherwise behave like Default
    (since sharing the node's own network namespace changes what DNS
    config they'd inherit) — this policy explicitly forces ClusterFirst
    behavior anyway, so a hostNetwork pod can still resolve cluster
    service names
  → without this, a hostNetwork pod needing to reach a Service by name
    would silently fail to resolve it, the same NXDOMAIN signature as
    Default further down

None:
  → no DNS config injected at all
  → must supply dnsConfig manually in pod spec — nameservers, searches,
    options all become entirely your own responsibility
  → useful for custom DNS configurations, but this demo's Break-Fix
    Error-1 shows exactly what happens when that manual config is wrong
```

---

## Lab Step-by-Step Guide

By the end of this walkthrough you'll have two Deployments in two
separate namespaces, and use that separation specifically to probe DNS
resolution — same-namespace short names, cross-namespace qualified
names, full FQDNs, CoreDNS's own Corefile, service environment
variables, and all four DNS policies. Steps 1–4 build the setup and
explore standard resolution; Step 4b resolves a pod directly; Steps
5–7 cover environment variables, DNS policies, and systematic debugging.

### Step 1: Setup — Deploy Services in Separate Namespaces

This step's only role is creating two namespaces to resolve *across* —
none of the objects themselves are new; every field here was already
covered in `01-clusterip-nodeport` and `02-deployments`. The genuinely
new content in this demo starts in Step 2.

```bash
cd 03-services/05-service-discovery/src
```

#### Backend Namespace, Deployment, and Service

Everything backend-related lives in its own namespace (`backend-ns`) —
the separation Step 3's cross-namespace resolution test depends on.

**`01-backend-namespace.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: backend-ns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deploy
  namespace: backend-ns
spec:
  replicas: 2
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
            - "-text=Hello from backend-ns"
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
  name: backend-svc
  namespace: backend-ns
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

#### Frontend Namespace and Deployment

The counterpart namespace (`frontend-ns`) — this one deliberately has no
Service yet, since Step 3's tests reach the backend *from* a pod here.

**`02-frontend-namespace.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: frontend-ns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-deploy
  namespace: frontend-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: frontend
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

```bash
kubectl apply -f 01-backend-namespace.yaml
kubectl apply -f 02-frontend-namespace.yaml

kubectl rollout status deployment/backend-deploy -n backend-ns
kubectl rollout status deployment/frontend-deploy -n frontend-ns

kubectl get svc -n backend-ns
kubectl get pods -n frontend-ns
```

**Expected output:**
```
NAME          TYPE        CLUSTER-IP      PORT(S)
backend-svc   ClusterIP   10.96.xxx.xxx   5678/TCP
```

---

### Step 2: Inspect /etc/resolv.conf

This step is where the demo's actual new content begins — reading the
DNS configuration every pod gets, in full, past the one-line summary
`01-clusterip-nodeport` gave it.

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -n frontend-ns -- bash
```

Inside the pod:
```bash
cat /etc/resolv.conf
```
**Expected output:**
```
search frontend-ns.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```
```
search domains reflect the pod's namespace (frontend-ns) ✅
nameserver 10.96.0.10 = CoreDNS ✅
ndots:5 → short names tried against search domains first
```

Exit:
```bash
exit
```

---

### Step 3: Cross-Namespace DNS Resolution

This step proves the search-domain mechanic from Step 2 directly — the
same short name that works inside a pod's own namespace fails across a
namespace boundary, and this shows exactly why, plus the two forms that
do work.

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -n frontend-ns -- bash
```

**Test 1 — Short name (same namespace) — will FAIL:**
```bash
curl backend-svc:5678
```
**Expected output:**
```
curl: (6) Could not resolve host: backend-svc
```
```
Short name backend-svc expanded to:
  backend-svc.frontend-ns.svc.cluster.local → NOT FOUND
  (service is in backend-ns, not frontend-ns)
```

**Test 2 — Namespace-qualified name — will SUCCEED:**
```bash
curl backend-svc.backend-ns:5678
```
**Expected output:**
```
Hello from backend-ns
```
```
backend-svc.backend-ns expanded to:
  backend-svc.backend-ns.svc.cluster.local → FOUND ✅
```

**Test 3 — Full FQDN — always works:**
```bash
curl backend-svc.backend-ns.svc.cluster.local:5678
```
**Expected output:**
```
Hello from backend-ns
```

**Test 4 — Verify with nslookup:**
```bash
nslookup backend-svc.backend-ns
```
**Expected output:**
```
Name:   backend-svc.backend-ns.svc.cluster.local
Address: 10.96.xxx.xxx
```

Exit:
```bash
exit
```

---

### Step 4: Inspect CoreDNS Configuration

Steps 2–3 showed DNS resolution *working* — this step looks at the
actual server making those decisions: CoreDNS's own configuration,
the ConfigMap-backed Corefile driving everything you've observed so far.

```bash
kubectl describe configmap coredns -n kube-system
```

**Expected output:**
```
Name:         coredns
Namespace:    kube-system
Data
====
Corefile:
----
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

**Explanation of key sections:**
```
kubernetes cluster.local ...:
  → handles all *.cluster.local DNS queries
  → TTL 30 seconds — how long responses are cached
  → pods insecure → enables pod DNS (pod-ip.namespace.pod.cluster.local)

forward . /etc/resolv.conf:
  → non-cluster queries (google.com, etc.) forwarded to node DNS
  → max_concurrent 1000 → limits concurrent external DNS requests

cache 30:
  → caches responses for 30 seconds
  → reduces load on CoreDNS for repeated queries

loadbalance:
  → randomizes A/AAAA record order for headless services — the exact
    mechanism behind 04-headless's multi-A-record DNS responses
```

Verify CoreDNS pods are healthy:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```
**Expected output:**
```
NAME                       READY   STATUS    RESTARTS
coredns-xxxxxxxxx-xxxxx    1/1     Running   0
coredns-xxxxxxxxx-yyyyy    1/1     Running   0
```
Two CoreDNS pods for redundancy. ✅

---

### Step 4b: Resolve a Pod Directly by DNS — Not Just Services

Everything so far has resolved **Service** names. The Corefile's
`kubernetes` plugin block above also enables `pods insecure` — a
separate, less-used capability: resolving an **individual pod** by DNS,
identified by its IP, not by going through any Service at all.

```bash
# Get a backend pod's IP
kubectl get pods -n backend-ns -o wide
```
**Expected output (note the IP, e.g. 10.244.1.23):**
```
NAME                              READY   STATUS    IP
backend-deploy-xxxxxxxxx-aaaaa    1/1     Running   10.244.1.23
```

The pod-DNS format replaces every `.` in the IP with a `-`:

```
<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>

10.244.1.23 → 10-244-1-23.backend-ns.pod.cluster.local
```

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- nslookup 10-244-1-23.backend-ns.pod.cluster.local
```
**Expected output:**
```
Name:   10-244-1-23.backend-ns.pod.cluster.local
Address: 10.244.1.23
```

**Why this exists, and why you'll rarely reach for it directly:** pod IPs
are ephemeral (`01-core-concepts`) — this DNS record only stays valid as
long as that specific pod does, which makes it far less useful on its own
than Service-based discovery. Where it actually matters is as
**infrastructure**, not something applications typically call directly:
this is the exact mechanism a headless Service's multi-A-record response
(`04-headless`) is built from — CoreDNS resolving each backing pod's own
record is what a headless Service's DNS answer actually assembles under
the hood.

---

### Step 5: Service Environment Variables

Create a pod AFTER services exist and inspect the injected variables:

```bash
# Deploy a service in default namespace
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-svc
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: demo
  ports:
    - port: 8080
      targetPort: 8080
EOF

# Create a pod AFTER the service exists
kubectl run env-test --image=busybox:1.38.0 --restart=Never -- sleep 3600

kubectl exec env-test -- env | grep -i demo
```
**Expected output:**
```
DEMO_SVC_SERVICE_HOST=10.96.xxx.xxx
DEMO_SVC_SERVICE_PORT=8080
```
```
DEMO_SVC_SERVICE_HOST → ClusterIP of demo-svc
DEMO_SVC_SERVICE_PORT → port 8080
Variables are UPPERCASED with dashes → underscores
Only injected for services that existed when pod STARTED
```

Create a second service AFTER the pod started:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: new-svc
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: new
  ports:
    - port: 9090
      targetPort: 9090
EOF

kubectl exec env-test -- env | grep -i new
```
**Expected output:**
```
(no output)
```
```
new-svc was created AFTER env-test pod started
→ environment variables NOT injected ❌
→ this is why DNS is preferred over environment variables
→ DNS always works regardless of when the service was created
```

```bash
kubectl delete pod env-test --grace-period=0 --force
kubectl delete svc demo-svc new-svc
```

---

### Step 6: DNS Policies

This step applies the `dnsPolicy` values from Concepts above to real
pods — confirming `ClusterFirst` (the default) resolves cluster names
and `Default` (confusingly named) doesn't.

```bash
# Default policy (ClusterFirst) — CoreDNS is the nameserver
kubectl run dns-default --image=nicolaka/netshoot --rm -it --restart=Never -- bash
```
```bash
cat /etc/resolv.conf
# Shows CoreDNS (10.96.0.10) as nameserver
nslookup kubernetes.default
# Resolves to kubernetes API server ClusterIP
exit
```

**Pod with dnsPolicy: Default — inherits node DNS:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dns-node-policy
spec:
  dnsPolicy: Default
  terminationGracePeriodSeconds: 0
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "50m"
          memory: "32Mi"
        limits:
          cpu: "100m"
          memory: "64Mi"
EOF

kubectl exec dns-node-policy -- cat /etc/resolv.conf
```
**Expected output:**
```
# Node's DNS config — NOT CoreDNS
nameserver 8.8.8.8   (or whatever the node uses)
(no search domains for cluster.local)
```
```bash
kubectl exec dns-node-policy -- nslookup kubernetes.default
```
**Expected output:**
```
** server can't find kubernetes.default: NXDOMAIN
```
```
dnsPolicy: Default → node DNS → cannot resolve cluster service names ❌
Use only for infrastructure pods that should not use cluster DNS
```

```bash
kubectl delete pod dns-node-policy --grace-period=0 --force
```

> `dnsPolicy: None` isn't demonstrated here since it requires supplying a
> complete, correct `dnsConfig` yourself — see this demo's Break-Fix
> Error-1 for exactly what happens when that manual configuration is
> wrong, since a *working* `None` example would just look identical to
> `ClusterFirst` if you simply pointed `dnsConfig` back at CoreDNS.
>
> `ClusterFirstWithHostNet` also isn't demonstrated hands-on here — it
> only matters for a pod with `hostNetwork: true`, which this chapter
> hasn't introduced. Know it exists and what problem it solves (a
> hostNetwork pod that still needs to resolve cluster Service names) —
> full hands-on treatment fits better alongside `hostNetwork` itself in
> a future demo.

---

### Step 7: Debug DNS Resolution

Systematic DNS debugging approach:

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash
```
```bash
# Step 1: Verify CoreDNS is reachable
nslookup kubernetes.default

# Step 2: Check if specific service resolves
nslookup backend-svc.backend-ns

# Step 3: Check full FQDN
nslookup backend-svc.backend-ns.svc.cluster.local

# Step 4: Check external DNS works
nslookup google.com

# Step 5: Check CoreDNS directly
dig @10.96.0.10 backend-svc.backend-ns.svc.cluster.local

# Step 6: Check /etc/resolv.conf
cat /etc/resolv.conf
```

**Common DNS failure patterns:**
```
NXDOMAIN for service name:
  → Wrong namespace (use: svc.namespace format)
  → Service does not exist (kubectl get svc -n <ns>)
  → Service has no matching pods (kubectl get endpoints)

NXDOMAIN for all names including kubernetes.default:
  → CoreDNS pods not running (kubectl get pods -n kube-system)
  → Pod dnsPolicy is not ClusterFirst (or ClusterFirstWithHostNet
    for a hostNetwork pod)

Timeout:
  → CoreDNS pods overloaded or crashing — see this demo's Break-Fix
    Error-2 for one concrete way this happens
  → Network policy blocking port 53 to CoreDNS
```

Exit:
```bash
exit
```

---

### Step 8: Final Cleanup

Tear down both namespaces — deleting a namespace cascades to everything
inside it (per `01-core-concepts`), so this alone removes every
Deployment, Service, and Pod created in Steps 1–7.

```bash
kubectl delete -f 01-backend-namespace.yaml
kubectl delete -f 02-frontend-namespace.yaml

kubectl get namespaces | grep -E "frontend-ns|backend-ns"
kubectl get pods -n default
```

---

## What You Learned

In this lab, you:
- ✅ Explained the full DNS naming format for Kubernetes services
- ✅ Read `/etc/resolv.conf` and explained search domains and `ndots:5` in full — resolving what `01-clusterip-nodeport` deferred
- ✅ Successfully resolved services across namespaces using `svc.namespace` format
- ✅ Inspected CoreDNS Corefile configuration and every key plugin
- ✅ Resolved an individual pod directly by DNS (`pods insecure`), and connected that mechanism to `04-headless`'s multi-A-record behavior
- ✅ Observed service environment variables and their pod-start-time-only limitation
- ✅ Applied `dnsPolicy: Default` and observed it breaks cluster DNS resolution
- ✅ Understood `dnsPolicy: None`'s manual-configuration requirement, and `ClusterFirstWithHostNet`'s narrower hostNetwork-specific purpose
- ✅ Followed a systematic DNS debugging approach

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1 — "A pod can't resolve anything, cluster or external"

**The scenario:** a pod was deliberately given a fully custom DNS
configuration (`dnsPolicy: None`) for a specialized use case, but now
*nothing* resolves from inside it — not cluster Service names, not
external hostnames either. Investigate what's actually configured.

**`src/break-fix/01-dnspolicy-none-broken.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-none-broken
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:
      - "10.96.0.99"   # wrong — real CoreDNS is at 10.96.0.10
    searches:
      - default.svc.cluster.local
    options:
      - name: ndots
        value: "5"
  terminationGracePeriodSeconds: 0
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "3600"]
```

```bash
kubectl apply -f 01-dnspolicy-none-broken.yaml
kubectl exec dns-none-broken -- cat /etc/resolv.conf
kubectl exec dns-none-broken -- nslookup kubernetes.default
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `dnsPolicy: None` means Kubernetes injects **nothing** on your
behalf — every field in `dnsConfig` is entirely your responsibility. Here,
`nameservers` points at `10.96.0.99`, which is not CoreDNS's real address
(`10.96.0.10`) — nothing is listening there, so every DNS query times out
or fails outright.

**Fix:** Correct `dnsConfig.nameservers` to `10.96.0.10`, or (more
robustly) don't use `None` at all unless you have a genuine reason to
fully own DNS config — `ClusterFirst` already does the right thing by
default.

**Cascade:** Unlike `dnsPolicy: Default` (Step 6), where node DNS at
least resolves *external* names correctly while failing only cluster
names, this failure mode breaks **everything** — cluster names and
external names alike — since the nameserver itself is simply wrong, not
just pointed at a different (but valid) resolver.

</details>

**Cleanup:**
```bash
kubectl delete pod dns-none-broken --grace-period=0 --force 2>/dev/null || true
```

---

### Error-2 — "Every pod in the cluster suddenly lost DNS at once"

**The scenario:** something changed recently, and now *every* pod
cluster-wide — not just one namespace or one Service — is failing every
DNS lookup, cluster and external names alike. This is a fundamentally
different scale of symptom from anything else in this chapter — track
down what's actually different.

This scenario is self-contained — it acts directly on the cluster-wide
`coredns` ConfigMap, no main-lab resources required.

```bash
kubectl edit configmap coredns -n kube-system
```
Introduce a deliberate syntax error into the Corefile — add a stray,
unmatched closing brace `}` right after the `kubernetes cluster.local
in-addr.arpa ip6.arpa {` block. Save and exit, then:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -w
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The `reload` plugin (from Concepts above) watches the
`coredns` ConfigMap and triggers CoreDNS to reload its config on change —
but it doesn't validate the new Corefile *before* attempting to load it.
An invalid Corefile causes CoreDNS to fail on startup, so the running
pods crash and restart into `CrashLoopBackOff` once the reload picks up
the bad config.

**Fix:** `kubectl edit configmap coredns -n kube-system` again and remove
the stray brace, restoring valid syntax. CoreDNS pods recover
automatically once a valid config is available — the same self-healing
reconciliation pattern from every previous chapter, just triggered by a
config error instead of a deleted object.

**Cascade:** This is the most severe scenario in this entire chapter's
Break-Fix content — while CoreDNS pods are crash-looping, **every pod in
the entire cluster** loses DNS resolution simultaneously, not just one
namespace or one Service. This is exactly why the "Timeout" failure
pattern in Step 7's debugging guide exists as its own category, distinct
from a single Service's `NXDOMAIN` — a cluster-wide DNS outage looks and
feels completely different from an individual Service misconfiguration.

</details>

**Cleanup:** ensure the Corefile is restored to valid syntax; CoreDNS pods will recover on their own once it is.

---

## Interview Prep

**Q: What is the CoreDNS service IP, and how would you find it if you forgot?**
A: `10.96.0.10` in this cluster, as the `kube-dns` Service in `kube-system` — but rather than memorizing it, `kubectl get svc kube-dns -n kube-system` or just reading any pod's own `/etc/resolv.conf` gives you the authoritative answer for that specific cluster.

**Q: Why does `ndots:5` exist?**
A: It controls when search domains are tried before querying a name as-is. Short names like `backend-svc` (0 dots) go through all search domains first — without this, short cluster-internal names would be sent directly to external DNS and fail before ever trying the cluster's own search domains.

**Q: Why is DNS preferred over service environment variables for discovery?**
A: Environment variables are injected once at pod creation and never updated — a service created after the pod starts is invisible to it entirely. DNS always reflects current state, regardless of when anything was created.

**Q: If `dnsPolicy: Default` breaks cluster DNS, why does it exist at all?**
A: It's specifically for infrastructure pods that need the *node's* DNS resolution rather than cluster DNS — CoreDNS pods themselves are a common example, since they can't sensibly use themselves as their own upstream resolver.

**Q: What's the practical risk of `dnsPolicy: None`?**
A: You own every part of DNS resolution yourself — `nameservers`, `search`, `ndots`, all of it. Get any of it wrong (this demo's Break-Fix Error-1) and nothing is auto-corrected or falls back to a sane default the way `ClusterFirst` would.

**Q: A pod runs with `hostNetwork: true` and needs to resolve cluster Service names. What DNS policy does it need?**
A: `ClusterFirstWithHostNet` — sharing the node's network namespace changes what DNS config a pod would otherwise inherit, so this policy exists specifically to force `ClusterFirst`-style resolution back on for that case. Without it, the pod would fail to resolve cluster Service names, the same NXDOMAIN pattern `Default` produces.

**Q: A single Service returns NXDOMAIN, but `nslookup kubernetes.default` works fine. What does that narrow down?**
A: CoreDNS itself is healthy and reachable — the problem is specific to that one Service: wrong namespace in the query, the Service doesn't exist, or it exists but has no matching Ready pods. This is different from every name failing, which points at CoreDNS itself or the pod's `dnsPolicy`.

**Q: Can you resolve an individual pod by DNS without going through a Service at all?**
A: Yes — the `pods insecure` CoreDNS option enables `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>`. It's rarely used directly by applications, since pod IPs (and therefore these records) are ephemeral, but it's the actual mechanism a headless Service's multi-A-record DNS response is built from.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | DNS naming format, cross-namespace resolution, CoreDNS internals |
| Troubleshooting | CKA | 30% | Systematic DNS debugging, distinguishing failure patterns |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Forgetting cross-namespace requires at least `svc.namespace` | Short names only resolve within the pod's own namespace — a very common exam-task gotcha |
| Confusing `dnsPolicy: Default` with "the default policy" | Confusingly named — `ClusterFirst` is actually the default; `Default` means "use the node's DNS," a completely different thing |
| Forgetting `ClusterFirstWithHostNet` exists | A `hostNetwork: true` pod using plain `ClusterFirst` may not resolve cluster names the way you'd expect — this is the policy built for that case |
| Assuming service env vars are always current | They're a snapshot at pod-start time only — stale the moment a relevant Service changes afterward |
| Not distinguishing single-name NXDOMAIN from total DNS failure | Different root causes entirely — one Service issue vs. CoreDNS itself being down |
| Assuming `dnsPolicy: None` needs no configuration | It needs the *most* configuration of the four policies — nothing is injected automatically |
| Forgetting the pod-DNS format uses dashes, not dots | `10.244.1.23` becomes `10-244-1-23`, not left as-is — a syntax detail easy to get backwards |

### Exam Task — Write it from scratch

A pod in namespace `app-a` needs to reach a Service `db-svc` in namespace `app-b` on port 5432. Write the correct connection string using each of the three valid forms (short-with-namespace, and full FQDN), and explain why the bare short name `db-svc` would fail.

Official docs: [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)

<details>
<summary>Reveal solution</summary>

```
db-svc.app-b:5432
db-svc.app-b.svc.cluster.local:5432
```

The bare `db-svc` fails because the pod's own search domains only
include `app-a.svc.cluster.local` (its own namespace) — CoreDNS never
even gets a query for `db-svc.app-b...` unless the namespace is included
explicitly.

**Key fields/commands to recall:** the DNS name format
`<service>.<namespace>.svc.<cluster-domain>`, and that each pod's
`/etc/resolv.conf` search list is namespace-specific.

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| DNS names follow a fixed format | `<service>.<namespace>.svc.<cluster-domain>` — every part matters for cross-namespace resolution |
| `ndots:5` decides whether search domains are tried first | Fewer dots than `ndots` → search domains tried before the name is queried as-is externally |
| CoreDNS is just another Deployment, reachable at a stable ClusterIP | `kube-dns` in `kube-system`, `10.96.0.10` in this cluster |
| The `reload` plugin doesn't validate before reloading | A syntax error in the Corefile ConfigMap crashes CoreDNS cluster-wide, not gracefully rejected |
| Service env vars are a stale snapshot, DNS is always current | Env vars only exist for Services that existed before the pod started; DNS has no such limitation |
| `dnsPolicy: Default` is confusingly named | It means "use the node's DNS," not "the default policy" — `ClusterFirst` is actually the default |
| `dnsPolicy: ClusterFirstWithHostNet` exists for `hostNetwork: true` pods | Forces `ClusterFirst`-style cluster-name resolution back on for a case that would otherwise silently lose it |
| `dnsPolicy: None` means total manual ownership of DNS config | Nothing injected automatically — get `dnsConfig` wrong and nothing falls back gracefully |
| A single-name NXDOMAIN and total DNS failure have different causes | One points at a specific Service/namespace mistake; the other points at CoreDNS itself being down |
| Individual pods can be resolved by DNS directly, not just Services | `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>`, enabled by `pods insecure` — rarely used directly, but the actual mechanism behind headless-Service multi-A-record answers |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get svc kube-dns -n kube-system` | Show CoreDNS service and ClusterIP |
| `kubectl get pods -n kube-system -l k8s-app=kube-dns` | Check CoreDNS pods |
| `kubectl describe configmap coredns -n kube-system` | Inspect CoreDNS Corefile |
| `nslookup <svc>` | Resolve service (from inside pod) |
| `nslookup <svc>.<namespace>` | Cross-namespace resolution |
| `dig @10.96.0.10 <fqdn>` | Query CoreDNS directly |
| `cat /etc/resolv.conf` | Check search domains and nameserver |

---

## Troubleshooting

**Service name not resolving:**
```bash
# Check service exists
kubectl get svc <name> -n <namespace>
# Check you are using correct namespace in name
nslookup <svc>.<correct-namespace>
# Check pods are ready
kubectl get pods -l <selector> -n <namespace>
```

**CoreDNS not working:**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
# Check CoreDNS service
kubectl get svc kube-dns -n kube-system
```

**External DNS not resolving:**
```bash
# Check forward plugin in CoreDNS Corefile
kubectl describe configmap coredns -n kube-system
# Check node's resolv.conf
minikube ssh -p 3node "cat /etc/resolv.conf"
```

---

## Appendix — Anki Cards

**`05-service-discovery-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::05-service-discovery
#separator:Comma
#columns:Front,Back,Tags
"What is the fixed DNS name format for a Kubernetes Service?","<service-name>.<namespace>.svc.<cluster-domain>","demo05-services,dns,cka-services-networking"
"What does ndots:5 actually control?","Whether search domains are tried before querying a name as-is — fewer dots than 5 means search domains get tried first","demo05-services,dns,ndots,cka-services-networking"
"Why does a bare short service name fail across namespaces?","The pod's search domains only include its OWN namespace — CoreDNS never even receives a query for the other namespace's version unless it's included explicitly","demo05-services,dns,cross-namespace,cka-services-networking"
"Does the CoreDNS reload plugin validate a new Corefile before applying it?","No — an invalid Corefile crashes CoreDNS on reload rather than being rejected gracefully","demo05-services,coredns,cka-troubleshooting"
"Are Service environment variables always current?","No — only injected for Services that existed before the pod started; DNS is always current by comparison","demo05-services,service-env-vars,cka-services-networking"
"Is dnsPolicy: Default actually the default policy?","No, confusingly — ClusterFirst is the actual default; Default means the pod uses the NODE's DNS instead of CoreDNS","demo05-services,dns-policy,cka-services-networking"
"What does dnsPolicy: None require that the other policies don't?","A fully manual dnsConfig — nameservers, search domains, and options are all your own responsibility, nothing is injected automatically","demo05-services,dns-policy,cka-services-networking"
"What problem does dnsPolicy: ClusterFirstWithHostNet solve?","A pod running with hostNetwork: true would otherwise lose cluster-name resolution — this policy forces ClusterFirst-style behavior back on for that case","demo05-services,dns-policy,hostnetwork,cka-services-networking"
"A single Service name returns NXDOMAIN, but nslookup kubernetes.default works. What does that narrow down?","CoreDNS itself is healthy — the problem is specific to that Service: wrong namespace, doesn't exist, or no Ready pods","demo05-services,troubleshooting,cka-troubleshooting"
"What's the blast radius when CoreDNS itself crashes vs. when a single Service is misconfigured?","CoreDNS crashing breaks DNS resolution for the entire cluster simultaneously; a single Service misconfiguration only affects that one Service's name","demo05-services,coredns,cka-troubleshooting"
"What CoreDNS plugin handles non-cluster DNS queries like google.com?","forward — forwards them to the node's own /etc/resolv.conf","demo05-services,coredns,cka-services-networking"
"What does the CoreDNS cache plugin do, and what's its default TTL for cluster DNS?","Caches DNS responses to reduce repeated load on CoreDNS — 30 seconds by default in the standard Corefile","demo05-services,coredns,cka-services-networking"
"What does the CoreDNS loadbalance plugin do?","Randomizes the order of A/AAAA records in a response — this is the actual mechanism behind headless Services returning pod IPs in a different order each query","demo05-services,coredns,headless,cka-services-networking"
"What's the DNS format for resolving an individual pod directly, without a Service?","<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain> — e.g. 10.244.1.23 becomes 10-244-1-23.backend-ns.pod.cluster.local","demo05-services,dns,pod-dns,cka-services-networking"
````

---

## Appendix — Quiz

**`05-service-discovery-quiz.md`:**

````markdown
# Quiz — 03-services/05-service-discovery: Service Discovery and CoreDNS

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. A pod in `frontend-ns` has `search frontend-ns.svc.cluster.local svc.cluster.local cluster.local` in its `/etc/resolv.conf`. Would this pod's search domains ever let a bare short name resolve a Service sitting in `backend-ns`?**

- A) Yes — `svc.cluster.local` matches any namespace
- B) No — none of these three search domains include `backend-ns` at all; only `backend-svc.backend-ns` or the full FQDN would work
- C) Yes, but only on the second DNS attempt
- D) Only if `ndots` is set to a lower value

<details>
<summary>Answer</summary>

**B** — Every search domain listed is scoped to the pod's own namespace or the cluster generally — none of them contain `backend-ns` as a suffix, so a bare `backend-svc` query can never land there.
Trap: A misreads `svc.cluster.local` as a wildcard across all namespaces, when it actually just strips the namespace segment, requiring the namespace to already be part of the query.

</details>

---

**Q2. Service environment variables follow a fixed naming transform — e.g. a Service named `demo-svc` produces `DEMO_SVC_SERVICE_HOST`. What's the transform applied to the Service name itself?**

- A) Lowercased, dashes kept as-is
- B) Uppercased, and dashes converted to underscores
- C) Reversed and uppercased
- D) Left exactly as written, with `_SERVICE_HOST` appended

<details>
<summary>Answer</summary>

**B** — `demo-svc` becomes `DEMO_SVC` before the suffix is appended — both the case change and the dash-to-underscore substitution are necessary to get a valid environment variable name.
Trap: D ignores that a bare hyphenated name isn't even a legal shell/environment variable identifier — the transform is required, not cosmetic.

</details>

---

**Q3. The Exam Task asks for three valid ways to reach `db-svc` in namespace `app-b` from a pod in `app-a`. The bare short name `db-svc` fails — what are the two forms that do work?**

- A) `db-svc.svc.cluster.local` and `db-svc.local`
- B) `db-svc.app-b` (namespace-qualified) and `db-svc.app-b.svc.cluster.local` (full FQDN)
- C) `app-b.db-svc` and `db-svc:app-b`
- D) Only the full FQDN works; there is no shorter valid form

<details>
<summary>Answer</summary>

**B** — Namespace-qualified and full-FQDN are the two forms this demo's Step 3 actually demonstrates succeeding, in that order of increasing explicitness.
Trap: C inverts the correct ordering of name components — this demo's DNS format always goes `<service>.<namespace>`, never the reverse.

</details>

---

**Q4. Why is `kubernetes.default` specifically a good "control" lookup when debugging DNS, rather than any other cluster name?**

- A) It's the only Service DNS can resolve reliably
- B) It's a core, always-present Service in every cluster — if it resolves, CoreDNS itself and the pod's own DNS policy are both confirmed healthy, isolating the problem to whatever specific name failed
- C) It resolves faster than any other Service name
- D) It's the only name that works under `dnsPolicy: None`

<details>
<summary>Answer</summary>

**B** — Its near-universal presence is exactly what makes it useful as a baseline — a working `kubernetes.default` lookup rules out whole categories of failure (CoreDNS down, wrong `dnsPolicy`) at once.
Trap: D invents a special exemption for this one name under `None`, when `None` actually requires manual `dnsConfig` regardless of which name you're resolving.

</details>

---

**Q5. Step 7's systematic debugging sequence starts with `nslookup kubernetes.default` before checking a specific failing Service name. Why start there instead of jumping straight to the actual problem Service?**

- A) It's required by `kubectl` — you cannot query a custom Service name first
- B) It establishes whether the failure is cluster-wide (CoreDNS/policy) or scoped to one Service, before spending effort narrowing further
- C) `kubernetes.default` must always be queried once per debugging session for caching reasons
- D) It has no real purpose beyond habit

<details>
<summary>Answer</summary>

**B** — This ordering is deliberate triage: confirm the baseline works before assuming the problem is specific to one Service, narrowing the search space efficiently.
Trap: C invents a caching-related requirement that has nothing to do with why this step is first.

</details>

---

**Q6. CoreDNS's `pods insecure` option is what enables resolving an individual pod directly by DNS. What does the word "insecure" actually flag about this capability?**

- A) That the connection to the resolved pod is unencrypted
- B) That it only allows resolving your own pod's IP, not others
- C) The demo doesn't specify — but naming aside, it's what enables the `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>` format used in Step 4b
- D) That pod DNS records expire after exactly 30 seconds

<details>
<summary>Answer</summary>

**C** — This demo names the option and shows what it enables (pod-level DNS records) without going into what "insecure" specifically implies beyond that — worth not inventing a confident answer the material doesn't actually give.
Trap: A and D both assert specific mechanisms the demo never actually states — recognizing what's genuinely covered vs. not is part of this question.

</details>

---

**Q7. Step 1 creates a Service for the backend namespace but deliberately does NOT create one for the frontend namespace. Why?**

- A) Frontend pods don't need a stable address in this demo
- B) Every cross-namespace test in Steps 3–4 reaches the backend *from* a frontend pod — the frontend side only ever needs to be the caller, never something resolved by name itself
- C) It was an oversight later fixed in `06-loadbalancer-traffic-policies`
- D) Namespaces can only contain one Service each

<details>
<summary>Answer</summary>

**B** — The entire test direction in this demo is frontend-pod-calls-backend-Service — nothing in Steps 2–7 ever needs to resolve anything living in `frontend-ns` by name.
Trap: D states an incorrect and easily-disprovable constraint — namespaces have no such limit, and this series' own earlier demos have shown multiple Services per namespace repeatedly.

</details>

---

**Q8. The Corefile shown in Step 4 includes both a `cache 30` line and a `forward . /etc/resolv.conf` line. If a pod queries `google.com`, which of these two plugins actually handles it, and does the other apply at all?**

- A) Only `forward` applies — `cache` only works for cluster-internal names
- B) `forward` sends the query to the node's own DNS; `cache` still applies afterward, caching that external response for repeated queries too
- C) Neither applies to external names — only the `kubernetes` plugin does
- D) `cache` intercepts the query before `forward` ever sees it, blocking external resolution

<details>
<summary>Answer</summary>

**B** — `forward` is what actually routes non-cluster names outward, but `cache`'s 30-second caching isn't scoped only to cluster-internal answers — it applies to whatever CoreDNS resolves, external names included.
Trap: A assumes caching is cluster-only, but nothing in the Corefile scopes `cache` that narrowly — it sits in the general plugin chain, applying broadly.

</details>

---

**Q9. This demo distinguishes a single Service's NXDOMAIN from CoreDNS crashing entirely (Break-Fix Error-2). Structurally, why does a Corefile syntax error cause a cluster-wide outage rather than just breaking DNS for the Service you happened to be querying?**

- A) Because CoreDNS itself is what crashes and restarts — every pod in the cluster depends on the same handful of CoreDNS pods, not per-Service instances
- B) Because the syntax error only affects Services in the `default` namespace
- C) Because `kube-proxy` also crashes when CoreDNS's config is invalid
- D) It doesn't actually cause a cluster-wide outage — only Services created after the edit are affected

<details>
<summary>Answer</summary>

**A** — There's no per-Service DNS process — every pod cluster-wide shares the same small set of CoreDNS pods as its nameserver, so those pods crash-looping takes down resolution for everyone simultaneously, regardless of namespace or which Service anyone happens to be querying.
Trap: B invents a namespace-scoped blast radius that doesn't match how CoreDNS actually serves the whole cluster from one shared set of pods.

</details>

---

**Q10. This demo's own Interview Prep states pod-level DNS records are "rarely used directly by applications." What's the actual justification given for why, despite the capability existing?**

- A) It requires special RBAC permissions most applications don't have
- B) Pod IPs are ephemeral, so a pod-DNS record only stays valid as long as that specific pod does — making it far less durable than Service-based discovery for anything an application would call directly
- C) It's disabled by default in most clusters
- D) It only works for pods without a Deployment

<details>
<summary>Answer</summary>

**B** — The same ephemerality theme from earlier chapters applies here directly — a record tied to one specific pod's IP is only as durable as that pod, which is exactly why Service-based (not pod-based) discovery is what applications actually rely on.
Trap: C and A both invent access/configuration barriers, when the real reason given is about the record's inherent durability, not permissions or defaults.

</details>

Score guide:
| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next chapter |
| 8/10 | Review the wrong answer, then proceed |
| 6-7/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
````