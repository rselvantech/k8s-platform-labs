# Quiz — 04-configmaps-secrets/01-configmaps: ConfigMaps

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next Demo.

**Q1. Concepts lists command arguments as a genuinely separate ConfigMap consumption method from environment variables, even though `$(VAR_NAME)` requires an env var to exist first. Why is it treated as distinct rather than just "a use of env vars"?**

- A) It isn't actually distinct — the docs just describe it that way for clarity
- B) The value ends up delivered as part of the process's argv, read via `sys.argv`/`$1`, not via `os.getenv()` — a genuinely different delivery mechanism for the receiving application
- C) It requires a completely different ConfigMap field
- D) It only works with exec-form commands

<details>
<summary>Answer</summary>

**B** — The env var step is always required first, but what the application actually receives (an argv entry vs. an environment lookup) is a real, distinct outcome.
Trap: D is disproven directly in this demo's own Concepts — `$(VAR_NAME)` is shown working in both exec-form and shell-form.

</details>

---

**Q2. `script.sh: |-` uses the block-scalar chomping indicator `|-` instead of plain `|`. What's the actual difference?**

- A) `|-` preserves all trailing newlines; `|` strips them all
- B) `|-` strips all trailing newlines; `|` strips only the final one
- C) `|-` is Kubernetes-specific syntax; `|` is standard YAML
- D) There is no difference — both are equivalent

<details>
<summary>Answer</summary>

**B** — `|` (plain) keeps internal newlines but trims to a single trailing newline; `|-` removes trailing newlines entirely — useful specifically for shell scripts where a stray trailing blank line is unwanted.
Trap: C reverses reality — both `|` and `|-` are standard YAML chomping indicators, neither is Kubernetes-specific.

</details>

---

**Q3. A ConfigMap volume item sets `path: nginx/nginx.conf` under a `mountPath` of `/etc/nginx`. Where does the file actually end up?**

- A) `/etc/nginx/nginx.conf`
- B) `/etc/nginx/nginx/nginx.conf` — a real subdirectory named `nginx` gets created
- C) `/nginx/nginx.conf`, ignoring `mountPath`
- D) The pod fails to start

<details>
<summary>Answer</summary>

**B** — Any `/` in `items[].path` creates a real subdirectory inside `mountPath` — this demo's own Lab hits this directly: `cat /etc/nginx/nginx.conf` fails with "No such file or directory" because the actual path requires the extra `nginx/` segment.
Trap: A is the intuitive-but-wrong assumption that trips up exactly this scenario in the demo's own walkthrough.

</details>

---

**Q4. `envFrom` supports an optional `prefix` field. What does setting `prefix: "CFG_"` actually do?**

- A) Filters which keys get loaded from the source
- B) Prepends `CFG_` to every key name from that specific `envFrom` source before it becomes an env var
- C) Sets a default value for any missing keys
- D) Renames only the first key alphabetically

<details>
<summary>Answer</summary>

**B** — `APP_ENV` becomes `CFG_APP_ENV`, `APP_PORT` becomes `CFG_APP_PORT`, etc. — useful specifically for avoiding key collisions when `envFrom` loads from multiple sources at once.
Trap: A invents a filtering behavior `prefix` doesn't have — it changes every key's name, it doesn't select a subset of them.

</details>

---

**Q5. A DER-format certificate must go in `binaryData`, but a PEM-format certificate of the same underlying certificate goes in `data`. Why the difference, given they represent the same certificate?**

- A) DER is a newer, more secure format than PEM
- B) PEM is base64-encoded text (`-----BEGIN CERTIFICATE-----`) and is therefore valid UTF-8; DER is the raw binary encoding of the same data and would be corrupted by UTF-8 handling
- C) PEM certificates are always self-signed; DER certificates never are
- D) DER is required for Kubernetes' own internal certificate handling

<details>
<summary>Answer</summary>

**B** — It's the same certificate, two different encodings — one happens to already be text-safe, the other genuinely isn't.
Trap: A and C both invent unrelated distinctions (security, signing) between two formats that differ only in encoding, not in what they cryptographically represent.

</details>

---

**Q6. Break-Fix Error-1 tries to create a ConfigMap from a ~1.6MB base64-encoded file. What's the actual rejection, and when does it happen?**

- A) The pod fails to start with `CreateContainerConfigError`
- B) `kubectl create configmap` itself is rejected immediately with a "Too long" error — no ConfigMap is ever created
- C) The ConfigMap is created but truncated to fit 1 MiB
- D) It succeeds, but only the first 1 MiB is readable

<details>
<summary>Answer</summary>

**B** — This fails at creation time, before any pod is even involved — there's no partial or truncated object, just an outright rejection.
Trap: C and D both imagine a partial-success outcome that doesn't happen — the object is never created at all.

</details>

---

**Q7. Break-Fix Error-2 puts the same key (`server.crt`) in both `data` and `binaryData` on one ConfigMap. Is the YAML itself syntactically invalid?**

- A) Yes — this is a YAML parsing error
- B) No — the YAML parses fine; the API server rejects it as a semantic validation error (duplicate key across the two fields)
- C) Yes, because YAML doesn't allow the same key name to appear twice anywhere in a document
- D) No — this is silently accepted, with `binaryData` taking precedence

<details>
<summary>Answer</summary>

**B** — The YAML is completely well-formed; `data` and `binaryData` are two separate maps, so `server.crt` appearing as a key in each is legal YAML — Kubernetes' own API validation is what rejects it, not the YAML parser.
Trap: C conflates "same key in the same map" (a real YAML restriction) with "same key across two different maps" (what's actually happening here) — these aren't the same rule.

</details>

---

**Q8. A pod references a ConfigMap that doesn't exist yet (no `optional: true`). Once the ConfigMap is created, does the pod need to be deleted and reapplied to pick it up?**

- A) Yes — a new pod must be created
- B) No — the existing pod transitions from `CreateContainerConfigError` to `Running` automatically once the ConfigMap exists
- C) Only if the ConfigMap is immutable
- D) Only if the pod's `restartPolicy` is `Always`

<details>
<summary>Answer</summary>

**B** — The kubelet keeps retrying container creation on its own; the same pod object recovers with no manual intervention the moment the missing dependency exists.
Trap: D invents a `restartPolicy` dependency that doesn't apply here — this is the kubelet retrying container *creation*, not a container restart after it already ran.

</details>

Score guide:
| Score | Action |
|---|---|
| 8/8 | Import Anki cards, move to next Demo |
| 7/8 | Review the wrong answer, then proceed |
| 6/8 | Re-read the relevant section, retry those questions |
| Below 6/8 | Re-read the full demo and redo the walkthrough before proceeding |
