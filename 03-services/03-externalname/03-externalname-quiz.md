# Quiz — 03-services/03-externalname: ExternalName Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. Concepts lists a TLS certificate validation limitation for ExternalName. Why might a TLS handshake fail even though DNS resolution via the CNAME works perfectly?**

- A) ExternalName Services can't carry HTTPS traffic at all
- B) The certificate presented by the external server is issued for its own real hostname, but the application may be validating against the internal Service name instead
- C) TLS is stripped by CoreDNS during CNAME resolution
- D) ExternalName requires plaintext HTTP only

<details>
<summary>Answer</summary>

**B** — This is the TLS-layer sibling of the HTTP Host-header problem — DNS redirection changes where the connection goes, but doesn't change what identity the application expects to be talking to.
Trap: C invents a DNS-layer effect on TLS that doesn't exist — CoreDNS only resolves names, it has no role in the TLS handshake itself.

</details>

---

**Q2. `kubectl get svc database-svc` shows `EXTERNAL-IP: httpbin.org`. Is this field actually holding an IP address here?**

- A) Yes, `httpbin.org` has been pre-resolved to an IP for display
- B) No — for ExternalName, this column is repurposed to display the CNAME target hostname, not a literal IP
- C) This is a display bug
- D) It only shows a hostname if the Service was created imperatively

<details>
<summary>Answer</summary>

**B** — Contrast this with a NodePort/LoadBalancer Service, where `EXTERNAL-IP` genuinely holds an IP (or `<none>`) — for `ExternalName`, the same column is repurposed to show the hostname target instead, since there's no IP to show at all.
Trap: A imagines a resolution step that doesn't happen at the `kubectl get svc` level — it just echoes the `externalName` field's literal value.

</details>

---

**Q3. `kubectl expose` cannot create an ExternalName Service. Structurally, why not — beyond just "it's a different subcommand"?**

- A) `kubectl expose` is hardcoded to reject the `ExternalName` type string
- B) `kubectl expose` always derives its target from an existing Deployment/Pod's selector and ports — but `ExternalName` has no selector, no ports, and no pod target at all to derive anything from
- C) `ExternalName` Services didn't exist when `kubectl expose` was written
- D) `kubectl expose` only supports `type=ClusterIP`

<details>
<summary>Answer</summary>

**B** — `expose`'s entire model is "take this existing workload object and front it with a Service" — `ExternalName` isn't fronting anything in the cluster at all, so there's nothing for `expose` to derive a selector or port from.
Trap: D is factually wrong and worth ruling out — `expose` supports ClusterIP, NodePort, and LoadBalancer, just not ExternalName.

</details>

---

**Q4. Both an IP address (`192.168.1.100`) and a URL with a scheme (`http://httpbin.org`) fail identically as `externalName` values — `NXDOMAIN`, no apply-time error. What's the shared root cause?**

- A) Both are blocked by an explicit Kubernetes validation rule
- B) Kubernetes never validates `externalName` against real DNS hostname syntax at apply time — both are accepted as strings and only fail later, when something actually tries to resolve them
- C) They fail for unrelated reasons that happen to look similar
- D) Only the IP case is a real failure; the URL case actually works

<details>
<summary>Answer</summary>

**B** — Neither this demo's Step 5 (IP) nor Break-Fix Error-2 (URL) is caught by `kubectl apply` — both are syntactically "valid enough" strings that Kubernetes stores without complaint, and both only reveal the problem when DNS resolution is actually attempted.
Trap: A assumes validation exists where the demo explicitly shows it doesn't — the entire point of both scenarios is the absence of an apply-time check.

</details>

---

**Q5. Step 4's migration relies on `backend-real-svc.default.svc.cluster.local` already being a real, resolvable DNS name. Which prior demo's mechanism is what actually makes that true?**

- A) `02-service-internals`'s EndpointSlice mechanism
- B) `01-clusterip-nodeport`'s CoreDNS-resolves-Service-names-to-ClusterIP mechanism
- C) This demo's own ExternalName mechanism, applied recursively
- D) It's a special DNS record created only for migration scenarios

<details>
<summary>Answer</summary>

**B** — Every ClusterIP Service automatically gets a DNS name of this exact shape, resolved by CoreDNS — that's `01-clusterip-nodeport`'s subject, and it's what lets an `ExternalName` Service CNAME-chain to it without anything special being set up for the migration itself.
Trap: C is circular — ExternalName is what's *consuming* that resolvable name in this step, not what's producing it.

</details>

---

**Q6. Does the `spec.externalName` field accept a list of multiple hostnames for basic failover between them?**

- A) Yes, up to 3 hostnames
- B) No — `externalName` is a single string field; there's no multi-hostname or failover concept built into this Service type at all
- C) Yes, but only with `type: LoadBalancer`
- D) Only in newer Kubernetes versions

<details>
<summary>Answer</summary>

**B** — Every manifest in this demo shows `externalName` as a single scalar string — there's no field shape here for a list, and nothing in ExternalName's pure-CNAME design supports choosing between multiple targets.
Trap: C invents a dependency on a completely different Service type — `LoadBalancer` and `ExternalName` are mutually exclusive `spec.type` values, not something combinable.

</details>

---

**Q7. `externalName` is accidentally set to `http://httpbin.org` instead of `httpbin.org`. What happens?**

- A) Kubernetes strips the scheme automatically
- B) It resolves fine — DNS ignores the scheme prefix
- C) It fails to resolve (NXDOMAIN) — the scheme prefix isn't a valid DNS label
- D) It's rejected at apply time with a validation error

<details>
<summary>Answer</summary>

**C** — Same failure signature as an IP address: `kubectl apply` doesn't validate `externalName` against real DNS syntax, so this is accepted, then fails silently at resolution time.
Trap: D assumes apply-time validation catches this — it doesn't; the failure only surfaces when something actually tries to resolve the name.

</details>

---

**Q8. If `httpbin.org`'s own DNS record later points to a different IP address (its operators change hosting providers, say), does `database-svc` need to be updated?**

- A) Yes — the Service object caches the resolved IP and needs to be refreshed
- B) No — `database-svc` only stores the hostname `httpbin.org`; resolving that hostname to whatever IP it currently points to happens fresh at DNS lookup time, every time
- C) Only if `kubectl rollout restart` is run
- D) Only if the Service is recreated

<details>
<summary>Answer</summary>

**B** — This is the direct payoff of "pure DNS redirection, no proxying" from Concepts — the Service holds a hostname, not a cached IP, so anything downstream that hostname's own DNS does is transparent to Kubernetes.
Trap: A imagines a caching layer inside the Service object that doesn't exist — there's nothing to go stale, since no IP is ever stored there in the first place.

</details>

Score guide:

| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
