# StatefulSet with Persistent Storage — volumeClaimTemplates and Data Persistence

## Lab Overview

This lab adds the third pillar of StatefulSet identity: **stable storage**.
Lab 01 established stable names and stable DNS. This lab proves that each pod
gets its own PersistentVolumeClaim that survives pod deletion, pod restart, and
even StatefulSet deletion.

The key demonstration: write unique data into each pod's volume, delete the pod,
watch the controller recreate it, and verify the data is still there. This is
the behaviour that makes StatefulSets suitable for databases — a pod restart does
not mean data loss.

**What you'll do:**
- Understand `volumeClaimTemplates` — how the StatefulSet controller creates PVCs
- Understand PVC naming convention: `<template-name>-<pod-name>`
- Deploy a StatefulSet with one PVC per pod using minikube's `standard` StorageClass
- Write unique data into each pod's volume
- Delete a pod and verify the replacement pod reattaches to the same PVC with data intact
- Delete the StatefulSet and verify PVCs survive (they are NOT deleted)
- Understand `persistentVolumeClaimRetentionPolicy` — the new policy for automatic PVC deletion
- Understand the AWS EBS production path

## Prerequisites

**Required Software:**
- Minikube `3node` profile with `standard` StorageClass available
- kubectl installed and configured

**Apply the control-plane taint (if not already set):**
```bash
kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule
```

**Verify StorageClass:**
```bash
kubectl get storageclass
# NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   k8s.io/minikube-hostpath   Delete          Immediate
```

**Knowledge Requirements:**
- **REQUIRED:** Completion of `01-basic-statefulset`
- Understanding of PersistentVolumes and PersistentVolumeClaims

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Explain `volumeClaimTemplates` — how one template creates N PVCs automatically
2. ✅ Explain PVC naming: `<template-name>-<pod-name>` (e.g. `data-web-0`)
3. ✅ Explain that PVCs are NOT deleted when a pod is deleted
4. ✅ Explain that PVCs are NOT deleted when the StatefulSet is deleted
5. ✅ Prove data persists across pod deletion and recreation
6. ✅ Explain `persistentVolumeClaimRetentionPolicy` and its two sub-policies
7. ✅ Explain the AWS production path: EBS CSI driver, gp3 StorageClass, IRSA

## Directory Structure

```
02-statefulset-with-persistent-storage/
└── src/
    ├── nginx-headless-service.yaml      # Headless Service (same as Lab 01)
    └── nginx-statefulset-storage.yaml   # StatefulSet with volumeClaimTemplates
```

---

## Understanding volumeClaimTemplates

### What volumeClaimTemplates Does

`volumeClaimTemplates` is a list of PVC templates inside the StatefulSet spec.
For every pod the controller creates, it creates one PVC per template entry:

```
StatefulSet: replicas: 3, volumeClaimTemplates: [{name: data, storage: 1Gi}]

Controller creates:
  Pod web-0  →  PVC data-web-0  (1Gi, bound to PV automatically)
  Pod web-1  →  PVC data-web-1  (1Gi, bound to PV automatically)
  Pod web-2  →  PVC data-web-2  (1Gi, bound to PV automatically)

PVC naming format:  <template-name>-<statefulset-name>-<ordinal>
                    data           -web               -0
```

**The binding is sticky — always the same PVC for the same pod:**
```
web-0 always mounts data-web-0  ← even after pod restart or node change
web-1 always mounts data-web-1
web-2 always mounts data-web-2
```

When `web-1` is deleted and recreated, the controller looks for the existing
PVC `data-web-1` and mounts it — the new pod gets the same data as the old one.

### PVC Lifecycle — Independent from the Pod

