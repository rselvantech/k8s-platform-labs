# Demo: 03-services/04-headless — Headless Service

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

This demo introduces just enough StatefulSet to understand why headless
services matter — full StatefulSet depth (storage via
`volumeClaimTemplates`, update strategies, scaling order guarantees) is
`09-statefulsets`' entire subject, much later in this curriculum.

**What this lab covers:**
- Headless service — `clusterIP: None`
- DNS A records returned per pod (not a single virtual IP)
- Just enough StatefulSet to understand stable pod DNS — the primary use case
- Headless with selector vs without selector
- Direct pod addressing via DNS
- Comparison: headless vs regular ClusterIP DNS behaviour

---

## Prerequisites

**Required:**
- Minikube `3node` profile — 1 control plane + 2 workers
- kubectl configured for `3node`
- Completion of `03-externalname` (this demo assumes you already understand Service DNS mechanics — CNAME vs A records — from that demo and `01-clusterip-nodeport`)

```bash
kubectl get nodes
# 3node (control-plane)  Ready
# 3node-m02              Ready
# 3node-m03              Ready
```

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Create a headless service and verify no ClusterIP is assigned
2. ✅ Verify DNS returns individual pod IPs, not a single virtual IP
3. ✅ Explain just enough of what a StatefulSet is to understand why it needs a headless service
4. ✅ Resolve individual StatefulSet pods by stable DNS name
5. ✅ Explain when to use headless vs regular ClusterIP
6. ✅ Explain the difference between stable pod *identity* (what StatefulSet gives) and stable pod *IP* (which no controller gives — pod IPs are always ephemeral)
7. ✅ Explain what `publishNotReadyAddresses` does and why StatefulSets sometimes need it for peer discovery during startup

## Directory Structure

```
03-services/04-headless/
├── README.md
├── src/
│   ├── 01-regular-svc.yaml       # Regular ClusterIP for comparison
│   ├── 02-headless-svc.yaml      # Headless service (clusterIP: None)
│   ├── 03-statefulset.yaml       # StatefulSet + its own headless service
│   └── break-fix/
│       ├── 01-servicename-mismatch.yaml     # Embedded inline in README — not generated on disk
│       └── 02-clusterip-empty-string.yaml   # Embedded inline in README — not generated on disk
├── 04-headless-anki.csv
└── 04-headless-quiz.md
```

---

## Recall Check — 03-externalname

Answer from memory before continuing — no peeking at the previous demo.

1. What does an ExternalName Service actually do?
2. Can `externalName` be set to an IP address?
3. What happens if you add a `selector` field to an ExternalName Service?

<details>
<summary>Answers</summary>

1. Returns a DNS CNAME record pointing to an external hostname — pure DNS redirection, no proxying, no ClusterIP, no kube-proxy involvement.
2. No — it's treated as a DNS name made of digits and fails to resolve (NXDOMAIN).
3. Nothing — it's accepted by the API but has zero effect; ExternalName remains pure DNS redirection regardless.

</details>

---

## Concepts

### What Makes a Service Headless

Services that are headless don't configure routes and packet forwarding
using virtual IP addresses and proxies; instead, headless Services report
the endpoint IP addresses of the individual pods via internal DNS
records, served through the cluster's DNS service.

To define a headless Service, you make a Service with `.spec.type` set to
`ClusterIP` (which is also the default for type), and you additionally
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
> leaving the `.spec.clusterIP` field unset — this demo's Break-Fix
> Error-2 is built around exactly this distinction.

---

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

---

### Just Enough StatefulSet — Why It Needs a Headless Service

StatefulSet is a full controller type in its own right, with a lot more
to it (persistent per-pod storage via `volumeClaimTemplates`, ordered
scaling/update guarantees) than this demo touches — full depth is
`09-statefulsets`' entire subject. Here's just enough to understand why
it pairs with a headless service.

Unlike a Deployment (`02-deployments`), which gives pods random name
suffixes and treats them as interchangeable, a StatefulSet gives pods
**ordered, stable names**: `mysql-0`, `mysql-1`, `mysql-2` — created in
that order, one at a time, and never renumbered. This is a fundamentally
different identity model from everything covered so far in this series.

