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
         → ClusterIP (frontend pods: hashicorp/http-echo)
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
│   ├── 03-frontend-deployment.yaml     # hashicorp/http-echo — 3 replicas
│   ├── 04-frontend-svc-nodeport.yaml   # NodePort service for frontend
│   └── break-fix/
│       ├── 01-selector-typo.yaml            # Embedded inline in README — not generated on disk
│       └── 02-port-target-port-swap.yaml    # Embedded inline in README — not generated on disk
├── 01-clusterip-nodeport-anki.csv
└── 01-clusterip-nodeport-quiz.md
```

---

## Recall Check — 02-deployments/03-deployment-strategies

Answer from memory before continuing — no peeking at the previous demo.

1. Does relabeling a canary Deployment's `metadata.labels` to say `track: stable` actually promote it?
2. What's the real resource cost of Blue-Green's "instant rollback" capability?
3. Why is Canary traffic split only approximate, not an exact percentage?

<details>
<summary>Answers</summary>

1. No — it only changes the Deployment object's own bookkeeping label. `spec.selector` and `spec.template.metadata.labels` are immutable, so the Pods it manages keep their real labels unchanged, and nothing about Service routing changes either.
2. Running two full production-sized environments simultaneously — roughly 2x the compute cost for however long both versions coexist.
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

---

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

---

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

---

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

---

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

---

### TPS — Memory Aid for Service Spec Fields

```
T → type       (ClusterIP, NodePort, LoadBalancer, ExternalName)
P → ports      (port, targetPort, nodePort, protocol)
S → selector   (matchLabels — which pods this service routes to)

"TPS — Type, Ports, Selector"
```

---

## Lab Step-by-Step Guide

By the end of this walkthrough you'll have a working two-tier
application: a `backend` Deployment (3 replicas) reachable only inside
the cluster via a **ClusterIP** Service, and a `frontend` Deployment
(3 replicas) reachable from outside the cluster via a **NodePort**
Service — with the frontend calling the backend internally by DNS name.
Steps 1–4 build that; Steps 5–8 verify and observe it working (DNS,
load balancing, self-updating endpoints); Step 9 rebuilds the same
Services imperatively for exam practice; Step 10 tears everything down.

### Step 1: Cluster Setup

Before deploying anything, confirm the cluster is in the expected state
this whole demo assumes — three Ready nodes, with the control plane
tainted so workload pods land only on the two workers.

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

This step creates the backend tier — 3 replicas, not yet reachable by
anything since no Service exists for them yet (that's Step 3).

#### Backend Deployment

`hashicorp/http-echo` is a lightweight in-memory web server that echoes
back whatever text you configure via `-text`. The `$(MY_POD_NAME)`
Downward API injection (see the note below the manifest) is this
demo's one notable addition — everything else here is standard
Deployment shape already covered in `02-deployments`.

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
        - name: backend
          image: hashicorp/http-echo:1.0.0
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

> `$(MY_POD_NAME)` injects the pod's own name into the response text via
> the Downward API — so which pod actually answered a request is visible
> directly in the response, not just inferable from the fact that a
> request succeeded. This makes the load-balancing you'll observe in
> Step 5 and Step 7 genuinely visible, not just assumed.

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

With backend pods running but nothing routing to them yet, this step
creates the Service that gives them a stable internal address — the
`backend-svc` that Steps 5 and beyond will call by name.

#### Backend ClusterIP Service

This Service spec gives the 3 backend pods a stable internal address,
selecting them by their `app: backend` label and translating its own
`port: 9090` to the container's actual `targetPort: 5678`. Nothing
outside this step applies the file directly, but every later step that
reaches the backend — Step 5's DNS/curl test, Step 7's load-balancing
check — is calling through the Service this file creates.

**`02-backend-svc-clusterip.yaml`:**

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
    - port: 9090 # service listens on 9090
      targetPort: 5678 # container listens on 5678
      protocol: TCP
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.type` | No — defaults to `ClusterIP` | Set explicitly here for clarity; omitting it has the identical effect |
| `spec.selector` | Yes | Which pods this Service routes to — matched against pod labels, not the Deployment object itself |
| `spec.ports[].port` | Yes | Port the Service itself listens on — what other pods/clients use to reach it |
| `spec.ports[].targetPort` | No — defaults to same value as `port` | Port the container actually listens on; only needs to differ when the app's internal port differs from the Service's external-facing port |
| `spec.ports[].protocol` | No — defaults to `TCP` | Set explicitly here for clarity |

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

