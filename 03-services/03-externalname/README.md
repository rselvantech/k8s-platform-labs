# ExternalName Service

## Lab Overview

An ExternalName service maps a Kubernetes service name to an external
DNS name. Instead of routing traffic to pods, it returns a DNS CNAME
record pointing to an external hostname.

```
Pod inside cluster → db-svc:5432
                       ↓
                  CoreDNS resolves db-svc
                       ↓
                  Returns CNAME: mydb.prod.rds.amazonaws.com
                       ↓
                  Pod connects to mydb.prod.rds.amazonaws.com:5432
```

**Real-world scenario:** Your backend application needs to connect to
a managed database (AWS RDS, Google Cloud SQL). Instead of hardcoding
the database hostname in the application, you create an ExternalName
service. If the database hostname ever changes (migration, failover),
you update only the service — not the application.

**What this lab covers:**
- ExternalName service — CNAME-based DNS redirection
- Why ExternalName is useful — decoupling from external endpoints
- How it differs from other service types (no ClusterIP, no proxy)
- Verifying CNAME resolution from inside a pod
- Limitations — no IP addresses, HTTP host header issues
- When to use ExternalName vs selectorless services

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [14-service-internals](../14-service-internals/)
- Basic understanding of DNS CNAME records

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create an ExternalName service and verify CNAME resolution
2. ✅ Explain how ExternalName differs from other service types
3. ✅ Verify that ExternalName has no ClusterIP and no endpoints
4. ✅ Demonstrate updating the external target without changing pods
5. ✅ Explain ExternalName limitations
6. ✅ Create ExternalName service imperatively

## Directory Structure

```
16-externalname/
├── README.md                        # This file
└── src/
    ├── backend-deployment.yaml      # Real backend for migration demo
    ├── backend-svc.yaml             # Regular ClusterIP service
    └── externalname-svc.yaml        # ExternalName pointing to backend
```

---

## Understanding ExternalName Service

### What ExternalName Does

An ExternalName Service is a special case of Service that does not have
selectors and uses DNS names instead. When looking up the host
`my-service.prod.svc.cluster.local`, the cluster DNS Service returns
a CNAME record with the configured external value.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-svc
spec:
  type: ExternalName
  externalName: mydb.prod.rds.amazonaws.com
```

```
Pod resolves db-svc:
  1. CoreDNS receives query for db-svc.default.svc.cluster.local
  2. Returns CNAME: mydb.prod.rds.amazonaws.com
  3. Pod's DNS resolver follows the CNAME
  4. Resolves mydb.prod.rds.amazonaws.com to the actual IP
  5. Pod connects to that IP

This is pure DNS redirection — no proxying, no ClusterIP,
no iptables rules, no kube-proxy involvement.
```

### ExternalName vs Other Service Types

```
ClusterIP       → virtual IP + kube-proxy rules → routes to pod IPs
NodePort        → virtual IP + node ports → routes to pod IPs
LoadBalancer    → virtual IP + node ports + cloud LB → routes to pod IPs
ExternalName    → DNS CNAME only → no virtual IP, no proxy, no endpoints
```

### Limitations of ExternalName

```
1. No IP addresses allowed in externalName
   → Services with external names that resemble IPv4 addresses are
     not resolved by DNS servers
   → Use selectorless service with manual EndpointSlice for IP-based
     external services

2. HTTP/HTTPS host header mismatch
   → The CNAME target may require a specific Host header
   → If your app sends Host: db-svc, the external server may reject it
     because it expects Host: mydb.prod.rds.amazonaws.com
   → This is a common production gotcha

3. No load balancing
   → Returns single CNAME — DNS-level load balancing only if the
     external service has multiple A records

4. TLS certificate validation
   → TLS SNI may fail if the certificate is for the external hostname
     but the app connects using the internal service name
```

### When to Use ExternalName vs Selectorless

```
ExternalName:
  → External service has a stable DNS name
  → You want DNS-level redirection (no proxy overhead)
  → Simple hostname mapping

Selectorless Service + EndpointSlice:
  → External service has a stable IP address
  → You want kube-proxy to handle load balancing across multiple IPs
  → You need port mapping/translation
