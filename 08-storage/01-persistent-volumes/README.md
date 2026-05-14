# 01 — Persistent Volumes

## Concepts

Kubernetes separates storage provisioning from storage consumption using three objects: **PersistentVolume (PV)**, **PersistentVolumeClaim (PVC)**, and the binding relationship between them.

### The three-object model

```
Administrator provisions                User requests
        ↓                                    ↓
PersistentVolume (PV)     ←binding→    PersistentVolumeClaim (PVC)
  - capacity                              - storage request
  - accessModes                           - accessModes
  - reclaimPolicy                         - storageClassName
  - storageClassName                      - selector (optional)
  - actual storage backend                      ↓
                                         Pod
                                           - volumes[].persistentVolumeClaim
```

### Access modes

| Mode | Short | Meaning | Supported by |
|------|-------|---------|-------------|
| `ReadWriteOnce` | RWO | One node can mount R/W | Most backends |
| `ReadOnlyMany` | ROX | Many nodes can mount read-only | NFS, some cloud |
| `ReadWriteMany` | RWX | Many nodes can mount R/W | NFS, cloud file stores |
| `ReadWriteOncePod` | RWOP | One **pod** can mount R/W (K8s 1.22+) | CSI drivers |

> Access modes are advertised by the PV and **requested** by the PVC. The PVC's modes must be a subset of the PV's modes for binding to succeed.

### Reclaim policies

| Policy | What happens when PVC is deleted |
|--------|----------------------------------|
| `Retain` | PV stays, data preserved, PV goes to `Released` state — manual reclaim required |
| `Delete` | PV and the underlying storage are deleted automatically |
| `Recycle` | Deprecated — basic scrub (`rm -rf`), then PV returned to `Available` (use dynamic provisioning instead) |

### PV lifecycle

```
Available → Bound → Released → (Retain: manual delete) / (Delete: auto-deleted)
```

A `Released` PV cannot be rebound to a new PVC even if the old PVC is gone — the PV retains a `claimRef` pointing to the old PVC. To reuse a `Retain` PV: edit and remove the `claimRef`.

### Binding mechanics

The control plane binds a PVC to a PV when **all** of the following match:
- `storageClassName` — must be identical (or both empty)
- `accessModes` — PVC modes must be a subset of PV modes
- `storage` capacity — PV must be >= PVC request
- `selector` (optional) — PV labels must match PVC label selector

If multiple PVs satisfy a PVC, Kubernetes picks the **smallest sufficient** PV (best-fit).

### Static vs dynamic provisioning

| Type | How PV is created | When to use |
|------|------------------|-------------|
| Static | Admin pre-creates PV YAML | On-prem, specific hardware, migration |
| Dynamic | StorageClass creates PV automatically on PVC creation | Cloud, minikube, production default |

This lab covers **static provisioning**. Dynamic provisioning is in `02-storageclasses`.

---

## Directory Structure

```
01-persistent-volumes/
├── README.md
└── src/
    ├── 01-pv-hostpath.yaml          # Static PV backed by node hostPath
    ├── 02-pvc-basic.yaml            # PVC that binds to the hostPath PV
    ├── 03-pod-with-pvc.yaml         # Pod consuming the PVC
    ├── 04-pv-retain-policy.yaml     # PV with Retain policy — lifecycle demo
    ├── 05-pvc-selector.yaml         # PVC using label selector to target specific PV
    └── 06-pv-selector-target.yaml   # PV with labels for selector binding
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Confirm available StorageClasses
kubectl get storageclass
# NAME                 PROVISIONER                RECLAIMPOLICY   ...
# standard (default)   k8s.io/minikube-hostpath   Delete          ...
```

---

### Step 1 — Create a static PV backed by hostPath

In minikube, `hostPath` PVs map to a directory on the minikube node's filesystem. This is the standard static provisioning approach for local development and on-prem bare-metal clusters.

**01-pv-hostpath.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-hostpath-demo
  # Labels allow PVCs to target this PV specifically via selector
  labels:
    type: local
    demo: hostpath