### Step 4: Deploy Frontend

With the backend fully reachable internally, this step adds the second
tier — the frontend pods that will eventually be exposed externally in
Step 6, and that call the backend by name in Step 5.

#### Frontend Deployment

Same `hashicorp/http-echo` + Downward API pattern as the backend, just
listening on port 80 instead of the default 5678 (`-listen=:80`) — this
demo is entirely about Service mechanics, not the applications behind
them, so keeping both tiers on the same simple, distinguishable image
keeps the focus there.

**`03-frontend-deployment.yaml`:**

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
          image: hashicorp/http-echo:1.0.0
          args:
            - "-listen=:80"
            - "-text=Hello from frontend pod $(MY_POD_NAME)"
          env:
            - name: MY_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
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

This step proves the backend is actually reachable the way an
application inside the cluster would reach it — by DNS name, not by IP
— using `nicolaka/netshoot`, a production-grade network debug container
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
Hello from backend pod backend-deploy-xxxxxxxxx-aaaaa
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
for i in $(seq 1 6); do curl -s backend-svc:9090; echo; done
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

> Load balancing is genuinely visible here, not just assumed — six
> requests, landing across different pods, exactly the distribution
> `backend-svc`'s Endpoints predict. `02-service-internals` builds on
> this same technique to inspect the iptables mechanics actually
> producing this distribution.

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

Internal connectivity is proven — this step makes the frontend reachable
from *outside* the cluster too, completing the two-tier architecture
from this demo's Lab Overview.

#### Frontend NodePort Service

This Service provisions a ClusterIP automatically (per Concepts above)
in addition to opening `nodePort: 31000` on every node — the field that
actually makes the frontend reachable from outside the cluster, which is
this step's whole point.

**`04-frontend-svc-nodeport.yaml`:**

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
    - port: 80         # ClusterIP port (internal)
      targetPort: 80   # container port
      nodePort: 31000  # external port on every node (30000-32767)
      protocol: TCP
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.type` | Yes (must be set to `NodePort` explicitly) | Unlike `ClusterIP`, this is never the default — must be stated |
| `spec.selector` | Yes | Which pods this Service routes to |
| `spec.ports[].port` | Yes | The auto-provisioned ClusterIP's own port — internal cluster traffic still uses this |
| `spec.ports[].targetPort` | No — defaults to same value as `port` | Port the container actually listens on |
| `spec.ports[].nodePort` | No — auto-assigned from 30000-32767 if omitted | The port opened on every node; set explicitly here so it's predictable for curl commands later in this step |
| `spec.ports[].protocol` | No — defaults to `TCP` | Set explicitly here for clarity |

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
Hello from frontend pod frontend-deploy-xxxxxxxxx-aaaaa
```

```bash
# Also works via 3node-m03 — same port on every node
curl http://192.168.58.4:31000
```

**Expected output:**

```
Hello from frontend pod frontend-deploy-xxxxxxxxx-bbbbb
```

> Port 31000 is open on ALL nodes — not just nodes running frontend pods.
> Traffic arriving at any node is forwarded to a frontend pod regardless
> of which node the pod is on — and the differing pod name in each
> response is direct proof of that, not an assumption. This is kube-proxy
> in action — exactly how it programs this is `02-service-internals`'s
> entire subject.

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

This step confirms two things: that repeated external requests actually
spread across all 3 frontend pods (not just one), and that the
Endpoints list stays accurate as replica count changes.

