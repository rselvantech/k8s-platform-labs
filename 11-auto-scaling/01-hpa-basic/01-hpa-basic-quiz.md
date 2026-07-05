# Quiz — 11-auto-scaling/01-hpa-basic: HPA and the Kubernetes Horizontal Scaling Model

> One correct answer per question unless stated otherwise.
> Target: 17/20 or above before moving to 02-hpa-advanced.

**Q1. What does cAdvisor read to collect container CPU and memory usage?**

- A) `/proc/<pid>/stat` for each process in the container
- B) The Linux cgroup filesystem (`/sys/fs/cgroup/`)
- C) The `metrics.k8s.io` API endpoint
- D) The kubelet's internal in-memory cache

<details>
<summary>Answer</summary>

**B** — cAdvisor reads the Linux cgroup filesystem. Each container runtime creates a cgroup hierarchy per container; cAdvisor reads the hierarchy totals to get ALL processes in the container, not just PID 1.

Trap A: `/proc/<pid>/stat` gives per-process view, cannot aggregate across all processes in a container. Trap C: cAdvisor feeds metrics-server, not the other way around. Trap D: no such cache.

</details>

---

**Q2. metrics-server scrapes kubelet every 60 seconds. What does it retain after each scrape?**

- A) The last 5 minutes of samples (rolling window)
- B) The last 15 seconds of samples
- C) Only the most recent sample per pod/container
- D) All samples since metrics-server started, up to 1GB

<details>
<summary>Answer</summary>

**C** — metrics-server retains only the most recent sample. It is not a time-series database. Restarting metrics-server clears all data.

Trap A and B: no rolling window. Trap D: no accumulation.

</details>

---

**Q3. `kubectl top pods` shows a container using 180m CPU. `kubectl get hpa` shows `<unknown>/50%` after 90 seconds. What is the most likely cause?**

- A) metrics-server is not running
- B) The HPA controller sync period has not elapsed yet
- C) `resources.requests.cpu` is not set on the container
- D) The Deployment has 0 replicas

<details>
<summary>Answer</summary>

**C** — `<unknown>` after 90 seconds is permanent — transient `<unknown>` resolves within 60s. `kubectl top` working confirms metrics-server is running and cAdvisor is producing data. Missing `resources.requests.cpu` means the HPA formula denominator is undefined.

Trap A: kubectl top working proves metrics-server is up. Trap B: 90 seconds is well past the 60s scrape cycle. Trap D: 0 replicas would show 0 pods in kubectl get pods, and REPLICAS: 0 in kubectl get hpa.

</details>

---

**Q4. A Deployment has 2 replicas. HPA target is CPU 50%. Current average CPU is 140%. What does HPA scale to?**

- A) 4 — ceil[2 × (140/50)] = ceil[5.6] = 6... wait that's 6
- B) 3 — ceil[2 × (140/100)] = ceil[2.8] = 3
- C) 6 — ceil[2 × (140/50)] = ceil[5.6] = 6
- D) 5 — ceil[2 × (140/50)] = 5.6, rounded down

<details>
<summary>Answer</summary>

**C** — `ceil[2 × (140/50)] = ceil[5.6] = 6`. The formula always uses `ceil()` (ceiling, rounds up).

Trap B: uses 100 as the denominator — the target is 50%, not 100%. Trap D: the formula uses ceiling, not floor or round.

</details>

---

**Q5. HPA tolerance is 10%. Target is 50%. Current CPU is 53%. Does HPA scale up?**

- A) Yes — 53% > 50%, HPA scales up
- B) No — 53/50 = 1.06, within the 10% tolerance band, no scaling
- C) No — HPA only scales up if CPU exceeds 100%
- D) Yes — tolerance only applies to scale-down

<details>
<summary>Answer</summary>

**B** — ratio = 53/50 = 1.06. The tolerance band is ±10% around 1.0, so ratios between 0.9 and 1.1 do not trigger scaling. 1.06 is within that band.

