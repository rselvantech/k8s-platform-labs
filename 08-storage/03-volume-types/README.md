# 03 — Volume Types

## Concepts

Kubernetes supports many volume types. This lab covers the three most important categories for CKA/CKAD and production use:

| Category | Types covered | Lifecycle |
|----------|--------------|-----------|
| Ephemeral (pod-scoped) | `emptyDir`, `configMap`, `secret`, `downwardAPI` | Lives and dies with the pod |
| Node-persistent | `hostPath` | Tied to a specific node; survives pod restarts |
| Cluster-persistent | PVC-backed (CSI) | Cluster-managed; independent of pod and node |

The ConfigMap, Secret, and downwardAPI volume types were covered in `04-configmaps-secrets`. This lab focuses on `emptyDir`, `hostPath`, and CSI via the standard PVC interface.

### emptyDir

`emptyDir` is an empty directory created when the pod is assigned to a node and deleted when the pod is removed (for any reason). All containers in the pod share the same emptyDir volume.

| Field | Default | Options |
|-------|---------|---------|
| `medium` | `""` (node disk) | `Memory` (tmpfs — RAM-backed) |
| `sizeLimit` | Unset | Any quantity — enforced by kubelet |

**Use cases for emptyDir:**
- Scratch space for sorting, checkpointing, or large computations
- Sharing files between containers in the same pod (sidecar pattern)
- Cache that is safe to lose if the pod restarts

**emptyDir with `medium: Memory`** is RAM-backed (`tmpfs`). Faster than disk, counts against the container's memory limit, and is cleared on node reboot. This is what Kubernetes uses internally for Secret volume mounts.

### hostPath

`hostPath` mounts a file or directory from the **host node's filesystem** into the pod.

| `type` field | Behaviour |
|-------------|-----------|
| `""` (empty) | No pre-check — mount whatever is at the path |
| `Directory` | Path must exist and be a directory |
| `DirectoryOrCreate` | Create directory if it doesn't exist |
| `File` | Path must exist and be a file |
| `FileOrCreate` | Create file if it doesn't exist |
| `Socket` | Path must be a Unix socket |
| `CharDevice` | Path must be a character device |
| `BlockDevice` | Path must be a block device |

**Security warning:** `hostPath` grants the pod access to the node's filesystem. A privileged pod with a hostPath mount at `/` can read and modify the entire node. Avoid in multi-tenant clusters; restrict with PodSecurity admission. Use cases: DaemonSets reading node logs (`/var/log`), monitoring agents accessing cgroups (`/sys/fs/cgroup`), container runtime socket (`/run/containerd/containerd.sock`).

### CSI (Container Storage Interface)

CSI is the standard API between Kubernetes and storage vendors. All modern storage backends (AWS EBS, GCE PD, Azure Disk, Ceph, Longhorn, etc.) are implemented as CSI drivers. From a pod's perspective, CSI storage is always accessed through a PVC — the CSI driver is transparent.

minikube uses `k8s.io/minikube-hostpath` as its CSI-equivalent provisioner. The interaction model is identical to production CSI: PVC → StorageClass → provisioner → PV.

---

## Directory Structure

```
03-volume-types/
├── README.md
└── src/
    ├── 01-pod-emptydir-scratch.yaml       # emptyDir for scratch space
    ├── 02-pod-emptydir-shared.yaml        # emptyDir shared between sidecar containers
    ├── 03-pod-emptydir-memory.yaml        # emptyDir with medium: Memory (tmpfs)
    ├── 04-pod-hostpath-log.yaml           # hostPath mounting node log directory
    ├── 05-pod-hostpath-types.yaml         # hostPath types: File, Socket, DirectoryOrCreate
    └── 06-pod-multi-volume.yaml           # Pod combining emptyDir + PVC + ConfigMap
```

---

## Lab

### Prerequisites

