# Quiz — 03-services/03-externalname: ExternalName Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. What does an ExternalName Service actually do?**

- A) Routes traffic to pods via a virtual IP, like ClusterIP
- B) Returns a DNS CNAME record — pure redirection, no proxying at all
- C) Opens a port on every node, like NodePort
- D) Load balances across multiple external IPs automatically

<details>
<summary>Answer</summary>

**B** — No virtual IP, no kube-proxy involvement, no EndpointSlices — just a CNAME.
Trap: A and C both describe mechanisms that involve pod/IP routing, which ExternalName specifically doesn't do.

</details>

---

**Q2. Can `externalName` be set to an IP address like `192.168.1.100`?**

- A) Yes, it resolves directly to that address
- B) No — it's treated as a DNS name made of digits and fails to resolve
- C) Only if quoted as a string
- D) Only on cloud-provider clusters

<details>
<summary>Answer</summary>

**B** — DNS doesn't resolve an IP-looking string as an address here; it results in NXDOMAIN.
Trap: C suggests a workaround that doesn't exist — quoting doesn't change how DNS interprets the value.

</details>

---

**Q3. You add a `selector` field to an ExternalName Service, expecting it to also route matching pods as a fallback. What happens?**

- A) It routes to pods only when the external DNS lookup fails
- B) Nothing — the selector is accepted but has no effect at all
- C) Kubernetes rejects the Service as invalid
- D) It converts the Service to ClusterIP automatically

<details>
<summary>Answer</summary>

**B** — This field is silently ignored on ExternalName Services — no error, no fallback behavior, just unused configuration.
Trap: A imagines a fallback mechanism that doesn't exist — ExternalName has exactly one behavior, CNAME redirection, with no conditional logic.

</details>

---

**Q4. What Host header does an external server receive when a pod accesses it via an ExternalName Service?**

- A) The external server's own real hostname
- B) The internal Service's name (e.g. `database-svc`), not the external hostname
- C) No Host header is sent at all
- D) The pod's own hostname

<details>
<summary>Answer</summary>

**B** — This is a real production gotcha: the app still addresses the internal Service name, so that's what ends up in the Host header, regardless of where DNS actually redirected the connection.
Trap: A assumes DNS redirection somehow rewrites application-layer headers too — it only affects DNS resolution, nothing at the HTTP layer.

</details>

---

**Q5. Can an ExternalName Service's target be another Kubernetes Service's own DNS name?**

- A) No, only external (non-Kubernetes) hostnames are valid
- B) Yes — CNAME chaining to a real resolvable hostname works, including another Service's internal DNS name
- C) Only if both Services are in the same namespace
- D) Only for headless Services

<details>
<summary>Answer</summary>

**B** — This is exactly Step 4's migration demo: `externalName` gets set to `backend-real-svc.default.svc.cluster.local`, a perfectly valid, resolvable DNS name.
Trap: C invents a same-namespace restriction that doesn't exist — the target just needs to be a resolvable hostname, full stop.

</details>

---

**Q6. When would a selectorless Service (from `02-service-internals`) be the right choice instead of ExternalName?**

- A) When the external target is a stable IP address, not a hostname
- B) Never — ExternalName always supersedes selectorless Services
- C) Only for internal cluster traffic
- D) Only when using NodePort

<details>
<summary>Answer</summary>

**A** — ExternalName needs a hostname; a selectorless Service with a manual EndpointSlice is the mechanism for a stable IP, since ExternalName explicitly can't handle IPs at all.
Trap: B treats the two as strictly ranked rather than suited to different situations — they solve genuinely different problems.

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

**Q8. Does ExternalName perform load balancing across multiple external endpoints?**

- A) Yes, automatically, using round-robin
- B) No — it returns a single CNAME; any load balancing is up to the external DNS itself
- C) Yes, but only in ipvs mode
- D) Only if `spec.ports` is set

<details>
<summary>Answer</summary>

**B** — kube-proxy is never involved with ExternalName Services at all — whatever load balancing exists is entirely a property of the external hostname's own DNS records, outside Kubernetes' control.
Trap: C ties this to a kube-proxy mode, but kube-proxy has no role in ExternalName Services whatsoever, in any mode.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