```
Pod lifecycle:        create → running → deleted → recreated
PVC lifecycle:        created once → survives forever (until manually deleted)

StatefulSet deleted:  pods deleted → PVCs remain (must delete manually)
Pod deleted:          pod deleted → PVC remains → new pod reattaches same PVC

This is intentional:
  You do not want your database's data deleted because a pod crashed.
  The data outlives the pod. The pod outlives the StatefulSet object.
  You choose explicitly when to delete the PVC.
```

### PVC Naming Convention — Full Examples

```
StatefulSet name:  web
Template name:     data
Namespace:         default

web-0  →  PVC: data-web-0
web-1  →  PVC: data-web-1
web-2  →  PVC: data-web-2

StatefulSet name:  mysql
Template name:     mysql-data
Namespace:         databases

mysql-0  →  PVC: mysql-data-mysql-0
mysql-1  →  PVC: mysql-data-mysql-1
```

### persistentVolumeClaimRetentionPolicy (Kubernetes 1.27+ stable)

By default, PVCs are never automatically deleted. Kubernetes 1.27 introduced
`persistentVolumeClaimRetentionPolicy` to control this:

```yaml
spec:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain    # What happens to PVCs when StatefulSet is deleted
    whenScaled: Retain     # What happens to PVCs when StatefulSet is scaled down

# whenDeleted values:
#   Retain  (default) — PVCs kept when StatefulSet is deleted (manual cleanup)
#   Delete            — PVCs deleted automatically when StatefulSet is deleted

# whenScaled values:
#   Retain  (default) — PVCs kept when scaled down (scale web-3 → web-2, data-web-2 stays)
#   Delete            — PVCs deleted when that pod is scaled away
```

**Choosing the right policy:**

| Scenario | whenDeleted | whenScaled |
|----------|-------------|-----------|
| Production database | `Retain` | `Retain` — data is precious, never auto-delete |
| Dev/test database | `Delete` | `Delete` — clean up automatically |
| Cache (data is reproducible) | `Delete` | `Delete` — no need to keep |
| Message queue with replay | `Retain` | `Retain` — messages must survive |

### AWS Production Path

In production on AWS EKS, the `standard` StorageClass is replaced with
an EBS-backed StorageClass:

```
minikube (this lab):
  StorageClass: standard
  Provisioner:  k8s.io/minikube-hostpath
  Backing:      directory on the minikube node filesystem
  Limitation:   not shared across nodes, not production-grade

AWS EKS production:
  StorageClass: gp3
  Provisioner:  ebs.csi.aws.com
  Backing:      AWS EBS volume (network-attached block storage)
  Requires:
    1. aws-ebs-csi-driver addon on EKS
    2. IAM permissions via IRSA (IAM Roles for Service Accounts):
       ServiceAccount annotated with IAM role ARN
       IAM role with ec2:CreateVolume, ec2:AttachVolume, ec2:DeleteVolume

  StorageClass definition for EKS:
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp3
    provisioner: ebs.csi.aws.com
    parameters:
      type: gp3
      encrypted: "true"
    reclaimPolicy: Retain        # Retain for production databases
    volumeBindingMode: WaitForFirstConsumer  # Create EBS in same AZ as pod
    allowVolumeExpansion: true

  volumeBindingMode: WaitForFirstConsumer
    → EBS volume created in the same AZ as the pod that claims it
    → Without this: EBS might be in us-east-1a, pod scheduled to us-east-1b = mount failure
```

---

## Manifest — Every Field Explained

### nginx-headless-service.yaml

**nginx-headless-service.yaml:**
```yaml
# Same as Lab 01 — no changes needed
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: default
  labels:
    app: nginx
spec:
  clusterIP: None
  selector:
    app: nginx
  ports:
    - name: http
      port: 80
      targetPort: 80
  publishNotReadyAddresses: false
```

### nginx-statefulset-storage.yaml

**nginx-statefulset-storage.yaml:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: default
  labels:
    app: nginx
