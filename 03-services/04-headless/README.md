# Headless Service

## Lab Overview

A headless service is a ClusterIP service with `clusterIP: None`. Unlike
regular services, it does not assign a virtual IP and does not use
kube-proxy for routing. Instead, CoreDNS returns the actual pod IP
addresses directly as A records.

```
Regular ClusterIP:
  nslookup backend-svc → 10.96.xxx.xxx (single virtual IP)
  kube-proxy routes to one of the pods

Headless Service:
  nslookup backend-headless → 10.244.1.5, 10.244.2.3, 10.244.1.8
  (all pod IPs returned — caller chooses or DNS round-robins)
```

**Real-world scenario:** StatefulSets require each pod to have a stable,
unique identity. A database cluster (MySQL, MongoDB, Cassandra) needs
pods to address each other directly by name — not through a load
balancer. A headless service combined with a StatefulSet gives each pod
a stable DNS name: `pod-0.service.namespace.svc.cluster.local`.

**What this lab covers:**
- Headless service — clusterIP: None
- DNS A records returned per pod (not a single virtual IP)
- StatefulSet stable pod DNS — the primary use case
- Headless with selector vs without selector
- Direct pod addressing via DNS
- Comparison: headless vs regular ClusterIP DNS behaviour

---

## Prerequisites

**Required Software:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl installed and configured

**Knowledge Requirements:**
- **REQUIRED:** Completion of [16-externalname](../16-externalname/)
- Basic understanding of StatefulSets (helpful)

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create a headless service and verify no ClusterIP is assigned
2. ✅ Verify DNS returns individual pod IPs not a single virtual IP
3. ✅ Create a StatefulSet with headless service for stable pod DNS
4. ✅ Resolve individual StatefulSet pods by stable DNS name
5. ✅ Explain when to use headless vs regular ClusterIP

## Directory Structure

```
17-headless/
├── README.md                        # This file
└── src/
    ├── headless-svc.yaml            # Headless service (clusterIP: None)
    ├── statefulset.yaml             # StatefulSet with headless service
    └── regular-svc.yaml             # Regular ClusterIP for comparison
```

---

## Understanding Headless Services

### What Makes a Service Headless

Services that are headless don't configure routes and packet forwarding
using virtual IP addresses and proxies; instead, headless Services
report the endpoint IP addresses of the individual pods via internal
DNS records, served through the cluster's DNS service.

To define a headless Service, you make a Service with `.spec.type` set
to `ClusterIP` (which is also the default for type), and you additionally
set `.spec.clusterIP` to `None`.

```yaml
spec:
  clusterIP: None   # ← this makes it headless
  selector:
    app: myapp
```

```
clusterIP: None    → headless — no virtual IP, no kube-proxy rules
clusterIP: ""      → NOT headless — Kubernetes auto-assigns an IP
clusterIP: <omit>  → NOT headless — Kubernetes auto-assigns an IP
```

> The string value `None` is a special case and is not the same as
> leaving the `.spec.clusterIP` field unset.

### DNS Behaviour — Headless vs Regular

```
Regular ClusterIP service:
  DNS query → single A record → ClusterIP (10.96.xxx.xxx)
  kube-proxy intercepts and routes to a pod

Headless service:
  DNS query → multiple A records → one per pod IP
  (10.244.1.5, 10.244.2.3, 10.244.1.8)
  No proxy — caller connects directly to pod

StatefulSet with headless service:
  Each pod gets its OWN stable DNS name:
  pod-0.headless-svc.default.svc.cluster.local → 10.244.1.5
  pod-1.headless-svc.default.svc.cluster.local → 10.244.2.3
  pod-2.headless-svc.default.svc.cluster.local → 10.244.1.8
```

### Why StatefulSets Need Headless Services

StatefulSets give pods stable identities (pod-0, pod-1, pod-2).
Combined with a headless service, each pod gets a stable DNS name
that resolves to its IP. Even if the pod restarts and gets a new IP,
the DNS name still resolves correctly.

```
Use case: MySQL primary-replica setup
  mysql-0.mysql-headless → MySQL primary (writable)
  mysql-1.mysql-headless → MySQL replica 1 (read-only)
  mysql-2.mysql-headless → MySQL replica 2 (read-only)

Application configures:
  write: mysql-0.mysql-headless:3306
  read:  mysql-1.mysql-headless:3306 or mysql-2.mysql-headless:3306

If mysql-1 restarts → gets new IP → DNS still resolves correctly
```

---

## Lab Step-by-Step Guide

---

### Step 1: Compare Regular vs Headless DNS

Deploy the same backend deployment twice — one with a regular ClusterIP
service and one with a headless service:

```bash
cd 17-headless/src

# Deploy backend
cat <<EOF | kubectl apply -f -
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
            - "-text=hello"
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

kubectl rollout status deployment/backend-deploy
```

**regular-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-regular
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

**headless-svc.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-headless
spec:
  type: ClusterIP
  clusterIP: None        # ← headless
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

```bash
kubectl apply -f regular-svc.yaml
kubectl apply -f headless-svc.yaml
kubectl get svc
```

**Expected output:**
```
NAME               TYPE        CLUSTER-IP      PORT(S)
backend-headless   ClusterIP   None            5678/TCP
backend-regular    ClusterIP   10.96.xxx.xxx   5678/TCP
```

```
backend-headless: CLUSTER-IP=None  → headless ✅
backend-regular:  CLUSTER-IP=10.96.xxx.xxx → regular ClusterIP
```

---

### Step 2: Verify DNS Difference

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
```

Inside the pod:

**Regular ClusterIP — single A record:**

```bash
nslookup backend-regular
```

**Expected output:**
```
Name:    backend-regular.default.svc.cluster.local
Address: 10.96.xxx.xxx     ← single ClusterIP
```

**Headless — multiple A records (one per pod):**

```bash
nslookup backend-headless
```

**Expected output:**
```
Name:    backend-headless.default.svc.cluster.local
Address: 10.244.1.x        ← pod 1 IP
Name:    backend-headless.default.svc.cluster.local
Address: 10.244.1.x        ← pod 2 IP
Name:    backend-headless.default.svc.cluster.local
Address: 10.244.2.x        ← pod 3 IP
```

```
3 A records returned — one per pod ✅
No virtual IP — caller connects directly to pod IP
```

**Dig for clearer output:**

```bash
dig backend-headless.default.svc.cluster.local
```

**Expected output:**
```
;; ANSWER SECTION:
backend-headless.default.svc.cluster.local. 5 IN A 10.244.1.x
backend-headless.default.svc.cluster.local. 5 IN A 10.244.1.x
backend-headless.default.svc.cluster.local. 5 IN A 10.244.2.x
```

Exit:

```bash
exit
```

---

### Step 3: StatefulSet with Headless Service

This is the primary production use case for headless services.

**statefulset.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql-headless   # ← links to headless service
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: mysql
          image: hashicorp/http-echo:0.2.3
          args:
            - "-text=Response from $(MY_POD_NAME)"
            - "-listen=:3306"
          env:
            - name: MY_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: 3306
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

```bash
kubectl apply -f statefulset.yaml
kubectl rollout status statefulset/mysql
kubectl get pods -l app=mysql -o wide
```

**Expected output:**
```
NAME      READY   STATUS    NODE
mysql-0   1/1     Running   3node-m02
mysql-1   1/1     Running   3node-m03
mysql-2   1/1     Running   3node-m02
```

> StatefulSet creates pods in ORDER (0, 1, 2) — not all at once.
> Each pod has a STABLE name that never changes: mysql-0, mysql-1, mysql-2.

---

### Step 4: Resolve Individual StatefulSet Pods by DNS

```bash
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- bash
```

Inside the pod:

**Resolve the headless service (all pods):**

```bash
nslookup mysql-headless
```

**Expected output:**
```
Name:   mysql-headless.default.svc.cluster.local
Address: 10.244.1.x   ← mysql-0
Name:   mysql-headless.default.svc.cluster.local
Address: 10.244.2.x   ← mysql-1
Name:   mysql-headless.default.svc.cluster.local
Address: 10.244.1.x   ← mysql-2
```

**Resolve individual pods by stable DNS name:**

```bash
nslookup mysql-0.mysql-headless
```

**Expected output:**
```
Name:   mysql-0.mysql-headless.default.svc.cluster.local
Address: 10.244.x.x   ← ONLY mysql-0's IP ✅
```

```bash
nslookup mysql-1.mysql-headless
```

**Expected output:**
```
Name:   mysql-1.mysql-headless.default.svc.cluster.local
Address: 10.244.x.x   ← ONLY mysql-1's IP ✅
```

**Connect directly to a specific pod:**

```bash
curl mysql-0.mysql-headless:3306
```

**Expected output:**
```
Response from mysql-0
```

```bash
curl mysql-1.mysql-headless:3306
```

**Expected output:**
```
Response from mysql-1
```

```
Direct pod addressing confirmed:
mysql-0.mysql-headless → always resolves to mysql-0 ✅
mysql-1.mysql-headless → always resolves to mysql-1 ✅