**Critical distinction — stable identity is not the same as a stable
IP.** `01-core-concepts/03-pod-container-basics` already established that
every pod's IP is ephemeral, full stop — that hasn't changed. A
StatefulSet pod that restarts still gets a **new IP**, exactly like any
other pod. What's stable is the **name** (`mysql-1`, always), and a
headless Service is what turns that stable name into a stable, always-
current **DNS record** — the DNS name doesn't change, even though the IP
behind it does.

```yaml
spec:
  serviceName: mysql-headless   # ← links the StatefulSet to its headless Service
  replicas: 3
```
The `serviceName` field is what connects the two objects — it tells the
StatefulSet controller which headless Service governs its pods' DNS
names. This demo's Break-Fix Error-1 shows what happens when that link
points at something that doesn't actually exist.

```
Use case: MySQL primary-replica setup
  mysql-0.mysql-headless → MySQL primary (writable)
  mysql-1.mysql-headless → MySQL replica 1 (read-only)
  mysql-2.mysql-headless → MySQL replica 2 (read-only)

Application configures:
  write: mysql-0.mysql-headless:3306
  read:  mysql-1.mysql-headless:3306 or mysql-2.mysql-headless:3306

If mysql-1 restarts → gets a NEW IP → DNS name still resolves correctly,
now pointing at that new IP
```

**One more accurate fact worth knowing:** unlike every other object type
in this series so far, there is **no `kubectl create statefulset`**
imperative subcommand at all — StatefulSets are YAML-only, no imperative
shortcut exists.

### publishNotReadyAddresses — Publishing DNS Before Readiness

Everything so far has assumed the default: a pod only gets a DNS record
once it's `Ready` — the exact same readiness-gating rule
`01-clusterip-nodeport` established for regular Service Endpoints applies
here too. For a headless Service, `spec.publishNotReadyAddresses: true`
turns that off — DNS starts returning a pod's record the moment the pod
exists, before it's passed any readiness check at all.

This sounds like it defeats the purpose of readiness, but it solves a
real, common StatefulSet problem: **peer discovery during startup.** A
clustered database's first pod often needs to find and contact its
sibling pods *before* any of them are individually ready to serve real
traffic — that's exactly when they're negotiating who's primary, joining
a raft/gossip cluster, or replicating initial state. If DNS only
published Ready pods, a pod couldn't even discover its peers until they
were already fully up — a chicken-and-egg problem for anything that
needs peer coordination *before* readiness. `publishNotReadyAddresses` is
what lets that discovery phase happen at all.

```yaml
spec:
  clusterIP: None
  publishNotReadyAddresses: true   # DNS record exists immediately,
                                    # not gated on readiness
  selector:
    app: mysql
```

This demo's own Step 5 (pod restart) demonstrates both sides of this
directly — the default readiness-gated behavior, and what changes once
`publishNotReadyAddresses` is set.

---

## Lab Step-by-Step Guide

By the end of this walkthrough you'll have deployed the same backend
behind two different Service objects — one regular ClusterIP, one
headless — to see the DNS difference directly, then built a 3-pod MySQL
StatefulSet behind its own headless Service to see the actual production
use case: per-pod DNS names that stay valid even as pods restart and get
new IPs. Steps 1–2 establish the headless-vs-regular contrast; Steps
3–5 build and probe the StatefulSet case.

### Step 1: Compare Regular vs Headless DNS

This step sets up the contrast the rest of the demo depends on — the
exact same backend pods, reachable through two different Services, so
Step 2 can query both and see the DNS difference directly.

```bash
cd 03-services/04-headless/src

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
          image: hashicorp/http-echo:1.0.0
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

#### Regular ClusterIP Service

A plain ClusterIP Service, identical in shape to every prior demo's —
its only role here is being the "before" side of Step 2's comparison.

**`01-regular-svc.yaml`:**
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

#### Headless Service

This demo's actual subject — a ClusterIP Service with `clusterIP: None`,
which (per Concepts above) skips virtual-IP/kube-proxy routing entirely
in favor of DNS returning pod IPs directly.

**`02-headless-svc.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-headless
spec:
  type: ClusterIP
  clusterIP: None        # the literal string "None" — not "" — is what makes this headless
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

