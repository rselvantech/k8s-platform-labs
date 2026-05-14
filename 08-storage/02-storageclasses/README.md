# 02 — StorageClasses

## Concepts

A **StorageClass** defines how storage is dynamically provisioned. Instead of an admin manually creating PVs, the StorageClass's provisioner creates a PV automatically the moment a PVC requests it. This is the default model in cloud environments and in minikube.

### StorageClass fields

| Field | Purpose |
|-------|---------|
| `provisioner` | The plugin that creates backing storage (e.g. `k8s.io/minikube-hostpath`, `ebs.csi.aws.com`) |
| `parameters` | Provisioner-specific settings (disk type, IOPS, filesystem, zone) |
| `reclaimPolicy` | `Delete` (default) or `Retain` — applied to dynamically created PVs |
| `volumeBindingMode` | `Immediate` or `WaitForFirstConsumer` |
| `allowVolumeExpansion` | `true` = PVCs can request more storage after creation |
| `mountOptions` | Options passed to the mount command (e.g. `noatime`, `discard`) |

### volumeBindingMode — critical for multi-zone clusters

| Mode | PV created when | Problem it solves |
|------|----------------|------------------|
| `Immediate` | PVC is created | PV may be provisioned in a different zone than the pod that uses it — pod can't schedule |
| `WaitForFirstConsumer` | Pod using the PVC is scheduled | PV is created in the same zone as the pod — no zone mismatch |

> **Rule of thumb:** Always use `WaitForFirstConsumer` for zone-aware storage (cloud disks, local volumes). `Immediate` is fine for zone-agnostic storage (NFS, minikube).

### Default StorageClass

A cluster can have one default StorageClass (annotated with `storageclass.kubernetes.io/is-default-class: "true"`). A PVC that omits `storageClassName` entirely (not `""`, but completely absent) gets the default StorageClass. In minikube, `standard` is the default.

```
PVC storageClassName absent → uses default StorageClass → dynamic provisioning
PVC storageClassName: ""    → static provisioning only, no StorageClass
PVC storageClassName: "foo" → dynamic provisioning via StorageClass "foo"
```

### Dynamic provisioning flow

```
PVC created
    ↓
StorageClass provisioner called
    ↓
PV created automatically (capacity = PVC request exactly, not larger)
    ↓
PVC binds to new PV
    ↓
Pod mounts PVC
    ↓
PVC deleted
    ↓
PV deleted + backing storage deleted (reclaimPolicy: Delete)
```

---

## Directory Structure

```
02-storageclasses/
├── README.md
└── src/
    ├── 01-storageclass-standard.yaml       # Inspect / reference the minikube default SC
    ├── 02-storageclass-retain.yaml         # Custom SC with Retain policy
    ├── 03-pvc-dynamic-default.yaml         # PVC using default SC (no storageClassName)
    ├── 04-pvc-dynamic-retain.yaml          # PVC using custom Retain SC
    ├── 05-pod-dynamic.yaml                 # Pod consuming a dynamically provisioned PVC
    └── 06-pvc-expansion.yaml              # PVC volume expansion demo
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Confirm the default StorageClass
kubectl get storageclass
# NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ...
# standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           ...
```

---

### Step 1 — Inspect the default StorageClass

The `standard` StorageClass ships with minikube. Inspect it to understand the structure before creating custom ones.

**01-storageclass-standard.yaml** (reference — do not apply, already exists):
```yaml
# This is what the minikube standard StorageClass looks like.
# Shown here for reference — it is pre-installed, do not apply.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    # This annotation makes it the cluster-wide default
    storageclass.kubernetes.io/is-default-class: "true"
# The provisioner that handles PV creation for this class
provisioner: k8s.io/minikube-hostpath
# reclaimPolicy applied to PVs this class creates
reclaimPolicy: Delete
# Immediate: PV created as soon as PVC is created (zone-unaware)
volumeBindingMode: Immediate
```

