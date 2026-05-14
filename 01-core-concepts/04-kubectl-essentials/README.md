# kubectl Essentials — The Command-Line Interface to Kubernetes

## Lab Overview

`kubectl` is the primary tool for interacting with Kubernetes clusters. Every
action you take — creating objects, inspecting state, debugging problems,
scaling workloads — goes through `kubectl`. This lab covers the patterns,
flags, and techniques you will use in every other lab and in the CKA/CKAD exams.

The CKA and CKAD exams are entirely command-line. Speed and accuracy with
`kubectl` is directly correlated with exam success. This lab focuses on the
commands and techniques that save time and reduce errors.

**What you'll learn:**
- kubeconfig: how kubectl knows which cluster to talk to
- Imperative commands: fast object creation without YAML
- Declarative workflow: `kubectl apply` and when to use it
- `--dry-run=client -o yaml`: generate YAML templates instantly
- Output formats: `-o wide`, `-o yaml`, `-o json`, `-o jsonpath`, `-o custom-columns`
- `kubectl explain`: your in-terminal API reference
- Filtering and watching: `-l`, `--field-selector`, `-w`
- Exec, logs, port-forward, copy: debugging live pods
- `kubectl diff`: preview changes before applying
- Context and namespace management

## Prerequisites

**Required:**
- Minikube `3node` profile running
- kubectl installed and configured

## Lab Objectives

By the end of this lab, you will be able to:
1. ✅ Read and modify kubeconfig to switch between clusters and contexts
2. ✅ Create any basic Kubernetes object using imperative kubectl commands
3. ✅ Generate YAML templates using `--dry-run=client -o yaml` (fastest exam technique)
4. ✅ Use all major output formats: wide, yaml, json, jsonpath, custom-columns
5. ✅ Use `kubectl explain` to look up any field definition without documentation
6. ✅ Filter objects by labels and field selectors
7. ✅ Debug pods with exec, logs, describe, and port-forward
8. ✅ Set namespace aliases and shell shortcuts for the exam

## Directory Structure

```
04-kubectl-essentials/
└── README.md    # This file — all kubectl techniques with examples
```

---

## kubeconfig — How kubectl Finds Your Cluster

```bash
# Default location: ~/.kube/config
# Override with: KUBECONFIG env var or --kubeconfig flag

kubectl config view                        # show full kubeconfig
kubectl config view --minify               # show only current context config
kubectl config current-context             # show active context name
kubectl config get-contexts                # list all contexts
kubectl config use-context 3node           # switch to 3node context
kubectl config use-context minikube        # switch back to default minikube

# Set default namespace for current context (saves typing -n constantly)
kubectl config set-context --current --namespace=default
```

**kubeconfig structure:**
```yaml
# ~/.kube/config (simplified)
clusters:          # cluster endpoints + CA certificates
  - name: 3node
    cluster:
      server: https://192.168.49.2:8443
      certificate-authority: /path/to/ca.crt

users:             # credentials
  - name: 3node
    user:
      client-certificate: /path/to/client.crt
      client-key: /path/to/client.key

contexts:          # cluster + user + namespace triplet
  - name: 3node
    context:
      cluster: 3node
      user: 3node
      namespace: default

current-context: 3node   # which context is active
```

---

## Imperative Commands — Fast Object Creation

Imperative commands create objects without writing YAML. Essential for the exam.

### Pods

```bash
kubectl run nginx --image=nginx:1.27
kubectl run nginx --image=nginx:1.27 --port=80
kubectl run nginx --image=nginx:1.27 --env="ENV=prod" --env="VERSION=1"
kubectl run nginx --image=nginx:1.27 --labels="app=nginx,tier=frontend"
kubectl run nginx --image=nginx:1.27 --requests='cpu=100m,memory=128Mi'
kubectl run nginx --image=nginx:1.27 --limits='cpu=500m,memory=256Mi'

# One-shot pod (runs command, auto-deleted on exit) — useful for debugging
kubectl run debug --image=busybox:1.36 --restart=Never -it --rm -- sh
kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm \
  -- nslookup kubernetes.default.svc.cluster.local
```

### Deployments

```bash
kubectl create deployment nginx --image=nginx:1.27
kubectl create deployment nginx --image=nginx:1.27 --replicas=3
kubectl create deployment nginx --image=nginx:1.27 --replicas=3 --port=80
kubectl scale deployment nginx --replicas=5
kubectl set image deployment/nginx nginx=nginx:1.28     # rolling update
kubectl rollout undo deployment/nginx                   # rollback
kubectl rollout status deployment/nginx                 # watch progress
```

### Services

