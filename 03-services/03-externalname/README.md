# Demo: 03-services/03-externalname — ExternalName Service

## Lab Overview

An ExternalName service maps a Kubernetes service name to an external DNS
name. Instead of routing traffic to pods, it returns a DNS CNAME record
pointing to an external hostname.

```
Pod inside cluster → db-svc:5432
                       ↓
                  CoreDNS resolves db-svc
                       ↓
                  Returns CNAME: mydb.prod.rds.amazonaws.com
                       ↓
                  Pod connects to mydb.prod.rds.amazonaws.com:5432
```

**Real-world scenario:** Your backend application needs to connect to a
managed database (AWS RDS, Google Cloud SQL). Instead of hardcoding the
database hostname in the application, you create an ExternalName service.
If the database hostname ever changes (migration, failover), you update
only the service — not the application.

**What this lab covers:**
- ExternalName service — CNAME-based DNS redirection
- Why ExternalName is useful — decoupling from external endpoints
- How it differs from other service types (no ClusterIP, no proxy)
- Verifying CNAME resolution from inside a pod
- Limitations — no IP addresses, HTTP host header issues
- When to use ExternalName vs the selectorless services covered in `02-service-internals`

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of `02-service-internals` (this demo assumes you already understand EndpointSlices and selectorless services — the comparison in this demo's Concepts section builds directly on that)
- Basic understanding of DNS CNAME records

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create an ExternalName service and verify CNAME resolution
2. ✅ Explain how ExternalName differs from other service types
3. ✅ Verify that ExternalName has no ClusterIP and no endpoints
4. ✅ Demonstrate updating the external target without changing pods
5. ✅ Explain ExternalName limitations
6. ✅ Create ExternalName service imperatively
7. ✅ Explain when ExternalName is the wrong tool and a selectorless Service (`02-service-internals`) is the right one instead

## Directory Structure

```
03-services/03-externalname/
├── README.md
├── src/
│   ├── 01-backend-deployment.yaml    # Real backend for migration demo
│   ├── 02-backend-svc.yaml           # Regular ClusterIP service
│   ├── 03-externalname-svc.yaml      # ExternalName pointing to backend
│   └── break-fix/
│       ├── 01-selector-on-externalname.yaml    # Embedded inline in README — not generated on disk
│       └── 02-url-instead-of-hostname.yaml     # Embedded inline in README — not generated on disk
├── 03-externalname-anki.csv
└── 03-externalname-quiz.md
```

---

## Recall Check — 02-service-internals

Answer from memory before continuing — no peeking at the previous demo.

1. Does kube-proxy process every packet sent to a Service?
2. For a Service WITH a selector, is its EndpointSlice self-healing if deleted?
3. For a selectorless Service, is that same self-healing true?

<details>
<summary>Answers</summary>

1. No — it only programs iptables/nftables/IPVS rules; the kernel handles all actual packet forwarding.
2. Yes — the endpointslice-controller continuously reconciles it against the selector and currently-Ready pods.
3. No — nothing reconciles a selectorless Service's manually-created EndpointSlice automatically; you're fully responsible for maintaining it yourself.

</details>

---

## Concepts

### What ExternalName Does

An ExternalName Service is a special case of Service that does not have
selectors and uses DNS names instead. When looking up the host
`my-service.prod.svc.cluster.local`, the cluster DNS Service returns a
CNAME record with the configured external value.

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
no iptables rules, no kube-proxy involvement at all.
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
   → Use the selectorless Service + manual EndpointSlice pattern from
     02-service-internals for IP-based external services instead

2. HTTP/HTTPS host header mismatch
   → The CNAME target may require a specific Host header
   → If your app sends Host: db-svc, the external server may reject it
     because it expects Host: mydb.prod.rds.amazonaws.com
   → This is a common production gotcha

3. No load balancing
   → Returns a single CNAME — DNS-level load balancing only if the
     external service itself has multiple A records

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

Selectorless Service + EndpointSlice (02-service-internals, Step 6):
  → External service has a stable IP address, not a hostname
  → You want kube-proxy to handle load balancing across multiple IPs
  → You need port mapping/translation (port ≠ targetPort)
```
This is a direct continuation of `02-service-internals`'s own selectorless
example (`external-db-svc` pointing at `10.240.0.50`) — same underlying
need ("point at something outside normal pod selection"), solved with two
genuinely different mechanisms depending on whether you have a hostname
(this demo) or an IP address (that one).

---

## Lab Step-by-Step Guide

### Step 1: Deploy a Real Backend (Migration Target)

This step simulates the scenario where you start with an external service
(represented by an ExternalName) and later migrate it into the cluster
without changing application configuration.

```bash
cd 03-services/03-externalname/src
```

**01-backend-deployment.yaml:**
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

**02-backend-svc.yaml:**
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
kubectl apply -f 01-backend-deployment.yaml
kubectl apply -f 02-backend-svc.yaml
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

**03-externalname-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: database-svc
spec:
  type: ExternalName
  externalName: httpbin.org
```
> We use `httpbin.org` — a public HTTP testing service — as the "external
> database" for this demo. In production this would be your RDS endpoint
> or other external service hostname.

```bash
kubectl apply -f 03-externalname-svc.yaml
kubectl get svc database-svc
```

**Expected output:**
```
NAME           TYPE           CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
database-svc   ExternalName   <none>       httpbin.org   <none>    5s
```
```
TYPE=ExternalName        → DNS CNAME only
CLUSTER-IP=<none>        → no virtual IP assigned ✅
EXTERNAL-IP=httpbin.org  → the CNAME target
PORT(S)=<none>           → no port proxy — DNS only
```

Verify no endpoints exist:
```bash
kubectl get endpointslices -l kubernetes.io/service-name=database-svc
```
**Expected output:**
```
No resources found in default namespace.
```
No EndpointSlices — ExternalName has no pod endpoints at all, unlike
either the ClusterIP or selectorless cases from `02-service-internals`. ✅

---

### Step 3: Verify CNAME Resolution from Inside a Pod

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash
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
```
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
> Note the Host header is `database-svc`, not `httpbin.org`. This is the
> HTTP host header limitation from Concepts above — the external server
> sees the internal service name, not its own hostname. Some servers
> reject this outright (`httpbin.org` doesn't, which is why this demo can
> use it safely). In production, configure your application to set the
> correct Host header explicitly if the external endpoint requires it.

Exit the pod:
```bash
exit
```

---

### Step 4: Demonstrate Migration — No Application Change

This is the core value of ExternalName. Update the service to point to
the internal backend (migration complete) — application pods need no
changes.

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
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash
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
> This CNAME chain works because `backend-real-svc.default.svc.cluster.local`
> is itself a real, resolvable DNS name — CoreDNS's own binding of a
> ClusterIP Service's name to its ClusterIP, exactly as covered in
> `01-clusterip-nodeport`. ExternalName can point at any resolvable
> hostname, including another Service's own internal DNS name.

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
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash

nslookup ip-externalname
```
**Expected output:**
```
** server can't find ip-externalname: NXDOMAIN
```
```
IP address in externalName → DNS cannot resolve ❌
Use the selectorless Service + EndpointSlice pattern from
02-service-internals for IP-based external services instead.
```

Exit and cleanup:
```bash
exit
kubectl delete svc ip-externalname
```

---

### Step 6: Imperative Creation

```bash
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
kubectl delete -f 03-externalname-svc.yaml
kubectl delete -f 02-backend-svc.yaml
kubectl delete -f 01-backend-deployment.yaml

kubectl get svc
kubectl get pods
```

---

## What You Learned

In this lab, you:
- ✅ Created an ExternalName service and verified CNAME resolution
- ✅ Confirmed ExternalName has no ClusterIP and no EndpointSlices
- ✅ Observed the HTTP Host header limitation directly
- ✅ Demonstrated zero-downtime migration by updating the ExternalName target without changing application pods, including a CNAME chain to another Service's own DNS name
- ✅ Verified IP addresses do not work with ExternalName
- ✅ Created ExternalName services imperatively
- ✅ Understood exactly when ExternalName is the right tool vs when `02-service-internals`'s selectorless pattern is

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-selector-on-externalname.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: confused-externalname
spec:
  type: ExternalName
  externalName: httpbin.org
  selector:
    app: backend    # this field is meaningless here — see below
  ports:
    - port: 5678
```

```bash
kubectl apply -f 01-selector-on-externalname.yaml
kubectl get svc confused-externalname
kubectl get endpointslices -l kubernetes.io/service-name=confused-externalname
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `selector` and `ports` are both accepted by the API on an
`ExternalName` Service — Kubernetes doesn't reject the combination — but
neither field has any effect. ExternalName is pure DNS redirection; it
never creates EndpointSlices and never routes based on a selector,
regardless of what's written in the spec.

**Fix:** Remove the `selector` and `ports` fields — they're not wrong in
the sense of causing an error, but they're misleading clutter that
implies behavior this Service type doesn't have.

**Cascade:** `kubectl get endpointslices` for this Service returns nothing,
exactly like a "clean" ExternalName Service — the selector is silently
ignored rather than producing any visible effect at all, which is exactly
what makes this trap easy to miss: there's no error to notice, just
unused configuration someone might reasonably assume is doing something.

</details>

**Cleanup:**
```bash
kubectl delete svc confused-externalname 2>/dev/null || true
```

---

### Error-2

**`src/break-fix/02-url-instead-of-hostname.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: broken-url-svc
spec:
  type: ExternalName
  externalName: "http://httpbin.org"   # includes the scheme — not a valid hostname
```

```bash
kubectl apply -f 02-url-instead-of-hostname.yaml
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- nslookup broken-url-svc
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `externalName` must be a bare DNS hostname, not a URL — a very
common mistake when someone copies a URL from a browser or config file
instead of extracting just the hostname portion. `http://httpbin.org`
isn't a valid DNS name (the `http://` scheme prefix isn't a legal DNS
label), so it can never resolve.