spec:
  serviceName: nginx
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0
  revisionHistoryLimit: 10

  # ── PVC Retention Policy (Kubernetes 1.27+ stable) ────────────────────
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain    # PVCs survive StatefulSet deletion — must delete manually
    whenScaled: Retain     # PVCs survive scale-down — data preserved for scale-up

  template:
    metadata:
      labels:
        app: nginx
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"

          # volumeMounts: links the volumeClaimTemplate to a path inside the container
          volumeMounts:
            - name: data           # Must match volumeClaimTemplates[].metadata.name
              mountPath: /usr/share/nginx/html   # nginx serves files from here

  # ── volumeClaimTemplates ─────────────────────────────────────────────
  # One PVC created per pod, per template entry.
  # PVC name = <template-name>-<pod-name>
  #   data-web-0, data-web-1, data-web-2
  #
  # PVCs are NOT deleted when the StatefulSet is deleted.
  # Delete manually: kubectl delete pvc -l app=nginx
  volumeClaimTemplates:
    - metadata:
        name: data              # PVC name prefix — also used in volumeMounts[].name
        labels:
          app: nginx            # Label PVCs for easy selection and cleanup
      spec:
        accessModes:
          - ReadWriteOnce       # One node mounts read-write at a time
                                # Correct for: databases, single-writer apps
                                # ReadWriteMany: NFS, EFS — multiple nodes simultaneously
                                # ReadWriteOncePod: exactly one POD (not node) — k8s 1.29+
        storageClassName: standard   # minikube default — k8s.io/minikube-hostpath
                                     # AWS EKS: use gp3 (requires EBS CSI driver)
                                     # Omit to use cluster default StorageClass
        resources:
          requests:
            storage: 256Mi      # Small for this lab — each pod gets 256Mi
                                # Production databases: 20-500Gi depending on workload
```

**Key fields in `volumeClaimTemplates`:**

| Field | Value | Meaning |
|-------|-------|---------|
| `metadata.name` | `data` | PVC name prefix. Becomes `data-web-0` etc. Must match `volumeMounts[].name` |
| `accessModes` | `ReadWriteOnce` | One node mounts this volume at a time |
| `storageClassName` | `standard` | Which StorageClass provisions the PV |
| `resources.requests.storage` | `256Mi` | Minimum size requested |

---

## Lab Step-by-Step Guide

### Step 1: Deploy the Headless Service

```bash
cd 02-statefulset-with-persistent-storage/src
kubectl apply -f nginx-headless-service.yaml
kubectl get service nginx
# CLUSTER-IP: None  ← headless confirmed
```

---

### Step 2: Deploy the StatefulSet with Storage

```bash
kubectl apply -f nginx-statefulset-storage.yaml
```

**Watch pods AND PVCs appear simultaneously:**
```bash
# Terminal 1 — watch pods
kubectl get pods -l app=nginx -w