```bash
# Expose a Deployment as a Service
kubectl expose deployment nginx --port=80 --target-port=80
kubectl expose deployment nginx --port=80 --target-port=80 --type=NodePort
kubectl expose deployment nginx --port=80 --type=ClusterIP --name=nginx-svc

# Expose a Pod directly
kubectl expose pod nginx --port=80 --name=nginx-pod-svc
```

### ConfigMaps and Secrets

```bash
# ConfigMap from literal values
kubectl create configmap app-config --from-literal=ENV=prod --from-literal=PORT=8080

# ConfigMap from a file
kubectl create configmap nginx-conf --from-file=nginx.conf

# Secret from literal values
kubectl create secret generic db-secret \
  --from-literal=username=admin \
  --from-literal=password=s3cr3t

# TLS secret from cert and key files
kubectl create secret tls my-tls \
  --cert=tls.crt \
  --key=tls.key
```

### Namespaces, ServiceAccounts, RBAC

```bash
kubectl create namespace monitoring
kubectl create serviceaccount prometheus -n monitoring
kubectl create role pod-reader --verb=get,list,watch --resource=pods
kubectl create rolebinding pod-reader-binding \
  --role=pod-reader --serviceaccount=default:prometheus
kubectl create clusterrolebinding cluster-admin-binding \
  --clusterrole=cluster-admin --user=admin@example.com
```

### Jobs and CronJobs

```bash
kubectl create job db-migrate --image=busybox:1.36 -- sh -c "echo migrating"
kubectl create cronjob daily-backup \
  --image=busybox:1.36 \
  --schedule="0 2 * * *" \
  -- sh -c "echo backing up"

# Manually trigger a CronJob
kubectl create job --from=cronjob/daily-backup manual-backup-001
```

---

## The Most Important Exam Technique: --dry-run=client -o yaml

Never write YAML from scratch in the exam. Generate it:

```bash
# Step 1: generate the YAML
kubectl create deployment nginx --image=nginx:1.27 --replicas=3 \
  --dry-run=client -o yaml > deployment.yaml

# Step 2: edit it to add fields the imperative command does not support
#   (resources, probes, volumes, init containers, etc.)
vi deployment.yaml

# Step 3: apply
kubectl apply -f deployment.yaml
```

**More examples:**

```bash
# Generate a Pod YAML
kubectl run nginx --image=nginx:1.27 --dry-run=client -o yaml

# Generate a Service YAML (expose first to get the right selector)
kubectl expose deployment nginx --port=80 --dry-run=client -o yaml

# Generate a ConfigMap YAML
kubectl create configmap my-cm --from-literal=key=val --dry-run=client -o yaml

# Generate a Job YAML
kubectl create job my-job --image=busybox:1.36 \
  --dry-run=client -o yaml -- sh -c "echo done"

# Generate a CronJob YAML
kubectl create cronjob my-cron --image=busybox:1.36 --schedule="*/5 * * * *" \
  --dry-run=client -o yaml -- sh -c "echo tick"
```

**Why `--dry-run=client`?** The client-side dry-run generates the YAML without
sending anything to the API server. Fast. Use `--dry-run=server` when you want
full validation (admission controllers run) but still not persist.

---

## kubectl explain — Your In-Terminal API Reference

In the exam, you cannot open a browser to Kubernetes docs (unless explicitly
allowed). `kubectl explain` gives you field definitions inline.

```bash
# Top-level resource structure
kubectl explain pod
kubectl explain deployment
kubectl explain service
kubectl explain statefulset

# Drill into specific fields
kubectl explain pod.spec
kubectl explain pod.spec.containers
kubectl explain pod.spec.containers.resources
kubectl explain pod.spec.containers.readinessProbe
kubectl explain pod.spec.initContainers

# Deployment update strategy
kubectl explain deployment.spec.strategy
kubectl explain deployment.spec.strategy.rollingUpdate

# Service types and fields
kubectl explain service.spec
kubectl explain service.spec.type

# --recursive: show ALL fields in a tree view
kubectl explain pod.spec --recursive | head -50
kubectl explain deployment.spec --recursive | grep -i "maxSurge\|maxUnavailable"
```

---

## Output Formats

### -o wide — Extra columns

```bash
kubectl get pods -o wide
# Adds: NODE, IP, NOMINATED NODE, READINESS GATES columns

kubectl get nodes -o wide
# Adds: INTERNAL-IP, EXTERNAL-IP, OS-IMAGE, KERNEL-VERSION, CONTAINER-RUNTIME
```

### -o yaml / -o json — Full object definition

```bash
kubectl get pod nginx-pod -o yaml      # full spec + status as YAML
kubectl get pod nginx-pod -o json      # same as JSON

# Useful for: seeing what the API actually stored (vs what you applied)
# Includes: metadata.resourceVersion, status, defaulted fields
```

