# Service Discovery and CoreDNS

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

**What this lab covers:**
- DNS naming format — short name, FQDN, cross-namespace
- /etc/resolv.conf — search domains and ndots
- CoreDNS architecture — ConfigMap, plugins, Corefile
- Cross-namespace service communication
- Service environment variables (the other discovery method)
- DNS policies — ClusterFirst, Default, None
- Debugging DNS resolution

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [17-headless](../17-headless/)
- Understanding of DNS basics (A records, CNAME, search domains)

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain the DNS naming format for Kubernetes services
2. ✅ Read /etc/resolv.conf and explain search domains and ndots
3. ✅ Inspect CoreDNS configuration (Corefile) via ConfigMap
4. ✅ Resolve services across namespaces using full DNS names
5. ✅ Use service environment variables for discovery
6. ✅ Apply different DNS policies to pods
7. ✅ Debug DNS resolution issues systematically

## Directory Structure

```
18-service-discovery/
├── README.md                        # This file
└── src/
    ├── backend-namespace.yaml       # Namespace + deployment + service
    └── frontend-namespace.yaml      # Namespace + deployment
```

---

## Understanding Service Discovery

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
resolver try the search domains in /etc/resolv.conf:

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

Every pod gets an /etc/resolv.conf injected by Kubernetes:

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
  → no DNS config injected
  → must supply dnsConfig manually in pod spec
  → useful for custom DNS configurations
```

---

## Lab Step-by-Step Guide

---

### Step 1: Setup — Deploy Services in Separate Namespaces

```bash
cd 18-service-discovery/src
```

**backend-namespace.yaml:**
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

**frontend-namespace.yaml:**
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
kubectl apply -f backend-namespace.yaml
kubectl apply -f frontend-namespace.yaml

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
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -n frontend-ns \
  -- bash
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
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -n frontend-ns \
  -- bash
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
  → randomizes A/AAAA record order for headless services
  → provides DNS-level round-robin
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
kubectl run env-test --image=busybox:1.36 \
  --restart=Never \
  -- sleep 3600

# Check injected environment variables
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
kubectl run dns-default --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
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

---

### Step 7: Debug DNS Resolution

Systematic DNS debugging approach:

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
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
  → CoreDNS pods overloaded or crashing
  → Network policy blocking port 53 to CoreDNS
```

Exit:

```bash
exit
```

---

### Step 8: Final Cleanup

```bash
kubectl delete -f backend-namespace.yaml
kubectl delete -f frontend-namespace.yaml

kubectl get namespaces | grep -E "frontend-ns|backend-ns"
kubectl get pods -n default
```

---

## Common Questions

### Q: What is the CoreDNS service IP?

**A:** The CoreDNS service is named `kube-dns` in the `kube-system`
namespace. Its ClusterIP is typically `10.96.0.10` — this is the
`nameserver` value in every pod's `/etc/resolv.conf`. You can verify
with: `kubectl get svc kube-dns -n kube-system`.

### Q: Why does ndots:5 exist?

**A:** `ndots:5` controls when search domains are tried. If a DNS name
has fewer than 5 dots, the resolver tries search domains first before
querying the name as-is. This means short names like `backend-svc`
(0 dots) go through all search domains before being sent to external
DNS. Without this, `backend-svc` would be sent directly to external DNS
and fail before trying cluster search domains.

### Q: Can I change CoreDNS configuration?

**A:** Yes — edit the `coredns` ConfigMap in `kube-system`. CoreDNS
watches the ConfigMap and reloads automatically (via the `reload`
plugin). Common customizations: adding stub domains for private DNS
zones, changing TTL, enabling DNSSEC.

### Q: Why use DNS over environment variables?

**A:** Environment variables are injected once at pod creation and
never updated. If a service is created or changes after the pod starts,
environment variables are stale. DNS always returns the current state.
DNS is the recommended and default method for service discovery.

---

## What You Learned

In this lab, you:
- ✅ Explained the full DNS naming format for Kubernetes services
- ✅ Read /etc/resolv.conf and explained search domains and ndots:5
- ✅ Successfully resolved services across namespaces using
  `svc.namespace` format
- ✅ Inspected CoreDNS Corefile configuration and key plugins
- ✅ Observed service environment variables and their limitation
  (only injected at pod start)
- ✅ Applied dnsPolicy: Default and observed it breaks cluster DNS
- ✅ Followed a systematic DNS debugging approach

**Key Takeaway:** DNS is the primary service discovery mechanism in
Kubernetes. CoreDNS serves all cluster DNS queries. Short names work
within the same namespace. Cross-namespace requires at least the
`service.namespace` format. Use DNS over environment variables —
DNS is always current. ndots:5 + search domains make short names work
transparently by trying cluster DNS before external.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get svc kube-dns -n kube-system` | Show CoreDNS service and ClusterIP |
| `kubectl get pods -n kube-system -l k8s-app=kube-dns` | Check CoreDNS pods |
| `kubectl describe configmap coredns -n kube-system` | Inspect CoreDNS Corefile |
| `nslookup <svc>` | Resolve service (from inside pod) |
| `nslookup <svc>.<namespace>` | Cross-namespace resolution |
| `dig @10.96.0.10 <fqdn>` | Query CoreDNS directly |
| `cat /etc/resolv.conf` | Check search domains and nameserver |

---

## CKA Certification Tips

✅ **DNS name format:**
```
<service-name>.<namespace>.svc.<cluster-domain>
backend-svc.default.svc.cluster.local
```

✅ **Cross-namespace requires namespace in name:**
```bash
# Same namespace: works
curl backend-svc:5678

# Different namespace: must include namespace
curl backend-svc.backend-ns:5678
curl backend-svc.backend-ns.svc.cluster.local:5678
```

✅ **CoreDNS service is kube-dns in kube-system:**
```bash
kubectl get svc kube-dns -n kube-system
```

✅ **DNS policies:**
```
ClusterFirst (default) → CoreDNS first → use for all regular pods
Default                → node DNS → cluster names don't resolve
None                   → no DNS injected → must supply dnsConfig
```

✅ **Environment variables vs DNS:**
```
Env vars → injected at pod start → stale if service changes after
DNS      → always current → preferred method
```

✅ **Debugging DNS — key commands:**
```bash
nslookup kubernetes.default    # verify CoreDNS works
nslookup <svc>.<ns>            # cross-namespace
dig @10.96.0.10 <fqdn>         # query CoreDNS directly
cat /etc/resolv.conf           # check search domains
```

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