Trap A: crossing the target does not automatically trigger scaling — must be outside the tolerance. Trap C: no such rule. Trap D: tolerance applies to both scale-up and scale-down.

</details>

---

**Q6. HPA has two metrics: CPU at 115% (target 50%) and memory at 8% (target 70%). How many replicas does HPA target from a starting point of 1?**

- A) 1 — memory is below target, so no scaling
- B) 3 — CPU says ceil[1×(115/50)]=3, memory says ceil[1×(8/70)]=1, MAX=3
- C) 2 — average of 3 and 1
- D) 4 — CPU + memory combined

<details>
<summary>Answer</summary>

**B** — HPA evaluates each metric independently and takes the MAX. CPU: ceil[1×(115/50)] = ceil[2.3] = 3. Memory: ceil[1×(8/70)] = ceil[0.11] = 1. MAX(3,1) = 3.

Trap A: the MAX rule means one metric exceeding target is sufficient. Trap C: metrics are not averaged. Trap D: metrics are not summed.

</details>

---

**Q7. What is the scale subresource, and what does HPA write to it?**

- A) A separate object in etcd that stores the Deployment's YAML
- B) A sub-path on the Deployment's API endpoint that contains only the replica count; HPA writes the desired replica count here
- C) A Kubernetes Event that records the scaling decision
- D) The `/metrics/resource` endpoint on the kubelet

<details>
<summary>Answer</summary>

**B** — the scale subresource is at `.../deployments/<name>/scale` and contains only replica count and selector. HPA writes the desired replica count to it; the Deployment controller then reconciles. HPA never modifies the full Deployment spec.

Trap A: no separate etcd object for scale. Trap C: Events are read-only audit records. Trap D: that is a kubelet endpoint, not part of the HPA pipeline.

</details>

---

**Q8. Why does HPA NOT use the Eviction API for scale-down?**

- A) The Eviction API does not exist in autoscaling/v2
- B) HPA was designed before the Eviction API matured; it uses direct DELETE for speed
- C) The Eviction API only works for nodes, not pods
- D) Using the Eviction API would prevent HPA from scaling below minReplicas

<details>
<summary>Answer</summary>

**B** — this is a known design decision/limitation: HPA predates the Eviction API and uses direct pod DELETE via the scale subresource. This means PDB is not respected during HPA scale-down.

Trap A: the Eviction API exists and works for pods. Trap C: the Eviction API applies to pods. Trap D: minReplicas is enforced separately, unrelated to which deletion mechanism is used.

</details>

---

**Q9. `kubectl describe hpa` shows `ScalingActive: False, FailedGetScale`. What is the correct first action?**

- A) Check if the HPA is in the default scale-down stabilisation window
- B) Check if the metric pipeline is working — metrics-server running and resources.requests set
- C) Raise maxReplicas — the HPA has hit its ceiling
- D) Delete and recreate the HPA

<details>
<summary>Answer</summary>

**B** — `ScalingActive: False` means the HPA cannot compute replicas at all. Fix the metric source first. `AbleToScale: False` (not ScalingActive) indicates cooldown. `ScalingLimited: True, TooManyReplicas` indicates hitting maxReplicas.

Trap A: that describes AbleToScale False, BackoffDownscale. Trap C: ScalingLimited True TooManyReplicas would show that. Trap D: recreating the HPA does not fix the metric problem.

</details>

---

**Q10. What does the default `scaleDown.stabilizationWindowSeconds: 300` prevent?**

- A) HPA from scaling up too fast after a brief quiet period
- B) HPA from removing pods immediately after a short load drop, preventing thrashing
- C) HPA from scaling to maxReplicas in a single step
- D) The Deployment from going below minReplicas

<details>
<summary>Answer</summary>

**B** — the stabilisation window records all scale-down recommendations over 5 minutes and only scales to the highest (least aggressive) recommendation seen. If load spikes again within the window, the scale-down is deferred. This prevents removing pods only to immediately add them back.

