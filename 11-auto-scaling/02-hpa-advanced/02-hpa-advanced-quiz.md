# Quiz — 11-auto-scaling/02-hpa-advanced: HPA Advanced — ContainerResource, Percent Behavior, and the Custom/External Metrics Pipeline

> One correct answer per question unless stated otherwise.
> Target: 7/8 or above before moving to 03-vpa-fundamentals.

**Q1. You have a 2-container pod (`app` + `sidecar`) and apply an HPA with `type: Resource` targeting CPU. The `sidecar` starts consuming significant CPU. What is the risk?**

- A) None — sidecar containers are excluded from Resource-type metrics automatically
- B) The HPA may scale the Deployment based on the sidecar's load, not just app's load
- C) The HPA fails with a MultipleContainers error
- D) Resource type can only be used on single-container pods

<details>
<summary>Answer</summary>

**B** — Resource type sums CPU across ALL containers vs the sum of their requests; a noisy sidecar can drive scaling unrelated to application load. Use ContainerResource to isolate one container.

Trap A: no automatic exclusion — sidecars are included. Trap C: no such error exists. Trap D: Resource works on multi-container pods, just averaged across all containers.

</details>

---

**Q2. You want an HPA to scale based ONLY on the `app` container's CPU in a 2-container pod. Which `metrics[]` entry is correct?**

- A) {type: Resource, resource: {name: cpu, container: app, target: {...}}}
- B) {type: ContainerResource, containerResource: {name: cpu, container: app, target: {...}}}
- C) {type: Pods, pods: {metric: {name: app_cpu}, target: {...}}}
- D) {type: Resource, resource: {name: cpu, target: {...}}, selector: {matchLabels: {container: app}}}

<details>
<summary>Answer</summary>

**B** — ContainerResource is the dedicated type for targeting a single named container's CPU/memory.

Trap A: Resource has no container field — always covers the whole pod. Trap C: Pods is for custom application metrics via an adapter. Trap D: resource blocks have no selector field for filtering containers.

</details>

---

**Q3. An HPA's `behavior.scaleUp` has `{policies: [{type: Percent, value: 100, periodSeconds: 30}], stabilizationWindowSeconds: 0}`. Starting at 1 replica, the metric immediately justifies 8 replicas. After the first 30-second evaluation, what is the replica count?**

- A) 8 — Percent policies do not limit the jump to the formula's desired value
- B) 1 — value: 100 means scale-up is disabled
- C) 2 — the step is capped at 100% of the current replica count
- D) 0 — Percent requires minReplicas: 0 to function

<details>
<summary>Answer</summary>

**C** — Percent caps the step at 100% of the CURRENT count: 100% of 1 = +1, so 1->2. Reaching 8 takes multiple 30-second windows.

Trap A: the policy is a rate limiter, not a pass-through. Trap B: value: 100 means can double, not disabled. Trap D: Percent has no relationship to minReplicas: 0.

</details>

---

**Q4. 01-hpa-basic's scaleUp policy was `{type: Pods, value: 4, periodSeconds: 15}`. This lab's is `{type: Percent, value: 100, periodSeconds: 30}`. Starting from 10 replicas with sustained high demand, which adds more replicas in the first 30 seconds?**

- A) The Pods policy — up to 8 replicas (4 per 15s x 2 windows) vs Percent's +10
- B) The Percent policy — up to 10 replicas (100% of 10) vs Pods' +8
- C) They are identical — both capped at 4 replicas per evaluation
- D) Neither — periodSeconds must match to compare them

<details>
<summary>Answer</summary>

**B** — at 10 replicas, Percent value: 100 allows +10 (doubling) within 30s; Pods allows at most 4+4=8 over two 15s windows. Percent scales faster at larger replica counts.

Trap A: Pods arithmetic is correct but the conclusion is wrong. Trap C: the types use different units. Trap D: wall-clock outcomes can be compared without matching periodSeconds.

</details>

---

**Q5. A 2-container pod has `app` with `resources.requests.cpu: 100m` and `sidecar` with no `resources.requests` block. An HPA with `type: Resource` targeting cpu is applied. What does `kubectl describe hpa` show for the CPU metric?**

- A) The utilisation of app only, since it is the only container with a request
- B) unknown for the whole pod's CPU metric
- C) 0%, since the missing request is treated as zero
- D) The HPA fails to create with a validation error

<details>
<summary>Answer</summary>

**B** — for Resource-type HPA, ALL containers must have a request for the measured resource. If any is missing, the entire pod-level metric is unknown.

Trap A: no per-container fallback for Resource type. Trap C: missing request is not treated as 0m. Trap D: HPA creation succeeds, but the metric stays unknown.

</details>

---

**Q6. Which statement correctly distinguishes the `Pods` and `Object` HPA metric types?**

- A) Pods reads from metrics-server; Object reads from the Custom Metrics API
- B) Pods averages a custom metric across all pods of the target; Object reads a single metric from one specific Kubernetes object
- C) Object is for CPU/memory; Pods is for everything else
- D) They are interchangeable — both compute the same value with different syntax

<details>
<summary>Answer</summary>

**B** — Pods divides total per-pod demand by a per-pod target (averaged); Object compares one value from a named object directly against a target — no per-pod averaging.

Trap A: BOTH read from custom.metrics.k8s.io — metrics-server serves neither. Trap C: neither type is for CPU/memory. Trap D: averaging behaviour differs significantly.

</details>

---

**Q7. Your team wants to scale a worker Deployment based on the depth of an AWS SQS queue. Which combination is correct?**

- A) type: Resource, since SQS depth is a resource metric
- B) type: External, reading from external.metrics.k8s.io, exposed via a metrics adapter
- C) type: Object, since SQS is a Kubernetes object
- D) metrics-server alone, once kubectl top is enabled

<details>
<summary>Answer</summary>

**B** — SQS queue depth has no associated Kubernetes object and is not CPU/memory, so it is an External metric served via external.metrics.k8s.io by an adapter (CloudWatch-based adapter or KEDA).

Trap A: Resource is strictly CPU/memory from metrics-server. Trap C: SQS queues are not Kubernetes objects. Trap D: metrics-server never serves external/custom metrics.

</details>

---

**Q8. (CKA-style) A Deployment's pods each run a single container. You want to scale based on that container's memory usage and metrics-server is running. Which metric type requires the LEAST additional setup?**

- A) External, since it is the most flexible
- B) Object, targeting the Deployment itself
- C) Resource, with name: memory
- D) Pods, with a custom memory metric

<details>
<summary>Answer</summary>

**C** — for a single-container pod, Resource with name: memory works directly off metrics-server with zero extra components.

Trap A: External requires an adapter. Trap B: Object targeting the Deployment is not how memory-per-pod scaling works. Trap D: Pods requires a custom metrics adapter — unnecessary when metrics-server already provides memory data.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read relevant section, retry those questions |
| Below 6/8 | Re-read full lab and redo walkthrough before proceeding |
