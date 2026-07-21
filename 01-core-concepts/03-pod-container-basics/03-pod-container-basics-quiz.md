# Quiz — 01-core-concepts/03-pod-container-basics: Pod and Container Basics

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What is the pause container's job in a Pod?**

- A) It runs the main application logic before your containers start
- B) It's the first container created — it claims the network/IPC/UTS namespaces so your containers can join them
- C) It only exists in multi-container pods
- D) It monitors resource usage and enforces limits

<details>
<summary>Answer</summary>

**B** — The pause container does nothing but hold namespaces open; every container in the pod, including single-container pods, joins its namespaces.
Trap: C is wrong — every Pod has a pause container, not just multi-container ones.

</details>

---

**Q2. Which namespaces are shared between containers in a Pod by default?**

- A) Network, IPC, UTS
- B) PID, mount, cgroup
- C) All Linux namespaces are shared by default
- D) None are shared by default — you must opt in to all sharing

<details>
<summary>Answer</summary>

**A** — Network, IPC, and UTS are shared automatically. PID sharing is opt-in (`shareProcessNamespace: true`), and mount namespace is never shared; each container also gets its own cgroup accounting.
Trap: B lists exactly the namespaces/mechanisms that are NOT shared by default — a common mix-up.

</details>

---

**Q3. A container inside a running Pod crashes and Kubernetes restarts it. What happens to the Pod itself?**

- A) The Pod is deleted and a brand new Pod is created with a new IP
- B) The Pod object is untouched — same IP, same UID, only the container instance is new
- C) The Pod moves to a different node automatically
- D) The Pod's labels are reset to default

<details>
<summary>Answer</summary>

**B** — The network namespace is held by the pause container, not the app container, so a container crash doesn't affect the Pod's identity.
Trap: A assumes "restart" always means full recreation — that's what happens when a *controller* replaces a pod, not when a container inside an existing pod restarts.

</details>

---

**Q4. A namespace has a LimitRange configured. You create a Pod with no `resources.requests` set. What happens?**

- A) The Pod is rejected outright
- B) The LimitRanger admission controller can inject a default request before the Pod is scheduled
- C) Nothing — LimitRange only affects Deployments, not Pods
- D) The Pod runs with unlimited resources

<details>
<summary>Answer</summary>

**B** — LimitRanger's mutating phase can inject defaults for unset resource fields before the object is ever scheduled — what you applied and what got persisted can differ.
Trap: D assumes omitting a field means no constraint at all, ignoring namespace-level defaulting.

</details>

---

**Q5. Does setting `containerPort` in a Pod spec open a port or configure a firewall rule?**

- A) Yes, it opens the port at the node's firewall
- B) No — it's informational only; a container is reachable on any port it listens on regardless
- C) It only matters if kube-proxy is running
- D) It configures the CNI plugin's port mapping

<details>
<summary>Answer</summary>

**B** — Nothing in the pod-creation path consumes this field to actually open anything. It mainly helps `kubectl` display output and lets a Service reference the port by name.
Trap: C wrongly ties this field to kube-proxy, which isn't involved in pod creation at all.

</details>

---

**Q6. What's the difference between `command` and `args` in a container spec?**

- A) They're interchangeable — either can be used for anything
- B) command overrides ENTRYPOINT; args overrides CMD
- C) command sets environment variables; args sets the image
- D) args overrides ENTRYPOINT; command overrides CMD

<details>
<summary>Answer</summary>

**B** — This is the actual mapping. Getting it backwards (D) is a common mix-up under time pressure.
Trap: D swaps the two — a classic exam-day error since the names don't obviously map to ENTRYPOINT/CMD without having memorized the direction.

</details>

---

**Q7. A pod shows `STATUS: Running` but `READY: 0/1`. What does that mean?**

- A) The pod is about to be deleted
- B) The container is running but failing its readiness probe
- C) The pod has no containers at all
- D) The node is out of resources

<details>
<summary>Answer</summary>

**B** — Running and Ready are two separate signals; a container can be executing and still not pass its readiness check.
Trap: This is one of the most common real-world misreadings — assuming "Running" alone means the pod is fully healthy.

</details>

---

**Q8. You run `kubectl get pods -l app=web-frontend` and get no results, even though you're sure you created the pod. What's a likely explanation?**

- A) The cluster lost the pod
- B) A label typo — the pod may exist under a slightly different label value
- C) Label selectors only work with 100% certainty on Deployments, not Pods
- D) You must use `--all-namespaces` for label selectors to work at all

<details>
<summary>Answer</summary>

**B** — An empty selector result doesn't mean the object doesn't exist — it means nothing currently matches that exact label. Run `kubectl get pods` without a selector to check.
Trap: A assumes cluster-level data loss for what's almost always a much simpler typo.

</details>

---

**Q9. In the end-to-end pod creation flow, which component actually enforces `resources.limits` at runtime?**

- A) kube-scheduler
- B) kube-apiserver, via admission control
- C) The kernel, via cgroups configured by kubelet through the CRI
- D) kube-proxy

<details>
<summary>Answer</summary>

**C** — kubelet translates `resources.limits` into cgroup parameters at container-creation time, but the actual throttling/OOM-killing enforcement happens at the kernel level, not through kubelet continuously policing it.
Trap: A confuses `requests` (a scheduling input) with `limits` (a runtime enforcement mechanism) — they're used by entirely different components.

</details>

---

**Q10. What actually happens, in order, when you run `kubectl delete pod`?**

- A) SIGKILL is sent immediately
- B) The pod is removed from etcd instantly, then containers stop afterward
- C) Terminating status → SIGTERM → grace period → SIGKILL if still running
- D) The pod is paused, not deleted, until manually confirmed

<details>
<summary>Answer</summary>

**C** — Deletion gives the container a chance to shut down cleanly within `terminationGracePeriodSeconds` before being forcefully killed, all driven by kubelet.
Trap: A skips the entire graceful-shutdown mechanism that `terminationGracePeriodSeconds` exists to provide.

</details>

---

**Q11. A pod's single container has `resources.requests` set for CPU and memory, but no `resources.limits` set at all. What's its QoS class?**

- A) Guaranteed
- B) Burstable
- C) BestEffort
- D) It has no QoS class unless limits are also set

<details>
<summary>Answer</summary>

**B** — Guaranteed requires requests *equal to* limits for every resource on every container; BestEffort requires *neither* requests nor limits set on any container. Anything else — including "only requests, no limits" — is Burstable.
Trap: C assumes any missing field defaults to the lowest tier; it doesn't — BestEffort specifically means *nothing at all* is set.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/11 or above | Import Anki cards, move to next Demo |
| 8/11 | Review the wrong answers, then proceed |
| 6–7/11 | Re-read the relevant section, retry those questions |
| Below 6/11 | Re-read the full demo and redo the walkthrough before proceeding |
