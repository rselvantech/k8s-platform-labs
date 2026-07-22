# Demo: 03-services/01-clusterip-nodeport — ClusterIP and NodePort Services

## Lab Overview

Pods in Kubernetes are ephemeral — they get new IP addresses every time
they restart. If frontend pods had to know backend pod IPs directly, the
configuration would break every time a pod was replaced. Kubernetes
Services solve this by providing a stable IP address and DNS name that
never changes, regardless of what happens to the underlying pods.

This demo builds a realistic two-tier web application:

```
User → NodePort (frontend-svc:31000)
         → ClusterIP (frontend pods: nginx)
           → ClusterIP (backend-svc:9090)
             → ClusterIP (backend pods: hashicorp/http-echo)
```

**Real-world scenario:** A frontend web application serving users
externally (NodePort) while communicating internally with a backend API
(ClusterIP). The backend is never directly exposed — only reachable
within the cluster.

This demo introduces just enough of the DNS and kube-proxy mechanics to
understand what you're observing — full depth on both is covered later in
this same chapter, and forward-referenced at the relevant points below,
rather than repeated here.

**What this lab covers:**
- Why Services exist — stable IP and DNS for ephemeral pods
- ClusterIP — internal pod-to-pod communication
- Service fields — port, targetPort, selector, type
- NodePort — external access, automatic ClusterIP creation
- NodePort range (30000-32767) — why this range exists
- Service nested design — NodePort builds on ClusterIP
- Verifying connectivity using netshoot debug pod
- Observing load balancing across pod replicas
- Imperative commands — kubectl expose and kubectl create service

---

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of `01-core-concepts` and `02-deployments` (this demo assumes you already understand Pods, Deployments, and labels/selectors — none of that is re-explained here)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