```bash
# Hit NodePort 10 times — observe requests distributed across pods
for i in $(seq 1 10); do
  curl -s http://192.168.58.3:31000
  echo
done
```

**Expected output — different pod names, direct proof of distribution:**

```
Hello from frontend pod frontend-deploy-xxxxxxxxx-aaaaa
Hello from frontend pod frontend-deploy-xxxxxxxxx-bbbbb
Hello from frontend pod frontend-deploy-xxxxxxxxx-ccccc
Hello from frontend pod frontend-deploy-xxxxxxxxx-aaaaa
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
    - name: frontend
      image: hashicorp/http-echo:1.0.0
      args:
        - "-listen=:80"
        - "-text=Hello from extra-frontend"
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

Everything built so far used YAML. This step rebuilds equivalent
Services imperatively — the faster, exam-relevant path — then cleans
those throwaway copies up before the real teardown in Step 10.

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
> `appendix-kubectl/01-kubectl-fundamentals` — useful here for adding
> fields not available imperatively (e.g. a fixed `nodePort` value).

**Cleanup imperative services:**

```bash
kubectl delete svc backend-svc-imperative frontend-svc-imperative
```

---

### Step 10: Final Cleanup

Tear down everything created in Steps 1–8, in reverse dependency order
(Services before the Deployments they select).

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

- ✅ Deployed a two-tier application — frontend + backend, both distinguishable per-pod via the Downward API
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

> **Both scenarios below are self-contained** — the main lab's Step 10
> cleanup already removed everything, so each one deploys its own
> throwaway backend rather than assuming `backend-deploy` is still
> running.

### Error-1 — "My Service exists, but nothing ever reaches a pod"

**The scenario:** you've deployed a backend and a Service meant to front
it, `kubectl apply` succeeded with no errors, but every request to the
Service just hangs — no connection refused, no clear error, just
silence. Investigate and fix it.

```bash
# Self-contained: deploy a throwaway backend for this scenario
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: breakfix-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: breakfix-backend
  template:
    metadata:
      labels:
        app: breakfix-backend
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: backend
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Hello from breakfix backend"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/breakfix-backend
```

**`src/break-fix/01-selector-typo.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc-typo
spec:
  type: ClusterIP
  selector:
    app: breakfix-backedn # typo: should be "breakfix-backend"
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

**Cause:** The selector's value is `breakfix-backedn` (typo), which matches no pod's actual `app: breakfix-backend` label. This is valid YAML — Kubernetes accepts it without complaint — it simply results in a Service with no matching pods.

**Fix:** Correct the selector to `app: breakfix-backend` and reapply.

**Cascade:** `kubectl get endpoints backend-svc-typo` shows an empty Endpoints list — not an error, just nothing. Every request to this Service fails or hangs with no Kubernetes-level error pointing at the actual cause. `kubectl describe svc backend-svc-typo` confirms the selector value but doesn't flag it as wrong, since Kubernetes has no way to know a label typo from an intentional selector.

</details>

**Cleanup:**

```bash
kubectl delete svc backend-svc-typo 2>/dev/null || true
kubectl delete deployment breakfix-backend 2>/dev/null || true
```

---

### Error-2 — "Endpoints look healthy, but requests still fail"

**The scenario:** a teammate swears the Service is misconfigured, but
`kubectl describe svc` shows healthy, correctly-selected Endpoints —
the pods are Running and Ready. Requests still hang anyway. If the
selector and the pods are both fine, what else could it be?

```bash
# Self-contained: deploy a throwaway backend for this scenario
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: breakfix-backend2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: breakfix-backend2
  template:
    metadata:
      labels:
        app: breakfix-backend2
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: backend
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=Hello from breakfix backend 2"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/breakfix-backend2
```

**`src/break-fix/02-port-target-port-swap.yaml`:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc-swapped
spec:
  type: ClusterIP
  selector:
    app: breakfix-backend2
  ports:
    - port: 5678 # swapped — this should be targetPort's value
      targetPort: 9090 # swapped — backend doesn't listen here
