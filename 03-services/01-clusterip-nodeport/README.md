# ClusterIP and NodePort Services

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

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured
- Control plane tainted (done in Demo 08)

**Knowledge Requirements:**
- **REQUIRED:** Completion of scheduling demos (Demo 06-12)
- Understanding of Deployments, labels and selectors
- Understanding of pod networking basics

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
01-clusterip-nodeport/
├── README.md                        # This file
└── src/
    ├── backend-deployment.yaml      # hashicorp/http-echo — 3 replicas
    ├── backend-svc-clusterip.yaml   # ClusterIP service for backend
    ├── frontend-deployment.yaml     # nginx:1.27 — 3 replicas
    └── frontend-svc-nodeport.yaml   # NodePort service for frontend
```

---

## Understanding Services

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

```yaml
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
Service's endpoints. Add a pod → it joins. Delete a pod → it leaves.
No manual endpoint management needed.
```

### Service Types — Nested Design

The type field in the Service API is designed as nested functionality — each level adds to the previous.

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

### NodePort — External Access

If you set the type field to NodePort, the Kubernetes control plane allocates a port from a range specified by --service-node-port-range flag (default: 30000-32767). Each node proxies that port (the same port number on every Node) into your Service.

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

**Why 30000-32767:**
This reserved range prevents collisions with well-known ports (0-1023)
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

---

### Step 1: Cluster Setup

```bash
cd 01-clusterip-nodeport/src

kubectl get nodes
```

**Expected output:**
```
NAME        STATUS   ROLES           AGE   VERSION
3node       Ready    control-plane   ...   v1.34.0
3node-m02   Ready    <none>          ...   v1.34.0
3node-m03   Ready    <none>          ...   v1.34.0
```

Verify control plane is tainted:

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
kubectl apply -f backend-deployment.yaml
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

**backend-svc-clusterip.yaml:**
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
kubectl apply -f backend-svc-clusterip.yaml
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
> list updates automatically — no manual changes needed.

---

### Step 4: Deploy Frontend — nginx

**frontend-deployment.yaml:**
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
kubectl apply -f frontend-deployment.yaml
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

> All responses say "Hello from backend" — to see WHICH pod answered,
> change the backend deployment args to include the pod hostname
> (see Step 9 for the enhanced version).

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

Exit the netshoot pod:

```bash
exit
```

---

### Step 6: Create NodePort Service for Frontend

**frontend-svc-nodeport.yaml:**
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
kubectl apply -f frontend-svc-nodeport.yaml
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
```html
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
```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

> Port 31000 is open on ALL nodes — not just nodes running frontend pods.
> Traffic arriving at any node is forwarded to a frontend pod regardless
> of which node the pod is on. This is kube-proxy in action.

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
# Create standalone pod with matching label
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
# Expose backend deployment as ClusterIP (same as backend-svc-clusterip.yaml)
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
> the resource. Redirect to a file and edit before applying — the
> approach from the CKA session transcripts. Useful for adding fields
> not available imperatively (e.g. nodePort value).

**Cleanup imperative services:**

```bash
kubectl delete svc backend-svc-imperative frontend-svc-imperative
```

---

### Step 10: Final Cleanup

```bash
kubectl delete -f frontend-svc-nodeport.yaml
kubectl delete -f frontend-deployment.yaml
kubectl delete -f backend-svc-clusterip.yaml
kubectl delete -f backend-deployment.yaml

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

## Common Questions

### Q: What is the difference between port and targetPort?

**A:** `port` is the port the Service listens on — what other pods
use to reach this service (e.g. `backend-svc:9090`). `targetPort` is
the port the container application actually listens on inside the pod
(e.g. `5678` for http-echo). The Service translates between them.
They can be the same value (common in production for simplicity) or
different (useful when you want to present a clean external port
without changing the application).

### Q: Does NodePort create a ClusterIP automatically?

**A:** Yes. To make the node port available, Kubernetes sets up a cluster IP address, the same as if you had requested a Service of type: ClusterIP. You can see this in the CLUSTER-IP column when you run `kubectl get svc` on a NodePort service.

### Q: Can I access a NodePort service via the control plane node IP?

**A:** Yes — the NodePort is opened on every node including the control
plane. However it is best practice to access via worker node IPs in
production since control plane nodes are often not in the load balancer
rotation.

### Q: What happens if I delete a pod that is an endpoint?

**A:** The endpoint is automatically removed from the service's
endpoint list within seconds. New requests are not routed to that pod.
When the Deployment creates a replacement pod, it is automatically
added back to the endpoint list once its readiness probe passes.

### Q: Why is EXTERNAL-IP shown as none for NodePort?

**A:** NodePort does not provision an external load balancer — it only
opens a port on each node. `EXTERNAL-IP` shows a value only for
LoadBalancer type services (covered in Demo 15) where a cloud provider
assigns an external IP automatically.

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

**Key Takeaway:** Services provide stable DNS names and virtual IPs for
ephemeral pods. ClusterIP is for internal communication — pods use it
to find each other by name. NodePort adds external access by opening a
port on every node. NodePort builds on ClusterIP — both are created
when you define a NodePort service. The selector is the glue — any pod
with the matching label is automatically part of the service.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get svc` | List all services |
| `kubectl describe svc <n>` | Show service details including endpoints |
| `kubectl get endpoints <n>` | Show pod IPs registered as endpoints |
| `kubectl expose deployment <n> --type=ClusterIP --port=<p> --target-port=<p>` | Create ClusterIP imperatively |
| `kubectl expose deployment <n> --type=NodePort --port=<p>` | Create NodePort imperatively |
| `kubectl expose deployment <n> --dry-run=client -o yaml` | Generate service YAML without creating |
| `minikube service <n> -p 3node --url` | Get NodePort URL on minikube |
| `kubectl get nodes -o wide` | Show node IPs for NodePort access |
| `kubectl explain svc.spec` | Browse Service spec field docs |

---

## CKA Certification Tips

✅ **Service API version — v1 (not apps/v1):**
```yaml
apiVersion: v1   # ← not apps/v1
kind: Service
```

✅ **TPS — memory aid for Service spec:**
```
T → type      ClusterIP (default), NodePort, LoadBalancer, ExternalName
P → ports     port, targetPort, nodePort, protocol
S → selector  matchLabels — which pods this service routes to
```

✅ **ClusterIP is the default — omitting type creates ClusterIP**

✅ **port vs targetPort:**
```
port       → what clients use to reach the SERVICE
targetPort → what the APPLICATION listens on in the container
```

✅ **NodePort range: 30000-32767**

✅ **NodePort automatically creates a ClusterIP**

✅ **Short name for service: svc**
```bash
kubectl get svc
kubectl describe svc <n>
```

✅ **Imperative service creation:**
```bash
# ClusterIP
kubectl expose deployment <n> --name=<svc-name> \
  --type=ClusterIP --port=9090 --target-port=5678

# NodePort
kubectl expose deployment <n> --name=<svc-name> \
  --type=NodePort --port=80 --target-port=80

# Generate YAML only
kubectl expose deployment <n> --dry-run=client -o yaml
```

✅ **Test connectivity quickly with netshoot:**
```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never -- bash
# Then: curl <service-name>:<port>
```

---

## Troubleshooting

**Service shows no endpoints:**
```bash
kubectl describe svc <n>
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
kubectl get svc <n>
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