```

---

## Lab Step-by-Step Guide

---

### Step 1: Deploy a Real Backend (Migration Target)

This step simulates the scenario where you start with an external
service (represented by an ExternalName) and later migrate it into
the cluster without changing application configuration.

```bash
cd 16-externalname/src

# Deploy a real backend that we'll reference externally first
# then migrate into the cluster
```

**backend-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deploy
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
            - "-text=Response from migrated backend"
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

**backend-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-real-svc
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

```bash
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-svc.yaml
kubectl rollout status deployment/backend-deploy
kubectl get svc backend-real-svc
```

**Expected output:**
```
NAME               TYPE        CLUSTER-IP      PORT(S)
backend-real-svc   ClusterIP   10.96.xxx.xxx   5678/TCP
```

---

### Step 2: Create ExternalName Service Pointing to External Host

**externalname-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: database-svc
spec:
  type: ExternalName
  externalName: httpbin.org
```

> We use `httpbin.org` — a public HTTP testing service — as the
> "external database" for this demo. In production this would be
> your RDS endpoint or other external service hostname.

```bash
kubectl apply -f externalname-svc.yaml
kubectl get svc database-svc
```

**Expected output:**
```
NAME           TYPE           CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
database-svc   ExternalName   <none>       httpbin.org   <none>    5s
```

```
TYPE=ExternalName    → DNS CNAME only
CLUSTER-IP=<none>    → no virtual IP assigned ✅
EXTERNAL-IP=httpbin.org → the CNAME target
PORT(S)=<none>       → no port proxy — DNS only
```

Verify no endpoints exist:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=database-svc
```

**Expected output:**
```
No resources found in default namespace.
```

No EndpointSlices — ExternalName has no pod endpoints. ✅

---

### Step 3: Verify CNAME Resolution from Inside a Pod

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
```

Inside the pod:

**Test 1 — CNAME resolution:**

```bash
nslookup database-svc
```

**Expected output:**
```
Server:   10.96.0.10
Address:  10.96.0.10#53

database-svc.default.svc.cluster.local  canonical name = httpbin.org
Name:   httpbin.org
Address: x.x.x.x
```

```
canonical name = httpbin.org  ← CNAME returned by CoreDNS ✅
                                not a ClusterIP — pure CNAME
```

**Test 2 — Dig for more detail:**

```bash
dig database-svc.default.svc.cluster.local
```

**Expected output:**
```
;; ANSWER SECTION:
database-svc.default.svc.cluster.local. 5 IN CNAME httpbin.org.
httpbin.org.  30  IN  A  x.x.x.x
```

```
CNAME record confirmed — ExternalName returns CNAME not A record ✅
```

**Test 3 — HTTP request via ExternalName:**

```bash
curl -s http://database-svc/get | python3 -m json.tool | head -10
```

**Expected output:**
```json
{
    "args": {},
    "headers": {
        "Accept": "*/*",
        "Host": "database-svc",
        ...
    },
    "url": "http://database-svc/get"
}
```

> Note the Host header is `database-svc` not `httpbin.org`. This is
> the HTTP host header limitation — the external server sees the
> internal service name, not its own hostname. Some servers may
> reject this. In production, configure your application to set
> the correct Host header.

Exit the pod:

```bash
exit
```

---

### Step 4: Demonstrate Migration — No Application Change

This is the core value of ExternalName. Update the service to point
to the internal backend (migration complete) — application pods
need no changes.

```bash
# Before migration: database-svc → httpbin.org (external)
kubectl get svc database-svc

# Simulate migration: update ExternalName to point to internal service
kubectl patch svc database-svc \
  -p '{"spec":{"externalName":"backend-real-svc.default.svc.cluster.local"}}'

kubectl get svc database-svc
```

**Expected output:**
```
NAME           TYPE           EXTERNAL-IP
database-svc   ExternalName   backend-real-svc.default.svc.cluster.local
```

Verify from inside a pod:

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
```

```bash
nslookup database-svc
```

**Expected output:**
```
database-svc.default.svc.cluster.local  canonical name = backend-real-svc.default.svc.cluster.local
backend-real-svc.default.svc.cluster.local  canonical name = ...
Address: 10.96.xxx.xxx   ← ClusterIP of backend-real-svc
```

```bash
curl database-svc:5678
```

**Expected output:**
```
Response from migrated backend
```

```
Application still uses database-svc:5678
ExternalName now points to internal backend
No application code change needed ✅
```

Exit:

```bash
exit
```

---

### Step 5: ExternalName Cannot Use IP Addresses

Verify the documented limitation — ExternalName does not work with IP addresses:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ip-externalname
spec:
  type: ExternalName
  externalName: "192.168.1.100"
EOF
```

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash

nslookup ip-externalname
```

**Expected output:**
```
** server can't find ip-externalname: NXDOMAIN
```

```
IP address in externalName → DNS cannot resolve ❌
Use selectorless service with EndpointSlice for IP-based external services
```

Exit and cleanup:

```bash
exit
kubectl delete svc ip-externalname
```

---

### Step 6: Imperative Creation

```bash
# Create ExternalName imperatively
kubectl create service externalname my-external-db \
  --external-name mydb.prod.rds.amazonaws.com

kubectl get svc my-external-db
```

**Expected output:**
```
NAME             TYPE           EXTERNAL-IP
my-external-db   ExternalName   mydb.prod.rds.amazonaws.com
```

Generate YAML with dry-run:

```bash
kubectl create service externalname my-external-db \
  --external-name mydb.prod.rds.amazonaws.com \
  --dry-run=client \
  -o yaml
```

**Expected output:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-external-db
spec:
  externalName: mydb.prod.rds.amazonaws.com
  type: ExternalName
```

```bash
kubectl delete svc my-external-db
```

---

### Step 7: Final Cleanup

```bash
kubectl delete -f externalname-svc.yaml
kubectl delete -f backend-svc.yaml
kubectl delete -f backend-deployment.yaml

kubectl get svc
kubectl get pods
```

---

## Common Questions

### Q: Can ExternalName use an IP address?

**A:** No. A Service of type ExternalName accepts an IPv4 address string, but treats that string as a DNS name comprised of digits, not as an IP address. Services with external names that resemble IPv4 addresses are not resolved by DNS servers. Use a selectorless service with a manual EndpointSlice for IP-based external routing.

### Q: Does ExternalName do any load balancing?

**A:** No. ExternalName only returns a CNAME record. Any load
balancing happens at the DNS level of the external service (if the
external hostname has multiple A records). kube-proxy is not involved.

### Q: Why would I use ExternalName instead of just configuring the hostname directly in my app?

**A:** ExternalName decouples your application from external
dependencies. If your RDS instance hostname changes (migration,
region failover), you update one Kubernetes service — not every
deployment's environment variables or config maps. It also keeps
your application configuration consistent — it always talks to
a Kubernetes service name, whether that service is internal or external.

---

## What You Learned

In this lab, you:
- ✅ Created an ExternalName service and verified CNAME resolution
- ✅ Confirmed ExternalName has no ClusterIP and no EndpointSlices
- ✅ Observed the Host header limitation with HTTP
- ✅ Demonstrated zero-downtime migration by updating ExternalName
  target without changing application pods
- ✅ Verified IP addresses do not work with ExternalName
- ✅ Created ExternalName services imperatively

**Key Takeaway:** ExternalName is pure DNS-level redirection — no
virtual IP, no proxy, no kube-proxy involvement. Its main value is
decoupling: your application always connects to a stable internal
service name, while the actual external target can change without
touching application code. IP addresses are not supported — use
selectorless services for IP-based external routing.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl create service externalname <n> --external-name <host>` | Create ExternalName imperatively |
| `kubectl get svc <n>` | Show EXTERNAL-IP (hostname) |
| `kubectl patch svc <n> -p '{"spec":{"externalName":"<new-host>"}}'` | Update external target |
| `nslookup <service-name>` | Verify CNAME from inside pod |
| `dig <service-name>.default.svc.cluster.local` | Detailed DNS query |

---

## CKA Certification Tips

✅ **ExternalName has no ClusterIP and no endpoints:**
```bash
kubectl get svc <n>  # CLUSTER-IP shows <none>
```

✅ **ExternalName returns CNAME — not A record**

✅ **ExternalName cannot use IP addresses — use selectorless for IPs**

✅ **No ports required in ExternalName spec (DNS only)**

✅ **Imperative creation:**
```bash
kubectl create service externalname <name> --external-name <hostname>
```

✅ **ExternalName does NOT require a selector field**