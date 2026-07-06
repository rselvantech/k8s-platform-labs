# Quiz — 11-auto-scaling/03-vpa-fundamentals: VPA Fundamentals

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to 04-keda-adapter.

**Q1. You apply a VPA in `Recreate` mode targeting a bare Pod object (not a Deployment). Load increases and the Recommender calculates a new Target. What happens?**

A. The pod's resources update in place with no restart
B. The Updater evicts the pod via the Eviction API, and it never comes back since there's no controller to recreate it
C. VPA refuses to accept the target and reports an error
D. The pod restarts automatically with the same resources unchanged

<details>
<summary>Answer</summary>

**B** — the Updater evicts, but no controller recreates it.
Trap: A confuses Recreate with the beta InPlaceOrRecreate mode. C assumes a validation step VPA doesn't perform. D ignores that eviction actually happens.

</details>

---

**Q2. A Deployment's container has no `resources.requests` set. You apply a VPA in `Off` mode and `kubectl describe vpa` shows a healthy Target recommendation. Is the pod protected from eviction under node memory pressure right now?**

A. Yes, because VPA is actively managing it
B. Yes, because Off mode still applies live resource caps
C. No — the pod is BestEffort QoS until the recommendation is actually applied
D. No, but only because Off mode is not a valid VPA mode

<details>
<summary>Answer</summary>

**C** — a Target recommendation existing doesn't change the pod's actual QoS.
Trap: A confuses "VPA has an opinion" with "VPA has acted." B misdescribes Off mode, which takes no action at all. D incorrectly claims Off isn't a valid mode.

</details>

---

**Q3. `kubectl describe vpa` shows `Target: cpu=50m`, `Uncapped Target: cpu=200m`. The task asks why the pod still throttles under peak load. What's the correct diagnosis?**

A. The Recommender is malfunctioning and needs a restart
B. `maxAllowed` in resourcePolicy is capping the applied Target well below actual usage
C. Metrics-server hasn't scraped recently enough
D. The pod is in Off mode so no recommendation is ever applied

<details>
<summary>Answer</summary>

**B** — the gap between Target and Uncapped Target is a deliberate cap, not a pipeline failure.
Trap: A and C assume something is broken when the values shown are exactly what a `maxAllowed` cap produces. D contradicts the fact that a Target is showing at all.

</details>

---

**Q4. An HPA scales a Deployment on CPU utilization, and a VPA in Recreate mode is also targeting CPU on the same Deployment. Replica count oscillates with no actual load change. What's happening?**

A. HPA and VPA are both broken and need to be recreated
B. VPA's resource-request changes shift the utilization % HPA calculates, and HPA's replica changes shift what VPA recommends next — feedback loop
C. This is expected steady-state behavior and requires no fix
D. The cluster doesn't have enough CPU capacity

<details>
<summary>Answer</summary>

**B** — the two autoscalers are feeding each other's inputs.
Trap: C wrongly dismisses a real conflict as normal. A jumps to "broken" instead of "conflicting." D introduces an unrelated capacity explanation.

</details>

---

**Q5. You want to demonstrate the HPA/VPA conflict pattern without the demo pod being repeatedly evicted. Which VPA `updateMode` should you use for this demo?**

A. Recreate
B. InPlaceOrRecreate
C. Off
D. Auto

<details>
<summary>Answer</summary>

**C** — Off makes recommendations visible without taking disruptive action.
Trap: A and B both cause real evictions/resizes, defeating the purpose of a clean conflict demo. D is deprecated and shouldn't be used at all.

</details>

---

**Q6. A Deployment has a PDB with `minAvailable: 100%`, and its VPA is in Recreate mode. A new recommendation is calculated. What happens when the Updater tries to apply it?**

A. The Updater bypasses the PDB since VPA changes are considered non-disruptive
B. The eviction is blocked by the PDB, so the new resource values are never applied
C. The PDB is automatically updated to allow the eviction
D. The pod is deleted and not recreated, same as a standalone-pod scenario

<details>
<summary>Answer</summary>

**B** — the Eviction API respects the PDB just like any other eviction request.
Trap: A wrongly assumes VPA has special eviction privileges. C invents automatic PDB mutation that doesn't happen. D confuses this with the separate standalone-pod failure mode.

</details>

---

**Q7. How does HPA change the number of running pods, mechanically?**

A. It uses the Eviction API to remove pods gracefully, respecting PDBs
B. It directly edits the Deployment's `replicas` field; the ReplicaSet controller creates/deletes pods to match, with no eviction involved
C. It sends a resize signal to the container runtime
D. It triggers the VPA Updater to evict and recreate pods with new counts

<details>
<summary>Answer</summary>

**B** — HPA only ever changes the desired replica count.
Trap: A describes VPA's Updater mechanism, not HPA's. C describes in-place resizing, unrelated to replica count. D conflates the two autoscalers' mechanisms entirely.

</details>

---

**Q8. You need a workload's resources to update without any pod restart whenever possible, falling back to restart only if truly necessary. Which VPA mode fits this requirement?**

A. Off
B. Initial
C. Recreate
D. InPlaceOrRecreate

<details>
<summary>Answer</summary>

**D** — attempts in-place resize first, falls back to evict-and-recreate only when necessary.
Trap: C always restarts. B only applies once at pod creation and never updates a running pod. A never applies anything automatically.

</details>

---

**Q9. `kubectl describe vpa` shows Lower Bound and Upper Bound values in addition to Target. What role do these play?**

A. They define hard limits the pod's actual resources can never exceed
B. They're historical min/max usage values with no effect on VPA's behavior
C. They define the range the Recommender tolerates without changing Target — actual usage must move outside this range before Target updates
D. They represent the previous and next scheduled recommendation update times

<details>
<summary>Answer</summary>

**C** — Lower/Upper Bound gate when Target actually changes.
Trap: A confuses these with resourcePolicy's min/maxAllowed, which are the real hard limits. B undersells their role in gating Target updates. D invents a time-based meaning that doesn't exist.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 7/9 | Re-read the relevant section, retry those questions |
| Below 7/9 | Re-read the full demo and redo the walkthrough before proceeding |