| Field | Required / Default | Description |
|---|---|---|
| `spec.type` | No — defaults to `ClusterIP` | Set explicitly for clarity, same as a regular ClusterIP Service |
| `spec.clusterIP` | Yes — must be the literal string `None` | The entire mechanism — `""` or omitting the field both mean "auto-assign," not headless. See this demo's Break-Fix Error-2 |
| `spec.selector` | Yes | Same role as any selector-based Service — determines which pods' IPs DNS returns |

```bash
kubectl apply -f 01-regular-svc.yaml
kubectl apply -f 02-headless-svc.yaml
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

This step is the payoff of Step 1's setup — querying both Services'
names from the same pod to see the actual DNS response shape differ.

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash
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

This step builds the actual production pairing Step 1–2 were building
toward — a StatefulSet whose pods get individually-resolvable, stable
DNS names via its own dedicated headless Service.

#### MySQL StatefulSet and Headless Service

The headless Service here is functionally identical to Step 1's
`backend-headless` — what's new is the StatefulSet itself: ordered pod
creation (`mysql-0`, `mysql-1`, `mysql-2`, in that order), and the
`serviceName` field that links it to the headless Service above it in
this same file. The `readinessProbe`'s `initialDelaySeconds: 25` is not
a real health check — it's purely so Step 5 has a predictable window to
observe DNS behavior during a pod's not-yet-Ready state.

**`03-statefulset.yaml`:**
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
  serviceName: mysql-headless   # links to the headless Service above — see Concepts
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
          image: hashicorp/http-echo:1.0.0
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
          readinessProbe:
            exec:
              command: ["true"]
            initialDelaySeconds: 25   # predictable ~25s "not Ready" window,
                                       # purely so Step 5 can observe DNS
                                       # behavior during it — not a real
                                       # health check
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
```

| Object | Field | Required / Default | Description |
|---|---|---|---|
| Service | `spec.clusterIP` | Yes — literal `None` | Same headless mechanism from Step 1, reused here |
| Service | `ports[].name` | No, unless multi-port | Set here (`mysql`) as good practice, though this Service only has one port |
| StatefulSet | `spec.serviceName` | Yes | Must match the headless Service's `metadata.name` exactly — not validated at apply time, see this demo's Break-Fix Error-1 |
| StatefulSet | `spec.replicas` | Yes | Same field as a Deployment, but creates pods in order (`mysql-0` → `mysql-1` → `mysql-2`), never all at once |
| StatefulSet | `readinessProbe.initialDelaySeconds` | No — defaults to `0` | Demo-specific: set to 25 purely to make Step 5's readiness-gated DNS behavior observable |

```bash
kubectl apply -f 03-statefulset.yaml
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
> StatefulSet creates pods in ORDER (0, 1, 2) — not all at once, unlike a
> Deployment's ReplicaSet. Each pod has a STABLE **name** that never
> changes: `mysql-0`, `mysql-1`, `mysql-2` — remember, this is name
> stability, not IP stability (see Concepts above).

---

### Step 4: Resolve Individual StatefulSet Pods by DNS

This step proves the actual production payoff of Step 3's setup —
resolving one specific pod by name, not just the whole StatefulSet's
pod IPs together.

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- bash
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

Even if mysql-1 restarts → gets a new IP → DNS name still resolves,
now pointing at the new IP. This is what stateful applications need.
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

### Step 5: StatefulSet Pod Restart — Stable DNS, New IP

Verify that after a pod restart, the DNS name still resolves — to a new
IP, exactly as the distinction in Concepts predicts:

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
mysql-1   1/1   Running   3node-m03   ← new pod, new IP
```

```bash
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- nslookup mysql-1.mysql-headless
```
**Expected output:**
```
Name:   mysql-1.mysql-headless.default.svc.cluster.local
Address: 10.244.x.x   ← new IP after restart, same DNS name ✅
```

**Now observe the default readiness-gating behavior directly.** The
`readinessProbe` added in Step 3 delays readiness by ~25 seconds — repeat
the delete, but this time query DNS immediately, before the probe would
have passed:

```bash
kubectl delete pod mysql-1 --grace-period=0 --force
# immediately, don't wait:
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- nslookup mysql-1.mysql-headless
```
**Expected output — likely no record yet, or a `NXDOMAIN`-style failure:**
```
** server can't find mysql-1.mysql-headless.default.svc.cluster.local: NXDOMAIN
```
This is `publishNotReadyAddresses` currently at its default (`false`,
since Step 3's YAML never set it) — the new `mysql-1` pod exists but
isn't `Ready` yet, so it has no DNS record at all until the ~25s probe
delay passes.

**Now turn `publishNotReadyAddresses` on and repeat:**
```bash
kubectl patch svc mysql-headless -p '{"spec":{"publishNotReadyAddresses":true}}'
kubectl delete pod mysql-1 --grace-period=0 --force
# immediately again:
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- nslookup mysql-1.mysql-headless
```
**Expected output — resolves immediately, despite not being Ready:**
```
Name:   mysql-1.mysql-headless.default.svc.cluster.local
Address: 10.244.x.x   ← the NEW pod's IP, published before readiness ✅
```
Same pod, same restart, only the Service's
`publishNotReadyAddresses` value changed — that's the entire mechanism
from Concepts above, made directly observable.

```bash
# Revert to the default before moving on
kubectl patch svc mysql-headless -p '{"spec":{"publishNotReadyAddresses":false}}'
```

---

### Step 6: Final Cleanup

Tear down everything created in Steps 1–3.

```bash
kubectl delete -f 03-statefulset.yaml
kubectl delete -f 02-headless-svc.yaml
kubectl delete -f 01-regular-svc.yaml
kubectl delete deployment backend-deploy --grace-period=0

kubectl get pods
kubectl get svc
kubectl get statefulsets
```

---

## What You Learned

In this lab, you:
- ✅ Created a headless service with `clusterIP: None`
- ✅ Confirmed CLUSTER-IP shows None in `kubectl get svc`
- ✅ Verified DNS returns multiple A records (one per pod) for headless
- ✅ Verified DNS returns a single A record for regular ClusterIP
- ✅ Understood just enough StatefulSet to explain the ordered, stable pod naming and the `serviceName` link
- ✅ Resolved individual pods by stable DNS name (`pod-0.svc`, `pod-1.svc`)
- ✅ Verified the DNS name remains stable across a pod restart — while the underlying IP still changes, exactly as pod IP ephemerality (`01-core-concepts`) predicts
- ✅ Observed `publishNotReadyAddresses` directly — the same restart with it off (NXDOMAIN during the readiness delay) vs on (resolves immediately)

---

## Break-Fix

```bash
cd src/break-fix/
```

### Error-1 — "Per-pod DNS never resolves, but the StatefulSet looks fine"

**The scenario:** `kubectl get statefulset` and `kubectl get pods` both
report everything healthy, `mysql-0`/`mysql-1` exist with the expected
names — but nothing can resolve `mysql-0.mysql-headless` or reach the
pods by their per-pod DNS names. Investigate what's actually missing.

**`src/break-fix/01-servicename-mismatch.yaml`:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: broken-mysql
spec:
  serviceName: nonexistent-headless-svc   # points at a Service that doesn't exist
  replicas: 2
  selector:
    matchLabels:
      app: broken-mysql
  template:
    metadata:
      labels:
        app: broken-mysql
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: mysql
          image: hashicorp/http-echo:1.0.0
          args:
            - "-text=hello"
          ports:
            - containerPort: 3306
```

```bash
kubectl apply -f 01-servicename-mismatch.yaml
kubectl get pods -l app=broken-mysql
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- nslookup broken-mysql-0.nonexistent-headless-svc
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Kubernetes does **not** validate at apply time that
`spec.serviceName` actually refers to an existing Service, let alone a
headless one — this is documented as a requirement ("this service must
exist before the StatefulSet") but not API-enforced; only external
tooling like Helm's strict schema validation checks the field is
*present*, and nothing checks it points at something real. The
StatefulSet is accepted, and — this is the trap — the **pods still get
created successfully**, with the expected stable names
(`broken-mysql-0`, `broken-mysql-1`). Everything in `kubectl get pods`
looks completely healthy.

**Fix:** Create the actual headless Service (`clusterIP: None`,
`metadata.name: nonexistent-headless-svc`, selector matching
`app: broken-mysql`) — once it exists, DNS resolution starts working
immediately, no StatefulSet changes needed.

**Cascade:** This is a "looks fine, isn't" failure — `kubectl get
statefulset`/`kubectl get pods` both show healthy status the entire
time. The only symptom is that per-pod DNS names never resolve
(`nslookup broken-mysql-0.nonexistent-headless-svc` fails), which is
invisible unless something actually tries to use that addressing
scheme. In production this typically surfaces as "the app can't find its
peers," not as any Kubernetes-level error or event.

</details>

**Cleanup:**
```bash
kubectl delete statefulset broken-mysql 2>/dev/null || true
```

---

### Error-2 — "The Service was meant to be headless, but something's routing through it"

**The scenario:** a Service was written with the intent of being
headless — the author remembers setting `clusterIP` to "nothing" — but
`kubectl get svc` shows a real allocated IP instead of `None`. Find what
was actually written.

This scenario is self-contained — it doesn't need pods to exist at all;
the symptom it demonstrates (`kubectl get svc` showing an allocated
`CLUSTER-IP`) is visible the moment the Service itself is created.

**`src/break-fix/02-clusterip-empty-string.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: fake-headless
spec:
  type: ClusterIP
  clusterIP: ""       # empty string — NOT the same as None
  selector:
    app: backend
  ports:
    - port: 5678
      targetPort: 5678
```

```bash
kubectl apply -f 02-clusterip-empty-string.yaml
kubectl get svc fake-headless
```

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `clusterIP: ""` (empty string) is **not** the headless
directive — only the literal string `None` is. An empty string tells
Kubernetes "you choose an IP for me," which is exactly what would have
happened if the field were omitted entirely — so this Service silently
gets a completely normal ClusterIP allocated.

**Fix:** Change `clusterIP: ""` to `clusterIP: None`, exactly.

**Cascade:** `kubectl get svc fake-headless` shows a real IP in the
`CLUSTER-IP` column, not `None` — which is actually a very visible
signal once you know to check for it, unlike Error-1's silent failure.
But if you only skim the output expecting "some Service" rather than
specifically checking for `None`, this is easy to miss — `nslookup` on
this Service returns a single A record like any normal ClusterIP, not
the multiple-A-record headless behavior the YAML's *intent* implies.

</details>

**Cleanup:**
```bash
kubectl delete svc fake-headless 2>/dev/null || true
```

---

## Interview Prep

**Q: What's the difference between `clusterIP: None` and `clusterIP: ""`?**
A: `clusterIP: None` explicitly creates a headless service — no virtual IP assigned. `clusterIP: ""` (empty string) means Kubernetes should auto-assign an IP — the service gets a normal ClusterIP, identical to omitting the field entirely. The string `None` is a special case that must be set explicitly.

**Q: Can you use a headless service without a StatefulSet?**
A: Yes. You can use a headless service with a regular Deployment — DNS will return all pod IPs. However, pod names in a Deployment are random (not stable like `mysql-0`, `mysql-1`), so per-pod DNS names aren't meaningful outside a StatefulSet context.

**Q: Does a headless service support load balancing?**
A: The DNS response returns multiple A records, and the client's own DNS resolver may randomize or round-robin the order it tries them — but there's no kube-proxy load balancing involved at all. The application or DNS client chooses which IP to use, not Kubernetes.

**Q: Does StatefulSet give pods a stable IP address?**
A: No — this is a common misconception. Pod IPs are always ephemeral, StatefulSet or not, exactly as established in `01-core-concepts`. What StatefulSet gives is a stable **name**, and the headless Service turns that stable name into a DNS record that always points at the pod's *current* IP, whatever that happens to be at any moment.

**Q: A StatefulSet's `serviceName` points at a Service that doesn't exist. Does `kubectl apply` reject it?**
A: No — there's no validation linking the two at apply time. The StatefulSet and its pods create successfully regardless; only per-pod DNS resolution actually fails, silently, with nothing in `kubectl get` pointing at the cause.

**Q: Why does StatefulSet require a headless service specifically, rather than a regular ClusterIP one?**
A: A regular ClusterIP would just load-balance across all the pods behind a single virtual IP — exactly what you *don't* want when the whole point is addressing one specific, named pod directly. Headless skips the virtual IP entirely so DNS can expose each pod's real IP individually.

**Q: A clustered database's pods need to find each other before any of them pass their own readiness check. What Service field addresses this?**
A: `publishNotReadyAddresses: true` on the headless Service — it publishes a pod's DNS record the moment the pod exists, without waiting for readiness. Without it, pods can't discover each other via DNS until they're already individually ready, which is a chicken-and-egg problem for anything doing peer coordination (leader election, cluster join) during startup.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Domain | Exam | Weight | Covered here |
|---|---|---|---|
| Services & Networking | CKA | 20% | Headless Service mechanics, per-pod DNS |
| Workloads & Scheduling | CKA | 15% | StatefulSet ordered naming (just enough — full depth in `09-statefulsets`) |

### Common Exam Traps

| Trap | Why it trips people up |
|---|---|
| Writing `clusterIP: ""` instead of `clusterIP: None` | Both look like "no IP," but only the literal string `None` actually means headless — empty string means auto-assign |
| Assuming StatefulSet gives pods a stable IP | It gives a stable *name*; the IP is still ephemeral like any pod — the headless Service's DNS record is what stays current |
| Assuming `serviceName` is validated against a real Service | It isn't — a typo or nonexistent target still lets the StatefulSet and its pods create successfully, only DNS silently fails |
| Trying `kubectl create statefulset` | Doesn't exist — StatefulSets are YAML-only, unlike Deployments/Services/Jobs which all have imperative creation |
| Forgetting the per-pod DNS format | `<pod-name>.<service-name>.<namespace>.svc.cluster.local` — all four parts matter |
| Assuming a not-yet-Ready pod never has a DNS record | True only by default — `publishNotReadyAddresses: true` on the headless Service changes that, for peer-discovery-before-readiness scenarios |

### Exam Task — Write it from scratch

Create a headless Service named `web-headless` (selector `app: web`) and a StatefulSet named `web` with 3 replicas linked via `serviceName`, then resolve `web-1.web-headless` from a debug pod.

Official docs: [Headless Services](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services), [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)

<details>
<summary>Reveal solution</summary>

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None
  selector:
    app: web
  ports:
    - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
spec:
  serviceName: web-headless
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.30.4
```
```bash
kubectl apply -f web.yaml
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never -- nslookup web-1.web-headless
```

**Key fields to recall:** `spec.clusterIP: None` (exact string), `spec.serviceName` on the StatefulSet (must match the headless Service's `metadata.name`).

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `clusterIP: None` is the only way to create a headless Service | `clusterIP: ""` or omitting the field both mean "auto-assign," not headless |
| Headless DNS returns every pod's IP as a separate A record | No virtual IP, no kube-proxy involvement — the caller (or its resolver) picks |
| StatefulSet gives pods stable, ordered names — not stable IPs | Pod IPs remain ephemeral regardless of controller type; the headless Service's DNS record is what stays current |
| `serviceName` links a StatefulSet to its headless Service | Not validated at apply time — a typo or missing target lets pods create fine while per-pod DNS silently fails |
| Per-pod DNS format is fixed | `<pod-name>.<service-name>.<namespace>.svc.cluster.local` |
| There's no `kubectl create statefulset` | YAML-only — no imperative shortcut exists for this object type |
| A headless Service works with a Deployment too, just not usefully for per-pod addressing | Deployment pod names are random, so stable per-pod DNS names have nothing meaningful to attach to |
| A missing/wrong `serviceName` is a silent failure, not a startup error | Pods and StatefulSet both report healthy — only DNS resolution actually breaks |
| `publishNotReadyAddresses: true` publishes DNS before readiness | Solves the peer-discovery-during-startup problem — pods can find each other via DNS before any of them individually pass readiness |

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get svc` | Check CLUSTER-IP column — `None` confirms headless |
| `nslookup <headless-svc>` | Returns multiple A records (from inside a debug pod) |
| `nslookup <pod-name>.<headless-svc>` | Resolve one specific StatefulSet pod |
| `dig <svc>.default.svc.cluster.local` | Detailed DNS query |
| `kubectl get statefulsets` | List StatefulSets |
| `kubectl rollout status statefulset/<name>` | Monitor StatefulSet rollout |

### Generating YAML skeletons with --dry-run

Not applicable to the StatefulSet portion of this demo — there is no
`kubectl create statefulset` subcommand, so `--dry-run=client -o yaml`
has nothing to generate against for this object type. The headless
Service itself can still be generated via `kubectl create service
clusterip NAME --clusterip="None" --tcp=PORT --dry-run=client -o yaml`,
same technique as `appendix-kubectl/01-kubectl-fundamentals`.

---

## Appendix — Anki Cards

**`04-headless-anki.csv`:**

````
#deck:k8s-platform-labs::03-services::04-headless
#separator:Comma
#columns:Front,Back,Tags
"What's the difference between clusterIP: None and clusterIP: \"\"?","None explicitly creates a headless Service; empty string means auto-assign a normal ClusterIP — identical to omitting the field entirely","demo04-services,headless,cka-services-networking"
"Does a headless Service use kube-proxy at all?","No — no virtual IP, no proxy rules; DNS returns pod IPs directly and the caller connects to them itself","demo04-services,headless,cka-services-networking"
"Does StatefulSet give pods a stable IP address?","No — pod IPs remain ephemeral regardless; StatefulSet gives a stable NAME, and the headless Service's DNS record is what stays current as the IP changes","demo04-services,statefulset,cka-workloads-scheduling"
"What field links a StatefulSet to its headless Service?","spec.serviceName on the StatefulSet, matching the headless Service's metadata.name","demo04-services,statefulset,cka-workloads-scheduling"
"Is spec.serviceName validated against a real, existing Service at apply time?","No — a typo or nonexistent target still lets the StatefulSet and its pods create successfully; only per-pod DNS resolution silently fails","demo04-services,statefulset,troubleshooting,cka-troubleshooting"
"What is the per-pod DNS format for a StatefulSet pod behind a headless Service?","<pod-name>.<service-name>.<namespace>.svc.cluster.local","demo04-services,statefulset,dns,cka-services-networking"
"Does kubectl create statefulset exist?","No — unlike Deployments, Services, and Jobs, StatefulSets have no imperative creation subcommand at all; YAML only","demo04-services,statefulset,imperative,ckad-application-deployment"
"Can a headless Service be used with a regular Deployment instead of a StatefulSet?","Yes — DNS returns all pod IPs either way, but Deployment pod names are random, so per-pod DNS addressing isn't meaningful without a StatefulSet's stable names","demo04-services,headless,deployment,cka-services-networking"
"Why does StatefulSet need a headless Service instead of a regular ClusterIP one?","A regular ClusterIP load-balances across all pods behind one virtual IP — the opposite of what's needed when the goal is addressing one specific named pod directly","demo04-services,statefulset,headless,cka-services-networking"
"Are StatefulSet pods created all at once or in order?","In order — mysql-0 before mysql-1 before mysql-2 — unlike a Deployment's ReplicaSet, which creates all replicas without a guaranteed sequence","demo04-services,statefulset,cka-workloads-scheduling"
"What does publishNotReadyAddresses: true do on a headless Service?","Publishes a pod's DNS record immediately, without waiting for readiness — solves peer-discovery-during-startup for clustered apps that need to find each other before any individual pod is ready","demo04-services,headless,statefulset,cka-services-networking"
````

---

## Appendix — Quiz

**`04-headless-quiz.md`:**

````markdown
# Quiz — 03-services/04-headless: Headless Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What's the actual difference between `clusterIP: None` and `clusterIP: ""`?**

- A) They're identical — both mean headless
- B) `None` means headless; `""` means auto-assign a normal ClusterIP
- C) `""` means headless; `None` means auto-assign
- D) Neither is valid YAML

