# Quiz — 03-services/01-clusterip-nodeport: ClusterIP and NodePort Services

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. A Service shows 3 healthy Endpoints in `kubectl describe svc`, but every `curl` to it from inside the cluster hangs or fails. What's a cause that `describe svc` alone won't reveal?**

- A) The pods aren't actually running
- B) A `port`/`targetPort` swap — traffic reaches a pod but hits a port nothing is listening on
- C) The Service doesn't exist
- D) DNS is completely broken cluster-wide

<details>
<summary>Answer</summary>

**B** — `describe svc` shows the port mapping as configured, not validated against what the container actually listens on. Healthy Endpoints only confirms the *pods* are fine and selected correctly, not that the port mapping is correct.
Trap: A is ruled out by the premise — "3 healthy Endpoints" already means the pods are Running and Ready.

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
Trap: C sounds plausible if you've heard "StatefulSets give stable identity," but that's stable *network identity via DNS*, not stable *IP addresses* — a distinction this demo doesn't cover but is worth not overgeneralizing from.

</details>

---

**Q3. You run `kubectl expose deployment backend --port=9090` with no `--target-port`. What port does traffic actually get forwarded to on the container?**

- A) The container's default port, whatever that is
- B) 9090 — targetPort defaults to the same value as port when omitted
- C) The command fails, requiring --target-port explicitly
- D) Port 80, always

<details>
<summary>Answer</summary>

**B** — Omitting `--target-port` doesn't leave it unset — it defaults to match `--port`. You only need to specify it when the container listens on something different.
Trap: C assumes a required flag that isn't actually required — this command is valid and complete as written.

</details>

---

**Q4. You scale `frontend-deploy` from 3 replicas down to 1. What, if anything, do you need to change on `frontend-svc`?**

- A) Update the Service's selector to match only the remaining pod
- B) Nothing — Endpoints recompute automatically from the existing selector
- C) Delete and recreate the Service
- D) Manually remove the two terminated pods' IPs from Endpoints

<details>
<summary>Answer</summary>

**B** — The Service was never pointed at specific pods, only at a label — scaling changes which pods exist, and Endpoints tracks that automatically.
Trap: D imagines Endpoints as something manually maintained, when it's entirely derived and self-updating.

</details>

---

**Q5. A NodePort Service's `EXTERNAL-IP` column shows `<none>`. A teammate says this means something's misconfigured. Are they right?**

- A) Yes, EXTERNAL-IP should always be populated
- B) No — `<none>` is normal and expected for NodePort; only LoadBalancer populates it
- C) Only right if the cluster is on-prem
- D) Only right if using IPv6

<details>
<summary>Answer</summary>

**B** — This is documented, correct behavior for both ClusterIP and NodePort — neither type provisions an external load balancer.
Trap: A treats the absence of a field as inherently an error, without checking whether that field applies to this Service type at all.

</details>

---

**Q6. `kubectl apply` on a Service succeeds with no errors, but `curl` to it from another pod hangs indefinitely. What's the first command you'd run to start diagnosing, and why?**

- A) `kubectl logs` on the Service — Services don't have logs, so this doesn't apply
- B) `kubectl get endpoints <svc-name>` — an empty list immediately narrows the problem to the selector, not the network
- C) Restart the cluster
- D) `kubectl delete` and recreate the Service

<details>
<summary>Answer</summary>

**B** — Checking Endpoints first is the fastest way to split "selector problem" from "everything else" — an empty list means look at labels; a populated list means look elsewhere (like Q1's port mismatch).
Trap: A is a real trap for people newer to Kubernetes — Services genuinely have no logs of their own, since they don't run anything.

</details>

---

**Q7. A user reaches a NodePort service via a worker node's IP but reports it doesn't work via the control-plane node's IP on the same port. Is that expected Kubernetes behavior?**

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

**Q8. On the exam, you need a Service's external port to be a specific fixed number every time you recreate it. What's the reliable way to guarantee that?**

- A) `kubectl expose` with `--port` set to the desired number
- B) Set `spec.ports[].nodePort` explicitly in YAML — `kubectl expose` alone can't pin it
- C) NodePort values are always randomly assigned, no way to fix them
- D) Use `--type=LoadBalancer` instead

<details>
<summary>Answer</summary>

**B** — `--port` controls the ClusterIP-facing port, not `nodePort` — to pin the actual external port you need `spec.ports[].nodePort` set explicitly, which means YAML (or `--dry-run=client -o yaml` then edit).
Trap: C overcorrects — nodePort *can* be fixed, just not through `kubectl expose`'s flags alone.

</details>

---

**Q9. You `curl` a ClusterIP service 6 times and get an identical response every time. Does this prove load balancing isn't working?**

- A) Yes — identical responses mean all requests hit the same pod
- B) No — if every backend pod is configured to return the same content, you can't distinguish which pod answered from the response alone
- C) Yes, because kube-proxy only load-balances when responses differ
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — Verifying load balancing requires distinguishing data per pod (like a pod name embedded in the response) — identical output across pods is a testing-setup limitation, not evidence about routing behavior.
Trap: A and C both draw a routing conclusion from response *content*, when content and routing are actually independent of each other here.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