```bash
minikube profile 3node
kubectl get nodes

# Create a ConfigMap used in Step 6
kubectl create configmap vol-demo-config \
  --from-literal=APP_ENV=production \
  --from-literal=config.yaml="server: {port: 8080}"
```

---

### Step 1 — emptyDir as scratch space

emptyDir is the simplest volume — empty at pod start, deleted when pod ends. Used for temporary computation, staging files, or inter-container data transfer.

**01-pod-emptydir-scratch.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-emptydir-scratch
  namespace: default
spec:
  volumes:
  - name: scratch
    emptyDir:
      # medium: ""      # default — node disk (uses the node's storage class)
      sizeLimit: 100Mi  # optional: kubelet enforces this limit; evicts pod if exceeded
      # If sizeLimit is omitted, the volume can grow to fill node disk (dangerous)

  containers:
  - name: worker
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== emptyDir scratch demo ==="
      echo "Writing large temp file..."
      # Generate a temp file representing computation scratch space
      dd if=/dev/urandom of=/scratch/work.tmp bs=1M count=10 2>&1
      ls -lh /scratch/
      echo ""
      echo "Processing..."
      wc -c /scratch/work.tmp
      echo ""
      echo "Cleaning up scratch space..."
      rm /scratch/work.tmp
      echo "Done — scratch space freed"
      sleep 3600
    volumeMounts:
    - name: scratch
      mountPath: /scratch
  restartPolicy: Never
```

```bash
kubectl apply -f src/01-pod-emptydir-scratch.yaml
kubectl wait --for=condition=Ready pod/pod-emptydir-scratch --timeout=30s

kubectl logs pod/pod-emptydir-scratch
# Writing large temp file...
# 10+0 records in ...
# -rw-r--r-- ... 10.0M work.tmp
# Processing...
# 10485760 /scratch/work.tmp
# Cleaning up scratch space...
# Done — scratch space freed

# Verify: the emptyDir is gone after pod deletion
kubectl delete pod pod-emptydir-scratch
# No trace of the scratch data remains anywhere
```

---

### Step 2 — emptyDir shared between sidecar containers

All containers in a pod share the same emptyDir. This is the foundational pattern for sidecars: one container writes, another reads.

**02-pod-emptydir-shared.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-emptydir-shared
  namespace: default
spec:
  volumes:
  # Single emptyDir shared by all containers in this pod
  - name: shared-data
    emptyDir: {}   # {} = use defaults (disk-backed, no size limit)

  containers:
  # Producer: writes data to the shared volume
  - name: producer
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      i=1
      while true; do
        echo "$(date) — event $i from producer" >> /data/events.log
        i=$((i + 1))
        sleep 5
      done
    volumeMounts:
    - name: shared-data
      mountPath: /data

  # Consumer (sidecar): reads data from the same shared volume
  - name: consumer
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      # Wait for producer to create the file
      until [ -f /data/events.log ]; do sleep 1; done
      echo "=== Consumer reading shared events ==="
      # Tail the file in real time (like a log shipper sidecar)
      tail -f /data/events.log
    volumeMounts:
    - name: shared-data
      mountPath: /data        # same mountPath — same shared directory
```

```bash
kubectl apply -f src/02-pod-emptydir-shared.yaml

# Both containers must be ready
kubectl wait --for=condition=Ready pod/pod-emptydir-shared --timeout=30s

# Watch the consumer reading events produced by producer
kubectl logs pod/pod-emptydir-shared -c consumer -f
# === Consumer reading shared events ===
# Mon Apr ... — event 1 from producer
# Mon Apr ... — event 2 from producer
# Mon Apr ... — event 3 from producer
# (Ctrl+C to stop)

# Confirm both containers see the same file
kubectl exec pod/pod-emptydir-shared -c producer -- wc -l /data/events.log
kubectl exec pod/pod-emptydir-shared -c consumer -- wc -l /data/events.log
# Same line count — same file, same emptyDir
```

---

### Step 3 — emptyDir with medium: Memory (tmpfs)