# Terminal 2 — watch PVCs appear
kubectl get pvc -w
```

**Terminal 1 — pods in order:**
```
NAME    READY   STATUS              AGE
web-0   0/1     ContainerCreating   2s
web-0   1/1     Running             8s   ← web-0 Ready → web-1 starts
web-1   0/1     ContainerCreating   8s
web-1   1/1     Running             15s  ← web-1 Ready → web-2 starts
web-2   0/1     ContainerCreating   15s
web-2   1/1     Running             22s
```

**Terminal 2 — PVCs created in parallel with pods:**
```
NAME        STATUS    VOLUME                                    CAPACITY   STORAGECLASS   AGE
data-web-0  Pending                                                                       2s
data-web-0  Bound     pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  256Mi      standard       4s
data-web-1  Pending                                                                       8s
data-web-1  Bound     pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy  256Mi      standard       10s
data-web-2  Pending                                                                       15s
data-web-2  Bound     pvc-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz 256Mi      standard       17s
```

**Key observation:** PVC `data-web-0` is created when `web-0` is created.
The PVC transitions Pending → Bound as the provisioner creates the PV.
Only after the PVC is Bound can the pod mount it and start.

---

### Step 3: Verify PVC-to-Pod Binding

```bash
kubectl get pvc -l app=nginx
```

**Expected output:**
```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-web-0  Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   256Mi      RWO            standard       2m
data-web-1  Bound    pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   256Mi      RWO            standard       2m
data-web-2  Bound    pvc-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz  256Mi      RWO            standard       2m
```

```bash
# View the underlying PersistentVolumes
kubectl get pv
```

**Expected output:**
```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS
pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   256Mi      RWO            Delete           Bound    default/data-web-0   standard
pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   256Mi      RWO            Delete           Bound    default/data-web-1   standard
pvc-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz  256Mi      RWO            Delete           Bound    default/data-web-2   standard
```

Three PVs — one per pod. Each bound to its specific PVC. The RECLAIM POLICY
`Delete` means the PV is deleted when the PVC is deleted (minikube default).

---

### Step 4: Write Unique Data into Each Pod's Volume

nginx serves files from `/usr/share/nginx/html` — the exact path where the
PVC is mounted. Write a unique file into each pod's volume:

```bash
for i in 0 1 2; do
  kubectl exec web-$i -- sh -c \
    "echo 'I am web-$i, my data is stored on PVC data-web-$i' \
     > /usr/share/nginx/html/identity.txt"
done
```

**Verify each pod reads its own data:**
```bash
for i in 0 1 2; do
  echo -n "web-$i: "
  kubectl exec web-$i -- cat /usr/share/nginx/html/identity.txt
done
```

**Expected output:**
```
web-0: I am web-0, my data is stored on PVC data-web-0
web-1: I am web-1, my data is stored on PVC data-web-1
web-2: I am web-2, my data is stored on PVC data-web-2
```

Each pod has independent storage — writing to `web-0`'s volume does not
affect `web-1` or `web-2`. This is the per-pod isolation that makes
StatefulSets suitable for database replicas.

---

### Step 5: Delete a Pod — Verify Data Persists

```bash
# Terminal 1 — watch
kubectl get pods -l app=nginx -w

# Terminal 2 — delete web-1
kubectl delete pod web-1
```

**Terminal 1 — expected sequence:**
```
NAME    READY   STATUS        AGE
web-0   1/1     Running       5m
web-1   1/1     Terminating   5m   ← deleted
web-2   1/1     Running       5m
web-1   0/1     Pending       0s   ← recreated with SAME name
web-1   0/1     ContainerCreating   0s
web-1   1/1     Running       5s   ← ready
```

**Verify PVC was NOT deleted:**
```bash
kubectl get pvc data-web-1
# STATUS: Bound  ← PVC survived pod deletion
```

**Verify data persists in the replacement pod:**
```bash
kubectl exec web-1 -- cat /usr/share/nginx/html/identity.txt
```

**Expected output:**
```
I am web-1, my data is stored on PVC data-web-1
```

The replacement `web-1` pod mounted `data-web-1` — the same PVC with the
same data written before the deletion. This is stable storage in action.

---

### Step 6: Verify PVC Details After Pod Restart

```bash
kubectl describe pvc data-web-1
```

**Key fields to observe:**
```
Name:          data-web-1
Status:        Bound
Volume:        pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   ← same PV as before
Capacity:      256Mi
Access Modes:  RWO
StorageClass:  standard
Mounted By:    web-1                                       ← bound to new web-1 pod
```

The `Volume` name is identical to before the deletion — the new pod is
mounted to exactly the same underlying PV with all its data.

---

### Step 7: Delete the StatefulSet — PVCs Survive

```bash
# Terminal 1 — watch PVCs
kubectl get pvc -w