<details>
<summary>Answer</summary>

**B** — Only the literal string `None` triggers headless behavior. An empty string is functionally the same as omitting the field entirely.
Trap: C reverses the actual mapping — a classic exam-day mix-up worth memorizing precisely.

</details>

---

**Q2. Does a headless Service use kube-proxy?**

- A) Yes, in a special headless-only mode
- B) No — no virtual IP, no proxy rules at all; DNS returns pod IPs directly
- C) Only for NodePort-type headless Services
- D) Only if selector is set

<details>
<summary>Answer</summary>

**B** — Headless Services skip the virtual-IP/kube-proxy layer entirely — that's the entire point of the pattern.
Trap: A invents a special kube-proxy mode that doesn't exist — headless simply removes kube-proxy from the picture.

</details>

---

**Q3. Does StatefulSet give its pods a stable IP address?**

- A) Yes, that's its main feature
- B) No — pod IPs stay ephemeral; it gives a stable name instead, and the headless Service keeps DNS current as the IP changes
- C) Only the first pod (index 0) gets a stable IP
- D) Only with a LoadBalancer-type headless Service

<details>
<summary>Answer</summary>

**B** — This is a very common misconception. Pod IP ephemerality (from `01-core-concepts`) applies regardless of controller type — StatefulSet's actual contribution is a stable, ordered name.
Trap: A states the exact misconception this demo's Concepts section explicitly corrects.

