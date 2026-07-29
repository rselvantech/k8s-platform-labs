# Quiz — 03-services/06-loadbalancer-traffic-policies: LoadBalancer and Traffic Policies

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. Step 1 deliberately uses `nginx`, not `hashicorp/http-echo` (used throughout every earlier demo in this chapter). Why the switch here specifically?**

- A) `http-echo` can't run on multiple replicas
- B) nginx's official image logs its access log to stdout in the standard `combined` format, whose first field is the client's real source IP — exactly the signal this demo's `externalTrafficPolicy` tests need
- C) nginx is required for `minikube tunnel` to work at all
- D) `http-echo` doesn't support port 80

<details>
<summary>Answer</summary>

**B** — This demo's whole point is observing *which* source IP a pod actually sees, and nginx's access log gives that for free via `kubectl logs`, with no extra tooling — that's the specific reason for the switch, not a general nginx-vs-http-echo preference.
Trap: C invents a `minikube tunnel` dependency on the specific backend image, which has nothing to do with how the tunnel actually works.

</details>

---

**Q2. Step 2's `kubectl get svc backend-lb` shows a populated `PORT(S)` column (`80:3xxxx/TCP`) even while `EXTERNAL-IP` is still `<pending>`. What does this confirm about LoadBalancer provisioning order?**

- A) The NodePort and ClusterIP layers are already fully provisioned immediately — only the external IP allocation is what's pending
- B) Nothing is actually created until `EXTERNAL-IP` resolves
- C) The NodePort shown is a placeholder that changes once `EXTERNAL-IP` populates
- D) This is a display bug specific to minikube

<details>
<summary>Answer</summary>

**A** — This is the nesting ladder from Concepts made directly visible — ClusterIP and NodePort exist the instant the Service is created, exactly like any NodePort Service; only the top rung (a real external IP) waits on something to provision it.
Trap: C imagines the NodePort value is provisional and will change later — it's assigned once and stays fixed, same as any other NodePort Service.

</details>

---

**Q3. Prerequisites flags that `minikube tunnel` is unreliable specifically on Linux with the Docker driver. What does this demo say you should do about Steps 3 onward if you're on that setup?**

- A) Skip the entire demo
- B) Nothing changes for Steps 3 onward — only Step 2's `EXTERNAL-IP` expectation is affected; every other step uses NodePort directly, unaffected by driver
- C) Switch to a cloud cluster before continuing
- D) Manually edit the Service's `status.loadBalancer` field

<details>
<summary>Answer</summary>

**B** — This is stated explicitly in Prerequisites: nothing else in the demo depends on the tunnel working, since every other step accesses the backend via plain NodePort.
Trap: A drastically overreacts to a limitation the demo itself frames as narrowly scoped to one step.

</details>

---

**Q4. Concepts describes `ClientIP` affinity pinning "all of them" to the same pod when many real users share one source IP (e.g. behind corporate NAT). What's the practical consequence of this specific limitation?**

- A) None — affinity always distributes load evenly regardless
- B) Load can concentrate unevenly onto one pod, since an entire NAT'd population of users is treated as a single client for affinity purposes
- C) The Service automatically detects NAT and disables affinity
- D) Requests from a shared IP are rejected outright

<details>
<summary>Answer</summary>

**B** — Affinity is purely IP-based, so it has no way to distinguish individual real users behind the same NAT'd address — they all get pinned together, which can genuinely skew load onto one pod.
Trap: C invents automatic NAT detection that doesn't exist — affinity has no visibility into what's actually behind a given source IP.

</details>

---

**Q5. Step 6 checks `internalTrafficPolicy` on a Service whose YAML never set it. What value does it show, and what does that confirm?**

- A) `Local` — because `sessionAffinity: ClientIP` implies local-only routing
- B) `Cluster` — the same API-server-defaulting behavior already seen for unset fields elsewhere in this series (e.g. Deployment's `spec.strategy`)
- C) An empty string, since the field was never set
- D) It errors, since `internalTrafficPolicy` has no default

<details>
<summary>Answer</summary>

**B** — This demo explicitly draws the parallel to `02-deployments/01-basic-deployment`'s `spec.strategy` defaulting — an unset field doesn't mean "no value," it means "the API server's default value," visible the moment you query it.
Trap: A invents a dependency between `sessionAffinity` and `internalTrafficPolicy` that doesn't exist — they're independent fields with independent defaults.

</details>

---

**Q6. The Quick Commands Reference notes that `externalTrafficPolicy` and `sessionAffinity` aren't settable via `kubectl expose`'s flags. What's the actual workaround this demo uses throughout for fields like these?**

- A) `kubectl patch` after creation, every time
- B) `kubectl expose ... --dry-run=client -o yaml`, redirected to a file, then edited before `kubectl apply`
- C) These fields can only ever be set by directly editing the live object with `kubectl edit`
- D) A separate `kubectl set trafficpolicy` subcommand

<details>
<summary>Answer</summary>

**B** — This is the same dry-run-then-edit technique used consistently across this entire series for any field an imperative command's flags don't expose — generate the skeleton, then add what's missing by hand.
Trap: D invents a subcommand that doesn't exist in kubectl at all.

</details>

---

**Q7. Step 4 curls a node both with and without a local backend pod under `Local` policy. What does the successful case's nginx log actually confirm, beyond just "the request succeeded"?**

- A) That the request went through the ClusterIP first
- B) That the source IP nginx logged is the real client's own IP, not a node's — direct proof `Local` policy avoided the SNAT step `Cluster` policy requires
- C) That `healthCheckNodePort` was actively used to route this specific request
- D) That the backend pod is running on the control-plane node

<details>
<summary>Answer</summary>

**B** — The whole comparison in Steps 3–4 hinges on what IP shows up in the log — the successful `Local` case logging your actual source IP (vs. a node IP under `Cluster`) is the concrete evidence, not just a bare "200 OK."
Trap: C assumes `healthCheckNodePort` is actively involved in routing an individual request — it's a signal for an *external* load balancer's own routing decisions, not something minikube's plain `curl` test exercises directly.

</details>

---

**Q8. Break-Fix Error-2's scenario looks like a `Local`-policy timeout but is actually a selector problem. What single command does this demo point to as the fastest way to tell the two apart?**

- A) `kubectl describe node`
- B) `kubectl get endpointslices` — an empty result means no pods exist anywhere for this Service at all, ruling out `Local` policy's designed trade-off as the explanation
- C) `kubectl get healthcheckports`
- D) `minikube tunnel --status`

<details>
<summary>Answer</summary>

**B** — This is the same first-diagnostic-step habit established back in `01-clusterip-nodeport` — checking Endpoints/EndpointSlices immediately separates "no pods matched at all" from any traffic-policy-specific behavior.
Trap: C invents a command that doesn't exist — there's no dedicated CLI surface for inspecting health-check ports directly.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, chapter complete |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