```

```bash
kubectl apply -f 02-port-target-port-swap.yaml
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- curl -s backend-svc-swapped:5678
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `port` and `targetPort` got swapped. The Service correctly accepts connections on `port: 5678`, but forwards them to `targetPort: 9090` — a port the `hashicorp/http-echo` container isn't actually listening on (it listens on 5678, per this scenario's own Deployment).

**Fix:** Swap the values back: `port: 9090`, `targetPort: 5678`.

**Cascade:** The `curl` request hangs or times out rather than giving a clear "connection refused" — from outside the pod there's no way to see that the request reached a real pod IP but hit a closed port. `kubectl describe svc` still shows healthy Endpoints (the pods are fine, Ready, selected correctly) — this is purely a port-mapping mistake, not a selector or pod-health problem, which is exactly what makes it a distinct failure mode from Error-1.

</details>

**Cleanup:**

```bash
kubectl delete svc backend-svc-swapped 2>/dev/null || true
kubectl delete deployment breakfix-backend2 2>/dev/null || true
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

Create a Deployment named `web` running `nginx:1.30.4` with 2 replicas, then expose it as a NodePort Service on port 80 with a fixed `nodePort` of 30080.

Official docs: [Service](https://kubernetes.io/docs/concepts/services-networking/service/)

<details>
<summary>Reveal solution</summary>

```bash
kubectl create deployment web --image=nginx:1.30.4 --replicas=2
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

See `appendix-kubectl/01-kubectl-fundamentals` for the full canonical `--dry-run=client` vs `--dry-run=server` explanation — this demo only applies the technique, it doesn't re-teach it.

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

```
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
"Does spec.ports[].protocol need to be set explicitly?","No — it defaults to TCP if omitted, same as omitting spec.type defaults to ClusterIP","demo01-services,service-fields,cka-services-networking"
```

---

## Appendix — Quiz

**`01-clusterip-nodeport-quiz.md`:**


````markdown
# Quiz — 03-services/01-clusterip-nodeport: ClusterIP and NodePort Services

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. This demo's backend and frontend both inject `$(MY_POD_NAME)` into their response text via the Downward API. What specifically does this let you verify that a plain, identical response couldn't?**

- A) It proves the Service has the correct `targetPort`
- B) It makes load balancing directly observable — you can see which specific pod answered each request, not just that a request succeeded
- C) It's required for `kubectl describe svc` to show Endpoints at all
- D) It changes how kube-proxy selects a pod

<details>
<summary>Answer</summary>

**B** — Without distinguishing data per pod, six successful `curl`s tell you nothing about distribution; injecting the pod name turns "it worked" into "here's exactly which pod handled each one."
Trap: D imagines the response content influences routing — it doesn't; routing happens before the request ever reaches the container.

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
Trap: C sounds plausible if you've heard "StatefulSets give stable identity," but that's stable *network identity via DNS*, not stable *IP addresses*.

</details>

---

**Q3. `spec.ports[].protocol` is omitted from a Service manifest entirely. What actually happens?**

- A) `kubectl apply` rejects the manifest as incomplete
- B) It defaults to `TCP`, the same way `spec.type` defaults to `ClusterIP` when omitted
- C) The Service is created with no protocol at all, and never routes traffic
- D) It defaults to whatever protocol the container's image uses internally

<details>
<summary>Answer</summary>

**B** — Same defaulting pattern this demo relies on elsewhere (omit `type` → get `ClusterIP`) — omitting `protocol` isn't an error, it just falls back to the common case.
Trap: D invents a mechanism where Kubernetes inspects the container image to infer protocol — nothing in the Service API works that way.

</details>

---

**Q4. This demo's `describe svc backend-svc` output shows `IP Family Policy: SingleStack`. What would need to be true of this cluster for that value to instead show `PreferDualStack`?**