</details>

---

**Q4. A StatefulSet's `spec.serviceName` points at a Service name that doesn't exist. What happens on `kubectl apply`?**

- A) The apply is rejected with a validation error
- B) It's accepted; the StatefulSet and its pods create successfully, but per-pod DNS silently fails
- C) Kubernetes automatically creates the missing Service
- D) The StatefulSet stays in Pending forever

<details>
<summary>Answer</summary>

**B** — There's no validation linking `serviceName` to an actual existing Service — this is a genuinely silent failure mode, invisible in `kubectl get` output.
Trap: C imagines auto-remediation that doesn't exist — nothing creates the missing Service for you.

</details>

---

**Q5. What is the correct per-pod DNS format for a StatefulSet pod behind a headless Service?**

- A) `<service-name>.<pod-name>.<namespace>.svc.cluster.local`
- B) `<pod-name>.<service-name>.<namespace>.svc.cluster.local`
- C) `<pod-name>.<namespace>.<service-name>.svc.cluster.local`
- D) `<namespace>.<pod-name>.<service-name>.svc.cluster.local`

<details>
<summary>Answer</summary>

**B** — Pod name comes first, then the headless Service name, then namespace, then the standard suffix.
Trap: A swaps the first two components — an easy typo to make and a common exam trap.

</details>

