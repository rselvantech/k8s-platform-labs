# Quiz — 03-services/05-service-discovery: Service Discovery and CoreDNS

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to the next chapter.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. A pod in `frontend-ns` has `search frontend-ns.svc.cluster.local svc.cluster.local cluster.local` in its `/etc/resolv.conf`. Would this pod's search domains ever let a bare short name resolve a Service sitting in `backend-ns`?**

- A) Yes — `svc.cluster.local` matches any namespace
- B) No — none of these three search domains include `backend-ns` at all; only `backend-svc.backend-ns` or the full FQDN would work
- C) Yes, but only on the second DNS attempt
- D) Only if `ndots` is set to a lower value

<details>
<summary>Answer</summary>

**B** — Every search domain listed is scoped to the pod's own namespace or the cluster generally — none of them contain `backend-ns` as a suffix, so a bare `backend-svc` query can never land there.
Trap: A misreads `svc.cluster.local` as a wildcard across all namespaces, when it actually just strips the namespace segment, requiring the namespace to already be part of the query.

</details>

---

**Q2. Service environment variables follow a fixed naming transform — e.g. a Service named `demo-svc` produces `DEMO_SVC_SERVICE_HOST`. What's the transform applied to the Service name itself?**

- A) Lowercased, dashes kept as-is
- B) Uppercased, and dashes converted to underscores
- C) Reversed and uppercased
- D) Left exactly as written, with `_SERVICE_HOST` appended

<details>
<summary>Answer</summary>

**B** — `demo-svc` becomes `DEMO_SVC` before the suffix is appended — both the case change and the dash-to-underscore substitution are necessary to get a valid environment variable name.
Trap: D ignores that a bare hyphenated name isn't even a legal shell/environment variable identifier — the transform is required, not cosmetic.

</details>

---

**Q3. The Exam Task asks for three valid ways to reach `db-svc` in namespace `app-b` from a pod in `app-a`. The bare short name `db-svc` fails — what are the two forms that do work?**

- A) `db-svc.svc.cluster.local` and `db-svc.local`
- B) `db-svc.app-b` (namespace-qualified) and `db-svc.app-b.svc.cluster.local` (full FQDN)
- C) `app-b.db-svc` and `db-svc:app-b`
- D) Only the full FQDN works; there is no shorter valid form

<details>
<summary>Answer</summary>

**B** — Namespace-qualified and full-FQDN are the two forms this demo's Step 3 actually demonstrates succeeding, in that order of increasing explicitness.
Trap: C inverts the correct ordering of name components — this demo's DNS format always goes `<service>.<namespace>`, never the reverse.

</details>

---

**Q4. Why is `kubernetes.default` specifically a good "control" lookup when debugging DNS, rather than any other cluster name?**

- A) It's the only Service DNS can resolve reliably
- B) It's a core, always-present Service in every cluster — if it resolves, CoreDNS itself and the pod's own DNS policy are both confirmed healthy, isolating the problem to whatever specific name failed
- C) It resolves faster than any other Service name
- D) It's the only name that works under `dnsPolicy: None`

<details>
<summary>Answer</summary>

**B** — Its near-universal presence is exactly what makes it useful as a baseline — a working `kubernetes.default` lookup rules out whole categories of failure (CoreDNS down, wrong `dnsPolicy`) at once.
Trap: D invents a special exemption for this one name under `None`, when `None` actually requires manual `dnsConfig` regardless of which name you're resolving.

</details>

---

**Q5. Step 7's systematic debugging sequence starts with `nslookup kubernetes.default` before checking a specific failing Service name. Why start there instead of jumping straight to the actual problem Service?**

- A) It's required by `kubectl` — you cannot query a custom Service name first
- B) It establishes whether the failure is cluster-wide (CoreDNS/policy) or scoped to one Service, before spending effort narrowing further
- C) `kubernetes.default` must always be queried once per debugging session for caching reasons
- D) It has no real purpose beyond habit

<details>
<summary>Answer</summary>

**B** — This ordering is deliberate triage: confirm the baseline works before assuming the problem is specific to one Service, narrowing the search space efficiently.
Trap: C invents a caching-related requirement that has nothing to do with why this step is first.

</details>

---

**Q6. CoreDNS's `pods insecure` option is what enables resolving an individual pod directly by DNS. What does the word "insecure" actually flag about this capability?**

