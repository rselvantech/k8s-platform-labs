# Quiz — 01-core-concepts/01-cluster-architecture: Cluster Architecture

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1.** A cluster's `kubectl get nodes` and `kubectl get pods -n kube-system`
commands both hang indefinitely with no response. What's the most likely
root cause?
- A) kube-scheduler is down
- B) kube-controller-manager is down
- C) kube-apiserver or etcd is down/unreachable
- D) kube-proxy is down on the control-plane node

<details>
<summary>Answer</summary>

**C** — kubectl itself can't get any response, which only happens when the apiserver (or the etcd it depends on) is unreachable.
Trap: A and B would still let kubectl commands succeed — you'd just see stuck Pending pods or missing reconciliation, not a total hang. D affects Service routing, not kubectl's ability to talk to the API at all.

</details>

---

**Q2.** You create a Deployment with 3 replicas. `kubectl get pods` shows 3
Pod objects, all stuck in `Pending` with zero scheduling-related events.
What's the most precise diagnosis?
- A) kubelet is down on all nodes
- B) kube-scheduler is down or not watching the apiserver
- C) etcd has lost quorum
- D) The container image doesn't exist

<details>
<summary>Answer</summary>

**B** — the Pod objects clearly exist and are visible, which already rules out an etcd/apiserver problem; the missing piece is scheduling.
Trap: C would likely prevent reliable listing of the Pods at all; A would show pods assigned to nodes but never actually starting, not stuck unscheduled; D would show an image-pull error after scheduling, not zero events pre-scheduling.

</details>

---

**Q3.** A 5-member etcd cluster has just lost 3 members simultaneously.
What happens?
- A) The cluster continues operating normally since 2 members remain
- B) Quorum is lost (a majority of 5 is 3) — no more writes are acknowledged, though existing pods keep running
- C) etcd automatically promotes remaining members to compensate
- D) Only read operations are affected; writes continue normally

<details>
<summary>Answer</summary>

**B** — with only 2 of 5 members left, there's no majority, so quorum is lost.
Trap: A and D wrongly assume 2 surviving members are enough; C invents automatic recovery behavior that doesn't happen — losing quorum requires manual/operational intervention.

</details>

---

**Q4.** A static pod's manifest on a control-plane node needs to be
corrected. What's the correct way to do it?
- A) `kubectl edit pod kube-apiserver-<node> -n kube-system`
- B) `kubectl apply -f` a corrected version of the pod spec
- C) Edit the manifest file directly at `/etc/kubernetes/manifests/` on that node — kubelet picks up the change automatically
- D) Delete the pod with `kubectl delete pod` and let it recreate itself with the corrected spec

<details>
<summary>Answer</summary>

**C** — static pods are sourced from the filesystem, not the API.
Trap: A and D both treat the static pod's mirror pod as a normal apiserver-managed object — mirror pods are read-only reflections; the real source of truth is the file on disk.

</details>

---

**Q5.** Pods on `3node-m02` can't reach a ClusterIP Service. Identical pods
on `3node-m03` reach it fine. Which component is the most likely cause, and
why is the failure node-scoped rather than cluster-wide?
- A) CoreDNS — but this would typically be cluster-wide, not node-scoped
- B) kube-proxy on `3node-m02` — it runs as a DaemonSet with one independent instance per node
- C) The Service object itself is misconfigured
- D) kube-scheduler placed the pods incorrectly

<details>
<summary>Answer</summary>

**B** — a per-node DaemonSet failure explains a single-node-scoped symptom.
Trap: A and C both describe causes that would produce cluster-wide symptoms, which doesn't match this scenario; D confuses scheduling placement with runtime networking behavior.

</details>

---

**Q6.** What's the correct order of events after `kubectl apply -f
deployment.yaml` succeeds, before any container starts running?
- A) apiserver writes to etcd → kubelet starts container → scheduler assigns node
- B) apiserver writes to etcd → Deployment controller creates ReplicaSet → ReplicaSet controller creates Pods → scheduler assigns node → kubelet starts container
- C) Deployment controller creates ReplicaSet → apiserver writes to etcd → scheduler assigns node
- D) scheduler assigns node → apiserver writes to etcd → Deployment controller creates ReplicaSet

<details>
<summary>Answer</summary>

**B** — this is the actual watch-driven chain, in order.
Trap: A skips the entire controller chain, jumping straight from the etcd write to kubelet; C and D reorder steps that must happen in a fixed sequence — the apiserver write must occur before any controller can observe the object via its watch.

</details>

---

**Q7.** kube-controller-manager crashes. A Deployment already has 3 healthy
running pods. One of those pods is manually deleted. What happens?
- A) A replacement pod is created within seconds, same as normal
- B) No replacement pod is ever created until kube-controller-manager is restored
- C) kubelet on another node automatically creates a replacement
- D) The remaining 2 pods automatically absorb the missing pod's traffic and no replacement is needed

<details>
<summary>Answer</summary>

**B** — the ReplicaSet controller, which enforces replica count, isn't running.
Trap: A ignores that the reconciliation loop responsible for this is down; C misattributes ReplicaSet-controller responsibility to kubelet, which only manages pods already assigned to its own node; D confuses Service load-balancing with replica-count enforcement — unrelated mechanisms.

</details>

---

**Q8.** Why does cloud-controller-manager not run in a minikube cluster,
and what would it do if it did?
- A) It's deprecated and no longer used in any Kubernetes cluster
- B) It only runs on cloud-managed clusters (EKS/GKE/AKS) to integrate with cloud-provider APIs — e.g. provisioning LoadBalancers, managing cloud VM node lifecycle, configuring VPC routes
- C) It's merged into kube-controller-manager in all clusters now
- D) minikube disables it purely for performance; it's fully functional if manually enabled

<details>
<summary>Answer</summary>

**B** — it exists specifically to bridge Kubernetes to a cloud provider's own APIs.
Trap: A is factually wrong — it's actively used on all major managed cloud clusters; C invents a merge that hasn't happened; D wrongly implies it's just switched off for speed, when the real reason is there's no cloud API for it to integrate with locally.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