---

**Q6. Does `kubectl create statefulset` exist as an imperative command?**

- A) Yes, identical syntax to `kubectl create deployment`
- B) No — StatefulSets have no imperative creation subcommand at all
- C) Yes, but only for headless-linked StatefulSets
- D) Only in `kubectl` versions before 1.20

<details>
<summary>Answer</summary>

**B** — Unlike Deployments, Services, and Jobs, there's no `kubectl create statefulset` — YAML is the only path.
Trap: A assumes StatefulSet follows the same imperative pattern as Deployment, which it doesn't.

</details>

---

**Q7. Can a headless Service be used with a regular Deployment instead of a StatefulSet?**

- A) No, headless only works with StatefulSets
- B) Yes — DNS still returns all pod IPs, but per-pod addressing isn't meaningful since Deployment pod names are random
- C) Yes, and it behaves identically to the StatefulSet case
- D) Only if the Deployment has exactly 1 replica

<details>
<summary>Answer</summary>

**B** — The headless mechanism itself doesn't require a StatefulSet, but per-pod DNS names only make sense when the pod names themselves are stable — which only a StatefulSet provides.
Trap: C overstates the similarity — the DNS-returns-all-IPs behavior is the same, but individual pod addressing isn't usefully available without stable names.

</details>

---

**Q8. Why does StatefulSet need a headless Service specifically, instead of a regular ClusterIP Service?**

- A) Regular ClusterIP Services don't support StatefulSets at all
- B) A regular ClusterIP would load-balance across all pods behind one IP — the opposite of addressing one specific pod directly
- C) Headless Services are required for any Service with more than 1 replica
- D) There's no real reason, it's just convention

<details>
<summary>Answer</summary>

**B** — The whole point of per-pod addressing is bypassing load-balancing to reach a specific pod — a regular ClusterIP's entire purpose (routing to any matching pod) works directly against that goal.
Trap: A is factually wrong and D dismisses a real architectural reason as arbitrary convention.

</details>

---

**Q9. What problem does `publishNotReadyAddresses: true` solve on a headless Service?**

- A) It makes unready pods pass their readiness check faster
- B) It publishes a pod's DNS record before it's Ready, enabling peer discovery during startup
- C) It removes the readiness requirement permanently for all future pods
- D) It's required for any StatefulSet with more than 1 replica

<details>
<summary>Answer</summary>

**B** — Without it, DNS only publishes Ready pods, which creates a chicken-and-egg problem for clustered apps that need to find their peers *before* any of them are individually ready.
Trap: A misreads this as affecting the readiness check itself — it only affects DNS publication, never touches the actual readiness probe or its result.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
````