```bash
# Describe to see all fields including parameters
kubectl describe storageclass standard

# The RECLAIMPOLICY column shows what happens to PVs when PVCs are deleted
kubectl get storageclass -o wide
```

---

### Step 2 — Create a custom StorageClass with Retain policy

The default `standard` class uses `Delete`. For stateful workloads where data survival after PVC deletion is required, create a custom class with `Retain`.

**02-storageclass-retain.yaml:**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-retain
  # No is-default-class annotation — this is NOT the default
  # PVCs must explicitly request storageClassName: standard-retain
provisioner: k8s.io/minikube-hostpath   # same provisioner as the default
reclaimPolicy: Retain                   # PV survives PVC deletion
volumeBindingMode: Immediate
# allowVolumeExpansion: true            # enable to allow PVC storage increase after creation
```

```bash
kubectl apply -f src/02-storageclass-retain.yaml

kubectl get storageclass
# NAME                 PROVISIONER                RECLAIMPOLICY   ...
# standard (default)   k8s.io/minikube-hostpath   Delete          ...
# standard-retain      k8s.io/minikube-hostpath   Retain          ...
```

---

### Step 3 — Dynamic provisioning with the default StorageClass

When `storageClassName` is **omitted entirely** from the PVC, the default StorageClass is used and a PV is created automatically.

**03-pvc-dynamic-default.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic-default
  namespace: default
spec:
  # storageClassName is intentionally ABSENT (not "" — absent)
  # This triggers the default StorageClass (standard → k8s.io/minikube-hostpath)
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 256Mi   # dynamically provisioned PV will have exactly 256Mi capacity
```

```bash
kubectl apply -f src/03-pvc-dynamic-default.yaml

# Watch PVC go from Pending to Bound
kubectl get pvc pvc-dynamic-default -w
# NAME                  STATUS    VOLUME   CAPACITY   ...
# pvc-dynamic-default   Pending                       ...
# pvc-dynamic-default   Bound     pvc-...  256Mi      ...

# A PV was automatically created
kubectl get pv
# NAME             CAPACITY   ...   RECLAIM POLICY   STATUS   CLAIM                         ...
# pvc-<uid>        256Mi      ...   Delete           Bound    default/pvc-dynamic-default   ...
# Note: capacity = exactly 256Mi (what PVC requested) — not a pre-sized PV

# Check the PV's storageClassName matches
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.storageClassName}{"\n"}{end}'
```

---

### Step 4 — Dynamic provisioning with the Retain StorageClass

**04-pvc-dynamic-retain.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic-retain
  namespace: default
spec:
  # Explicitly request the Retain-policy StorageClass
  storageClassName: standard-retain
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 128Mi
```

```bash
kubectl apply -f src/04-pvc-dynamic-retain.yaml

kubectl get pvc pvc-dynamic-retain
# STATUS = Bound

# The auto-created PV has reclaimPolicy: Retain
kubectl get pv | grep retain
# pvc-<uid>  128Mi  RWO  Retain  Bound  default/pvc-dynamic-retain  standard-retain

# Delete the PVC — with Retain, PV survives
kubectl delete pvc pvc-dynamic-retain
kubectl get pv | grep 128
# pvc-<uid>  128Mi  RWO  Retain  Released  ...  standard-retain
# STATUS = Released (not deleted) — Retain policy preserved the PV
# To fully clean up, manually delete the PV:
# kubectl delete pv <pv-name>
```

---

### Step 5 — Pod consuming a dynamically provisioned PVC

**05-pod-dynamic.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-dynamic
  namespace: default
spec:
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-dynamic-default   # the dynamically provisioned PVC

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Dynamic PV info ==="
      df -h /data
      echo ""
      echo "=== Write test ==="
      echo "dynamic storage works: $(date)" > /data/test.txt
      cat /data/test.txt
      sleep 3600
    volumeMounts:
    - name: data
      mountPath: /data
  restartPolicy: Never
```

