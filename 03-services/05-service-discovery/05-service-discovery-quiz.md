# Quiz — 03-services/05-service-discovery: Service Discovery and CoreDNS

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.

**Q1. What does `ndots:5` actually control?**

- A) The maximum number of DNS servers a pod can use
- B) Whether search domains are tried before querying a name as-is
- C) How many times a failed DNS query is retried
- D) The TTL for cached DNS responses

<details>
<summary>Answer</summary>

**B** — Names with fewer dots than the `ndots` value get search domains tried first; names with more are queried directly.
Trap: D confuses this with the CoreDNS `cache` plugin's TTL setting, a completely separate mechanism.

</details>

---

**Q2. A pod in `app-a` tries `curl db-svc` where `db-svc` actually lives in `app-b`. What happens?**

- A) It resolves fine — DNS is cluster-wide by default
- B) It fails — the pod's search domains only include its own namespace
- C) It resolves, but connects to the wrong service
- D) It works only if both namespaces share a NetworkPolicy

<details>
<summary>Answer</summary>

**B** — Cross-namespace access requires at least `db-svc.app-b` — the bare short name never even generates a query CoreDNS could match against the other namespace.
Trap: A assumes namespace-agnostic short-name resolution, which contradicts the entire search-domain mechanism.

</details>

---

**Q3. Does the CoreDNS `reload` plugin validate a new Corefile before applying it?**

- A) Yes, always, rejecting invalid syntax safely
- B) No — an invalid Corefile causes CoreDNS to crash on reload
- C) Only in production clusters
- D) Only if the `errors` plugin is also enabled

<details>
<summary>Answer</summary>

**B** — This is a real operational risk: editing the `coredns` ConfigMap with a syntax error doesn't get rejected, it crashes the running CoreDNS pods.
Trap: A assumes safe validation exists, which would prevent exactly the kind of outage this demo's Break-Fix Error-2 demonstrates.

</details>

---

**Q4. Are Kubernetes service environment variables always up to date?**

- A) Yes, they update live as Services change
- B) No — only injected for Services that existed before the pod started
- C) Only ClusterIP services get environment variables
- D) They update every 30 seconds via the cache plugin

<details>
<summary>Answer</summary>

**B** — A Service created after a pod starts is completely invisible to that pod's environment — this staleness is exactly why DNS is the preferred discovery method.
Trap: D invents a periodic refresh mechanism that doesn't exist for environment variables at all.

</details>

---

**Q5. Is `dnsPolicy: Default` actually the default DNS policy for a pod?**

- A) Yes, that's what "Default" means
- B) No — `ClusterFirst` is the actual default; `Default` means using the node's own DNS instead
- C) It depends on the cluster's CNI plugin
- D) Only StatefulSet pods default to `Default`

<details>
<summary>Answer</summary>

**B** — This naming is genuinely confusing and worth memorizing precisely: `ClusterFirst` is what a pod gets if you don't specify anything.
Trap: A is the natural but incorrect reading of the name itself.

</details>

---

**Q6. A pod runs with `hostNetwork: true` and needs to resolve cluster Service names by their normal DNS names. What `dnsPolicy` handles this?**

- A) `Default` — hostNetwork pods should use node DNS
- B) `ClusterFirstWithHostNet`
- C) `None`, with a manually configured nameserver
- D) hostNetwork pods can never resolve cluster Service names

<details>
<summary>Answer</summary>

**B** — This policy exists specifically because a plain `ClusterFirst` doesn't behave the same way once a pod shares the node's network namespace — `ClusterFirstWithHostNet` forces the cluster-resolution behavior back on.
Trap: A sounds plausible but is backwards — `Default` would prevent exactly the cluster-name resolution the pod needs.

</details>

---

**Q7. What does `dnsPolicy: None` require that `ClusterFirst` doesn't?**

- A) Nothing extra — it behaves identically
- B) A fully manual `dnsConfig` — nameservers, search domains, and options are entirely your responsibility
- C) A NetworkPolicy allowing DNS traffic
- D) Running the pod in `kube-system`

<details>
<summary>Answer</summary>

**B** — `None` means nothing is injected automatically at all; get any part of `dnsConfig` wrong (like a mistyped nameserver IP) and nothing falls back gracefully.
Trap: A assumes equivalence with the default behavior, which is the opposite of what `None` actually means.

</details>

---

**Q8. A single Service's name returns NXDOMAIN, but `nslookup kubernetes.default` succeeds. What does this narrow down?**

- A) CoreDNS itself must be down
- B) CoreDNS is healthy — the issue is specific to that one Service (wrong namespace, doesn't exist, or no Ready pods)
- C) The pod's dnsPolicy must be wrong
- D) The cluster's NodePort range is misconfigured

<details>
<summary>Answer</summary>

**B** — A working `kubernetes.default` lookup rules out CoreDNS and the pod's own DNS policy entirely — the problem is isolated to that specific Service.
Trap: A and C both assume broader breakage than the evidence actually supports — a successful control lookup rules those out.

</details>

---

**Q9. What's the correct DNS format for resolving pod `10.244.1.23` in namespace `backend-ns` directly, without going through a Service?**

- A) `10.244.1.23.backend-ns.pod.cluster.local`
- B) `10-244-1-23.backend-ns.pod.cluster.local`
- C) `backend-ns.10-244-1-23.pod.cluster.local`
- D) Pods cannot be resolved by DNS directly, only Services can

<details>
<summary>Answer</summary>

**B** — Every dot in the IP becomes a dash; the namespace and `pod.<cluster-domain>` suffix come after, in that order.
Trap: A keeps the dots from the original IP, which isn't valid — CoreDNS's `pods insecure` option specifically expects the dashed form.

</details>

---

**Q10. What does the CoreDNS `loadbalance` plugin actually do?**

- A) Distributes CoreDNS's own workload across replica pods
- B) Randomizes the order of A/AAAA records in a DNS response
- C) Balances traffic between ClusterIP and NodePort Services
- D) Assigns weights to different backend pods based on CPU usage

<details>
<summary>Answer</summary>

**B** — This is the actual mechanism behind a headless Service (`04-headless`) returning pod IPs in a different order each query — CoreDNS itself is doing the shuffling, not kube-proxy or the Service object.
Trap: A confuses this with CoreDNS's own pod-level scaling (a separate, unrelated concern) rather than what it does to the *content* of a DNS response.

</details>

Score guide:
| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next chapter |
| 8/10 | Review the wrong answer, then proceed |
| 6-7/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