### -o jsonpath — Extract specific fields

```bash
# Get just the pod IP
kubectl get pod nginx-pod -o jsonpath='{.status.podIP}'

# Get the image of the first container
kubectl get pod nginx-pod -o jsonpath='{.spec.containers[0].image}'

# Get all container images in a pod
kubectl get pod nginx-pod -o jsonpath='{.spec.containers[*].image}'

# Get all pod names in a namespace
kubectl get pods -o jsonpath='{.items[*].metadata.name}'

# Get pod name + node for each pod (with newline separator)
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# Get the node's external IP
kubectl get node 3node -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'

# Get all container images across all pods
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{": "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

### -o custom-columns — Formatted table output

```bash
# Custom table with pod name, status, and node
kubectl get pods -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'

# Deployments with image info
kubectl get deployments -o custom-columns='DEPLOYMENT:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,REPLICAS:.spec.replicas'
```

---

## Filtering Objects

### Label selectors (-l / --selector)

```bash
# Exact match
kubectl get pods -l app=nginx
kubectl get pods -l app=nginx,tier=frontend      # AND condition
kubectl get pods -l 'app in (nginx, apache)'     # OR condition
kubectl get pods -l 'app notin (nginx)'          # NOT IN
kubectl get pods -l '!deprecated'               # label does not exist

# Used to delete all pods matching a label
kubectl delete pods -l app=nginx
```

### Field selectors (--field-selector)

```bash
# Filter by field values (subset of fields supported)
kubectl get pods --field-selector status.phase=Running
kubectl get pods --field-selector spec.nodeName=3node-m02
kubectl get pods --field-selector metadata.namespace=default
kubectl get events --field-selector reason=BackOff
kubectl get events --field-selector involvedObject.name=nginx-pod

# Combine field selectors
kubectl get pods --field-selector status.phase=Running,spec.nodeName=3node-m02
```

### Watching (-w / --watch)

```bash
kubectl get pods -w                        # watch all pods in namespace
kubectl get pods -w -l app=nginx           # watch filtered pods
kubectl get deployment nginx -w            # watch specific deployment
kubectl get events -w                      # watch all events (noisy but useful)
```

---

## Debugging Commands

### kubectl describe — Human-readable detail with events

```bash
kubectl describe pod nginx-pod       # pod detail + events (most useful for debugging)
kubectl describe deployment nginx    # deployment detail, rollout status
kubectl describe service nginx       # service detail, endpoints, events
kubectl describe node 3node-m02      # node conditions, capacity, allocatable, events
kubectl describe pvc my-pvc          # PVC binding status, events
```

The **Events section** at the bottom of `describe` output is where most
debugging information lives: image pull errors, scheduling failures,
probe failures, OOM kills, etc.

### kubectl logs — Container output

```bash
kubectl logs nginx-pod                          # current logs
kubectl logs nginx-pod -c nginx                 # specific container (multi-container pods)
kubectl logs nginx-pod --previous               # logs from previous (crashed) container
kubectl logs nginx-pod --tail=50                # last 50 lines
kubectl logs nginx-pod --since=1h               # last hour
kubectl logs nginx-pod -f                       # follow (stream) live logs
kubectl logs -l app=nginx                       # logs from all pods with label
kubectl logs -l app=nginx --all-containers      # all containers in matching pods
```

### kubectl exec — Shell access to running containers

```bash
kubectl exec nginx-pod -- ls /etc/nginx                    # run command
kubectl exec nginx-pod -- cat /etc/nginx/nginx.conf        # read file
kubectl exec -it nginx-pod -- bash                         # interactive shell
kubectl exec -it nginx-pod -c nginx -- sh                  # specific container
kubectl exec -it nginx-pod -- env | grep MY_VAR            # check env var
kubectl exec -it nginx-pod -- curl http://localhost:80     # test internal port
```

### kubectl port-forward — Local access to cluster resources

```bash
kubectl port-forward pod/nginx-pod 8080:80         # pod port-forward
kubectl port-forward deployment/nginx 8080:80      # deployment (any pod)
kubectl port-forward service/nginx 8080:80         # service port-forward
kubectl port-forward svc/grafana -n monitoring 3000:3000
```

### kubectl cp — Copy files

```bash
kubectl cp nginx-pod:/etc/nginx/nginx.conf ./local-copy.conf   # pod → local
kubectl cp ./local-config.conf nginx-pod:/tmp/config.conf       # local → pod
kubectl cp nginx-pod:/var/log/nginx/ ./nginx-logs/              # directory copy
```

---

## Pre-Exam Shell Setup (CKA/CKAD Time Savers)

```bash
# Set at the start of the exam — saves time on every command
alias k=kubectl
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'
alias kd='kubectl describe'
alias kdp='kubectl describe pod'
alias kgn='kubectl get nodes'
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'

