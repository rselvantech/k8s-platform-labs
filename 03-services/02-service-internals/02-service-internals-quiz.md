# Quiz — 03-services/02-service-internals: Service Internals

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. kube-proxy watches for changes to both Services and EndpointSlices. Why does it need to watch EndpointSlices specifically, separate from watching Services?**

- A) It doesn't — watching Services alone is sufficient
- B) A Service's own spec rarely changes, but which pods back it changes constantly (scaling, restarts, readiness) — EndpointSlice changes are what actually drive re-programming the iptables rules
- C) EndpointSlices are watched only during initial cluster setup
- D) Services and EndpointSlices are the same object internally

<details>
<summary>Answer</summary>

**B** — The Service object (port, selector, type) is comparatively static; the EndpointSlice is what changes moment to moment as pods come and go, which is exactly what the DNAT rules need to stay current with.
Trap: D conflates two genuinely separate API objects that just happen to be linked by a label.

</details>

---

**Q2. An EndpointSlice entry shows `Terminating: true`. Does the pod immediately stop handling any traffic at that instant?**

- A) Yes, immediately — no further requests are processed
- B) No — it's removed from new load-balancing selection, but the pod keeps running and finishing in-flight requests until its grace period elapses
- C) `Terminating: true` only appears after the pod is already fully gone
- D) It has no effect on traffic at all, only on `kubectl get pods` display

<details>
<summary>Answer</summary>

**B** — This mirrors the graceful-shutdown timing already covered for Pods generally — kube-proxy stops sending it *new* requests, but the pod itself isn't force-killed just because this condition flipped.
Trap: A assumes an instant hard cutover, ignoring that graceful termination is specifically designed to avoid dropping in-flight work.

</details>

---

**Q3. Both a Deployment-managed Pod (`01-basic-deployment`) and a DaemonSet-managed kube-proxy pod (this demo's Break-Fix Error-1) get recreated automatically when deleted. Is the underlying mechanism the same?**

- A) No — DaemonSets use a completely different reconciliation system from Deployments/ReplicaSets
- B) Yes in principle — both are controllers continuously reconciling actual state (pods that exist) against desired state (one pod per node, for a DaemonSet), just with different desired-state rules
- C) DaemonSets don't self-heal; only Deployments do
- D) Only true if the DaemonSet is in `kube-system`

<details>
<summary>Answer</summary>

**B** — The general reconciliation pattern (watch → compare actual vs. desired → correct the gap) is the same shape across ReplicaSet, DaemonSet, and EndpointSlice controllers — only what "desired" means differs per controller type.
Trap: D invents a namespace-based exception — self-healing has nothing to do with which namespace a DaemonSet's pods run in.

</details>

---

**Q4. This demo's Break-Fix Error-1 (kube-proxy pod deleted) and Error-2 (EndpointSlice deleted) both result in no lasting disruption. What's the key structural difference between what actually got removed in each case?**

- A) There's no difference — both are the same failure
- B) Error-1 removes a controller *pod* whose job is to program rules; Error-2 removes the *data object* describing which pods should receive traffic — different layers, both self-healing for different reasons
- C) Error-1 is DNS-related, Error-2 is scheduling-related
- D) Error-2 can only happen on selectorless Services

<details>
<summary>Answer</summary>

**B** — Error-1 is "the thing that programs rules briefly went away, but the rules it already wrote still work." Error-2 is "the object describing current pod IPs went away, but the controller that owns that object rebuilds it." Different objects, different owners, same theme of resilience through reconciliation.
Trap: D contradicts the demo directly — Error-2's scenario specifically uses a *selector-based* Service to demonstrate self-healing; the selectorless case is explicitly called out as the exception, not the rule, in that same Break-Fix's closing note.

</details>

---

**Q5. `nftables` has been stable since Kubernetes v1.33. Is it currently the default kube-proxy mode?**