Trap A: the stabilisation window is for scale-DOWN, not scale-UP. Scale-up default window is 0 (immediate). Trap C: that is the job of behavior policies (Pods, Percent). Trap D: minReplicas is a hard floor independent of the stabilisation window.

</details>

---

**Q11. Two HPAs target the same Deployment. What happens?**

- A) The HPA with lower minReplicas takes precedence
- B) The HPA created first takes precedence
- C) Both HPAs stop working — AmbiguousSelector conflict
- D) The Deployment scales to the average of both HPAs' desired replica counts

<details>
<summary>Answer</summary>

**C** — the HPA controller cannot determine which HPA is authoritative and refuses to act on either. Both report FailedGetScale with AmbiguousSelector. The Deployment replica count freezes.

Traps A, B, D: no precedence or averaging — the conflict breaks both HPAs.

</details>

---

**Q12. `behavior.scaleDown.selectPolicy: Disabled` is set. After load drops to zero, what happens over the next 30 minutes?**

- A) HPA scales down normally but slowly
- B) HPA scales down after the stabilisationWindowSeconds elapses
- C) HPA never scales down — Disabled blocks all scale-down regardless of metric
- D) HPA scales down to minReplicas only

<details>
<summary>Answer</summary>

**C** — `Disabled` overrides all policies; the policies list is completely ignored. This is intentional behaviour for incident management, but is a common misconfiguration when copy-pasted.

Trap A, B, D: Disabled has no exceptions — it blocks all scale-down in that block.

</details>

---

**Q13. `kubectl autoscale deployment nginx --min=1 --max=5 --cpu=50%` creates which API version internally?**

- A) autoscaling/v1
- B) autoscaling/v2beta1
- C) autoscaling/v2
- D) autoscaling/v3

<details>
<summary>Answer</summary>

**C** — `kubectl autoscale` creates `autoscaling/v2` internally, even with the v1-style `--cpu=50%` flag. Verify with `kubectl get hpa nginx -o yaml | grep apiVersion`.

Trap A: v1 is stored as v2 internally. Trap B: v2beta1 is deprecated. Trap D: does not exist.

</details>

---

**Q14. What is the correct `kubectl autoscale` flag for CPU (not deprecated)?**

- A) `--cpu-percent=50`
- B) `--cpu=50%`
- C) `--target-cpu=50`
- D) `--averageUtilization=50`

<details>
<summary>Answer</summary>

**B** — `--cpu=50%` is the current form. `--cpu-percent` is deprecated.

Traps A, C, D: not the current standard form.

</details>

---

**Q15. A pod has `resources.requests.cpu: 200m`. `kubectl top` shows 180m CPU usage. What utilisation% does HPA calculate?**

- A) 180% — usage/limit × 100
- B) 90% — 180/200 × 100
- C) 36% — 180/500 × 100 (using the limit)
- D) Cannot calculate — usage exceeds limit

<details>
<summary>Answer</summary>

**B** — HPA `type: Utilization` computes `usage / request × 100` = 180/200 × 100 = 90%. It uses the request, not the limit.

Trap A: would require dividing by limit (100m) — wrong denominator. Trap C: uses limits not requests. Trap D: 180m is below the 200m request, well within limits.

</details>

---

**Q16. `kubectl describe hpa` shows `AbleToScale: False, BackoffDownscale`. What does this mean?**

- A) The metric pipeline is broken — check metrics-server
- B) HPA recently scaled down and is in the scale-down stabilisation window — normal expected behaviour
- C) HPA is blocked because the Deployment is at minReplicas
- D) A PodDisruptionBudget is preventing scale-down

<details>
<summary>Answer</summary>

**B** — BackoffDownscale means HPA computed a scale-down recommendation but is in the stabilisation window (still recording recommendations to take the highest). This is normal expected behaviour after a load drop — not an error.

