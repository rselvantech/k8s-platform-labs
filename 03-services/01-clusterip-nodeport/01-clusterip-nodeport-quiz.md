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