`medium: Memory` creates a RAM-backed filesystem. Useful for high-performance scratch space or when data must never touch disk (sensitive processing).

**03-pod-emptydir-memory.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-emptydir-memory
  namespace: default
spec:
  volumes:
  - name: ramdisk
    emptyDir:
      medium: Memory    # RAM-backed (tmpfs) — faster, never on disk, cleared on node reboot
      sizeLimit: 64Mi   # IMPORTANT: counts against the container's memory limit
                        # If container limit is 128Mi and ramdisk uses 64Mi, only 64Mi left for the process

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== tmpfs (RAM-backed) mount ==="
      df -h /ramdisk
      # Confirm it's tmpfs
      mount | grep ramdisk
      echo ""
      echo "=== Write to RAM ==="
      echo "sensitive-data" > /ramdisk/secret.tmp
      cat /ramdisk/secret.tmp
      echo ""
      echo "=== This data exists only in RAM — never written to node disk ==="
      sleep 3600
    resources:
      limits:
        memory: "128Mi"   # sizeLimit (64Mi) counts against this
    volumeMounts:
    - name: ramdisk
      mountPath: /ramdisk
  restartPolicy: Never
```

```bash
kubectl apply -f src/03-pod-emptydir-memory.yaml
kubectl wait --for=condition=Ready pod/pod-emptydir-memory --timeout=30s

kubectl logs pod/pod-emptydir-memory
# === tmpfs (RAM-backed) mount ===
# Filesystem  Size  Used  ...  Mounted on
# tmpfs       64M   0     ...  /ramdisk    ← tmpfs confirms RAM-backed
#
# tmpfs on /ramdisk type tmpfs (rw,nosuid,nodev,noexec,size=65536k)
#
# === Write to RAM ===
# sensitive-data
#
# === This data exists only in RAM — never written to node disk ===
```

---

### Step 4 — hostPath mounting node log directory

DaemonSets running log agents (Fluent Bit, Fluentd) use hostPath to access all pod logs written by the container runtime on the node.

**04-pod-hostpath-log.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-hostpath-log
  namespace: default
spec:
  volumes:
  - name: node-logs
    hostPath:
      path: /var/log/pods   # container runtime writes pod logs here on every node
      type: Directory        # path must exist and be a directory (it always does on K8s nodes)

  - name: node-journal
    hostPath:
      path: /var/log        # broader log directory
      type: Directory

  containers:
  - name: log-reader
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Pod logs on this node ==="
      ls /node-logs/ | head -20
      echo ""
      echo "=== Node is: $NODE_NAME ==="
      echo "(All pods scheduled to this node have logs here)"
      echo ""
      echo "=== /var/log directory ==="
      ls /var/log/ | head -10
      sleep 3600
    env:
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    volumeMounts:
    - name: node-logs
      mountPath: /node-logs
      readOnly: true          # log agents only read — never write to node log dirs
    - name: node-journal
      mountPath: /var/log
      readOnly: true

  # nodeName or nodeSelector would pin this to a specific node in production
  # DaemonSets handle this automatically — they schedule one pod per node
```

```bash
kubectl apply -f src/04-pod-hostpath-log.yaml
kubectl wait --for=condition=Ready pod/pod-hostpath-log --timeout=30s

kubectl logs pod/pod-hostpath-log
# === Pod logs on this node ===
# default_pod-hostpath-log_...
# kube-system_coredns-...
# kube-system_etcd-3node_...
# ...
#
# === Node is: 3node-m02 ===
# (All pods scheduled to this node have logs here)

# Identify which node the pod landed on
kubectl get pod pod-hostpath-log -o wide
# NODE: 3node-m02 (or whichever worker was chosen)
```

---

### Step 5 — hostPath types

**05-pod-hostpath-types.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-hostpath-types
  namespace: default