```bash
kubectl apply -f src/05-pod-dynamic.yaml
kubectl wait --for=condition=Ready pod/pod-dynamic --timeout=30s

kubectl logs pod/pod-dynamic
# === Dynamic PV info ===
# Filesystem  Size  Used ...  Mounted on
# ...                         /data
#
# === Write test ===
# dynamic storage works: ...

# Show the complete chain: PVC → PV → StorageClass → actual path
kubectl get pvc pvc-dynamic-default -o jsonpath='{.spec.volumeName}'
# pvc-<uid>
kubectl get pv $(kubectl get pvc pvc-dynamic-default -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.hostPath.path}'
# /tmp/hostpath-provisioner/<namespace>/pvc-dynamic-default
```

---

### Step 6 — Volume expansion

PVCs can request more storage after creation if the StorageClass has `allowVolumeExpansion: true`. Note: minikube's `k8s.io/minikube-hostpath` provisioner does not enforce capacity limits (it's a fake provisioner for local dev), so the expansion is accepted but the underlying directory doesn't actually resize — this is a workflow demo.

**06-pvc-expansion.yaml:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-expandable
  namespace: default
spec:
  # standard-retain doesn't have allowVolumeExpansion set
  # Use the default 'standard' SC which we'll patch to allow expansion
  storageClassName: standard
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi   # initial size
```

```bash
# First: patch the standard SC to allow expansion (minikube doesn't set this by default)
kubectl patch storageclass standard \
  --type=merge \
  -p '{"allowVolumeExpansion": true}'

kubectl get storageclass standard -o jsonpath='{.allowVolumeExpansion}'
# true

kubectl apply -f src/06-pvc-expansion.yaml
kubectl get pvc pvc-expandable
# STATUS = Bound   CAPACITY = 100Mi

# Expand the PVC — edit the resources.requests.storage field
kubectl patch pvc pvc-expandable \
  --type=merge \
  -p '{"spec":{"resources":{"requests":{"storage":"200Mi"}}}}'

kubectl get pvc pvc-expandable
# CAPACITY = 200Mi  ← expanded
# (minikube hostpath provisioner accepts the change; real cloud disks resize the actual disk)

# On real cloud providers (EBS, GCE PD), after the PVC is expanded,
# the filesystem inside the pod is also expanded — no pod restart needed for ext4/xfs.
```

---

### Step 7 — Cleanup

```bash
kubectl delete pod pod-dynamic 2>/dev/null || true
kubectl delete pvc pvc-dynamic-default pvc-dynamic-retain pvc-expandable 2>/dev/null || true
kubectl delete storageclass standard-retain 2>/dev/null || true
# Manually delete any Released PVs left by Retain policy:
kubectl get pv | grep Released | awk '{print $1}' | xargs kubectl delete pv 2>/dev/null || true
# Restore standard SC (remove allowVolumeExpansion patch) — optional
kubectl patch storageclass standard --type=merge -p '{"allowVolumeExpansion": false}'
```

---

## Key Takeaways

| Concept | Detail |
|---------|--------|
| Dynamic provisioning | StorageClass provisioner creates PV automatically on PVC creation |
| `storageClassName` absent | Uses cluster default SC (if one exists) |
| `storageClassName: ""` | Static provisioning only — no SC, no dynamic provisioning |
| Dynamic PV capacity | Exactly matches PVC request (not pre-sized like static PVs) |
| `WaitForFirstConsumer` | PV created only after pod is scheduled — prevents zone mismatch |
| `reclaimPolicy` on SC | Inherited by all PVs the SC creates; `Delete` is the common default |
| Custom SC with `Retain` | Essential pattern for databases — prevents accidental data loss on PVC delete |
| `allowVolumeExpansion` | Enables `kubectl patch pvc` to increase storage; filesystem resizes online for most CSI drivers |
| Default SC annotation | `storageclass.kubernetes.io/is-default-class: "true"` — only one should be default |