spec:
  # Total capacity advertised by this PV
  capacity:
    storage: 1Gi

  # How the volume can be mounted — must match or superset what PVC requests
  accessModes:
  - ReadWriteOnce       # one node at a time, read-write

  # What happens to this PV when its PVC is deleted
  reclaimPolicy: Retain # data survives PVC deletion — must manually reclaim

  # Empty string = no StorageClass = static provisioning
  # PVC must also have storageClassName: "" to bind to this PV
  storageClassName: ""

  # The actual storage backend
  hostPath:
    path: /mnt/data/pv-hostpath-demo   # directory on the minikube node
    type: DirectoryOrCreate             # create the dir if it doesn't exist
```

```bash
kubectl apply -f src/01-pv-hostpath.yaml

kubectl get pv pv-hostpath-demo
# NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      ...
# pv-hostpath-demo   1Gi        RWO            Retain           Available   ...
# STATUS = Available — waiting for a PVC to bind to it
```

---

### Step 2 — Create a PVC that binds to the PV

**02-pvc-basic.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-basic
  namespace: default
spec:
  # Must match the PV's storageClassName exactly
  # Empty string = request a statically provisioned PV (no StorageClass)
  storageClassName: ""

  accessModes:
  - ReadWriteOnce   # must be a subset of the PV's accessModes

  resources:
    requests:
      storage: 500Mi  # requesting 500Mi — will bind to pv-hostpath-demo (1Gi) as best-fit
```

```bash
kubectl apply -f src/02-pvc-basic.yaml

# Watch the binding happen
kubectl get pvc pvc-basic
# NAME        STATUS   VOLUME             CAPACITY   ACCESS MODES   STORAGECLASS   ...
# pvc-basic   Bound    pv-hostpath-demo   1Gi        RWO                           ...
# STATUS = Bound — PVC is bound to pv-hostpath-demo
# CAPACITY = 1Gi — PVC gets the PV's full capacity even though it only requested 500Mi

kubectl get pv pv-hostpath-demo
# NAME               CAPACITY   ...   STATUS   CLAIM              ...
# pv-hostpath-demo   1Gi        ...   Bound    default/pvc-basic  ...
# STATUS = Bound — PV shows which PVC it is bound to (namespace/name)
```

---

### Step 3 — Pod consuming the PVC

**03-pod-with-pvc.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-pvc
  namespace: default
spec:
  volumes:
  - name: storage          # volume name — referenced in volumeMounts
    persistentVolumeClaim:
      claimName: pvc-basic  # the PVC to use
      readOnly: false        # false = read-write (default)

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Writing to PV-backed storage ==="
      echo "pod: $HOSTNAME" > /data/info.txt
      echo "written_at: $(date)" >> /data/info.txt
      cat /data/info.txt
      echo ""
      echo "=== Storage mount info ==="
      df -h /data
      echo ""
      echo "=== Files on the PV ==="
      ls -la /data/
      sleep 3600
    volumeMounts:
    - name: storage
      mountPath: /data       # directory inside the container backed by the PV
  restartPolicy: Never
```

```bash
kubectl apply -f src/03-pod-with-pvc.yaml
kubectl wait --for=condition=Ready pod/pod-pvc --timeout=30s

kubectl logs pod/pod-pvc
# === Writing to PV-backed storage ===
# pod: pod-pvc
# written_at: ...
#
# === Storage mount info ===
# Filesystem      Size  Used  ...  Mounted on
# /dev/...        ...              /data
#
# === Files on the PV ===
# -rw-r--r-- ... info.txt

# Verify the file exists on the minikube node's hostPath
minikube ssh -p 3node -- cat /mnt/data/pv-hostpath-demo/info.txt
# pod: pod-pvc
# written_at: ...
```

---

### Step 4 — Data persistence across pod deletion

```bash
# Delete the pod — PVC and PV remain
kubectl delete pod pod-pvc

kubectl get pvc pvc-basic
# STATUS = Bound   ← PVC still exists and still bound to PV

# Recreate the pod — data must still be there
kubectl apply -f src/03-pod-with-pvc.yaml
kubectl wait --for=condition=Ready pod/pod-pvc --timeout=30s