spec:
  volumes:
  # DirectoryOrCreate: creates the directory if it doesn't exist
  - name: app-data
    hostPath:
      path: /mnt/app-data
      type: DirectoryOrCreate   # safe: won't fail if dir is missing

  # FileOrCreate: creates an empty file if it doesn't exist
  - name: lock-file
    hostPath:
      path: /tmp/app.lock
      type: FileOrCreate

  # Socket: mounts an existing Unix socket (e.g. container runtime)
  # Shown as comment — mounting the runtime socket requires privileged access
  # - name: runtime-socket
  #   hostPath:
  #     path: /run/containerd/containerd.sock
  #     type: Socket

  initContainers:
  - name: setup
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== hostPath DirectoryOrCreate ==="
      ls -la /app-data/
      echo "Directory exists (created by Kubernetes if it was missing)"
      echo ""
      echo "=== hostPath FileOrCreate ==="
      ls -la /lock-file
      echo "File exists (created empty by Kubernetes if it was missing)"
    volumeMounts:
    - name: app-data
      mountPath: /app-data
    - name: lock-file
      mountPath: /lock-file

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "Writing to node-persistent directory..."
      echo "$(hostname): started at $(date)" > /app-data/startup.log
      cat /app-data/startup.log
      echo ""
      echo "=== This file survives pod deletion (hostPath is node-persistent) ==="
      sleep 3600
    volumeMounts:
    - name: app-data
      mountPath: /app-data
    - name: lock-file
      mountPath: /lock-file
```

```bash
kubectl apply -f src/05-pod-hostpath-types.yaml
kubectl wait --for=condition=Ready pod/pod-hostpath-types --timeout=30s

kubectl logs pod/pod-hostpath-types -c app
# Writing to node-persistent directory...
# pod-hostpath-types: started at Mon Apr ...
#
# === This file survives pod deletion (hostPath is node-persistent) ===

# Find which node it's on, then SSH to verify the file is on the node disk
NODE=$(kubectl get pod pod-hostpath-types -o jsonpath='{.spec.nodeName}')
echo "Pod is on node: $NODE"
minikube ssh -p 3node -n $NODE -- cat /mnt/app-data/startup.log
# pod-hostpath-types: started at Mon Apr ...

# Delete pod and verify the file persists on the node
kubectl delete pod pod-hostpath-types
minikube ssh -p 3node -n $NODE -- cat /mnt/app-data/startup.log
# pod-hostpath-types: started at Mon Apr ...   ← still there after pod deletion
```

---

### Step 6 — Pod combining multiple volume types

Production pods often use multiple volumes simultaneously: a PVC for durable data, an emptyDir for scratch, and a ConfigMap for config.

**06-pod-multi-volume.yaml:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-multi-volume
  namespace: default
spec:
  volumes:
  # 1. PVC: durable cluster-managed storage (survives pod and node)
  - name: durable-data
    persistentVolumeClaim:
      claimName: pvc-multi      # created below before applying this pod

  # 2. emptyDir: ephemeral scratch space (lost on pod deletion)
  - name: scratch
    emptyDir:
      sizeLimit: 50Mi

  # 3. emptyDir Memory: RAM-backed temp space
  - name: cache
    emptyDir:
      medium: Memory
      sizeLimit: 32Mi

  # 4. ConfigMap: application configuration (read-only)
  - name: app-config
    configMap:
      name: vol-demo-config
      items:
      - key: config.yaml
        path: config.yaml

  containers:
  - name: app
    image: busybox:1.36
    command:
    - sh
    - -c
    - |
      echo "=== Multi-volume pod mounts ==="
      df -h | grep -E 'Filesystem|/durable|/scratch|/cache|/config'
      echo ""
      echo "=== Writing to each volume ==="
      echo "durable: $(date)" >> /durable/record.log
      echo "scratch: $(date)" > /scratch/temp.dat
      echo "cache: $(date)" > /cache/hot.dat
      echo ""
      echo "=== Durable storage (survives pod restart) ==="
      cat /durable/record.log
      echo ""
      echo "=== Config (from ConfigMap) ==="
      cat /config/config.yaml
      echo ""
      echo "=== Volume summary ==="
      echo "durable → PVC (cluster-managed, survives pod+node)"
      echo "scratch  → emptyDir disk (ephemeral, lost on pod delete)"
      echo "cache    → emptyDir Memory/tmpfs (RAM, faster, never on disk)"
      echo "config   → ConfigMap (read-only, live-updates)"
      sleep 3600
    volumeMounts:
    - name: durable-data
      mountPath: /durable
    - name: scratch
      mountPath: /scratch
    - name: cache
      mountPath: /cache
    - name: app-config
      mountPath: /config
      readOnly: true
```