# Terminal 2 — delete StatefulSet
kubectl delete statefulset web
```

**Terminal 2 — pods terminate in reverse order:**
```
statefulset.apps "web" deleted
# web-2 terminates, then web-1, then web-0
```

**Terminal 1 — PVCs remain:**
```
NAME        STATUS   VOLUME     CAPACITY   AGE
data-web-0  Bound    pvc-xxx    256Mi      10m   ← still Bound after StatefulSet deleted
data-web-1  Bound    pvc-yyy    256Mi      10m   ← still Bound
data-web-2  Bound    pvc-zzz    256Mi      10m   ← still Bound
```

**Verify:**
```bash
kubectl get pods -l app=nginx
# No resources found  ← pods gone

kubectl get pvc -l app=nginx
# data-web-0, data-web-1, data-web-2 still listed ← PVCs survive
```

**This is the default `Retain` behaviour of `persistentVolumeClaimRetentionPolicy`.**
PVCs exist independently of the StatefulSet. You must delete them manually.

---

### Step 8: Recreate the StatefulSet — Data Reattaches

```bash
kubectl apply -f nginx-statefulset-storage.yaml
```

**Watch pods come up and reattach existing PVCs:**
```bash
kubectl get pods -l app=nginx -w
```

```
web-0   0/1     ContainerCreating   0s
web-0   1/1     Running             8s
...
```

**Verify data is still there — the StatefulSet picked up its existing PVCs:**
```bash
for i in 0 1 2; do
  echo -n "web-$i: "
  kubectl exec web-$i -- cat /usr/share/nginx/html/identity.txt
done
```

**Expected output:**
```
web-0: I am web-0, my data is stored on PVC data-web-0
web-1: I am web-1, my data is stored on PVC data-web-1
web-2: I am web-2, my data is stored on PVC data-web-2
```

The controller found existing PVCs matching the naming convention and
reattached them. No data was lost across the full StatefulSet delete and recreate cycle.

---

### Step 9: Inspect the Volume Mount Inside a Pod

```bash
kubectl exec web-0 -- df -h /usr/share/nginx/html
```

**Expected output:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/...        252M  1.0M  251M   1% /usr/share/nginx/html
```

The PVC is mounted at the correct path. 252M available — the 256Mi requested.

```bash
# See all mounts inside the pod
kubectl exec web-0 -- mount | grep nginx
# /dev/... on /usr/share/nginx/html type ext4 (rw,...)
```

---

### Step 10: Cleanup — Correct Order and PVC Deletion

```bash
# 1 — Delete the StatefulSet (pods terminate, PVCs remain)
kubectl delete statefulset web

# 2 — Delete the PVCs explicitly (PVs are then deleted by ReclaimPolicy: Delete)
kubectl delete pvc -l app=nginx

# 3 — Delete the Headless Service
kubectl delete service nginx
```

**Verify complete removal:**
```bash
kubectl get statefulset
kubectl get pvc -l app=nginx
kubectl get pv    # All PVs should be gone (ReclaimPolicy: Delete)
kubectl get service nginx
```

All empty. The PVs were deleted automatically by the `Delete` ReclaimPolicy
when the PVCs were deleted.

> **Production note:** Use `ReclaimPolicy: Retain` for production databases.
> Retained PVs keep their data even after the PVC is deleted — giving you a
> recovery window if a PVC was deleted accidentally.

---

## Common Questions

### Q: What happens if I scale down and then scale back up — does the same PVC reattach?
**A:** Yes — with `whenScaled: Retain` (default). Scale from 3 to 1 removes
`web-2` and `web-1` pods but keeps `data-web-2` and `data-web-1` PVCs.
Scale back to 3 and the controller creates `web-1` and `web-2` again,
mounting the existing `data-web-1` and `data-web-2`. Data persists across
scale-down and scale-up cycles.

### Q: Can two pods share the same PVC?
**A:** Not with `ReadWriteOnce`. Each PVC with `RWO` can only be mounted by
pods on a single node at a time. In a StatefulSet, each pod gets its own PVC
so this is never an issue. If you need shared storage across pods (e.g. a
shared config file), add a regular volume (not a `volumeClaimTemplate`) to
the pod spec — all pods will share it.