**Fix:** Set `externalName: httpbin.org` — hostname only, no scheme, no
path.

**Cascade:** Same failure signature as Step 5's IP-address limitation —
`NXDOMAIN`, with no indication from `kubectl get svc` itself that
anything is wrong (`EXTERNAL-IP` happily displays the invalid string
exactly as written, since Kubernetes doesn't validate `externalName`
against real DNS syntax at apply time).

</details>

**Cleanup:**
```bash
kubectl delete svc broken-url-svc 2>/dev/null || true
```

---

## Interview Prep

**Q: Can ExternalName use an IP address?**
A: No. A Service of type ExternalName accepts an IPv4-looking string, but treats it as a DNS name comprised of digits, not as an IP address — DNS servers don't resolve it. Use a selectorless Service with a manual EndpointSlice (`02-service-internals`) for IP-based external routing instead.

**Q: Does ExternalName do any load balancing?**
A: No. It only returns a CNAME record. Any load balancing happens at the DNS level of the external service itself (if that hostname has multiple A records) — kube-proxy is never involved.

**Q: Why would I use ExternalName instead of just hardcoding the hostname directly in my app?**
A: ExternalName decouples your application from external dependencies. If your RDS instance's hostname changes (migration, region failover), you update one Kubernetes Service — not every deployment's environment variables or ConfigMaps. Your application always talks to a stable internal Service name, whether that name currently points internally or externally.