Even if mysql-1 restarts → gets new IP → DNS still resolves correctly
This is what stateful applications need
```

**Full FQDN format:**

```bash
# Full FQDN: <pod-name>.<service-name>.<namespace>.svc.cluster.local
nslookup mysql-2.mysql-headless.default.svc.cluster.local
```

Exit:

```bash
exit
```

---

### Step 5: StatefulSet Pod Restart — Stable DNS

Verify that after a pod restart, the DNS name still resolves (to the new IP):

```bash
# Delete mysql-1 (StatefulSet will recreate it)
kubectl delete pod mysql-1 --grace-period=0 --force

# Watch it restart
kubectl get pods -l app=mysql -o wide -w
```

**Expected output:**
```
mysql-0   1/1   Running   3node-m02
mysql-1   0/1   Pending   <none>      ← deleted, recreating
mysql-2   1/1   Running   3node-m02
mysql-1   1/1   Running   3node-m03   ← new pod, possibly new IP
```

```bash
# Resolve mysql-1 after restart — DNS still works
kubectl run netshoot --image=nicolaka/netshoot \
  --rm -it --restart=Never \
  -- nslookup mysql-1.mysql-headless
```

**Expected output:**
```
Name:   mysql-1.mysql-headless.default.svc.cluster.local
Address: 10.244.x.x   ← new IP after restart, but same DNS name ✅
```

---

### Step 6: Final Cleanup

```bash
kubectl delete -f statefulset.yaml
kubectl delete -f headless-svc.yaml
kubectl delete -f regular-svc.yaml
kubectl delete deployment backend-deploy --grace-period=0

kubectl get pods
kubectl get svc
kubectl get statefulsets
```

---

## Common Questions

### Q: What is the difference between clusterIP: None and clusterIP: ""?

**A:** `clusterIP: None` explicitly creates a headless service — no
virtual IP assigned. `clusterIP: ""` (empty string) means Kubernetes
should auto-assign an IP — the service gets a ClusterIP. Omitting
the field also results in auto-assignment. The string `None` is a
special case that must be set explicitly.

### Q: Can I use headless services without a StatefulSet?

**A:** Yes. You can use a headless service with a regular Deployment.
DNS will return all pod IPs. However, pod names in a Deployment are
random (not stable like mysql-0, mysql-1), so per-pod DNS names are
not meaningful with Deployments.

### Q: Does headless service support load balancing?

**A:** The DNS response returns multiple A records. The DNS client
(resolver) may randomize or round-robin the order. However there is
no kube-proxy load balancing. The application or DNS client chooses
which IP to use.

### Q: Why does StatefulSet require a headless service?

**A:** StatefulSet uses the headless service's name as the DNS
subdomain for per-pod DNS records. The `serviceName` field in the
StatefulSet spec links it to the headless service. Without this link,
pods would not get stable DNS names.

---

## What You Learned

In this lab, you:
- ✅ Created a headless service with `clusterIP: None`
- ✅ Confirmed CLUSTER-IP shows None in kubectl get svc
- ✅ Verified DNS returns multiple A records (one per pod) for headless
- ✅ Verified DNS returns single A record for regular ClusterIP
- ✅ Created a StatefulSet linked to a headless service
- ✅ Resolved individual pods by stable DNS name (pod-0.svc, pod-1.svc)
- ✅ Verified DNS name remains stable after pod restart

**Key Takeaway:** Headless services skip the virtual IP layer entirely.
DNS returns pod IPs directly. Their main use is StatefulSets — where
each pod needs a stable DNS identity. Regular Deployments use ClusterIP
services for transparent load balancing. StatefulSets use headless
services for direct pod addressing.

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl get svc` | Show CLUSTER-IP=None for headless services |
| `nslookup <headless-svc>` | Returns multiple A records (from inside pod) |
| `nslookup <pod-name>.<headless-svc>` | Resolve specific StatefulSet pod |
| `dig <svc>.default.svc.cluster.local` | Detailed DNS query |
| `kubectl get statefulsets` | List StatefulSets |
| `kubectl rollout status statefulset/<n>` | Monitor StatefulSet rollout |

---

## CKA Certification Tips

✅ **Headless = clusterIP: None (explicit — not empty string)**

✅ **Headless service shows CLUSTER-IP=None in kubectl get svc**

✅ **StatefulSet requires serviceName field pointing to headless service**

✅ **Per-pod DNS format:**
```
<pod-name>.<service-name>.<namespace>.svc.cluster.local
mysql-0.mysql-headless.default.svc.cluster.local
```

✅ **Headless has no kube-proxy rules — DNS returns pod IPs directly**

✅ **Use case summary:**
```
Regular ClusterIP → stateless apps, load balanced
Headless          → stateful apps, direct pod addressing (StatefulSets)
```