### Q: What is the difference between `accessModes: ReadWriteOnce` and `ReadWriteOncePod`?
**A:** `ReadWriteOnce` — multiple pods on the same node can mount the volume
simultaneously. `ReadWriteOncePod` (Kubernetes 1.29+) — only a single pod
across the entire cluster can mount the volume. `ReadWriteOncePod` is stricter
and is recommended for databases where you need to guarantee only one writer.

### Q: Can I change the storage size of a volumeClaimTemplate after creation?
**A:** The `volumeClaimTemplates` field is immutable — you cannot change it
without deleting and recreating the StatefulSet. To resize existing PVCs,
edit each PVC directly (`kubectl edit pvc data-web-0`) and change
`spec.resources.requests.storage` — this triggers volume expansion if
`allowVolumeExpansion: true` is set in the StorageClass.

### Q: What happens to PVCs if I delete the StatefulSet with `whenDeleted: Delete`?
**A:** The PVCs are deleted automatically as part of the StatefulSet deletion.
The pods terminate first (in reverse order), then the PVCs are deleted,
then the PVs are deleted (if ReclaimPolicy: Delete). This is the "clean up
everything" mode — use only for non-production or reproducible data.

---

## What You Learned

In this lab, you:
- ✅ Explained `volumeClaimTemplates` — one PVC per pod, named `<template>-<pod-name>`
- ✅ Proved that each pod gets independent, isolated storage
- ✅ Proved data persists across pod deletion — replacement pod reattaches same PVC
- ✅ Proved PVCs survive StatefulSet deletion — must be deleted manually with `Retain`
- ✅ Proved data survives a full StatefulSet delete-and-recreate cycle
- ✅ Explained `persistentVolumeClaimRetentionPolicy` — `whenDeleted` and `whenScaled`
- ✅ Understood the AWS production path: EBS CSI, gp3 StorageClass, IRSA, `WaitForFirstConsumer`

**Key Takeaway:** `volumeClaimTemplates` is what separates "a StatefulSet" from
"a Deployment with storage" in terms of real database suitability. Each pod's
data is isolated to its own PVC. The PVC outlives the pod, outlives the
StatefulSet, and only disappears when you explicitly delete it. This is the
guarantee that makes restarting a database pod safe — the data waits for the
pod to come back.

---

## Quick Commands Reference

| Command | Description |
|---------|-------------|
| `kubectl get pvc -l app=nginx` | List all PVCs for this StatefulSet |
| `kubectl get pv` | List all PersistentVolumes |
| `kubectl describe pvc data-web-0` | PVC details — bound volume, mounted by |
| `kubectl exec web-0 -- df -h /path` | Verify volume is mounted inside pod |
| `kubectl delete pvc -l app=nginx` | Delete all PVCs (after StatefulSet deleted) |
| `kubectl get pvc -l app=nginx -o name \| xargs kubectl delete` | Alternative PVC cleanup |

---

## Troubleshooting

**PVC stuck in Pending?**
```bash
kubectl describe pvc data-web-0
# Events section: look for provisioner errors
kubectl get storageclass
# Verify "standard" StorageClass exists and has a provisioner
# On minikube: minikube addons enable storage-provisioner --profile 3node
```

**Pod stuck in ContainerCreating?**
```bash
kubectl describe pod web-0
# Look for: "Unable to attach or mount volumes"
# Common cause: PVC not yet Bound — wait for provisioner
# If minikube: the storage-provisioner addon must be enabled
```

**Data not persisting after pod restart?**
```bash
# Verify the pod is mounting the correct PVC
kubectl get pod web-1 -o yaml | grep -A5 "volumes:"
# Should show: persistentVolumeClaim: claimName: data-web-1

# Verify PVC is Bound
kubectl get pvc data-web-1
```