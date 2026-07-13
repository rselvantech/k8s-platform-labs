# Quiz — 11-auto-scaling/04-keda-fundamentals: KEDA Architecture, ScaledObjects, and Scale-to-Zero

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. HPA requires `minReplicas >= 1` by default. How does KEDA achieve scale-to-zero?**

- A) KEDA replaces HPA with its own controller that supports 0 replicas
- B) KEDA Operator directly patches Deployment.spec.replicas=0, bypassing HPA for the final 1→0 step
- C) KEDA sets HPA `minReplicas: 0` on the managed HPA object
- D) KEDA uses the VPA Updater to evict the last pod

<details>
<summary>Answer</summary>

**B** — HPA scales from N down to 1 (its floor); KEDA Operator then handles 1→0 by directly patching the Deployment spec, bypassing HPA entirely for this final step.

Trap A: KEDA does not replace HPA — it creates and manages HPA objects. Trap C: the KEDA-managed HPA's `minReplicas` stays at 1 by default — HPA rejects 0 at schema validation unless the alpha `HPAScaleToZero` gate is explicitly enabled. Trap D: VPA Updater has no role in KEDA scaling.

</details>

---

**Q2. You create a ScaledObject targeting the `worker` Deployment. What does KEDA create automatically?**

- A) A VPA targeting the same Deployment
- B) A Pod that runs the KEDA scaler logic
- C) An HPA named `keda-hpa-<scaledobject-name>` targeting the same Deployment
- D) A ClusterTriggerAuthentication for the event source

<details>
<summary>Answer</summary>

**C** — KEDA Operator creates and manages an HPA object for every ScaledObject, named `keda-hpa-<scaledobject-name>`.

Trap A: VPA is unrelated to KEDA. Trap B: scaler logic runs inside the Operator and Metrics Server, not a separate Pod per ScaledObject. Trap D: TriggerAuthentication is created by you, not KEDA.

</details>

---

**Q3. A ScaledObject already exists on a Deployment. You then apply a manual HPA targeting the same Deployment. What happens?**

- A) The apply is rejected immediately by KEDA's admission webhook
- B) The apply succeeds; the conflict only surfaces afterward as AmbiguousSelector, and both HPAs stop functioning
- C) The manual HPA silently overrides the KEDA-managed one
- D) KEDA merges the two HPAs into one

<details>
<summary>Answer</summary>

**B** — A plain HPA is not a KEDA resource, so KEDA's admission webhook never validates it. The apply succeeds; the HPA controller then finds two HPAs targeting the same Deployment and cannot determine which is authoritative — both stop processing.

Trap A: this is true only in the REVERSE order (a ScaledObject applied against an already-existing conflicting HPA) — order matters. Trap C, D: no override or merge occurs — the conflict just breaks both.

</details>

---

**Q4. A ScaledObject's cron window closed 2 minutes ago (`cooldownPeriod: 300`, the default). `kubectl get pods` still shows the Deployment's pods running. Is this a bug?**

- A) Yes — KEDA should scale to zero the instant the window closes
- B) No — cooldownPeriod is a flat, unconditional delay applied after any trigger deactivation, including an unambiguous one like a cron window closing
- C) Yes — this only happens if pollingInterval is misconfigured
- D) No, but only because Cron scalers never actually scale to zero

<details>
<summary>Answer</summary>

**B** — `cooldownPeriod` (default 300s) applies as a flat delay regardless of whether the deactivation signal needed debouncing. 2 minutes is well within the 5-minute default.

Trap A: conflates the ACTIVE flag flipping with the scale-to-zero action actually happening — they're separated by cooldownPeriod. Trap C: pollingInterval controls query frequency, unrelated to this delay. Trap D: Cron scalers fully support scale-to-zero.

</details>

---

**Q5. What is the difference between `pollingInterval` and `cooldownPeriod`?**

- A) They are two names for the same setting
- B) pollingInterval controls query frequency in both directions; cooldownPeriod only delays the scale-to-zero action after deactivation
- C) pollingInterval only applies to Cron; cooldownPeriod only applies to Redis
- D) cooldownPeriod controls how fast pods scale up from zero

<details>
<summary>Answer</summary>

**B** — `pollingInterval` affects how often KEDA checks the event source, in both the activation and deactivation direction. `cooldownPeriod` only applies once on the way to zero — there's no equivalent grace period scaling up from zero.

Trap C: both settings are generic to all trigger types. Trap D: scale-from-zero has no cooldown-equivalent delay — it reacts at the next pollingInterval.

</details>

---

**Q6. Why doesn't the Cron scaler require a TriggerAuthentication?**

- A) Cron scalers are exempt from KEDA's authentication requirements by design
- B) Cron has no external event source to authenticate to — it scales purely against the system clock
- C) TriggerAuthentication is optional for every scaler type
- D) Cron uses the KEDA Operator's own service account instead

