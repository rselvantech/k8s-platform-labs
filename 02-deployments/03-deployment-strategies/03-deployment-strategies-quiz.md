# Quiz — 02-deployments/03-deployment-strategies: Deployment Strategies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Neither `RollingUpdate` nor `Recreate` can express "send exactly 10% of traffic to a new version." Why not, structurally?**

- A) Kubernetes simply hasn't implemented that feature yet for `spec.strategy`
- B) Both operate entirely within a single Deployment's own reconciliation loop — there's no partial-traffic concept anywhere below the whole-Deployment level
- C) Only Services support percentages, and Deployments never touch Services
- D) `maxSurge` already is a traffic percentage, it's just named confusingly

<details>
<summary>Answer</summary>

**B** — Both native strategies replace Pods within one Deployment; neither one has any concept of routing a portion of *requests* anywhere. That's exactly the ceiling Blue-Green and Canary solve by moving control to a Service's selector instead.
Trap: D confuses a *Pod-count* knob (`maxSurge`) with a *traffic-routing* knob — they aren't the same kind of percentage at all.

</details>

---

**Q2. `kubectl port-forward deployment/nginx-green 8080:5678` is used to test Green before switching traffic. Does this go through the Service at all?**

- A) Yes — it forwards through the Service, so it's a true production-traffic test
- B) No — it connects directly to a Green Pod, completely bypassing the Service and its selector
- C) Only if the Service selector already includes `version: green`
- D) It depends on the Service's `type`

<details>
<summary>Answer</summary>

**B** — Port-forward talks straight to a Pod. That's exactly why it's safe to run before Step 7's switch — it can't accidentally expose real users to an unverified version, since it never touches the Service's Endpoints at all.
Trap: C imagines port-forward's behavior depends on the Service's current selector — it doesn't, since it never consults the Service in the first place.

</details>

---

**Q3. Neither Blue-Green YAML in this demo sets `spec.strategy` at all, yet `kubectl describe deployment nginx-blue` shows `RollingUpdateStrategy: 25% max unavailable, 25% max surge`. Why?**

- A) Blue-Green deployments always hardcode 25%/25%, regardless of the YAML
- B) These are RollingUpdate's ordinary API-server defaults, applying here for the same reason they'd apply to any Deployment that doesn't set `spec.strategy`
- C) minikube sets this value at cluster install time
- D) The Service overrides the Deployment's strategy once it selects `version: blue`

<details>
<summary>Answer</summary>

**B** — Same defaulting behavior covered for any ordinary Deployment — nothing about running inside a Blue-Green *pattern* changes it. It only becomes relevant if you ever update `nginx-blue`/`nginx-green` directly (not the Blue-Green switch itself), since that would briefly allow a Pod or two unavailable.
Trap: D invents a Service-to-Deployment override mechanism that doesn't exist — a Service's selector has no influence over how a Deployment reconciles its own Pods.

</details>

---

**Q4. After switching traffic from Blue to Green, the Service object's own `AGE` in `kubectl get svc` is unchanged from before the switch. What does that confirm?**

- A) The switch didn't actually take effect yet
- B) Switching traffic never recreates the Service — it only recomputes which Pods currently qualify as Endpoints
- C) `AGE` only updates when `spec.type` changes
- D) The Service was cached and needs a manual refresh

<details>
<summary>Answer</summary>

**B** — Compare the Endpoints IP list before and after the switch: every IP changes, but the Service object itself — including its `AGE` — never does. That's direct evidence the mechanism is "recompute Endpoints," not "delete and recreate the Service."
Trap: A assumes an unchanged `AGE` means nothing happened, when the actual change (the Endpoints list) is a different field entirely.

</details>

---

**Q5. `kubectl expose deployment nginx-blue --port=80 --target-port=5678` derives its selector automatically from the Deployment it targets. Why doesn't this work well for Blue-Green or Canary's own Service?**

- A) `kubectl expose` doesn't support `NodePort` type
- B) It would copy the full Deployment selector (including `version`/`track`), when Blue-Green needs a selector matching only one version and Canary needs one deliberately omitting the differentiating label
- C) `kubectl expose` can only target Services, not Deployments
- D) It requires the Deployment to already have a Service attached

<details>
<summary>Answer</summary>

**B** — Both patterns need a Service selector shaped differently from either Deployment's own selector — Blue-Green needs to target exactly one `version` value at a time, Canary needs to omit `track` entirely so it matches both Deployments at once. `kubectl expose`'s auto-derived selector can't express either shape reliably, which is why this demo hand-writes the Service YAML instead.
Trap: A is a real `kubectl expose` limitation in general, but it isn't the reason this pattern specifically avoids it.

</details>

---