**Control plane taint:** Step 1 below checks whether the control-plane
node is tainted (so workload pods don't get scheduled onto it) and applies
the taint itself if it's missing — this demo is self-sufficient on that
point, no separate prior demo is required to have done it first.

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create a ClusterIP service and verify it selects the correct pods
2. ✅ Verify internal pod-to-pod communication via ClusterIP
3. ✅ Observe DNS resolution of service names inside a pod
4. ✅ Create a NodePort service and access it externally
5. ✅ Explain that NodePort automatically creates a ClusterIP
6. ✅ Observe load balancing across multiple pod replicas
7. ✅ Create services imperatively using kubectl expose

## Directory Structure

```
03-services/01-clusterip-nodeport/
├── README.md
├── src/
│   ├── 01-backend-deployment.yaml      # hashicorp/http-echo — 3 replicas
│   ├── 02-backend-svc-clusterip.yaml   # ClusterIP service for backend
│   ├── 03-frontend-deployment.yaml     # nginx:1.27 — 3 replicas
│   ├── 04-frontend-svc-nodeport.yaml   # NodePort service for frontend
│   └── break-fix/
│       ├── 01-selector-typo.yaml            # Embedded inline in README — not generated on disk
│       └── 02-port-target-port-swap.yaml    # Embedded inline in README — not generated on disk
├── 01-clusterip-nodeport-anki.csv
└── 01-clusterip-nodeport-quiz.md
```

---

## Recall Check — 03-deployment-strategies

Answer from memory before continuing — no peeking at the previous demo.

1. What makes a Service's Endpoints list update instantly when you change its selector?
2. Does a pod that matches a Service's selector but isn't Ready receive traffic?
3. Why is Canary traffic split only approximate?

<details>
<summary>Answers</summary>

1. Kubernetes continuously recomputes Endpoints from the selector against currently Ready, matching pods.
2. No — only Ready pods become Endpoints, regardless of label match.
3. It's driven by pod-count ratio and round-robin load balancing, not a guaranteed percentage.

</details>

---

## Concepts

### Why Services Exist

```
Without Service:
  frontend pod → hardcoded backend pod IP (e.g. 10.244.1.5)
  backend pod restarts → gets new IP (e.g. 10.244.1.8)
  frontend breaks → cannot reach backend

With Service:
  frontend pod → backend-svc (stable DNS name — never changes)
  backend pod restarts → Service automatically updates endpoints
  frontend works → always reaches a healthy backend pod
```

### Service Fields

```
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  type: ClusterIP          # service type — default if omitted
  selector:                # which pods this service routes to
    app: backend
  ports:
    - port: 9090           # port the SERVICE listens on (cluster-facing)
      targetPort: 5678     # port the CONTAINER listens on (pod-facing)
      protocol: TCP        # default — can be omitted
```

**port vs targetPort — critical distinction:**

```
port       → the port you use to reach the SERVICE
             clients call: backend-svc:9090
             this is what other pods use

targetPort → the port your APPLICATION listens on inside the container
             hashicorp/http-echo listens on 5678 inside the container
             Service translates: 9090 → 5678

These can be the same or different. In production they are often
the same (e.g. port: 80, targetPort: 80 for nginx) but can differ
when you want to present a clean port externally without changing
the application's internal port.
```

**selector — how a Service finds its pods:**

```
Service selector:    app: backend
Pod labels:          app: backend

Any pod with label app=backend is automatically added to this
Service's endpoints — provided that pod is Ready (a Pod matching the
selector but not yet Ready is not added; full readiness-and-endpoints
mechanics are covered in 02-service-internals). Add a pod → it joins.
Delete a pod → it leaves. No manual endpoint management needed.
```

### Service Types — Nested Design

The `type` field in the Service API is designed as nested functionality — each level adds to the previous.

```
ClusterIP  → internal only
             stable virtual IP within cluster
             default type

NodePort   → external access
             builds ON TOP of ClusterIP
             allocates a port (30000-32767) on every node
             automatically creates a ClusterIP too

LoadBalancer → cloud provider external IP
               builds ON TOP of NodePort
               automatically creates NodePort and ClusterIP too
               (covered in a later demo, once this repo reaches a
               cloud-provider-backed cluster — not applicable to
               this minikube-based series)
```

### ClusterIP — Internal Communication

ClusterIP is the default service type. It assigns a virtual IP address
that is only reachable from within the cluster. Pods in any namespace
can reach it by service name — CoreDNS resolves the name to the
ClusterIP automatically.

```
backend-svc:9090
     ↓
CoreDNS resolves to ClusterIP (e.g. 10.96.74.12)
     ↓
kube-proxy routes to one of the backend pod endpoints
     ↓
Container port 5678 receives the request
```

The middle two steps here — exactly how CoreDNS resolves that name, and
exactly how kube-proxy performs that routing — are each the entire
subject of a dedicated demo later in this chapter:
`02-service-internals` for the kube-proxy/iptables mechanics,
`05-service-discovery` for the DNS resolution mechanics. This demo shows
you both working, without going deep into either yet.

### NodePort — External Access

If you set the type field to NodePort, the Kubernetes control plane allocates a port from a range specified by the `--service-node-port-range` flag (default: 30000-32767). Each node proxies that port (the same port number on every Node) into your Service.

```
External user → <any-node-IP>:31000
     ↓
Node receives on port 31000
     ↓
kube-proxy routes to ClusterIP (auto-created)
     ↓
ClusterIP routes to one of the frontend pod endpoints
     ↓
Container port 80 receives the request
```

**Why 30000-32767:** This reserved range prevents collisions with well-known ports (0-1023)
and ephemeral ports (typically 32768+). It keeps NodePort traffic
clearly identifiable and avoids conflicts with OS-assigned ports.

### TPS — Memory Aid for Service Spec Fields

```
T → type       (ClusterIP, NodePort, LoadBalancer, ExternalName)
P → ports      (port, targetPort, nodePort, protocol)
S → selector   (matchLabels — which pods this service routes to)

"TPS — Type, Ports, Selector"
```

---

## Lab Step-by-Step Guide

### Step 1: Cluster Setup

```bash
cd 03-services/01-clusterip-nodeport/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   ...   v1.34.0
3node-m02   Ready    <none>          ...   v1.34.0
3node-m03   Ready    <none>          ...   v1.34.0
```

Verify control plane is tainted (so workload pods land on the workers, not the control plane):

```bash
kubectl describe node 3node | grep Taints
```

**Expected output:**
```
Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

If not tainted:
```bash
kubectl taint nodes 3node node-role.kubernetes.io/control-plane:NoSchedule
```

---

### Step 2: Deploy Backend — hashicorp/http-echo

`hashicorp/http-echo` is a lightweight in-memory web server that echoes
back whatever text you configure via `--text` argument. Perfect for
demonstrating which pod answered a request.

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
            - "-text=Hello from backend"
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

```bash
kubectl apply -f 01-backend-deployment.yaml
kubectl rollout status deployment/backend-deploy
kubectl get pods -l app=backend -o wide
```

**Expected output:**
```
deployment.apps/backend-deploy successfully rolled out

NAME                              READY   STATUS    NODE
backend-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
backend-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m02
backend-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m03
```

Verify the app is working by checking pod logs:
```bash
kubectl logs -l app=backend --tail=2
```

**Expected output:**
```
2026/... server is listening on :5678
```

---

### Step 3: Create ClusterIP Service for Backend

**02-backend-svc-clusterip.yaml:**
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
    - port: 9090        # service listens on 9090
      targetPort: 5678  # container listens on 5678
      protocol: TCP
```

```bash
kubectl apply -f 02-backend-svc-clusterip.yaml
kubectl get svc backend-svc
```

**Expected output:**
```
NAME          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
backend-svc   ClusterIP   10.96.xxx.xxx   <none>        9090/TCP   5s
```

```
TYPE=ClusterIP      → internal only — no EXTERNAL-IP
PORT(S)=9090/TCP    → service port (not container port)
CLUSTER-IP          → stable virtual IP — never changes
```

Inspect the service in detail:
```bash
kubectl describe svc backend-svc
```

**Expected output:**
```
Name:              backend-svc
Namespace:         default
Selector:          app=backend
Type:              ClusterIP
IP Family Policy:  SingleStack
IP Families:       IPv4
IP:                10.96.xxx.xxx
Port:              <unset>  9090/TCP
TargetPort:        5678/TCP
Endpoints:         10.244.1.x:5678,10.244.1.x:5678,10.244.2.x:5678
Session Affinity:  None
```

```
Endpoints: 3 pod IPs listed → all 3 backend pods registered ✅
TargetPort: 5678 → traffic forwarded to container port 5678
Port: 9090 → service accepts traffic on port 9090
IP Family Policy / IP Families: SingleStack / IPv4
                     → this cluster's Services use only one IP family
                       (IPv4 here) rather than both simultaneously.
                       Kubernetes supports dual-stack networking (a
                       Service can have both an IPv4 and an IPv6
                       ClusterIP at once), controlled by this same
                       field set to PreferDualStack or RequireDualStack
                       instead — not something this demo's cluster is
                       configured for, so it defaults to SingleStack.
```

Verify endpoints directly:
```bash
kubectl get endpoints backend-svc
```

**Expected output:**
```
NAME          ENDPOINTS
backend-svc   10.244.1.x:5678,10.244.1.x:5678,10.244.2.x:5678
```

> When a pod matching the selector is added or removed, the endpoints
> list updates automatically — no manual changes needed. `kubectl get
> endpoints` is the older, now-deprecated view of this data — the
> current API (`EndpointSlices`), why it replaced this one, and full
> readiness-tracking detail are `02-service-internals`'s entire subject.

---

### Step 4: Deploy Frontend — nginx

**03-frontend-deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-deploy
spec:
  replicas: 3
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
kubectl apply -f 03-frontend-deployment.yaml
kubectl rollout status deployment/frontend-deploy
kubectl get pods -l app=frontend -o wide
```

**Expected output:**
```
deployment.apps/frontend-deploy successfully rolled out

NAME                               READY   STATUS    NODE
frontend-deploy-xxxxxxxxx-aaaaa    1/1     Running   3node-m02
frontend-deploy-xxxxxxxxx-bbbbb    1/1     Running   3node-m03
frontend-deploy-xxxxxxxxx-ccccc    1/1     Running   3node-m03
```

---

### Step 5: Verify ClusterIP — Internal Connectivity

Use `nicolaka/netshoot` — a production-grade network debug container
with curl, dig, nslookup, ss, and more pre-installed.

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
```

Inside the netshoot pod:

**Test 1 — Reach backend by service name:**
```bash
curl backend-svc:9090
```
**Expected output:**
```
Hello from backend
```

**Test 2 — DNS resolution of service name:**
```bash
nslookup backend-svc
```
**Expected output:**
```
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   backend-svc.default.svc.cluster.local
Address: 10.96.xxx.xxx
```
```
10.96.0.10 = CoreDNS service IP (kube-dns in kube-system namespace)
backend-svc.default.svc.cluster.local = fully qualified DNS name
10.96.xxx.xxx = ClusterIP of backend-svc
```

**Test 3 — Observe load balancing across pods:**
```bash
for i in $(seq 1 6); do curl -s backend-svc:9090; done
```
**Expected output:**
```
Hello from backend
Hello from backend
Hello from backend
Hello from backend
Hello from backend
Hello from backend
```
> All responses say "Hello from backend" — every pod runs the identical
> `-text` argument, so you can't tell which pod answered from this alone.
> This is fine for this demo's purposes; `02-service-internals` uses a
> per-pod-name variant of this same backend to make load balancing
> visible per-response.

**Test 4 — Check /etc/resolv.conf — how DNS works inside a pod:**
```bash
cat /etc/resolv.conf
```
**Expected output:**
```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```
```
nameserver 10.96.0.10  → CoreDNS IP — all DNS queries go here
search default.svc...  → search domains — why "backend-svc" resolves
                          without the full FQDN
ndots:5                → if name has fewer than 5 dots, try search
                          domains first before external DNS
```
> This is enough to understand what you just observed. The full
> mechanics — CoreDNS's Corefile and plugins, cross-namespace
> resolution, service environment variables, DNS policies, and a
> systematic debugging approach — are `05-service-discovery`'s entire
> subject.

Exit the netshoot pod:
```bash
exit
```

---

### Step 6: Create NodePort Service for Frontend

**04-frontend-svc-nodeport.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - port: 80          # ClusterIP port (internal)
      targetPort: 80    # container port
      nodePort: 31000   # external port on every node (30000-32767)
      protocol: TCP
```

```bash
kubectl apply -f 04-frontend-svc-nodeport.yaml
kubectl get svc frontend-svc
```

**Expected output:**
```
NAME           TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
frontend-svc   NodePort   10.96.xxx.xxx   <none>        80:31000/TCP   5s
```
```
TYPE=NodePort               → external access enabled
PORT(S)=80:31000/TCP        → 80=ClusterIP port, 31000=NodePort
CLUSTER-IP=10.96.xxx.xxx    → auto-created ClusterIP ✅
EXTERNAL-IP=<none>          → no cloud load balancer (expected on minikube)
```

Inspect the service:
```bash
kubectl describe svc frontend-svc
```
**Expected output:**
```
Name:                     frontend-svc
Type:                     NodePort
IP:                       10.96.xxx.xxx
Port:                     <unset>  80/TCP
TargetPort:               80/TCP
NodePort:                 <unset>  31000/TCP
Endpoints:                10.244.1.x:80,10.244.2.x:80,10.244.2.x:80
```
```
NodePort: 31000   → open on EVERY node in the cluster
Endpoints: 3 pods → all frontend pods registered ✅
ClusterIP: auto-created → NodePort builds on top of ClusterIP ✅
```

**Access frontend externally via NodePort:**
```bash
# Get minikube node IPs
kubectl get nodes -o wide
```
**Expected output:**
```
NAME        STATUS   INTERNAL-IP
3node       Ready    192.168.58.2
3node-m02   Ready    192.168.58.3
3node-m03   Ready    192.168.58.4
```

```bash
# Access via any node IP — all nodes proxy port 31000
curl http://192.168.58.3:31000
```
**Expected output:**
```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

```bash
# Also works via 3node-m03 — same port on every node
curl http://192.168.58.4:31000
```
**Expected output:**
```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```
> Port 31000 is open on ALL nodes — not just nodes running frontend pods.
> Traffic arriving at any node is forwarded to a frontend pod regardless
> of which node the pod is on. This is kube-proxy in action — exactly
> how it programs this is `02-service-internals`'s entire subject.

Alternatively use minikube service command:
```bash
minikube service frontend-svc -p 3node --url
```
**Expected output:**
```
http://192.168.58.3:31000
```

---

### Step 7: Verify Load Balancing — NodePort to Pods

```bash
# Hit NodePort 10 times — observe requests distributed across pods
for i in $(seq 1 10); do
  curl -s http://192.168.58.3:31000 | grep -o "Welcome to nginx"
done
```
**Expected output:**
```
Welcome to nginx
Welcome to nginx
Welcome to nginx
...
```

Verify endpoints are all healthy:
```bash
kubectl get endpoints frontend-svc
```
**Expected output:**
```
NAME           ENDPOINTS
frontend-svc   10.244.1.x:80,10.244.2.x:80,10.244.2.x:80
```

**Scale down and observe endpoints update automatically:**
```bash
kubectl scale deployment frontend-deploy --replicas=1
kubectl get endpoints frontend-svc
```
**Expected output:**
```
NAME           ENDPOINTS
frontend-svc   10.244.x.x:80    ← only 1 endpoint now
```

```bash
kubectl scale deployment frontend-deploy --replicas=3
kubectl get endpoints frontend-svc
# Verify 3 endpoints restored
```

---

### Step 8: Observe Service Selector in Action

Add a new pod with the same label — it is automatically added to the
service endpoints without any manual intervention:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: extra-frontend
  labels:
    app: frontend
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: nginx
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
EOF

kubectl get endpoints frontend-svc
```
**Expected output:**
```
NAME           ENDPOINTS
frontend-svc   10.244.1.x:80,10.244.2.x:80,10.244.2.x:80,10.244.x.x:80
                                                              ↑ new pod added ✅
```

The extra pod was automatically added to the service endpoints because
it has the `app: frontend` label matching the service selector.

```bash
kubectl delete pod extra-frontend --grace-period=0 --force
kubectl get endpoints frontend-svc
# Verify endpoint removed automatically
```

---

### Step 9: Imperative Commands

**Create service using kubectl expose:**
```bash
# Expose backend deployment as ClusterIP (same as 02-backend-svc-clusterip.yaml)
kubectl expose deployment backend-deploy \
  --name=backend-svc-imperative \
  --type=ClusterIP \
  --port=9090 \
  --target-port=5678

kubectl get svc backend-svc-imperative
```
**Expected output:**
```
NAME                     TYPE        CLUSTER-IP      PORT(S)
backend-svc-imperative   ClusterIP   10.96.xxx.xxx   9090/TCP
```

**Create NodePort service imperatively:**
```bash
kubectl expose deployment frontend-deploy \
  --name=frontend-svc-imperative \
  --type=NodePort \
  --port=80 \
  --target-port=80

kubectl get svc frontend-svc-imperative
```
**Expected output:**
```
NAME                      TYPE       CLUSTER-IP      PORT(S)
frontend-svc-imperative   NodePort   10.96.xxx.xxx   80:3xxxx/TCP
```
> Note: nodePort is auto-assigned when not specified imperatively.
> To specify a fixed nodePort imperatively, use --dry-run and edit
> the YAML before applying.

**Generate YAML using dry-run:**
```bash
kubectl expose deployment backend-deploy \
  --name=backend-svc-dry \
  --type=ClusterIP \
  --port=9090 \
  --target-port=5678 \
  --dry-run=client \
  -o yaml
```
**Expected output:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc-dry
spec:
  ports:
  - port: 9090
    protocol: TCP
    targetPort: 5678
  selector:
    app: backend
  type: ClusterIP
```
> `--dry-run=client -o yaml` generates the manifest without creating
> the resource, exactly the technique already covered in
> `01-core-concepts/04-kubectl-essentials` — useful here for adding
> fields not available imperatively (e.g. a fixed `nodePort` value).

**Cleanup imperative services:**
```bash
kubectl delete svc backend-svc-imperative frontend-svc-imperative
```

---

### Step 10: Final Cleanup

```bash
kubectl delete -f 04-frontend-svc-nodeport.yaml
kubectl delete -f 03-frontend-deployment.yaml
kubectl delete -f 02-backend-svc-clusterip.yaml
kubectl delete -f 01-backend-deployment.yaml

# Verify clean
kubectl get svc
kubectl get pods
kubectl get deployments
```

**Expected output:**
```
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   ...

No resources found in default namespace.
No resources found in default namespace.
```

---

## What You Learned

In this lab, you:
- ✅ Deployed a two-tier application — nginx frontend + http-echo backend
- ✅ Created a ClusterIP service and verified 3 backend endpoints registered
- ✅ Verified internal DNS resolution — `backend-svc` resolves via CoreDNS
- ✅ Verified load balancing — requests distributed across pod replicas
- ✅ Observed `/etc/resolv.conf` — how pods discover the DNS server
- ✅ Created a NodePort service and accessed frontend externally
- ✅ Confirmed NodePort automatically creates a ClusterIP
- ✅ Observed service selector — pods added/removed automatically
- ✅ Used kubectl expose and --dry-run=client for imperative service creation

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1

**`src/break-fix/01-selector-typo.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc-typo
spec:
  type: ClusterIP
  selector:
    app: backedn      # typo: should be "backend"
  ports:
    - port: 9090
      targetPort: 5678
```

```bash
kubectl apply -f 01-selector-typo.yaml
kubectl get endpoints backend-svc-typo
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The selector's value is `backedn` (typo), which matches no pod's actual `app: backend` label. This is valid YAML — Kubernetes accepts it without complaint — it simply results in a Service with no matching pods.

**Fix:** Correct the selector to `app: backend` and reapply.

**Cascade:** `kubectl get endpoints backend-svc-typo` shows an empty Endpoints list — not an error, just nothing. Every request to this Service fails or hangs with no Kubernetes-level error pointing at the actual cause. `kubectl describe svc backend-svc-typo` confirms the selector value but doesn't flag it as wrong, since Kubernetes has no way to know a label typo from an intentional selector.

</details>

**Cleanup:**
```bash
kubectl delete svc backend-svc-typo 2>/dev/null || true
```

---

### Error-2

**`src/break-fix/02-port-target-port-swap.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc-swapped
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5678         # swapped — this should be targetPort's value
      targetPort: 9090   # swapped — backend doesn't listen here
```

```bash
kubectl apply -f 02-port-target-port-swap.yaml
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- curl -s backend-svc-swapped:5678
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `port` and `targetPort` got swapped. The Service correctly accepts connections on `port: 5678`, but forwards them to `targetPort: 9090` — a port the `hashicorp/http-echo` container isn't actually listening on (it listens on 5678, per this demo's own Deployment).

