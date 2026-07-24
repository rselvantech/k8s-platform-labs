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
- DNS policies — ClusterFirst, Default, None
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
6. ✅ Apply all three DNS policies to pods, including `None` with a manual `dnsConfig`
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

None:
  → no DNS config injected at all
  → must supply dnsConfig manually in pod spec — nameservers, searches,
    options all become entirely your own responsibility
  → useful for custom DNS configurations, but this demo's Break-Fix
    Error-1 shows exactly what happens when that manual config is wrong
```

---

## Lab Step-by-Step Guide

### Step 1: Setup — Deploy Services in Separate Namespaces

```bash
cd 03-services/05-service-discovery/src
```

**01-backend-namespace.yaml:**
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
          image: hashicorp/http-echo:0.2.3
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

**02-frontend-namespace.yaml:**
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
          image: nginx:1.27
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
kubectl run env-test --image=busybox:1.36 --restart=Never -- sleep 3600

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
  → Pod dnsPolicy is not ClusterFirst

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
- ✅ Observed service environment variables and their pod-start-time-only limitation
- ✅ Applied `dnsPolicy: Default` and observed it breaks cluster DNS resolution
- ✅ Understood `dnsPolicy: None`'s manual-configuration requirement
- ✅ Followed a systematic DNS debugging approach

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

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

### Error-2

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

**Q: A single Service returns NXDOMAIN, but `nslookup kubernetes.default` works fine. What does that narrow down?**
A: CoreDNS itself is healthy and reachable — the problem is specific to that one Service: wrong namespace in the query, the Service doesn't exist, or it exists but has no matching Ready pods. This is different from every name failing, which points at CoreDNS itself or the pod's `dnsPolicy`.

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
| Assuming service env vars are always current | They're a snapshot at pod-start time only — stale the moment a relevant Service changes afterward |
| Not distinguishing single-name NXDOMAIN from total DNS failure | Different root causes entirely — one Service issue vs. CoreDNS itself being down |
| Assuming `dnsPolicy: None` needs no configuration | It needs the *most* configuration of the three policies — nothing is injected automatically |

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
| `dnsPolicy: None` means total manual ownership of DNS config | Nothing injected automatically — get `dnsConfig` wrong and nothing falls back gracefully |
| A single-name NXDOMAIN and total DNS failure have different causes | One points at a specific Service/namespace mistake; the other points at CoreDNS itself being down |

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
"A single Service name returns NXDOMAIN, but nslookup kubernetes.default works. What does that narrow down?","CoreDNS itself is healthy — the problem is specific to that Service: wrong namespace, doesn't exist, or no Ready pods","demo05-services,troubleshooting,cka-troubleshooting"
"What's the blast radius when CoreDNS itself crashes vs. when a single Service is misconfigured?","CoreDNS crashing breaks DNS resolution for the entire cluster simultaneously; a single Service misconfiguration only affects that one Service's name","demo05-services,coredns,cka-troubleshooting"
"What CoreDNS plugin handles non-cluster DNS queries like google.com?","forward — forwards them to the node's own /etc/resolv.conf","demo05-services,coredns,cka-services-networking"
````

---

## Appendix — Quiz

**`05-service-discovery-quiz.md`:**

````markdown
# Quiz — 03-services/05-service-discovery: Service Discovery and CoreDNS

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.

**Q1. What does `ndots:5` actually control?**

- A) The maximum number of DNS servers a pod can use
- B) Whether search domains are tried before querying a name as-is
- C) How many times a failed DNS query is retried
- D) The TTL for cached DNS responses

<details>
<summary>Answer</summary>

**B** — Names with fewer dots than the `ndots` value get search domains tried first; names with more are queried directly.
Trap: D confuses this with the CoreDNS `cache` plugin's TTL setting, a completely separate mechanism.

</details>

---

**Q2. A pod in `app-a` tries `curl db-svc` where `db-svc` actually lives in `app-b`. What happens?**

- A) It resolves fine — DNS is cluster-wide by default
- B) It fails — the pod's search domains only include its own namespace
- C) It resolves, but connects to the wrong service
- D) It works only if both namespaces share a NetworkPolicy

<details>
<summary>Answer</summary>

**B** — Cross-namespace access requires at least `db-svc.app-b` — the bare short name never even generates a query CoreDNS could match against the other namespace.
Trap: A assumes namespace-agnostic short-name resolution, which contradicts the entire search-domain mechanism.

</details>

---

**Q3. Does the CoreDNS `reload` plugin validate a new Corefile before applying it?**

- A) Yes, always, rejecting invalid syntax safely
- B) No — an invalid Corefile causes CoreDNS to crash on reload
- C) Only in production clusters
- D) Only if the `errors` plugin is also enabled

<details>
<summary>Answer</summary>

**B** — This is a real operational risk: editing the `coredns` ConfigMap with a syntax error doesn't get rejected, it crashes the running CoreDNS pods.
Trap: A assumes safe validation exists, which would prevent exactly the kind of outage this demo's Break-Fix Error-2 demonstrates.

</details>

---

**Q4. Are Kubernetes service environment variables always up to date?**

- A) Yes, they update live as Services change
- B) No — only injected for Services that existed before the pod started
- C) Only ClusterIP services get environment variables
- D) They update every 30 seconds via the cache plugin

<details>
<summary>Answer</summary>

**B** — A Service created after a pod starts is completely invisible to that pod's environment — this staleness is exactly why DNS is the preferred discovery method.
Trap: D invents a periodic refresh mechanism that doesn't exist for environment variables at all.

</details>

---

**Q5. Is `dnsPolicy: Default` actually the default DNS policy for a pod?**

- A) Yes, that's what "Default" means
- B) No — `ClusterFirst` is the actual default; `Default` means using the node's own DNS instead
- C) It depends on the cluster's CNI plugin
- D) Only StatefulSet pods default to `Default`

<details>
<summary>Answer</summary>

**B** — This naming is genuinely confusing and worth memorizing precisely: `ClusterFirst` is what a pod gets if you don't specify anything.
Trap: A is the natural but incorrect reading of the name itself.

</details>

---

**Q6. What does `dnsPolicy: None` require that `ClusterFirst` doesn't?**

- A) Nothing extra — it behaves identically
- B) A fully manual `dnsConfig` — nameservers, search domains, and options are entirely your responsibility
- C) A NetworkPolicy allowing DNS traffic
- D) Running the pod in `kube-system`

<details>
<summary>Answer</summary>

**B** — `None` means nothing is injected automatically at all; get any part of `dnsConfig` wrong (like a mistyped nameserver IP) and nothing falls back gracefully.
Trap: A assumes equivalence with the default behavior, which is the opposite of what `None` actually means.

</details>

---

**Q7. A single Service's name returns NXDOMAIN, but `nslookup kubernetes.default` succeeds. What does this narrow down?**

- A) CoreDNS itself must be down
- B) CoreDNS is healthy — the issue is specific to that one Service (wrong namespace, doesn't exist, or no Ready pods)
- C) The pod's dnsPolicy must be wrong
- D) The cluster's NodePort range is misconfigured

<details>
<summary>Answer</summary>

**B** — A working `kubernetes.default` lookup rules out CoreDNS and the pod's own DNS policy entirely — the problem is isolated to that specific Service.
Trap: A and C both assume broader breakage than the evidence actually supports — a successful control lookup rules those out.

</details>

---

**Q8. What's the practical difference in blast radius between a CoreDNS crash and a single misconfigured Service?**

- A) They're equivalent — both affect the whole cluster
- B) A CoreDNS crash breaks DNS for the entire cluster at once; a misconfigured Service only affects its own name
- C) A misconfigured Service is always worse because it's harder to detect
- D) There's no meaningful difference in practice

<details>
<summary>Answer</summary>

**B** — This is exactly why "Timeout" (all names failing) and "NXDOMAIN for one name" are treated as distinct diagnostic categories in this demo's systematic debugging approach.
Trap: A collapses two very different failure scopes into one, losing the diagnostic value of distinguishing them.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next chapter |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````