**Q6. What does `hashicorp/http-echo` actually do that a plain `nginx` image doesn't, and why does that matter for this specific demo?**

- A) It's faster to pull, which is the only reason it's used
- B) It responds to every request with a fixed text string you set yourself, which is what lets `curl` prove which version actually answered — a plain `nginx` page looks identical regardless of version
- C) It automatically load-balances between Blue and Green
- D) It requires no `ports` field, simplifying the YAML

<details>
<summary>Answer</summary>

**B** — The whole point of switching this demo's images was to make Step 4/8's `curl` output *itself* the evidence of which version is live, instead of an unfalsifiable generic welcome page.
Trap: C invents a routing capability that has nothing to do with what `http-echo` actually is — it's a trivial echo server, not a proxy.

</details>

---

**Q7. A Service is described as "not a running process." What is it actually, mechanically?**

- A) A background pod that proxies all traffic
- B) A stable network identity (ClusterIP/DNS name) plus a continuously-recomputed list of matching, Ready Pod IPs (Endpoints)
- C) A DNS entry only, with no IP of its own
- D) A special kind of ReplicaSet

<details>
<summary>Answer</summary>

**B** — There's no process to restart or crash — a Service is bookkeeping plus a live selector query, which is exactly why editing its selector has no Pod-level side effects of its own.
Trap: D confuses a Service with a workload controller — a Service manages nothing about Pod lifecycle, only which existing Pods currently qualify as Endpoints.

</details>

---

**Q8. Once confident in Canary at 100%, the demo deletes `nginx-stable` and mentions relabeling `nginx-canary`'s own `metadata.labels`. Besides that relabel not touching Pods, what's the actual honest way to get a Deployment genuinely named/labeled `nginx-stable` going forward?**

- A) Wait for the next scheduled rollout, which will rename it automatically
- B) Either keep running under the current name (`nginx-canary`) as the new baseline and update your own tooling/docs accordingly, or delete-and-recreate a proper `nginx-stable` Deployment with the new image
- C) `kubectl rename deployment nginx-canary nginx-stable`
- D) Patch `spec.selector` directly to say `track: stable`

<details>
<summary>Answer</summary>

**B** — There's no shortcut here — a Deployment's name and its `spec.selector`/`spec.template.metadata.labels` are all effectively fixed once created (name entirely, selector by the immutability rule from `01-basic-deployment`), so genuine renaming means either living with the current name or a real delete-and-recreate.
Trap: C invents a command that doesn't exist — `kubectl` has no rename operation for any object; identity is fixed at creation.

</details>

---

**Q9. Both Blue-Green and Canary in this demo were built with full hand-written YAML rather than imperative commands. What specifically makes the imperative route (`kubectl create deployment` + `kubectl expose`) awkward here, beyond just being "more typing"?**

- A) Imperative commands can't set `replicas`
- B) `-text`/`args`, container port, and a precisely-shaped Service selector (partial match for Canary, single-version match for Blue-Green) all need to align exactly, and imperative flags don't cleanly express all of them together
- C) Imperative commands don't support the `apps/v1` API group
- D) `kubectl create deployment` doesn't support `NodePort` Services at all

<details>
<summary>Answer</summary>

**B** — It's not that any single imperative command is broken — it's that several fields (container args, ports, and a deliberately-shaped selector) all have to agree precisely, which is fiddlier to guarantee with flags than with one reviewable YAML file.
Trap: A and D both invent hard limitations that don't actually exist — the real friction is precision across several fields at once, not a missing feature.

</details>

---

**Q10. Blue-Green requires running two full-sized environments simultaneously. Structurally, why can't Canary's approach (adjusting replica counts on two Deployments sharing one broad Service selector) work for an instant, all-at-once switch the way Blue-Green does?**

- A) It could — Canary and Blue-Green are functionally identical patterns
- B) Canary's Service selector matches both Deployments at once by design, so traffic share is only ever adjustable gradually via relative pod counts — there's no single selector edit that flips 100% of traffic from one to the other instantly
- C) Canary Deployments are hardcoded to a maximum of 4 replicas
- D) Blue-Green doesn't actually support instant switching either

<details>
<summary>Answer</summary>

**B** — Blue-Green's instant switch works because its selector matches *exactly one* version at a time — flipping one label value moves 100% of traffic at once. Canary's selector deliberately matches *both* versions simultaneously, so its only lever is the relative pod-count ratio, which is inherently gradual, not an instant single-edit switch.
Trap: A collapses two patterns that this entire demo treats as structurally distinct — same underlying Endpoints mechanism, opposite selector shape, and therefore opposite switch behavior.

</details>

Score guide:

| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next Demo |
| 7-8/10 | Review the wrong answer(s), then proceed |
| 6/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