<details>
<summary>Answer</summary>

**B** — There's no backend system to connect to for a schedule-based trigger, so there's nothing to authenticate. TriggerAuthentication matters for scalers connecting to a real backend (Redis, Kafka, cloud APIs).

Trap A: it's not a special exemption — there's simply nothing to authenticate against. Trap C: some scalers absolutely require authentication for real use. Trap D: not how Cron works — it needs no external connection at all.

</details>

---

**Q7. Which KEDA CRD would you use to process one batch of files, where each file is handled by its own short-lived pod that exits when done?**

- A) ScaledObject
- B) ScaledJob
- C) TriggerAuthentication
- D) ClusterTriggerAuthentication

<details>
<summary>Answer</summary>

**B** — ScaledJob creates one Kubernetes Job per unit of work; each Job pod processes one item and exits. ScaledObject targets long-running Deployments that never "complete."

Trap A: ScaledObject is for long-running workloads. Trap C, D: these are for credentials, not scaling targets.

</details>

---

**Q8. What does the KEDA Metrics Server implement, and how does HPA use it?**

- A) It implements `metrics.k8s.io` — HPA reads CPU/memory from it
- B) It implements `external.metrics.k8s.io` — HPA queries it for trigger metrics via the External Metrics API
- C) It implements `custom.metrics.k8s.io` — HPA queries it for Pods and Object metric types
- D) It runs as a sidecar in each target pod

<details>
<summary>Answer</summary>

**B** — KEDA Metrics Server registers as an APIService for `external.metrics.k8s.io`. Every KEDA scaler, regardless of type, surfaces through this one API group.

Trap A: `metrics.k8s.io` is served by metrics-server, unrelated to KEDA — and it's exactly what a CPU/memory-triggered ScaledObject's HPA reads from directly, bypassing KEDA's own metrics server entirely. Trap C: KEDA never implements the Custom Metrics API — that's the Prometheus Adapter's domain. Trap D: KEDA Metrics Server is a cluster-wide Deployment, not per-pod.

</details>

---

**Q9. `kubectl get scaledobject` shows `READY=False` with `ScalerNotReady: deployments.apps "wroker" not found`. What is the most likely cause?**

- A) The target Deployment has 0 replicas
- B) A typo in `scaleTargetRef.name`
- C) KEDA is not installed correctly
- D) The trigger type is misconfigured

<details>
<summary>Answer</summary>

**B** — The error message names the exact missing Deployment name ("wroker"), which is a spelling mismatch against the real Deployment name ("worker") in `scaleTargetRef.name`.

Trap A: 0 replicas would still mean the Deployment exists — this error means it can't find the Deployment at all. Trap C: if KEDA itself were broken, you wouldn't get this specific, well-formed error. Trap D: the error is about finding the Deployment, not about the trigger.

</details>

---

**Q10. Why isn't KEDA's Prometheus scaler really in competition with the Prometheus Adapter's Custom metrics types?**

- A) They serve completely unrelated use cases with no overlap at all
- B) KEDA only implements `external.metrics.k8s.io`, so it can't provide the native per-pod/per-object averaging that Adapter's Pods/Object types give you — Adapter is the right tool whenever that averaging is needed
- C) KEDA's Prometheus scaler is strictly worse in every scenario
- D) The Prometheus Adapter cannot connect to the same Prometheus instance KEDA uses

<details>
<summary>Answer</summary>

**B** — The real division: Adapter's Custom metrics types provide native Kubernetes-object-aware averaging KEDA cannot replicate (KEDA is External-only, uniformly, for all 50+ scalers). KEDA is the simpler choice specifically for the External use case, where Adapter's `external:` rule type is the (rarely-used) alternative.

Trap A: there is real overlap in the External-metrics case, just not where most people assume. Trap C: KEDA is genuinely better for scale-to-zero and simple external aggregates. Trap D: both can point at the same Prometheus instance — that's not a limitation of either.

</details>

---

**Q11. A ScaledObject's `pollingInterval` is 60 seconds. The Deployment already has 2 running pods and load is increasing. How often does the managed HPA recalculate desired replicas?**

- A) Every 60 seconds, matching `pollingInterval`
- B) On HPA's own independent sync period (~15s by default), unrelated to `pollingInterval`
- C) Only when `keda-operator` explicitly triggers a recalculation
- D) Continuously, with no fixed interval

<details>
<summary>Answer</summary>

**B** — `pollingInterval` only governs `keda-operator`'s own activation poll (Loop 1, the 0↔1 edge). Once at least one pod is running, the ordinary HPA controller (Loop 2) takes over on its own sync period, which has nothing to do with `pollingInterval`.

Trap A: conflates KEDA's two separate polling loops into one. Trap C: `keda-operator` isn't involved in 1→N scaling at all once active. Trap D: HPA still operates on a fixed sync period, not continuously.