**Q: If you add a `selector` field to an ExternalName Service, does it start routing to matching pods?**
A: No — `selector` (and `ports`) are accepted without error but have no effect on an ExternalName Service. It remains pure DNS redirection regardless; this is a real trap precisely because nothing errors to reveal the mistake.

**Q: What's the practical difference between ExternalName and the selectorless-Service pattern from `02-service-internals`?**
A: ExternalName is DNS-only redirection to a hostname — no ports, no proxying, no load balancing beyond whatever the external DNS name itself provides. Selectorless + manual EndpointSlice targets an IP address directly, goes through kube-proxy like any other Service, and supports port mapping and load balancing across multiple IPs. Choose based on whether you have a stable hostname or a stable IP.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | ExternalName mechanics, CNAME resolution, imperative creation |
| Services & Networking | CKAD | — | Choosing the right Service type for a given external-connectivity need |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Trying to use an IP address in `externalName` | Silently fails to resolve (NXDOMAIN) — DNS treats it as digits, not an address; no validation error at apply time |
| Assuming `selector`/`ports` do something on an ExternalName Service | Both are accepted, both are ignored — no error, just dead configuration |
| Copying a full URL into `externalName` instead of a bare hostname | `http://host` isn't a valid DNS name — same silent NXDOMAIN failure as the IP-address case |
| Forgetting the HTTP Host header implication | The external server sees your internal Service name as the Host header, not its own hostname — can cause real rejections on strict servers |
| Confusing ExternalName with a selectorless Service | Different mechanisms for different needs — hostname vs IP, no ports vs full port mapping |

### Exam Task — Write it from scratch

Create an ExternalName Service named `external-api` pointing to `api.example.com`, using `kubectl create service externalname`, then verify via `nslookup` from a debug pod that it returns a CNAME rather than an A record directly.