**Fix:** Swap the values back: `port: 9090`, `targetPort: 5678` (matching `02-backend-svc-clusterip.yaml`).

**Cascade:** The `curl` request hangs or times out rather than giving a clear "connection refused" — from outside the pod there's no way to see that the request reached a real pod IP but hit a closed port. `kubectl describe svc` still shows healthy Endpoints (the pods are fine, Ready, selected correctly) — this is purely a port-mapping mistake, not a selector or pod-health problem, which is exactly what makes it a distinct failure mode from Error-1.

</details>

**Cleanup:**
```bash
kubectl delete svc backend-svc-swapped 2>/dev/null || true
```

---

## Interview Prep

**Q: What's the actual difference between `port` and `targetPort`?**
A: `port` is what other pods/clients use to reach the Service; `targetPort` is what the application inside the container actually listens on. The Service translates between them — they can be the same value or different.

**Q: Does NodePort create a ClusterIP automatically?**
A: Yes — setting up a NodePort also provisions a ClusterIP, visible in the `CLUSTER-IP` column of `kubectl get svc` even on a NodePort-type Service. NodePort is built as a layer on top of ClusterIP, not a replacement for it.

**Q: Can I access a NodePort service via the control-plane node's IP?**
A: Yes — the NodePort is opened on every node, including the control plane. In production it's more common to route through worker node IPs, since control-plane nodes are often excluded from load-balancer rotation.

