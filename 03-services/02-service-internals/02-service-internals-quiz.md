# Quiz — 03-services/02-service-internals: Service Internals

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Does kube-proxy sit in the data path, processing every packet sent to a Service?**

- A) Yes, every packet passes through kube-proxy
- B) No — it only programs rules; the kernel forwards packets using them
- C) Only in ipvs mode
- D) Only for NodePort, not ClusterIP

<details>
<summary>Answer</summary>

**B** — kube-proxy's job ends at programming iptables/nftables/IPVS rules; the kernel does all actual packet forwarding from that point on.
Trap: C invents an exception that doesn't exist — this is true across all three modes, it's the fundamental design.

</details>

---

**Q2. You delete the kube-proxy pod running on one node. What happens to existing Service traffic through that node while it's being recreated?**

- A) All traffic through that node stops immediately
- B) Existing routing continues uninterrupted — already-programmed rules don't disappear when the pod is deleted
- C) Only NodePort traffic is affected, ClusterIP keeps working
- D) The node is automatically cordoned

<details>
<summary>Answer</summary>

**B** — Since kube-proxy already programmed the kernel's rules and isn't in the data path, those rules keep working independent of whether the kube-proxy pod itself is currently running.
Trap: A assumes kube-proxy is actively involved in ongoing traffic, contradicting the fundamental "only programs rules" design already established.

</details>

---

**Q3. You delete the EndpointSlice for a Service that has a selector. What happens?**

- A) The Service permanently loses all endpoints
- B) The endpointslice-controller recreates it almost immediately, since it's continuously reconciled
- C) Nothing — EndpointSlices for selector-based Services can't be deleted
- D) The Service automatically converts to selectorless

<details>
<summary>Answer</summary>

**B** — Selector-based EndpointSlices are owned and reconciled by the endpointslice-controller — deleting one is a self-healing scenario, not permanent damage.
Trap: A assumes no reconciliation exists for this object, which contradicts the ownership model already shown via the `managed-by` label in Step 2.

</details>

---

**Q4. Is that same self-healing true for a selectorless Service's manually-created EndpointSlice?**

- A) Yes, identical behavior
- B) No — nothing reconciles it automatically; it's entirely your own responsibility
- C) Only if the Service has a LoadBalancer type
- D) Only in production clusters

<details>
<summary>Answer</summary>

**B** — There's no selector for a controller to reconcile against, so a selectorless Service's EndpointSlice is unmanaged — a critical distinction from the selector-based case in Q3.
Trap: A assumes uniform behavior across both cases when they're actually fundamentally different in ownership.

</details>

---

**Q5. Three backend pods all return the identical response text to every request. Does this prove load balancing is broken?**

- A) Yes, identical responses mean one pod is answering everything
- B) No — without distinguishing data per pod, you can't tell which pod answered from content alone
- C) Yes, because kube-proxy should randomize response content
- D) It depends on the Service type

<details>
<summary>Answer</summary>

**B** — Without distinguishing data per pod, successful requests alone can't tell you whether they hit one pod repeatedly or several — this is exactly why both this demo's and `01-clusterip-nodeport`'s backends inject the pod's own name into the response.
Trap: C invents a responsibility for kube-proxy (modifying response content) that it has no role in at all — it only routes packets.

</details>

---

**Q6. Why does kube-proxy run on the control-plane node even though a taint blocks regular workload scheduling there?**

- A) Taints don't apply to system components at all
- B) kube-proxy is a DaemonSet with its own explicit toleration for that taint
- C) The control-plane taint is automatically removed after cluster setup
- D) kube-proxy runs outside the cluster's normal scheduling entirely

<details>
<summary>Answer</summary>

**B** — Taints only block pods that don't explicitly tolerate them; kube-proxy's DaemonSet spec includes a toleration for exactly this taint.
Trap: A overgeneralizes — taints absolutely can affect system components; it's specifically having a matching toleration that exempts a given pod, not being "system" in some general sense.

</details>

---

**Q7. In the iptables chain for a 3-pod Service, what do the cascading `probability 0.333`, `0.500`, and implicit-last values achieve?**

- A) They prioritize the first pod listed to receive more traffic
- B) Roughly equal distribution across all 3 pods, computed via cascading probability of the remainder
- C) They're vestigial and have no functional effect
- D) They represent CPU usage per pod

<details>
<summary>Answer</summary>

**B** — 1/3 for the first, 1/2 of the remaining 2/3 (= 1/3) for the second, everything left (= 1/3) for the third — netting out to equal distribution despite each individual probability looking different.
Trap: A misreads the first probability as favoring that pod, without accounting for how the cascading remainder math actually works out equal in the end.

</details>

---

**Q8. What is `ipvs` mode's current status, as of Kubernetes v1.35?**

- A) It's the default mode for all new clusters
- B) It was formally deprecated — `nftables` is the current recommendation for its original "scale better than iptables" use case
- C) It was removed entirely and no longer exists
- D) It's only usable on cloud-managed clusters now

<details>
<summary>Answer</summary>

**B** — `ipvs` is deprecated as of v1.35, not simply "less preferred" — `nftables` (stable since v1.33) is the actively-developed answer to the same scaling problem `ipvs` was originally built to solve.
Trap: C overstates the situation — deprecated is not the same as removed; existing clusters running `ipvs` aren't broken, but it shouldn't be chosen for a new one.

</details>

---

**Q9. You hand-write an EndpointSlice for a selectorless Service, but the Service still shows no working endpoints. What's the most likely cause?**

- A) Selectorless Services can never have working endpoints
- B) The `kubernetes.io/service-name` label on the EndpointSlice doesn't match the Service's actual name
- C) EndpointSlices always require a selector to function
- D) The `port` field was omitted

<details>
<summary>Answer</summary>

**B** — This label is the *only* thing linking a manually-created EndpointSlice to its Service; get it wrong and the Service has no endpoints at all, with no error pointing at the cause.
Trap: C contradicts the entire premise of this demo's selectorless pattern — EndpointSlices work perfectly well without a selector, that's the point.

</details>

Score guide:
| Score | Action |
|---|---|
| 8-9/9 | Import Anki cards, move to next Demo |
| 7/9 | Review the wrong answer, then proceed |
| 6/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