Official docs: [ExternalName](https://kubernetes.io/docs/concepts/services-networking/service/#externalname)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create service externalname external-api --external-name api.example.com
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- nslookup external-api
```

**Key fields to recall:** `spec.type: ExternalName`, `spec.externalName` (bare hostname only, no scheme, no IP address).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| ExternalName is pure DNS redirection | No virtual IP, no proxy, no kube-proxy involvement, no EndpointSlices — CNAME only |
| It decouples your app from an external hostname's actual value | Update the Service, not the application, when the external target changes |
| IP addresses don't work in `externalName` | Treated as digits, not an address — resolves to NXDOMAIN silently |
| `selector` and `ports` are silently ignored on ExternalName | Accepted by the API with no error, but have zero effect |
| The HTTP Host header stays as your internal Service name | Can cause real rejections against strict external servers expecting their own hostname |
| ExternalName can CNAME-chain to another Service's own DNS name | This is exactly how Step 4's "migrate without app changes" demo works |
| Choose ExternalName for hostnames, selectorless Services for IPs | Different mechanisms, `02-service-internals` owns the IP-based case in full |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl create service externalname <name> --external-name <host>` | Create ExternalName imperatively |
| `kubectl get svc <name>` | Show EXTERNAL-IP (the hostname target) |
| `kubectl patch svc <name> -p '{"spec":{"externalName":"<new-host>"}}'` | Update the external target |
| `nslookup <service-name>` | Verify CNAME from inside a pod |
| `dig <service-name>.default.svc.cluster.local` | Detailed DNS query, shows the CNAME record explicitly |

### Generating YAML skeletons with --dry-run

```bash
kubectl create service externalname my-external-db --external-name mydb.prod.rds.amazonaws.com --dry-run=client -o yaml
```
See `01-core-concepts/04-kubectl-essentials` for the full canonical `--dry-run` explanation.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Service (ExternalName) | `kubectl create service externalname NAME --external-name HOSTNAME` | Different subcommand family from `kubectl expose` — `expose` has no ExternalName mode |

---

## Appendix — Anki Cards

**`03-externalname-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::03-externalname
#separator:Comma
#columns:Front,Back,Tags
"What does an ExternalName Service actually do?","Returns a DNS CNAME record pointing to an external hostname — pure DNS redirection, no proxying, no ClusterIP, no kube-proxy involvement","demo03-services,externalname,cka-services-networking"
"Does an ExternalName Service have any EndpointSlices?","No — it never creates endpoints of any kind, unlike both ClusterIP and selectorless Services","demo03-services,externalname,endpointslices,cka-services-networking"
"Can externalName be set to an IP address?","No — it's treated as a DNS name made of digits, not an IP, and fails to resolve (NXDOMAIN)","demo03-services,externalname,cka-services-networking"
"What happens if you add a selector field to an ExternalName Service?","Nothing — it's accepted by the API but has zero effect; ExternalName remains pure DNS redirection regardless","demo03-services,externalname,ckad-application-deployment"
"What Host header does an external server see when accessed via ExternalName?","Your internal Service's own name, not the external server's real hostname — can cause rejections on Host-header-strict servers","demo03-services,externalname,http,cka-services-networking"
"Can an ExternalName Service's externalName point at another Kubernetes Service's own DNS name?","Yes — CNAME chaining to a real resolvable hostname works, including another ClusterIP Service's internal DNS name","demo03-services,externalname,dns,cka-services-networking"
"What's the main practical value of using ExternalName instead of hardcoding a hostname in application config?","If the external target changes, you update one Service object instead of every deployment's config — the app always talks to a stable internal name","demo03-services,externalname,ckad-application-deployment"
"When would you use a selectorless Service instead of ExternalName?","When your external target is a stable IP address (not a hostname) and you need port mapping or load balancing across multiple IPs — covered in 02-service-internals","demo03-services,selectorless,cka-services-networking"
"Does ExternalName perform any load balancing?","No — it returns a single CNAME; any load balancing happens at the external DNS level if that hostname has multiple A records","demo03-services,externalname,cka-services-networking"
"Is kubectl create service externalname the same command family as kubectl expose?","No — kubectl expose has no ExternalName mode; ExternalName Services use the separate kubectl create service externalname subcommand","demo03-services,imperative,ckad-application-deployment"
````

---

## Appendix — Quiz

**`03-externalname-quiz.md`:**

````markdown
# Quiz — 03-services/03-externalname: ExternalName Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What does an ExternalName Service actually do?**

- A) Routes traffic to pods via a virtual IP, like ClusterIP
- B) Returns a DNS CNAME record — pure redirection, no proxying at all
- C) Opens a port on every node, like NodePort
- D) Load balances across multiple external IPs automatically

<details>
<summary>Answer</summary>

**B** — No virtual IP, no kube-proxy involvement, no EndpointSlices — just a CNAME.
Trap: A and C both describe mechanisms that involve pod/IP routing, which ExternalName specifically doesn't do.

</details>

---

**Q2. Can `externalName` be set to an IP address like `192.168.1.100`?**

- A) Yes, it resolves directly to that address
- B) No — it's treated as a DNS name made of digits and fails to resolve
- C) Only if quoted as a string
- D) Only on cloud-provider clusters

<details>
<summary>Answer</summary>

**B** — DNS doesn't resolve an IP-looking string as an address here; it results in NXDOMAIN.
Trap: C suggests a workaround that doesn't exist — quoting doesn't change how DNS interprets the value.

</details>

---

**Q3. You add a `selector` field to an ExternalName Service, expecting it to also route matching pods as a fallback. What happens?**

- A) It routes to pods only when the external DNS lookup fails
- B) Nothing — the selector is accepted but has no effect at all
- C) Kubernetes rejects the Service as invalid
- D) It converts the Service to ClusterIP automatically

<details>
<summary>Answer</summary>

**B** — This field is silently ignored on ExternalName Services — no error, no fallback behavior, just unused configuration.
Trap: A imagines a fallback mechanism that doesn't exist — ExternalName has exactly one behavior, CNAME redirection, with no conditional logic.

</details>

---

**Q4. What Host header does an external server receive when a pod accesses it via an ExternalName Service?**

- A) The external server's own real hostname
- B) The internal Service's name (e.g. `database-svc`), not the external hostname
- C) No Host header is sent at all
- D) The pod's own hostname

<details>
<summary>Answer</summary>

**B** — This is a real production gotcha: the app still addresses the internal Service name, so that's what ends up in the Host header, regardless of where DNS actually redirected the connection.
Trap: A assumes DNS redirection somehow rewrites application-layer headers too — it only affects DNS resolution, nothing at the HTTP layer.

</details>

---

**Q5. Can an ExternalName Service's target be another Kubernetes Service's own DNS name?**

- A) No, only external (non-Kubernetes) hostnames are valid
- B) Yes — CNAME chaining to a real resolvable hostname works, including another Service's internal DNS name
- C) Only if both Services are in the same namespace
- D) Only for headless Services

<details>
<summary>Answer</summary>

**B** — This is exactly Step 4's migration demo: `externalName` gets set to `backend-real-svc.default.svc.cluster.local`, a perfectly valid, resolvable DNS name.
Trap: C invents a same-namespace restriction that doesn't exist — the target just needs to be a resolvable hostname, full stop.

</details>

---

**Q6. When would a selectorless Service (from `02-service-internals`) be the right choice instead of ExternalName?**

- A) When the external target is a stable IP address, not a hostname
- B) Never — ExternalName always supersedes selectorless Services
- C) Only for internal cluster traffic
- D) Only when using NodePort

<details>
<summary>Answer</summary>

**A** — ExternalName needs a hostname; a selectorless Service with a manual EndpointSlice is the mechanism for a stable IP, since ExternalName explicitly can't handle IPs at all.
Trap: B treats the two as strictly ranked rather than suited to different situations — they solve genuinely different problems.

</details>

---

**Q7. `externalName` is accidentally set to `http://httpbin.org` instead of `httpbin.org`. What happens?**

- A) Kubernetes strips the scheme automatically
- B) It resolves fine — DNS ignores the scheme prefix
- C) It fails to resolve (NXDOMAIN) — the scheme prefix isn't a valid DNS label
- D) It's rejected at apply time with a validation error

<details>
<summary>Answer</summary>

**C** — Same failure signature as an IP address: `kubectl apply` doesn't validate `externalName` against real DNS syntax, so this is accepted, then fails silently at resolution time.
Trap: D assumes apply-time validation catches this — it doesn't; the failure only surfaces when something actually tries to resolve the name.

</details>

---

**Q8. Does ExternalName perform load balancing across multiple external endpoints?**

- A) Yes, automatically, using round-robin
- B) No — it returns a single CNAME; any load balancing is up to the external DNS itself
- C) Yes, but only in ipvs mode
- D) Only if `spec.ports` is set

<details>
<summary>Answer</summary>

**B** — kube-proxy is never involved with ExternalName Services at all — whatever load balancing exists is entirely a property of the external hostname's own DNS records, outside Kubernetes' control.
Trap: C ties this to a kube-proxy mode, but kube-proxy has no role in ExternalName Services whatsoever, in any mode.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
````