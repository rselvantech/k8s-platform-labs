# Quiz — 03-services/04-headless: Headless Service

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.
> This quiz does not restate the Anki deck's facts verbatim — it tests
> other Concepts/Lab material the deck doesn't cover.

**Q1. Step 3's `readinessProbe` uses `exec: command: ["true"]` with `initialDelaySeconds: 25`. What is this actually simulating?**

- A) A real health check confirming MySQL is ready to accept connections
- B) Nothing real — it's a deliberately fake, fixed delay purely so Step 5 has a predictable "not Ready" window to observe DNS behavior during it
- C) A network latency test between StatefulSet pods
- D) The minimum time MySQL needs to initialize its data directory

<details>
<summary>Answer</summary>

**B** — `true` always succeeds instantly; the only thing doing any work here is the artificial 25-second delay, explicitly noted as being for observability, not health-checking.
Trap: A treats this as a genuine probe, when the demo is explicit that it exists purely to make Step 5's timing observable.

</details>

---

**Q2. Concepts states StatefulSet pod names are "never renumbered." If `mysql-1` is deleted from a 3-replica StatefulSet, what name does its replacement get?**

- A) `mysql-3` — the next available number
- B) `mysql-1` again — the exact same ordinal position
- C) A random suffix, the same as a Deployment's pods
- D) It depends on which node the replacement lands on

<details>
<summary>Answer</summary>

**B** — Pod names are tied to ordinal position, not an incrementing counter — the replacement fills the same slot, never a new number.
Trap: A assumes StatefulSet names work like ReplicaSet's ever-incrementing suffixes, which is exactly the identity model this demo contrasts it against.

</details>

---

**Q3. In Break-Fix Error-2, `fake-headless` has `clusterIP: ""` but a valid selector and ports matching real pods. Does it actually fail to route any traffic?**

- A) Yes — an empty `clusterIP` breaks routing entirely
- B) No — it silently becomes a completely ordinary, working ClusterIP Service; only its headless *intent* fails, not its basic function
- C) It only routes traffic to `mysql-0`
- D) It routes traffic but with no DNS resolution at all

<details>
<summary>Answer</summary>

**B** — `clusterIP: ""` auto-assigns a normal virtual IP, so this Service actually works fine as a regular ClusterIP Service — the failure is purely that `nslookup` returns one A record instead of the multiple-A-record behavior the YAML's intent implied.
Trap: A assumes an empty value breaks the Service outright, when it actually just falls back to completely normal behavior.

</details>

---

**Q4. The MySQL headless Service in Step 3 sets `ports[].name: mysql` even though it only has one port. Is this naming actually required here?**

- A) Yes — every headless Service port must be named
- B) No — naming is only required once a Service has more than one port; this single-port Service names it purely as good practice
- C) Yes, because StatefulSets require named ports specifically
- D) No, but only because this is a headless Service — regular Services always require names

<details>
<summary>Answer</summary>

**B** — The named-ports requirement (covered in full in `06-loadbalancer-traffic-policies`) only activates with a second port — this Service could have omitted the name with no rejection.
Trap: C and D both invent a headless-Service-specific or StatefulSet-specific naming rule that doesn't exist — the real trigger is purely port count.

</details>

---

**Q5. This demo explicitly defers StatefulSet's storage (`volumeClaimTemplates`), update strategies, and scaling-order guarantees to `09-statefulsets`. Why introduce a StatefulSet here at all rather than waiting?**

- A) Because headless Services require at least a partial StatefulSet example to configure at all
- B) Because a headless Service's real production purpose is fundamentally tied to StatefulSet's ordered, stable naming — that piece can't be skipped even though the rest of StatefulSet waits for its own demo
- C) It's an error — StatefulSets shouldn't appear before their dedicated demo
- D) Because `03-externalname` already required it as a prerequisite

<details>
<summary>Answer</summary>

**B** — "Just enough StatefulSet" specifically means the naming/identity model, since that's what actually explains why headless Services exist — the rest (storage, updates, scaling order) genuinely can wait.
Trap: C treats a deliberate "just enough" scoping choice as a structural mistake.

</details>

---

**Q6. Both `01-clusterip-nodeport`'s Endpoints/EndpointSlices and this demo's headless-Service DNS query return multiple items. What's the fundamental difference in what's returned?**

- A) There's no real difference — both return the same information to the same audience
- B) Endpoints/EndpointSlices return pod IP:port pairs that kube-proxy uses internally to program routing rules; headless DNS returns those same pod IPs directly to the calling application itself, with no kube-proxy involved at all
- C) Endpoints are pod names; headless DNS returns pod IPs
- D) EndpointSlices are namespace-scoped; headless DNS is cluster-scoped

<details>
<summary>Answer</summary>

**B** — The data (pod IPs) is similar in shape, but the *audience* differs completely — one feeds kube-proxy's internal rule-programming, the other is handed straight to whatever application queried DNS.
Trap: A collapses two genuinely different mechanisms into one just because both eventually reference the same underlying pod IPs.

</details>

---

**Q7. Per this demo's own field table, what is `readinessProbe.initialDelaySeconds`'s default value if a manifest omits it entirely?**

- A) 10 seconds
- B) 0
- C) 30 seconds
- D) There is no default — it must always be set

<details>
<summary>Answer</summary>

**B** — Stated directly in this demo's Step 3 field table: default `0` if omitted, with this demo's own `25` being a deliberate, demo-specific override.
Trap: D assumes a required field where the table explicitly states a default exists.

</details>

---

**Q8. Break-Fix Error-2 is described as self-contained, needing no pods at all. What does it actually demonstrate, given that?**

- A) A full StatefulSet failure scenario
- B) The `clusterIP: ""` vs `None` distinction, entirely at the Service-object level — visible from `kubectl get svc` output alone
- C) A DNS resolution failure inside a running pod
- D) A kube-proxy iptables misconfiguration

<details>
<summary>Answer</summary>

**B** — Since the whole point is what value ended up in `spec.clusterIP`, `kubectl get svc` alone shows the symptom — no backend pods or DNS queries from inside a pod are needed to demonstrate it.
Trap: C assumes a DNS-query-based demonstration, when the demo shows the problem purely through the Service object's own displayed fields.

</details>

---

**Q9. Compare Error-1's cascade ("looks fine, isn't" — pods and StatefulSet both report healthy) against Error-2's cascade (a visibly wrong `CLUSTER-IP`). Which is the more dangerous failure mode in practice, and why?**

- A) Error-2 — because it produces a visible, non-`None` value
- B) Error-1 — because nothing in `kubectl get pods`/`kubectl get statefulset` signals any problem at all; only actually attempting per-pod DNS resolution reveals it
- C) Both are equally dangerous
- D) Neither is dangerous since both are covered in this demo's documentation

<details>
<summary>Answer</summary>

**B** — Error-2's symptom is visible the instant you run `kubectl get svc` and know to check for `None` specifically; Error-1 gives zero signal anywhere in standard health-check commands, only surfacing when something actually tries per-pod DNS.
Trap: A treats "visibly wrong" as automatically more dangerous, when a silent failure that standard monitoring wouldn't catch is the harder one to actually detect in production.

</details>

Score guide:
| Score | Action |
|---|---|
| 9/9 | Import Anki cards, move to next Demo |
| 8/9 | Review the wrong answer, then proceed |
| 6-7/9 | Re-read the relevant section, retry those questions |
| Below 6/9 | Re-read the full demo and redo the walkthrough before proceeding |