- A) The cluster would need to be running on a cloud provider
- B) The cluster would need to be configured for dual-stack networking, giving Services both an IPv4 and IPv6 ClusterIP at once
- C) `SingleStack` is hardcoded and can never be changed
- D) It only changes once a NodePort Service is created

<details>
<summary>Answer</summary>

**B** — This cluster defaults to `SingleStack` because it isn't configured for dual-stack — the field itself is a genuine cluster/Service-level setting, not a fixed constant.
Trap: C treats an observed default as an unchangeable fact, when the demo's own Concepts explicitly frame it as configuration-dependent.

</details>

---

**Q5. A user reaches a NodePort service via a worker node's IP but reports it doesn't work via the control-plane node's IP on the same port. Is that expected Kubernetes behavior?**

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

**Q6. `kubectl apply` on a Service succeeds with no errors, but `curl` to it from another pod hangs indefinitely. What's the first command you'd run to start diagnosing, and why?**

- A) `kubectl logs` on the Service — Services don't have logs, so this doesn't apply
- B) `kubectl get endpoints <svc-name>` — an empty list immediately narrows the problem to the selector, not the network
- C) Restart the cluster
- D) `kubectl delete` and recreate the Service

<details>
<summary>Answer</summary>

**B** — Checking Endpoints first is the fastest way to split "selector problem" from "everything else."
Trap: A is a real trap for people newer to Kubernetes — Services genuinely have no logs of their own, since they don't run anything.

</details>

---

**Q7. This demo's backend Service is created before the frontend Deployment even exists in Step 4. Why does that ordering not cause a problem?**

- A) It does cause a problem — Services must be created after their target pods
- B) A Service with no matching Ready pods yet simply has an empty Endpoints list until matching pods appear; nothing about creating it early is invalid
- C) Kubernetes queues the Service creation until pods exist
- D) `kubectl apply` automatically reorders manifests by dependency

<details>
<summary>Answer</summary>

**B** — A Service's own existence is completely independent of whether anything currently matches its selector — this is the same "entirely derived and self-updating" Endpoints behavior demonstrated later in Steps 7-8, just observed from the other direction (before any Pods exist at all, rather than after scaling).
Trap: D invents a smart-ordering behavior `kubectl apply` doesn't have — manifests are applied in the order given (or per-file), with no dependency resolution.

</details>

---

**Q8. On the exam, you need a Service's external port to be a specific fixed number every time you recreate it. What's the reliable way to guarantee that?**

- A) `kubectl expose` with `--port` set to the desired number
- B) Set `spec.ports[].nodePort` explicitly in YAML — `kubectl expose` alone can't pin it
- C) NodePort values are always randomly assigned, no way to fix them
- D) Use `--type=LoadBalancer` instead

<details>
<summary>Answer</summary>

**B** — `--port` controls the ClusterIP-facing port, not `nodePort` — to pin the actual external port you need `spec.ports[].nodePort` set explicitly.
Trap: C overcorrects — nodePort *can* be fixed, just not through `kubectl expose`'s flags alone.

</details>

---

**Q9. Why does this demo route `frontend-svc` (NodePort) → `frontend` pods, and separately have those frontend pods call `backend-svc` (ClusterIP) by DNS name, instead of the frontend calling the backend via its own NodePort?**

- A) NodePort Services can't be reached from inside the cluster at all
- B) The backend is deliberately never exposed via NodePort — it only needs a ClusterIP, since nothing outside the cluster should reach it directly, per this demo's own real-world scenario
- C) ClusterIP is faster than NodePort for internal traffic
- D) DNS names only resolve for ClusterIP Services, not NodePort ones

<details>
<summary>Answer</summary>

**B** — This is a deliberate architecture choice stated in the Lab Overview, not a technical limitation — the backend is "never directly exposed," which is exactly why it only gets a ClusterIP.
Trap: D is factually wrong and worth ruling out explicitly — NodePort Services get a ClusterIP (and therefore a DNS name) automatically, same as any ClusterIP Service.

</details>

Score guide:

| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
````