**Q: What happens if I delete a pod that's currently a Service endpoint?**
A: It's removed from the endpoint list within seconds, and new requests stop being routed to it. Once the Deployment's controller creates a replacement and it passes readiness, it's added back automatically.

**Q: Why does `EXTERNAL-IP` show `<none>` for a NodePort service?**
A: NodePort doesn't provision an external load balancer — it only opens a port on every node. `EXTERNAL-IP` only gets populated for `LoadBalancer`-type Services, where a cloud provider actually assigns one.

**Q: A Service has healthy Endpoints, but requests to it still fail. What's a failure mode that `kubectl describe svc` alone won't reveal?**
A: A `port`/`targetPort` swap — the Service can have perfectly healthy, correctly-selected Endpoints and still forward traffic to a port nothing is listening on. `describe svc` shows the (wrong) port mapping as configured, not as validated against what the container actually listens on.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | ClusterIP, NodePort, port/targetPort, selectors |
| Services & Networking | CKAD | — | Service creation, imperative `kubectl expose` |
| Application Deployment | CKAD | — | Connecting a Deployment to a Service via labels |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Confusing `port` and `targetPort` | Easy to write them backwards under time pressure — the Service still applies without error, just silently forwards to the wrong place |
| A selector typo | Valid YAML, silently matches zero pods — no error message points at the cause; always cross-check against `kubectl get pods --show-labels` |
| Assuming `EXTERNAL-IP: <none>` means the Service is broken | It's expected and correct for both ClusterIP and NodePort — only `LoadBalancer` populates this field |
| Forgetting NodePort's range is 30000-32767 | Specifying a `nodePort` outside this range is rejected outright |
| Not checking `kubectl get endpoints` when a Service "isn't working" | Empty endpoints is the single fastest signal that the selector, not the network, is the problem |