kubectl logs pod/pod-pvc
# === Files on the PV ===
# -rw-r--r-- ... info.txt   ← file written by previous pod still exists
```

---

### Step 5 — Observe the Retain reclaim policy

```bash
# Delete the PVC
kubectl delete pvc pvc-basic

# PV transitions to Released — NOT Available — data is preserved
kubectl get pv pv-hostpath-demo
# NAME               CAPACITY   ...   STATUS     CLAIM              ...
# pv-hostpath-demo   1Gi        ...   Released   default/pvc-basic  ...
# STATUS = Released (not Available) — claimRef still set to deleted PVC

# A new PVC with storageClassName: "" will NOT bind to this PV — it's Released, not Available
# To reuse it, remove the claimRef manually:
kubectl patch pv pv-hostpath-demo --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'

kubectl get pv pv-hostpath-demo
# STATUS = Available   ← now bindable again
# Data at /mnt/data/pv-hostpath-demo/ is still there on the node

# Verify data survived PVC deletion and the reclaim cycle
minikube ssh -p 3node -- ls /mnt/data/pv-hostpath-demo/
# info.txt   ← Retain policy: data was never deleted
```

---

### Step 6 — PV with Delete policy (contrast)

```yaml
# For reference — NOT a separate src file
# Change reclaimPolicy to Delete:
#   reclaimPolicy: Delete
# When the PVC is deleted, the PV AND the underlying storage are deleted automatically.
# With hostPath, "Delete" means the directory on the node is removed.
# With cloud volumes (EBS, GCE PD), the disk is deleted from the cloud provider.
```

---

### Step 7 — PVC with label selector targeting a specific PV

When multiple static PVs exist, a PVC can use a `selector` to bind to a specific one by label instead of relying on best-fit capacity matching.

**06-pv-selector-target.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-fast-ssd
  labels:
    tier: ssd           # label used by PVC selector
    zone: ca-central-1a
spec:
  capacity:
    storage: 2Gi
  accessModes:
  - ReadWriteOnce
  reclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/data/pv-fast-ssd
    type: DirectoryOrCreate
```

**05-pvc-selector.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-selector
  namespace: default
spec:
  storageClassName: ""
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  # selector: only bind to PVs whose labels match this expression
  selector:
    matchLabels:
      tier: ssd         # must match pv-fast-ssd's label exactly
    # matchExpressions:  # also supported — same syntax as pod affinity
    # - key: zone
    #   operator: In
    #   values: [ca-central-1a, ca-central-1b]
```

```bash
kubectl apply -f src/06-pv-selector-target.yaml
kubectl apply -f src/05-pvc-selector.yaml

kubectl get pvc pvc-selector
# NAME           STATUS   VOLUME        CAPACITY   ...
# pvc-selector   Bound    pv-fast-ssd   2Gi        ...
# Bound to pv-fast-ssd specifically — selector overrode best-fit

kubectl get pv pv-fast-ssd
# STATUS = Bound    CLAIM = default/pvc-selector
```

---

### Step 8 — Cleanup

```bash
kubectl delete pod pod-pvc 2>/dev/null || true
kubectl delete pvc pvc-basic pvc-selector 2>/dev/null || true
kubectl delete pv pv-hostpath-demo pv-fast-ssd 2>/dev/null || true
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| PV/PVC separation | Admin provisions PV; user requests PVC; binding is automatic |
| Binding rules | storageClassName + accessModes (subset) + capacity (PV >= PVC) + selector (optional) |
| Best-fit | If multiple PVs qualify, smallest sufficient PV wins |
| `Retain` | PV goes to `Released` on PVC delete; data preserved; must manually remove `claimRef` to reuse |
| `Delete` | PV and backing storage deleted automatically when PVC is deleted |
| `Released` ≠ `Available` | A Released PV cannot be bound by a new PVC until `claimRef` is removed |
| `selector` | PVC can target a specific PV by label; overrides capacity best-fit |
| `storageClassName: ""` | Opt out of dynamic provisioning; only binds to static PVs with the same empty class |
| Data persistence | Data survives pod deletion; only deleted when PV is deleted (with Delete policy) |