Trap A: that is `ScalingActive: False`. Trap C: that is `ScalingLimited: True, TooFewReplicas`. Trap D: HPA does not consult PDB.

</details>

---

**Q17. Which HPA metric types require a metrics adapter beyond metrics-server?**

- A) Resource and ContainerResource
- B) Pods, Object, and External
- C) All five metric types
- D) Only External

<details>
<summary>Answer</summary>

**B** — Pods (custom.metrics.k8s.io), Object (custom.metrics.k8s.io), and External (external.metrics.k8s.io) all require a metrics adapter. Resource and ContainerResource are served by metrics-server alone.

Trap A: those two work with metrics-server. Trap C: not all five. Trap D: External is one, but Pods and Object also need an adapter.

</details>

---

**Q18. What is the difference between HPA `type: Utilization` and `type: AverageValue` for CPU?**

- A) Utilization is for CPU only; AverageValue is for memory only
- B) Utilization expresses the target as a percentage of resources.requests; AverageValue expresses it as a raw quantity (millicores, bytes)
- C) AverageValue averages across all nodes; Utilization averages across all pods
- D) They are interchangeable — same formula, different field names

<details>
<summary>Answer</summary>

**B** — Utilization: `averageUtilization: 50` means 50% of the cpu request. Requires requests to be set. AverageValue: `averageValue: "50m"` means 50 millicores raw; `averageValue: "50"` means 50 nanocores (almost certainly wrong for CPU targets).

Trap A: both work for CPU and memory. Trap C: both average across pods of the target. Trap D: different formulas — Utilization divides usage by request; AverageValue compares usage directly.

</details>

---

**Q19. (CKA-style) You run `kubectl get hpa nginx-hpa -w` and observe REPLICAS going 1→3→1→3 every 5 minutes with no traffic changes. What is the most likely cause, and how do you fix it?**

- A) The HPA has two conflicting metrics — remove one
- B) `scaleDown.stabilizationWindowSeconds: 0` is set — raise it to 300 or higher
- C) AmbiguousSelector — delete the duplicate HPA
- D) maxReplicas is set too low — raise it

<details>
<summary>Answer</summary>

**B** — oscillation between 3 and 1 every 5 minutes with no traffic change is the classic symptom of `stabilizationWindowSeconds: 0` on scaleDown. The metric briefly dips below target after scale-out, immediately triggering scale-in, then load returns and triggers scale-out again. The 5-minute default window prevents this by waiting to confirm the load has genuinely dropped.

Trap A: conflicting metrics would show `<unknown>` or AmbiguousSelector, not oscillation. Trap C: AmbiguousSelector freezes both HPAs. Trap D: hitting maxReplicas would show ScalingLimited True.

</details>

---

**Q20. (CKA-style) `kubectl describe hpa` shows `ScalingLimited: True, TooManyReplicas`. Deployment has 10 replicas. Is this an error?**

- A) Yes — HPA should never hit maxReplicas; increase resources
- B) No — this is expected when demand exceeds what maxReplicas can handle; raise maxReplicas if more scale is genuinely needed
- C) Yes — it means minReplicas and maxReplicas are equal
- D) No — it means HPA is paused by the operator

<details>
<summary>Answer</summary>

**B** — `TooManyReplicas` means HPA wants to scale beyond maxReplicas but cannot because of the configured ceiling. This is expected behaviour. If the load genuinely requires more pods, raise `maxReplicas`. If the cap is intentional (cost or capacity limit), the Deployment will stay at maxReplicas under load.

Trap A: this is not an error — it is expected functioning. Trap C: ScalingLimited TooFewReplicas would indicate minReplicas constraint. Trap D: no such pause mechanism in HPA.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 20/20 | Import Anki cards, move to next Demo |
| 18–19/20 | Review the wrong answers, then proceed |
| 17/20 | Re-read relevant Concepts sections, retry those questions |
| Below 17/20 | Re-read the full lab and redo the walkthrough before proceeding |