```bash
# Create the PVC first
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-multi
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-multi --timeout=30s

kubectl apply -f src/06-pod-multi-volume.yaml
kubectl wait --for=condition=Ready pod/pod-multi-volume --timeout=30s

kubectl logs pod/pod-multi-volume
# === Multi-volume pod mounts ===
# Filesystem  ...  Mounted on
# ...              /durable
# ...              /scratch
# tmpfs            /cache      ← RAM-backed
# ...              /config
#
# === Writing to each volume ===
#
# === Durable storage (survives pod restart) ===
# durable: Mon Apr ...
#
# === Config (from ConfigMap) ===
# server: {port: 8080}
#
# === Volume summary ===
# durable → PVC (cluster-managed, survives pod+node)
# scratch  → emptyDir disk (ephemeral, lost on pod delete)
# cache    → emptyDir Memory/tmpfs (RAM, faster, never on disk)
# config   → ConfigMap (read-only, live-updates)

# Delete and recreate the pod — durable data survives, scratch/cache do not
kubectl delete pod pod-multi-volume
kubectl apply -f src/06-pod-multi-volume.yaml
kubectl wait --for=condition=Ready pod/pod-multi-volume --timeout=30s
kubectl logs pod/pod-multi-volume | grep -A5 "Durable storage"
# durable: Mon Apr ... (first write)
# durable: Mon Apr ... (second write from new pod)  ← accumulated
```

---

### Step 7 — Cleanup

```bash
kubectl delete pod pod-emptydir-scratch pod-emptydir-shared pod-emptydir-memory \
  pod-hostpath-log pod-hostpath-types pod-multi-volume 2>/dev/null || true
kubectl delete pvc pvc-multi 2>/dev/null || true
kubectl delete configmap vol-demo-config 2>/dev/null || true
```

---

## Key Takeaways

| Volume type | Lifecycle | Shared across | Use case |
|-------------|-----------|--------------|---------|
| `emptyDir` (disk) | Pod lifetime | Containers in pod | Scratch space, sidecar file sharing |
| `emptyDir` (Memory) | Pod lifetime | Containers in pod | Fast scratch, sensitive data, counts vs memory limit |
| `hostPath` | Node lifetime | Pods on same node | DaemonSet log agents, runtime sockets, local dev PVs |
| PVC (CSI) | Cluster lifetime | Pods claiming same PVC | Databases, persistent app data, StatefulSets |
| `configMap` / `secret` | ConfigMap/Secret lifetime | Containers in pod | Config files, credentials |

| Concept | Detail |
|---------|--------|
| emptyDir deleted on | Pod deletion for any reason (eviction, termination, node failure) |
| hostPath node affinity | Pod must reschedule to the same node to see the same data — not portable |
| `medium: Memory` size | `sizeLimit` counts against container memory limit; container OOM-killed if exceeded |
| `sizeLimit` on emptyDir | kubelet evicts pod when the limit is exceeded (disk or memory-backed) |
| hostPath `type` | Always set explicitly — default `""` skips validation and can silently mount wrong path |
| Multi-volume pattern | Combine PVC (durable) + emptyDir (scratch) + ConfigMap (config) in one pod spec |