### Exam Task — Write it from scratch

Create a Deployment named `web` running `nginx:1.27` with 2 replicas, then expose it as a NodePort Service on port 80 with a fixed `nodePort` of 30080.

Official docs: [Service](https://kubernetes.io/docs/concepts/services-networking/service/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=2
kubectl expose deployment web --port=80 --target-port=80 --type=NodePort --dry-run=client -o yaml > web-svc.yaml
# edit web-svc.yaml to set spec.ports[0].nodePort: 30080
kubectl apply -f web-svc.yaml
kubectl get svc web
```

**Key fields to recall:** `spec.type: NodePort`, `spec.ports[].port`, `spec.ports[].targetPort`, `spec.ports[].nodePort` (only settable via YAML, not directly via `kubectl expose`'s flags).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| A Service's stable identity solves pod ephemerality | Pods get new IPs on every restart; a Service's ClusterIP and DNS name never change |
| `port` vs `targetPort` are two different things | `port` is what clients use; `targetPort` is what the container actually listens on |
| NodePort is built on top of ClusterIP, not instead of it | Every NodePort Service also gets a ClusterIP automatically |
| NodePort opens the same port on every node | Regardless of which node actually runs a matching pod |
| A selector typo is silent | Valid YAML, zero matching pods, no error — check `get endpoints` and `get pods --show-labels` |
| Only Ready pods become Endpoints | Matching the selector alone isn't sufficient |
| `port`/`targetPort` mismatches are invisible in `describe svc` | The Service looks correctly configured even when it's forwarding to a port nothing listens on |
| `EXTERNAL-IP: <none>` is normal for ClusterIP and NodePort | Only `LoadBalancer` populates this field |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get svc` | List all services |
| `kubectl describe svc <name>` | Show service details including endpoints |
| `kubectl get endpoints <name>` | Show pod IPs registered as endpoints |
| `kubectl expose deployment <name> --type=ClusterIP --port=<p> --target-port=<p>` | Create ClusterIP imperatively |
| `kubectl expose deployment <name> --type=NodePort --port=<p>` | Create NodePort imperatively |
| `minikube service <name> -p 3node --url` | Get NodePort URL on minikube |
| `kubectl get nodes -o wide` | Show node IPs for NodePort access |
| `kubectl explain svc.spec` | Browse Service spec field docs |

### Generating YAML skeletons with --dry-run

```bash
kubectl expose deployment backend-deploy --name=backend-svc --type=ClusterIP --port=9090 --target-port=5678 --dry-run=client -o yaml
```
See `01-core-concepts/04-kubectl-essentials` for the full canonical `--dry-run=client` vs `--dry-run=server` explanation — this demo only applies the technique, it doesn't re-teach it.

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| Service (ClusterIP) | `kubectl expose deployment NAME --port=P --target-port=P` | `--type=ClusterIP` is the default, can be omitted |
| Service (NodePort) | `kubectl expose deployment NAME --port=P --type=NodePort` | `nodePort` auto-assigned unless set via YAML |

---

## Troubleshooting

**Service shows no endpoints:**
```bash
kubectl describe svc <name>
# Check Endpoints field — if empty, selector may not match pod labels
kubectl get pods --show-labels
# Verify pod labels match service selector exactly
```

**curl to service name fails from inside pod:**
```bash
# Verify DNS is working
nslookup <service-name>
# If DNS fails — check CoreDNS pods
kubectl get pods -n kube-system | grep coredns
# Try full FQDN
curl <service-name>.<namespace>.svc.cluster.local:<port>
```

**NodePort not accessible externally:**
```bash
# Verify NodePort is in 30000-32767 range
kubectl get svc <name>
# Get correct node IPs
kubectl get nodes -o wide
# Try different node IP — NodePort is on ALL nodes
curl http://<node-ip>:<nodeport>
```

**Wrong number of endpoints:**
```bash
kubectl get pods -l <selector> -o wide
# Check all pods are Ready (1/1) not just Running
# Unhealthy pods (0/1 Ready) are not added to endpoints
```

---

## Appendix — Anki Cards

**`01-clusterip-nodeport-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::01-clusterip-nodeport
#separator:Comma
#columns:Front,Back,Tags
"What problem do Services solve for pod IPs?","Pods are ephemeral and get new IPs on restart — a Service gives a stable IP and DNS name that never changes regardless of what happens to underlying pods","demo01-services,services,cka-services-networking"
"What's the difference between port and targetPort?","port is what clients use to reach the Service; targetPort is what the application actually listens on inside the container","demo01-services,port-targetport,cka-services-networking"
"Does NodePort create a ClusterIP automatically?","Yes — every NodePort Service also gets a ClusterIP, visible in kubectl get svc's CLUSTER-IP column","demo01-services,nodeport,cka-services-networking"
"What is the default NodePort range and why?","30000-32767 — reserved to avoid colliding with well-known ports (0-1023) and typical ephemeral ports (32768+)","demo01-services,nodeport,cka-services-networking"
"Is a NodePort only opened on nodes that actually run matching pods?","No — it's opened on every node in the cluster, regardless of where the matching pods actually run","demo01-services,nodeport,cka-services-networking"
"What happens if a Service selector has a typo?","It's valid YAML and silently matches zero pods — no error, check kubectl get endpoints and kubectl get pods --show-labels","demo01-services,troubleshooting,cka-troubleshooting"
"Does a port/targetPort swap show up as an error in kubectl describe svc?","No — the Service looks correctly configured; requests just silently fail to reach anything listening, since describe doesn't validate against what the container actually listens on","demo01-services,troubleshooting,cka-troubleshooting"
"Why does EXTERNAL-IP show <none> for a NodePort service?","NodePort doesn't provision an external load balancer, it only opens a port per node — EXTERNAL-IP only populates for LoadBalancer type","demo01-services,nodeport,cka-services-networking"
"Does a pod need to be Ready to become a Service Endpoint?","Yes — matching the selector alone isn't sufficient; only Ready pods are added to Endpoints","demo01-services,endpoints,cka-services-networking"
"What does nameserver 10.96.0.10 in a pod's /etc/resolv.conf point to?","CoreDNS's own Service IP (kube-dns, in kube-system) — every DNS query from any pod goes there first","demo01-services,dns,cka-services-networking"
"Why does 'backend-svc' resolve without a full FQDN inside a pod?","The search domains in resolv.conf get tried as suffixes before falling back to external DNS — this is what makes the short name work at all","demo01-services,dns,cka-services-networking"
"If you run kubectl expose deployment X --port=80 without --target-port, what does targetPort default to?","The same value as port — --target-port only needs to be set when the container listens on a different port","demo01-services,imperative,ckad-application-deployment"
"What Service type does kubectl expose default to if --type isn't specified?","ClusterIP","demo01-services,imperative,ckad-application-deployment"
"If you scale a Deployment from 3 to 1 replica, do you need to update its Service?","No — the Service's Endpoints list is recomputed automatically from the selector; nothing about the Service itself needs to change","demo01-services,endpoints,cka-services-networking"
"What does the TPS mnemonic stand for in a Service spec?","Type, Ports, Selector — the three field groups that define a Service","demo01-services,service-fields,cka-services-networking"
"Does LoadBalancer build on top of NodePort the same way NodePort builds on ClusterIP?","Yes — LoadBalancer automatically creates a NodePort and ClusterIP too, continuing the same nested pattern","demo01-services,service-types,cka-services-networking"
"Can you pin a Service's nodePort to a specific number using only kubectl expose flags?","No — kubectl expose has no flag for it; you must set spec.ports[].nodePort explicitly in YAML (or --dry-run=client -o yaml, then edit)","demo01-services,imperative,nodeport,ckad-application-deployment"
"If every backend pod returns an identical response, does that prove load balancing isn't happening?","No — it just means you can't tell from response content alone; you need distinguishing data per pod (e.g. pod name/hostname in the response) to actually verify load balancing is occurring","demo01-services,load-balancing,debugging,cka-troubleshooting"
"What does IP Family Policy: SingleStack mean on a Service?","The Service uses only one IP family (IPv4 or IPv6), not both at once — dual-stack Services exist via PreferDualStack/RequireDualStack instead, which this demo's cluster isn't configured for","demo01-services,networking,dual-stack,cka-services-networking"
````

---

## Appendix — Quiz

**`01-clusterip-nodeport-quiz.csv`:**


````markdown
# Quiz — 03-services/01-clusterip-nodeport: ClusterIP and NodePort Services

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. A Service shows 3 healthy Endpoints in `kubectl describe svc`, but every `curl` to it from inside the cluster hangs or fails. What's a cause that `describe svc` alone won't reveal?**

- A) The pods aren't actually running
- B) A `port`/`targetPort` swap — traffic reaches a pod but hits a port nothing is listening on
- C) The Service doesn't exist
- D) DNS is completely broken cluster-wide

<details>
<summary>Answer</summary>

**B** — `describe svc` shows the port mapping as configured, not validated against what the container actually listens on. Healthy Endpoints only confirms the *pods* are fine and selected correctly, not that the port mapping is correct.
Trap: A is ruled out by the premise — "3 healthy Endpoints" already means the pods are Running and Ready.

</details>

---

**Q2. A teammate says "when a pod dies, the Deployment should give the replacement the same IP so nothing breaks." What's wrong with this expectation?**

- A) Nothing — that's exactly what happens
- B) Pod IPs are inherently ephemeral and always change on recreation; a stable address is the Service's job, not the pod's
- C) Only StatefulSets guarantee stable pod IPs
- D) IPs stay the same, but ports change

<details>
<summary>Answer</summary>

**B** — Expecting IP stability from the Pod layer at all is the wrong mental model — that's precisely the problem Services solve, at a different layer entirely.
Trap: C sounds plausible if you've heard "StatefulSets give stable identity," but that's stable *network identity via DNS*, not stable *IP addresses* — a distinction this demo doesn't cover but is worth not overgeneralizing from.

</details>

---

**Q3. You run `kubectl expose deployment backend --port=9090` with no `--target-port`. What port does traffic actually get forwarded to on the container?**

- A) The container's default port, whatever that is
- B) 9090 — targetPort defaults to the same value as port when omitted
- C) The command fails, requiring --target-port explicitly
- D) Port 80, always

<details>
<summary>Answer</summary>

**B** — Omitting `--target-port` doesn't leave it unset — it defaults to match `--port`. You only need to specify it when the container listens on something different.
Trap: C assumes a required flag that isn't actually required — this command is valid and complete as written.

</details>

---

**Q4. You scale `frontend-deploy` from 3 replicas down to 1. What, if anything, do you need to change on `frontend-svc`?**

- A) Update the Service's selector to match only the remaining pod
- B) Nothing — Endpoints recompute automatically from the existing selector
- C) Delete and recreate the Service
- D) Manually remove the two terminated pods' IPs from Endpoints

<details>
<summary>Answer</summary>

**B** — The Service was never pointed at specific pods, only at a label — scaling changes which pods exist, and Endpoints tracks that automatically.
Trap: D imagines Endpoints as something manually maintained, when it's entirely derived and self-updating.

</details>

---

**Q5. A NodePort Service's `EXTERNAL-IP` column shows `<none>`. A teammate says this means something's misconfigured. Are they right?**

- A) Yes, EXTERNAL-IP should always be populated
- B) No — `<none>` is normal and expected for NodePort; only LoadBalancer populates it
- C) Only right if the cluster is on-prem
- D) Only right if using IPv6

<details>
<summary>Answer</summary>

**B** — This is documented, correct behavior for both ClusterIP and NodePort — neither type provisions an external load balancer.
Trap: A treats the absence of a field as inherently an error, without checking whether that field applies to this Service type at all.

</details>

---

**Q6. `kubectl apply` on a Service succeeds with no errors, but `curl` to it from another pod hangs indefinitely. What's the first command you'd run to start diagnosing, and why?**

- A) `kubectl logs` on the Service — Services don't have logs, so this doesn't apply
- B) `kubectl get endpoints <svc-name>` — an empty list immediately narrows the problem to the selector, not the network
- C) Restart the cluster
- D) `kubectl delete` and recreate the Service

<details>
<summary>Answer</summary>

**B** — Checking Endpoints first is the fastest way to split "selector problem" from "everything else" — an empty list means look at labels; a populated list means look elsewhere (like Q1's port mismatch).
Trap: A is a real trap for people newer to Kubernetes — Services genuinely have no logs of their own, since they don't run anything.

</details>

---

**Q7. A user reaches a NodePort service via a worker node's IP but reports it doesn't work via the control-plane node's IP on the same port. Is that expected Kubernetes behavior?**

- A) Yes — NodePort is only opened on worker nodes by design
- B) No — NodePort opens on every node including the control plane; something else (firewall, network path) is blocking it
- C) Yes, because the control plane is tainted
- D) It depends on the CNI plugin

<details>
<summary>Answer</summary>

**B** — The taint only affects *pod scheduling*, not NodePort's own behavior — kube-proxy opens the NodePort on every node regardless of taints or what's actually running there.
Trap: C sounds plausible because taints were just covered in Step 1, but a scheduling taint and NodePort's per-node listener are unrelated mechanisms.

</details>

---

**Q8. On the exam, you need a Service's external port to be a specific fixed number every time you recreate it. What's the reliable way to guarantee that?**

- A) `kubectl expose` with `--port` set to the desired number
- B) Set `spec.ports[].nodePort` explicitly in YAML — `kubectl expose` alone can't pin it
- C) NodePort values are always randomly assigned, no way to fix them
- D) Use `--type=LoadBalancer` instead

<details>
<summary>Answer</summary>

**B** — `--port` controls the ClusterIP-facing port, not `nodePort` — to pin the actual external port you need `spec.ports[].nodePort` set explicitly, which means YAML (or `--dry-run=client -o yaml` then edit).
Trap: C overcorrects — nodePort *can* be fixed, just not through `kubectl expose`'s flags alone.

</details>

---

**Q9. You `curl` a ClusterIP service 6 times and get an identical response every time. Does this prove load balancing isn't working?**

- A) Yes — identical responses mean all requests hit the same pod
- B) No — if every backend pod is configured to return the same content, you can't distinguish which pod answered from the response alone
- C) Yes, because kube-proxy only load-balances when responses differ
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — Verifying load balancing requires distinguishing data per pod (like a pod name embedded in the response) — identical output across pods is a testing-setup limitation, not evidence about routing behavior.
Trap: A and C both draw a routing conclusion from response *content*, when content and routing are actually independent of each other here.

</details>


Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
````