</details>

---

**Q12. A Redis trigger has `listLength: "10"` (scaling target) and `activationThreshold: "50"`. The queue currently has 40 items. What replica count does KEDA target?**

- A) 4 replicas — `ceil(40/10)`
- B) 0 replicas — 40 is below `activationThreshold`, so the trigger is not active regardless of the scaling math
- C) 5 replicas — rounds up from the activation threshold
- D) 1 replica — the minimum non-zero value

<details>
<summary>Answer</summary>

**B** — Activation always overrides scaling when they disagree. The scaling math alone would suggest 4 replicas, but since 40 is below the `activationThreshold` of 50, KEDA treats the trigger as inactive and scales to zero regardless.

Trap A: correct scaling-only arithmetic, but ignores that activation gates the whole decision first. Trap C, D: neither reflects how activation vs. scaling actually interact.

</details>

---

**Q13. A ScaledObject is applied targeting a Deployment that already has a manual HPA. Separately, a manual HPA is applied targeting a different Deployment that already has a ScaledObject. Are both conflicts caught the same way?**

- A) Yes — KEDA's admission webhook rejects both at apply time
- B) No — the webhook rejects the new ScaledObject at apply time (it validates against the existing HPA); the manual HPA in the second case isn't a KEDA resource, so it passes the webhook and only surfaces later as `AmbiguousSelector`
- C) No — neither is caught automatically; both require manual detection
- D) Yes — but only the manual HPA case produces an immediate error

<details>
<summary>Answer</summary>

**B** — KEDA's admission webhook validates KEDA-native resources being applied, including against pre-existing conflicting HPAs — so a new ScaledObject targeting an already-HPA'd Deployment is rejected immediately. A manually-created HPA is invisible to that webhook entirely, so it applies successfully when created after the ScaledObject, and only reveals the conflict later via the ScaledObject's `AmbiguousSelector` condition.

Trap A: overstates the webhook's scope — it only validates KEDA resources being applied, not arbitrary resources. Trap C: the ScaledObject-vs-existing-HPA case IS caught automatically. Trap D: inverts which case gets the immediate error.

</details>

---

**Q14. `minReplicaCount: 0` is set in a ScaledObject. What does `kubectl get hpa` show for that ScaledObject's managed HPA's `MINPODS` column?**

- A) 0, matching the ScaledObject exactly
- B) 1 by default — the HPA API rejects `minReplicas: 0` at schema validation unless the alpha `HPAScaleToZero` feature gate is explicitly enabled
- C) It depends on `maxReplicaCount`
- D) The column is blank until the first scaling event

<details>
<summary>Answer</summary>

**B** — HPA's own API validation requires `minReplicas ≥ 1` by default, since its algorithm needs at least one running pod to have any metric to compute against. KEDA's managed HPA respects this unconditionally on a standard cluster — `MINPODS` shows 1 regardless of `minReplicaCount` in the ScaledObject, and `keda-operator` handles the 0↔1 edge itself, outside the HPA entirely. (The `HPAScaleToZero` alpha gate is a real exception that exists, but is off by default on essentially every standard cluster, including this demo's.)

Trap A: this is exactly the mismatch that trips people up — the ScaledObject and the generated HPA genuinely disagree on this field, and that's expected. Trap C, D: neither reflects the actual mechanism.

</details>

---

**Q15. A ScaledObject uses a plain CPU Resource trigger (not Cron, Redis, or another External-metrics trigger) with `minReplicaCount: 0`. Can it reliably scale to zero and back?**

- A) Yes — KEDA handles all trigger types identically for scale-to-zero
- B) No — CPU/memory triggers read from ordinary metrics-server, which has no data at zero replicas, so there's no signal to scale back up from zero
- C) Yes, but only if `activationThreshold` is set
- D) No — CPU/memory triggers are entirely unsupported by KEDA

<details>
<summary>Answer</summary>

**B** — CPU/memory Resource-type triggers bypass `keda-operator-metrics-apiserver` entirely; the managed HPA reads directly from ordinary Kubernetes `metrics-server`, the same source `01-hpa-basic` used. At zero pods there is no CPU/memory data at all, so `keda-operator` has no basis to decide when to reactivate. Reliable scale-to-zero requires an External-metrics trigger.

Trap A: this is precisely the exception — not every trigger type behaves the same way for scale-to-zero. Trap C: `activationThreshold` doesn't fix a missing data source. Trap D: CPU/memory triggers work fine for ordinary 1→N scaling; the limitation is specific to zero.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 15/15 | Import Anki cards, move to next demo |
| 13–14/15 | Review the wrong answers, then proceed |
| 11–12/15 | Re-read the relevant section, retry those questions |
| Below 11/15 | Re-read the full demo and redo the walkthrough before proceeding |