# Enable kubectl auto-completion (if not already set)
source <(kubectl completion bash)
complete -F __start_kubectl k

# Set editor for kubectl edit
export KUBE_EDITOR=vi   # or nano if you prefer

# Example workflow saving 60%+ typing:
k get po             # instead of kubectl get pods
k describe po nginx  # instead of kubectl describe pod nginx
k run test --image=busybox:1.36 --restart=Never -it --rm -- sh
```

---

## kubectl diff — Preview Before Applying

```bash
# Shows what WILL change if you apply this file — like git diff
kubectl diff -f deployment.yaml

# Example output:
# -     image: nginx:1.27
# +     image: nginx:1.28
# -     replicas: 2
# +     replicas: 5
```

Always run `kubectl diff` before `kubectl apply` in production.

---

## Useful One-Liners

```bash
# Get all images running in the cluster
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u

# Find all pods NOT in Running state
kubectl get pods -A --field-selector 'status.phase!=Running'

# Get resource usage per node (requires metrics-server)
kubectl top nodes
kubectl top pods -A --sort-by=cpu

# Force delete a stuck terminating pod (last resort)
kubectl delete pod stuck-pod --force --grace-period=0

# Get events sorted by time (most recent last)
kubectl get events --sort-by='.lastTimestamp'

# Get events sorted by time (most recent first)
kubectl get events --sort-by='.lastTimestamp' | tail -20

# Patch a field imperatively
kubectl patch deployment nginx -p '{"spec":{"replicas":3}}'
kubectl patch pod nginx-pod -p '{"metadata":{"labels":{"version":"1.28"}}}'

# Label a node
kubectl label node 3node-m02 disktype=ssd

# Annotate an object
kubectl annotate deployment nginx kubernetes.io/change-cause="Deploy v1.27"

# Remove a label
kubectl label node 3node-m02 disktype-    # trailing dash removes the label

# Taint a node
kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule
kubectl taint node 3node node-role.kubernetes.io/control-plane:NoSchedule-  # remove

# Cordon and uncordon
kubectl cordon 3node-m02         # mark unschedulable
kubectl uncordon 3node-m02       # restore scheduling
kubectl drain 3node-m02 --ignore-daemonsets --delete-emptydir-data
```

---

## Imperative vs Declarative — When to Use Each

```
Imperative (kubectl create, kubectl run, kubectl scale):
  ✅ One-off tasks, debugging, quick verification
  ✅ Exam questions that say "create a pod/deployment with these properties"
  ✅ When --dry-run=client -o yaml is the goal (generate YAML, then edit)
  ❌ Not idempotent — running twice creates duplicate / errors
  ❌ Not version-controllable — no file to commit to git

Declarative (kubectl apply -f file.yaml):
  ✅ Production workloads — tracked in git, reviewable, repeatable
  ✅ Multi-field objects that need comments and documentation
  ✅ Idempotent — applying the same file twice is safe
  ✅ kubectl diff works with declarative
  ❌ Slower for quick one-off tasks

Hybrid (generate YAML, then apply) — best of both:
  kubectl create deployment nginx --image=nginx:1.27 \
    --dry-run=client -o yaml > deployment.yaml
  # edit deployment.yaml to add probes, resources, etc.
  kubectl apply -f deployment.yaml
```

---

## What You Learned

In this lab, you:
- ✅ Read kubeconfig structure — clusters, users, contexts, current-context
- ✅ Used `kubectl config` to switch contexts and set default namespaces
- ✅ Created pods, deployments, services, configmaps, secrets, jobs, cronjobs imperatively
- ✅ Mastered `--dry-run=client -o yaml` — the fastest YAML template technique
- ✅ Used `kubectl explain` to look up any field definition without docs
- ✅ Extracted specific fields with `-o jsonpath` — critical for automation
- ✅ Filtered objects with `-l` (label selectors) and `--field-selector`
- ✅ Debugged pods with `describe`, `logs --previous`, `exec`, `port-forward`
- ✅ Set up exam-ready shell aliases and kubectl completion
- ✅ Used `kubectl diff` to preview changes before applying

**Key Takeaway:** kubectl mastery is non-negotiable for CKA/CKAD. The exam
is timed and hands-on — every second saved on syntax recalls and typos
is a second for solving problems. Practise until `k get po`, `k describe po`,
`k run --dry-run=client -o yaml`, and `k explain pod.spec` feel automatic.