- A) That the connection to the resolved pod is unencrypted
- B) That it only allows resolving your own pod's IP, not others
- C) The demo doesn't specify — but naming aside, it's what enables the `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>` format used in Step 4b
- D) That pod DNS records expire after exactly 30 seconds

<details>
<summary>Answer</summary>

**C** — This demo names the option and shows what it enables (pod-level DNS records) without going into what "insecure" specifically implies beyond that — worth not inventing a confident answer the material doesn't actually give.
Trap: A and D both assert specific mechanisms the demo never actually states — recognizing what's genuinely covered vs. not is part of this question.

</details>

---

**Q7. Step 1 creates a Service for the backend namespace but deliberately does NOT create one for the frontend namespace. Why?**

- A) Frontend pods don't need a stable address in this demo
- B) Every cross-namespace test in Steps 3–4 reaches the backend *from* a frontend pod — the frontend side only ever needs to be the caller, never something resolved by name itself
- C) It was an oversight later fixed in `06-loadbalancer-traffic-policies`
- D) Namespaces can only contain one Service each

<details>
<summary>Answer</summary>

**B** — The entire test direction in this demo is frontend-pod-calls-backend-Service — nothing in Steps 2–7 ever needs to resolve anything living in `frontend-ns` by name.
Trap: D states an incorrect and easily-disprovable constraint — namespaces have no such limit, and this series' own earlier demos have shown multiple Services per namespace repeatedly.

</details>

---

**Q8. The Corefile shown in Step 4 includes both a `cache 30` line and a `forward . /etc/resolv.conf` line. If a pod queries `google.com`, which of these two plugins actually handles it, and does the other apply at all?**

- A) Only `forward` applies — `cache` only works for cluster-internal names
- B) `forward` sends the query to the node's own DNS; `cache` still applies afterward, caching that external response for repeated queries too
- C) Neither applies to external names — only the `kubernetes` plugin does
- D) `cache` intercepts the query before `forward` ever sees it, blocking external resolution

<details>
<summary>Answer</summary>

**B** — `forward` is what actually routes non-cluster names outward, but `cache`'s 30-second caching isn't scoped only to cluster-internal answers — it applies to whatever CoreDNS resolves, external names included.
Trap: A assumes caching is cluster-only, but nothing in the Corefile scopes `cache` that narrowly — it sits in the general plugin chain, applying broadly.

</details>

---

**Q9. This demo distinguishes a single Service's NXDOMAIN from CoreDNS crashing entirely (Break-Fix Error-2). Structurally, why does a Corefile syntax error cause a cluster-wide outage rather than just breaking DNS for the Service you happened to be querying?**

- A) Because CoreDNS itself is what crashes and restarts — every pod in the cluster depends on the same handful of CoreDNS pods, not per-Service instances
- B) Because the syntax error only affects Services in the `default` namespace
- C) Because `kube-proxy` also crashes when CoreDNS's config is invalid
- D) It doesn't actually cause a cluster-wide outage — only Services created after the edit are affected

<details>
<summary>Answer</summary>

**A** — There's no per-Service DNS process — every pod cluster-wide shares the same small set of CoreDNS pods as its nameserver, so those pods crash-looping takes down resolution for everyone simultaneously, regardless of namespace or which Service anyone happens to be querying.
Trap: B invents a namespace-scoped blast radius that doesn't match how CoreDNS actually serves the whole cluster from one shared set of pods.

</details>

---

**Q10. This demo's own Interview Prep states pod-level DNS records are "rarely used directly by applications." What's the actual justification given for why, despite the capability existing?**

- A) It requires special RBAC permissions most applications don't have
- B) Pod IPs are ephemeral, so a pod-DNS record only stays valid as long as that specific pod does — making it far less durable than Service-based discovery for anything an application would call directly
- C) It's disabled by default in most clusters
- D) It only works for pods without a Deployment

<details>
<summary>Answer</summary>

**B** — The same ephemerality theme from earlier chapters applies here directly — a record tied to one specific pod's IP is only as durable as that pod, which is exactly why Service-based (not pod-based) discovery is what applications actually rely on.
Trap: C and A both invent access/configuration barriers, when the real reason given is about the record's inherent durability, not permissions or defaults.

</details>

Score guide:
| Score | Action |
|---|---|
| 9-10/10 | Import Anki cards, move to next chapter |
| 8/10 | Review the wrong answer, then proceed |
| 6-7/10 | Re-read the relevant section, retry those questions |
| Below 6/10 | Re-read the full demo and redo the walkthrough before proceeding |