- A) Yes, as of v1.33 it replaced iptables as the default
- B) No — `iptables` remains the default mode even though `nftables` is the current recommendation for new clusters on supported kernels
- C) The default depends entirely on which CNI plugin is installed
- D) There is no default; it must always be set explicitly

<details>
<summary>Answer</summary>

**B** — "Stable" and "recommended for new clusters" aren't the same as "default" — this demo's Concepts are explicit that `iptables` is still what you get without configuring otherwise.
Trap: A conflates stability/recommendation with being the actual default setting.

</details>

---

**Q6. In the EndpointSlice output, each endpoint has a `TargetRef` pointing to a specific `Pod/backend-deploy-xxxxx-aaaaa`. What does this give you that just having the IP address wouldn't?**

- A) Nothing — the IP alone is sufficient for all purposes
- B) A direct link back to the actual Pod object, letting you `kubectl describe` or `kubectl logs` that exact backing pod instead of having to guess which pod owns a given IP
- C) `TargetRef` is only informational and can't be used to look anything up
- D) It's required for kube-proxy to function at all

<details>
<summary>Answer</summary>

**B** — When you're debugging a specific misbehaving endpoint, `TargetRef` is what turns "10.244.1.x is acting up" into "which pod is that, so I can `kubectl logs` it" without a separate IP-to-pod lookup.
Trap: D overstates its necessity — kube-proxy's actual rule-programming works from addresses and ports, not from needing to resolve `TargetRef` back to a Pod object.

</details>

---

**Q7. As of Kubernetes v1.33+, what specifically happens when you run `kubectl get endpoints` (the old API)?**

- A) The command fails outright with an error
- B) It still works and returns the same underlying data, but prints a deprecation warning pointing to EndpointSlices
- C) It silently returns an empty result
- D) It's automatically translated into `kubectl get endpointslices` output

<details>
<summary>Answer</summary>

**B** — Deprecated means "still functions, but you're told to migrate" — not removed and not silently broken.
Trap: A and C both assume deprecation means broken/non-functional, which overstates what "deprecated" actually means here.

</details>

---

**Q8. A selectorless Service's manually-written EndpointSlice must include its own `ports[]` list, separate from the Service's own `spec.ports[]`. Why is this duplication necessary?**

- A) It isn't necessary — the EndpointSlice inherits ports from the Service automatically
- B) For a selector-based Service, the endpointslice-controller derives the EndpointSlice's ports from the Service automatically; for a selectorless one, nothing does that derivation, so you must state it yourself
- C) EndpointSlice ports are purely cosmetic and never actually used
- D) Only the Service's `ports[]` matters; the EndpointSlice's copy is ignored

<details>
<summary>Answer</summary>

**B** — This is the same theme as `conditions.ready` needing to be explicit on a manual EndpointSlice — anything the endpointslice-controller normally computes for you has to be written by hand once there's no controller doing that computation.
Trap: D assumes one of the two duplicated fields is simply dead weight, when in fact the EndpointSlice's own values are what's actually used for routing in the selectorless case.

</details>

---

**Q9. Why does this demo re-run the "distinguishable per-pod response" check from `01-clusterip-nodeport` in its own Step 1, before introducing anything new?**

- A) It's unnecessary repetition with no purpose
- B) To reconfirm load balancing is genuinely happening before this demo goes on to explain the exact iptables mechanics producing it — establishing the "what" again right before diving into the "how"
- C) Because the backend image changed since the last demo
- D) It's required for EndpointSlices to be created at all

<details>
<summary>Answer</summary>

**B** — Step 1 explicitly frames this as re-confirmation before Steps 4-5 explain the underlying mechanism — establishing the observed behavior first, then explaining it, rather than assuming it's still true from the last demo.
Trap: D invents a dependency between response content and EndpointSlice creation — EndpointSlices are created based on Service selectors and pod readiness, completely independent of what a pod's application actually returns.

</details>

Score guide:

| Score | Action |
|---|---|
| 8-9/9 | Import Anki cards, move to next Demo |
| 7/9 | Review the wrong answer, then proceed |
| 6/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
