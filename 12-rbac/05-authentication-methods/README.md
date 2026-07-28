# Demo: 12-rbac/05-authentication-methods — Establishing Real Identity

## Lab Overview

Every demo in this series so far has used `--as`/`--as-group` impersonation to *simulate* a subject — `ci-pipeline`, `oncall-engineer`, `platform-team` never actually authenticated to anything; we told the API server to pretend. This demo builds a real one: a genuine client-certificate identity, from a private key through to a working `kubeconfig`, using the exact mechanism `01`'s Request Flow diagram labeled "AuthN" and then set aside.

**Real-world scenario:** A new contractor, Jane, needs her own cluster identity — not a shared admin credential, not a ServiceAccount (she's a human, not a workload). You'll generate her a private key and certificate signing request, have the cluster sign it via the `CertificateSigningRequest` API, build her a `kubeconfig`, and bind the exact same `pod-log-reader`-style access from `01` to her — this time to a *real* identity instead of an impersonated one.

**What this lab covers:**
- A short survey of the four real-world Kubernetes authentication methods: client certificates, ServiceAccount tokens, OIDC, webhook token authentication
- The full client-certificate pipeline: private key → CSR → `CertificateSigningRequest` object → approval → signed certificate → `kubeconfig`
- Binding both a `User` and a `Group` grant to the resulting real identity — proving `03`'s Group theory (the Organization field *is* the group) against something real for the first time
- The 403 e2e test: proving that a `Forbidden` response means AuthN already succeeded before AuthZ ever ran

> **Scope note:** This lab gives full hands-on treatment only to client certificates. ServiceAccount tokens get hands-on treatment in `12-rbac/06-service-accounts-rbac`; OIDC and webhook token authentication are covered here as theory only — neither requires (or gets) a live external identity provider or webhook service stood up in this lab.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — control plane + 2 workers, already running from earlier topic groups
- kubectl v1.35.x (matched to cluster version)
- `openssl` — used to generate the private key and CSR

**Verify before starting:**
```bash
kubectl get nodes
openssl version
```

**Knowledge Requirements:**
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` (Role/RoleBinding, the AuthN→AuthZ→Admission Control flow), `12-rbac/03-advanced-policyrules-and-subjects` (the `Group` subject kind, the `system:` prefix)

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Name the four real-world Kubernetes authentication methods and state when each is actually used
2. ✅ Generate a private key and CSR, and submit it to the cluster as a `CertificateSigningRequest` object
3. ✅ Approve a CSR and extract the resulting signed certificate into a working `kubeconfig`
4. ✅ Bind access to a real client-certificate identity by both `User` (Common Name) and `Group` (Organization), and verify each independently
5. ✅ Prove, live, that a `403 Forbidden` means AuthN already succeeded — AuthZ denied the request after identity was already established

---

## Directory Structure

```
12-rbac/05-authentication-methods/
├── README.md
├── 05-authentication-methods-anki.csv
├── 05-authentication-methods-quiz.md
└── src/
    ├── 01-namespace-ci.yaml                    # reused pattern from 01-rbac-fundamentals
    ├── 02-csr-contractor-jane.yaml.template      # CertificateSigningRequest object — templated, CSR content generated per-run
    ├── 03-role-pod-log-reader.yaml               # identical Role to 01 — the point is the identity, not the Role
    └── 04-rolebinding-contractor.yaml             # binds BOTH the User and the Group from Jane's certificate
```

---

## Recall Check — 04-clusterroles-clusterrolebindings

Answer from memory before continuing — no peeking at the previous demo.

1. Does binding a `ClusterRole` via an ordinary `RoleBinding` ever grant access to a cluster-scoped resource like Nodes?
2. Does the built-in `view` ClusterRole grant read access to Secrets?
3. What happens if you write a `nonResourceURLs` rule inside a `Role` instead of a `ClusterRole`?

<details>
<summary>Answers</summary>

1. No — a `RoleBinding` is namespace-scoped regardless of which object it references; the cluster-scoped part of a `ClusterRole`'s rules never activates through that path.
2. No — `view` deliberately excludes Secrets as a documented security choice, not an oversight.
3. The API server rejects it outright with a validation error at apply time — `nonResourceURLs` has no namespace to scope to, so it's invalid in a namespace-scoped `Role`.

</details>

---

## Concepts

### The Four Real-World Authentication Methods

**What it is:** `01`'s Request Flow diagram named AuthN as "verifies identity: client cert, bearer token, OIDC token, etc." — this is that "etc." made concrete. Kubernetes doesn't implement authentication itself so much as it delegates to one or more of these mechanisms, each producing the same output regardless of which one ran: a username plus a group list, handed to the Authorization stage.

| Method | How identity is established | Where it's typically used |
|---|---|---|
| **Client certificates** | A certificate signed by the cluster's CA, with the Common Name (CN) as username and Organization (O) fields as groups | Human operators, CI/CD systems, break-glass admin access — this demo's hands-on method |
| **ServiceAccount tokens** | A JWT, automatically mounted into every Pod, cryptographically tied to a `ServiceAccount` API object | Workloads running inside the cluster authenticating to the API server — covered hands-on in `06-service-accounts-rbac` |
| **OIDC (OpenID Connect)** | An ID token issued by an external identity provider (e.g. an org's SSO), validated by the API server against that provider's public keys | Human operators in organizations with centralized SSO — lets a company's existing identity system double as its Kubernetes identity system |
| **Webhook token authentication** | The API server forwards the presented token to an external HTTP(S) service, which returns a username and groups | Organizations with a custom or legacy identity system with no native OIDC support |

- **All four produce the same shape of output:** a username string and a list of group strings — nothing downstream (RBAC, Admission Control) knows or cares which method produced them. This is exactly why every concept from `01` onward that referenced "the subject's identity" applies unchanged regardless of which AuthN method is in play.
- **Why client certificates for this lab specifically:** no external dependency (unlike OIDC/webhook), and it's the method every other demo in this series has been implicitly assuming since `01` — the minikube admin identity itself, used throughout every prior Step 1, *is* a client certificate.

### The Client Certificate Pipeline

**What it is:** Five stages, each producing the input the next stage needs:

```
openssl genrsa          openssl req -new         CertificateSigningRequest    kubectl certificate      kubectl config
  (private key)     →      (CSR, unsigned)    →      (submitted to API)    →      approve          →     set-credentials
                                                                                (cluster signs it)         (kubeconfig)
```

- **The private key never leaves your machine.** Only the CSR — a request containing your public key and identity claims, cryptographically signed by the private key to prove you hold it — is ever submitted to the cluster.
- **The CSR's Subject fields map directly to RBAC subjects:** the Common Name (`CN=`) becomes the `User` subject's `name`; every Organization field (`O=`) becomes a `Group` the identity carries — this is the literal mechanism behind `03`'s statement that Groups are "supplied by the authenticator alongside the username." A cert with `/CN=contractor-jane/O=platform-team` produces a `User` named `contractor-jane` who is also a member of the `Group` `platform-team` — both usable in a `RoleBinding`'s `subjects`, independently, as proven live in this demo's Step 5.
- **`signerName` determines what the resulting certificate can be used for:** `kubernetes.io/kube-apiserver-client` (used in this lab) produces a certificate valid for authenticating *to* the API server as a client. Other signers exist for different purposes (e.g. `kubernetes.io/kubelet-serving`, for kubelets' own serving certificates) — not used in this lab, but worth knowing the field isn't a formality.
- **Approval is itself an RBAC-gated action:** `kubectl certificate approve` requires `approve` on the `certificatesigningrequests/approval` subresource — first named as a subresource example all the way back in `01`'s Concepts, now actually exercised.

### The 403 e2e Proof

**What it is:** `01` stated that a `403 Forbidden` means "AuthZ denied you before your request content was ever evaluated" — implying, but never proving, that AuthN had already succeeded by that point. This demo proves it directly, because Jane's identity is now real rather than impersonated.

- **The proof's logic:** if AuthN had failed, the API server would reject the request with `401 Unauthorized` — it would never reach the Authorization stage at all, and RBAC would never be consulted. Getting a `403` specifically, rather than a `401`, is direct evidence that Jane's certificate was successfully validated and her identity accepted — the request only failed *afterward*, at the Authorization stage, because no Role granted her anything yet. This is demonstrated live in Step 4, before any RoleBinding exists for her.

---

## Lab Step-by-Step Guide

---

### Step 1 — Generate the Private Key and CSR

```bash
openssl genrsa -out contractor-jane.key 2048
openssl req -new -key contractor-jane.key -out contractor-jane.csr \
  -subj "/CN=contractor-jane/O=platform-team"
```
```
⚠️ [VERIFY]
```
```
# Observation: /CN=contractor-jane becomes the User; /O=platform-team
# becomes a Group this identity carries — the exact mapping from
# Concepts, generated for real this time instead of asserted.
```

---

### Step 2 — Submit as a CertificateSigningRequest

Base64-encode the CSR for embedding in the Kubernetes object:
```bash
CSR_BASE64=$(cat contractor-jane.csr | base64 | tr -d '\n')
```

**`src/02-csr-contractor-jane.yaml.template`** (substitute `${CSR_BASE64}` before applying):
```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: contractor-jane
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client   # produces a client-auth certificate specifically
  usages:
  - client auth
```

```bash
envsubst < src/02-csr-contractor-jane.yaml.template > src/02-csr-contractor-jane.yaml
kubectl apply -f src/02-csr-contractor-jane.yaml
kubectl get csr contractor-jane
```
```
⚠️ [VERIFY]
NAME              AGE   SIGNERNAME                            REQUESTOR         REQUESTEDDURATION   CONDITION
contractor-jane   2s    kubernetes.io/kube-apiserver-client    minikube-user     <none>              Pending
```
```
# Observation: CONDITION reads Pending — the object exists, but no
# certificate has been issued yet. Nothing has been signed until
# approval happens in the next step.
```

---

### Step 3 — Approve and Extract the Signed Certificate

```bash
kubectl certificate approve contractor-jane
kubectl get csr contractor-jane
```
```
⚠️ [VERIFY]
certificatesigningrequest.certificates.k8s.io/contractor-jane approved
NAME              AGE   SIGNERNAME                            REQUESTOR         CONDITION
contractor-jane   30s   kubernetes.io/kube-apiserver-client    minikube-user     Approved,Issued
```

```bash
kubectl get csr contractor-jane -o jsonpath='{.status.certificate}' | base64 -d > contractor-jane.crt
```
```
⚠️ [VERIFY]
```
```
# Observation: the cluster's CA has now signed a real certificate for
# contractor-jane — status.certificate only populates once approval
# has happened; attempting this extraction before approval returns
# nothing.
```

---

### Step 4 — Build the kubeconfig and Prove the 403

```bash
kubectl config set-credentials contractor-jane \
  --client-certificate=contractor-jane.crt \
  --client-key=contractor-jane.key \
  --embed-certs=true

kubectl config set-context contractor-jane-context \
  --cluster=3node \
  --user=contractor-jane
```
```
⚠️ [VERIFY]
```

**Prove the 403 before any RoleBinding exists for Jane:**
```bash
kubectl --context=contractor-jane-context get pods -n ci
```
```
⚠️ [VERIFY]
Error from server (Forbidden): pods is forbidden: User "contractor-jane" cannot list resource "pods" in API group "" in the namespace "ci"
```
```
# Observation: Forbidden, not Unauthorized — Jane's certificate was
# validated successfully (AuthN succeeded; a failed cert would produce
# 401 and never reach this message at all). The request failed at
# Authorization, because no Role/RoleBinding grants her anything yet.
# This is the 403 e2e proof from Concepts, made concrete.
```

---

### Step 5 — Bind Access by Both User and Group

**`src/01-namespace-ci.yaml`** and **`src/03-role-pod-log-reader.yaml`:**

Identical to `01`, reused here (see `01-rbac-fundamentals` for the full Role definition).

**`src/04-rolebinding-contractor.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: contractor-jane-pod-log-reader
  namespace: ci
subjects:
- kind: User
  name: contractor-jane                # from the CSR's CN
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-log-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/01-namespace-ci.yaml
kubectl apply -f src/03-role-pod-log-reader.yaml
kubectl apply -f src/04-rolebinding-contractor.yaml
kubectl --context=contractor-jane-context get pods -n ci
```
```
⚠️ [VERIFY]
```
```
# Observation: the same 403 from Step 4 is now gone — this is the exact
# same identity, the exact same certificate, only a RoleBinding was
# added in between. Nothing about Jane's authentication changed at all.
```

**Confirm the Group grant works independently — bind by `platform-team` instead, remove the User binding, and prove the Organization field alone is sufficient:**
```bash
kubectl delete -f src/04-rolebinding-contractor.yaml
kubectl auth can-i get pods -n ci --as-group=platform-team --as=contractor-jane
```
```
⚠️ [VERIFY]
no
```
```
# Note: no RoleBinding currently references contractor-jane or
# platform-team at this point — "no" is expected here. Reapply a
# Group-scoped RoleBinding (subjects: kind: Group, name: platform-team)
# and rerun this check to confirm "yes", proving the O= field in Jane's
# certificate functions as a real, independently-grantable Group.
```

---

### Step 6 — Cleanup

**(a) Demo-scoped resources:** the `ci` namespace, Role, and RoleBinding stay in place if you plan to continue exploring; the `CertificateSigningRequest` object and kubeconfig context are safe to leave as well.

**(b) Full teardown:**
```bash
kubectl delete namespace ci --ignore-not-found
kubectl delete csr contractor-jane --ignore-not-found
kubectl config delete-context contractor-jane-context --ignore-not-found
kubectl config delete-user contractor-jane --ignore-not-found
rm -f contractor-jane.key contractor-jane.csr contractor-jane.crt
```

---

## What You Learned

- ✅ Named the four real-world Kubernetes authentication methods and when each is used
- ✅ Generated a private key and CSR, submitted as a `CertificateSigningRequest`
- ✅ Approved a CSR and built a working `kubeconfig` from the signed certificate
- ✅ Bound access by both `User` and `Group` to a real identity, verifying each independently
- ✅ Proved live that `403 Forbidden` means AuthN already succeeded — AuthZ denied the request afterward

**Key Takeaway:** Every RBAC concept from `01` onward operates on the output of authentication — a username plus a group list — regardless of which of the four methods produced it. A client certificate's Common Name and Organization fields are that output made literal: `CN` is the username, every `O` is a group, and RBAC never knows or needs to know that a certificate (rather than impersonation, an OIDC token, or a ServiceAccount) is what produced them.

---

## Break-Fix

Two scenarios below. Diagnose from the symptom command output alone before opening the reveal.

### Error-1 — the CSR is stuck `Pending` forever

```bash
kubectl get csr contractor-jane
```
```
⚠️ [VERIFY]
NAME              AGE   SIGNERNAME                            REQUESTOR       CONDITION
contractor-jane   10m   kubernetes.io/kube-apiserver-client    minikube-user   Pending
```

Ten minutes have passed and the condition still reads `Pending`. What's the most likely cause?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** Nobody has approved it yet. Unlike most objects in this series, a `CertificateSigningRequest` doesn't take effect just by existing — it requires an explicit `kubectl certificate approve` from someone holding the `approve` permission on `certificatesigningrequests/approval`. There's no timeout or auto-approval by default; it stays `Pending` indefinitely until a human (or an automated approval controller, if one is configured) acts on it.

**Fix:** `kubectl certificate approve contractor-jane`.

**Cascade:** This is a different kind of "silent" than earlier demos' RBAC typos — nothing is misconfigured here at all; the object is working exactly as designed. The trap is assuming CSR creation alone is sufficient, the same category of assumption `01` warned about for Role-with-no-RoleBinding.

</details>

---

### Error-2 — the kubeconfig context exists, but every command fails with a certificate error

```bash
kubectl --context=contractor-jane-context get pods -n ci
```
```
⚠️ [VERIFY]
error: unable to load client cert and key: tls: failed to find any PEM data in certificate input
```

The context was created following Step 4 exactly. What's the most likely cause?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `contractor-jane.crt` was extracted before the CSR was approved (Step 3's `status.certificate` field is empty until `Approved,Issued`), producing an empty or invalid file that `--embed-certs=true` then embedded as-is. The kubeconfig itself is structurally fine; the certificate data inside it isn't real.

**Fix:** Re-run the extraction command from Step 3 *after* confirming `kubectl get csr contractor-jane` shows `Approved,Issued`, then rebuild the credential entry with `kubectl config set-credentials` again.

**Cascade:** A reminder that this pipeline's steps are strictly sequential with a real dependency, not just a suggested order — extracting a certificate before it exists produces a file that looks superficially fine (it's still a file) but contains nothing usable.

</details>

---

## Interview Prep

**Q1. Two different authentication methods — client certificates and OIDC — both authenticate the same human. Does RBAC treat that person differently depending on which method was used?**
No. Both methods produce the same shape of output — a username and a group list — and that's all Authorization ever sees. RBAC has no visibility into which AuthN method produced the identity it's evaluating; a `Role`/`RoleBinding` grant works identically regardless of whether the subject authenticated via certificate, OIDC token, ServiceAccount token, or webhook.

**Q2. A `CertificateSigningRequest` has existed for an hour with `CONDITION: Pending`. Is anything actually broken?**
Not necessarily. Unlike RBAC objects earlier in this series, a CSR requires an explicit approval action — there's no timeout, and no implicit grant just from the object existing. `Pending` for an extended period usually just means nobody with `approve` permission has acted on it yet, not a misconfiguration.

**Q3. How would you prove, to someone skeptical, that a `403 Forbidden` response means authentication succeeded — not that the certificate itself was rejected?**
Point to the status code distinction: a failed or invalid certificate produces `401 Unauthorized`, and the request never reaches the Authorization stage at all — RBAC is never consulted. Getting `403` specifically means the identity was accepted and the request proceeded to Authorization, which then denied it for lack of a matching Role/RoleBinding. The two status codes map to two different, non-overlapping stages of the request flow.

**Q4. In a client certificate's Subject, what determines the `User` versus the `Group` a resulting identity carries?**
The Common Name (`CN=`) becomes the `User` subject's name; every Organization field (`O=`) present becomes a `Group` the identity is a member of. A certificate can carry multiple `O=` values, producing membership in multiple groups simultaneously from one certificate.

**Q5. Why does this demo use client certificates for its hands-on identity, rather than OIDC or webhook token authentication?**
Client certificates require no external system — no identity provider, no webhook service — everything happens using the cluster's own CA and standard tooling (`openssl`, `kubectl certificate approve`). OIDC and webhook authentication are architecturally dependent on a real external service, which this lab deliberately doesn't stand up; they're covered as theory for that reason.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| CSR generation and approval workflow | Cluster Architecture, Installation & Configuration (25%) | — | A classically CKA-only task ("create a user with a client certificate") — rarely appears on CKAD |
| `kubectl config set-credentials`/`set-context` | Cluster Architecture, Installation & Configuration (25%) | — | Building a working kubeconfig from a signed cert is a common full end-to-end exam task |
| `403` vs `401` distinction | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | Frequently tested as a diagnostic reasoning question, not just a command |
| Authentication method landscape (survey) | Cluster Architecture, Installation & Configuration (25%) | — | Rarely tested in hands-on form; more likely tested as "which method would you use for X" scenario questions |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Create a user with a client certificate and verify access" | Full pipeline: key → CSR → CSR object → approve → extract cert → kubeconfig → RoleBinding | Stopping after certificate approval, forgetting the kubeconfig step is what actually makes the identity usable via `kubectl` |
| Extracting the signed certificate | Confirm `CONDITION: Approved,Issued` first | Extracting `status.certificate` immediately after creating the CSR, before approval — produces an empty/invalid certificate |
| Diagnosing an access failure for a real (non-impersonated) identity | Check the HTTP status distinction (`401` vs `403`) before assuming an RBAC misconfiguration | Assuming every access failure is an RBAC problem, without first confirming authentication actually succeeded |

### Exam Task — Write it from scratch

**Task:** Create a client-certificate identity for a user named `auditor` with Organization `security-team`, get the CSR approved, and build a working kubeconfig context for it.

**Official documentation:**
- [Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/) — the CSR object and approval reference

**What to practise:**
1. `openssl genrsa -out auditor.key 2048`
2. `openssl req -new -key auditor.key -out auditor.csr -subj "/CN=auditor/O=security-team"`
3. Base64-encode and wrap in a `CertificateSigningRequest` with `signerName: kubernetes.io/kube-apiserver-client`
4. `kubectl certificate approve auditor`
5. Extract, build kubeconfig, verify with `kubectl auth can-i` under the new context

<details>
<summary>Reference solution (open only after attempting)</summary>

```bash
openssl genrsa -out auditor.key 2048
openssl req -new -key auditor.key -out auditor.csr -subj "/CN=auditor/O=security-team"
CSR_BASE64=$(cat auditor.csr | base64 | tr -d '\n')
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: auditor
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF
kubectl certificate approve auditor
kubectl get csr auditor -o jsonpath='{.status.certificate}' | base64 -d > auditor.crt
kubectl config set-credentials auditor --client-certificate=auditor.crt --client-key=auditor.key --embed-certs=true
kubectl config set-context auditor-context --cluster=3node --user=auditor
```

**Fields you must know without looking up:**
- `signerName: kubernetes.io/kube-apiserver-client` — the specific signer for client-auth certificates; other signers produce certificates for different purposes entirely
- `usages: [client auth]` — required for the resulting certificate to be valid for authenticating as a client
- `--embed-certs=true` on `set-credentials` — without it, the kubeconfig references file paths rather than embedding the certificate data directly

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| All four AuthN methods produce the same output shape | A username plus a group list — RBAC never knows or cares which method produced them |
| A CSR requires explicit approval | No timeout, no implicit grant from existence alone — `Pending` can mean "working as designed, not yet approved," not necessarily broken |
| `status.certificate` only populates after approval | Extracting it earlier produces an empty/invalid value that a kubeconfig will embed as-is |
| Client certificate `CN` → `User`; every `O` → `Group` | The literal mechanism behind `03`'s claim that Groups are supplied by the authenticator — one certificate can carry multiple `O=` values, joining multiple groups at once |
| `403 Forbidden` proves AuthN already succeeded | A failed authentication produces `401 Unauthorized` and never reaches Authorization at all — `403` specifically means identity was accepted, then denied afterward |
| Approving a CSR is itself RBAC-gated | Requires `approve` on `certificatesigningrequests/approval` — the same subresource pattern from `01`/`02`, now exercised directly |
| The private key never leaves the requester's machine | Only the CSR (containing the public key, signed by the private key) is ever submitted to the cluster |
| `signerName` determines what a resulting certificate can be used for | `kubernetes.io/kube-apiserver-client` is specific to client authentication — not a formality, a functional constraint |

> **Demo scope:** Primary concept: the client-certificate identity pipeline (key → CSR → approval → kubeconfig). Supporting concepts: the four-method AuthN landscape (survey only for three of them), the 403 e2e proof.
> Estimated completion time: 65–70 minutes — flagged at the §0b sizing check as borderline-high; kept as one demo per prior agreed scope, since the pipeline itself is not meaningfully splittable.
> Checkpoints: 2 natural stopping points — after Step 4 (kubeconfig built, 403 proven, before any RoleBinding exists) and after Step 5 (both User and Group grants verified, before cleanup).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `openssl req -new -key <key> -out <csr> -subj "/CN=<user>/O=<group>"` | Generates a CSR with the identity claims that become the RBAC `User`/`Group` |
| `kubectl certificate approve <name>` | Approves a pending `CertificateSigningRequest` |
| `kubectl get csr <name> -o jsonpath='{.status.certificate}' \| base64 -d` | Extracts the signed certificate after approval |
| `kubectl config set-credentials <name> --client-certificate=<crt> --client-key=<key> --embed-certs=true` | Adds a credential entry to the kubeconfig |
| `kubectl config set-context <name> --cluster=<cluster> --user=<user>` | Creates a usable context tying the credential to a cluster |
| `kubectl --context=<name> <command>` | Runs any command as that context's identity, without switching the current default context |

### Generating YAML skeletons with --dry-run

This demo's primary object, `CertificateSigningRequest`, has no imperative `kubectl create` equivalent at all — it must always be hand-written or templated, since its `spec.request` field is a base64-encoded CSR that no imperative flag can generate for you.

**Supported — the Role/RoleBinding portion reused from `01`:**
```bash
kubectl create role NAME --verb=get,list,watch --resource=pods --dry-run=client -o yaml
kubectl create rolebinding NAME --role=ROLE --user=USER --dry-run=client -o yaml
```

**Not supported:** `CertificateSigningRequest` object creation (always hand-authored or templated), `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| RoleBinding | `kubectl create rolebinding NAME --role=ROLE --user=USER -n NAMESPACE` | Reused from `01`; nothing new for this demo |

`CertificateSigningRequest` is intentionally absent from this table — there is no imperative creation path for it in any form.

---

## Troubleshooting

**A CSR stays `Pending` indefinitely:**
```bash
kubectl get csr <name>
```
```
# Cause: nobody has approved it — there's no timeout or implicit grant
#        from existence alone.
# Fix: kubectl certificate approve <name>
```

**kubeconfig produces a TLS/certificate parsing error:**
```bash
kubectl --context=<name> get pods
```
```
# Cause: the certificate was likely extracted before approval completed,
#        producing an empty or invalid file that got embedded as-is.
# Fix: Confirm `kubectl get csr <name>` shows Approved,Issued, then
#      re-extract and rebuild the credential entry.
```

**A real (non-impersonated) identity gets `403` and you're not sure if it's an AuthN or AuthZ problem:**
```
# Cause/Fix: Check the HTTP status specifically. 401 = AuthN failed,
#            never reached RBAC. 403 = AuthN succeeded, RBAC denied.
#            This determines whether you're debugging a certificate/token
#            problem or a missing Role/RoleBinding.
```

---

## Appendix — Anki Cards

**`05-authentication-methods-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::05-authentication-methods
#separator:Comma
#columns:Front,Back,Tags
"What four real-world methods can establish a Kubernetes identity, and what do they all produce as output?","Client certificates, ServiceAccount tokens, OIDC, and webhook token authentication — all four produce the same shape of output regardless of method: a username plus a group list, handed to Authorization.","authentication-methods,authn-landscape,cka-cluster-architecture-installation-configuration"
"In a client certificate's Subject, what field becomes the RBAC User, and what becomes a Group?","The Common Name (CN=) becomes the User subject's name. Every Organization field (O=) present becomes a Group the identity is a member of — a certificate can carry multiple O= values, joining multiple groups at once.","authentication-methods,client-certificates,groups,cka-cluster-architecture-installation-configuration"
"Does a CertificateSigningRequest take effect just by existing, the way most Kubernetes objects do?","No. It requires an explicit approval action (kubectl certificate approve) from someone with the approve permission on certificatesigningrequests/approval — there's no timeout or implicit grant from existence alone.","authentication-methods,csr,approval,cka-cluster-architecture-installation-configuration"
"When does a CSR's status.certificate field actually populate?","Only after approval — kubectl certificate approve triggers the cluster to sign and populate it. Extracting it before approval returns an empty or invalid value.","authentication-methods,csr,cka-troubleshooting"
"What HTTP status code does a failed/invalid client certificate produce, and does the request ever reach RBAC?","401 Unauthorized — the request never reaches the Authorization stage at all; RBAC is never consulted when AuthN itself fails.","authentication-methods,401-vs-403,cka-troubleshooting"
"What does a 403 Forbidden response prove about the authentication stage, specifically?","That AuthN already succeeded. A 403 means the identity was accepted and the request proceeded to Authorization, which then denied it — a failed authentication would produce 401 instead, never reaching this point.","authentication-methods,401-vs-403,cka-troubleshooting,ckad-application-environment-configuration-security"
"What does the signerName field on a CertificateSigningRequest actually control?","What the resulting certificate can be used for. kubernetes.io/kube-apiserver-client produces a certificate valid for authenticating as a client to the API server — other signers (e.g. for kubelet serving certificates) produce certificates for entirely different purposes.","authentication-methods,csr,signername,cka-cluster-architecture-installation-configuration"
"Does the private key ever get submitted to the Kubernetes cluster during the CSR pipeline?","No. Only the CSR — containing the public key and identity claims, signed by the private key to prove possession — is submitted. The private key stays on the requester's machine throughout.","authentication-methods,csr,private-key,cka-cluster-architecture-installation-configuration"
"Does RBAC behave any differently for a subject authenticated via OIDC versus one authenticated via client certificate?","No. Both produce the identical output shape (username + group list) that Authorization consumes — RBAC has no visibility into which AuthN method produced the identity it's evaluating.","authentication-methods,authn-landscape,rbac-independence,cka-cluster-architecture-installation-configuration"
"What does --embed-certs=true do on kubectl config set-credentials, and what happens without it?","It embeds the certificate/key data directly inside the kubeconfig file. Without it, the kubeconfig instead references external file paths, which breaks if those files move or are deleted.","authentication-methods,kubeconfig,imperative-commands,cka-cluster-architecture-installation-configuration"
"Is there an imperative kubectl create command for a CertificateSigningRequest?","No. spec.request is a base64-encoded CSR that no imperative flag can generate — the object must always be hand-authored or templated from a real openssl-generated CSR.","authentication-methods,csr,imperative-commands,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`05-authentication-methods-quiz.md`:**

````markdown
# Quiz — 12-rbac/05-authentication-methods: Establishing Real Identity

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. In a client certificate with Subject `/CN=jane/O=platform-team`, what RBAC subjects does this identity carry?**

- A) `User: jane` only — Organization fields are ignored by RBAC
- B) `User: jane` and `Group: platform-team`
- C) `Group: jane` and `User: platform-team`
- D) Neither — client certificates require a separate mapping file

<details>
<summary>Answer</summary>

**B** — `CN` maps to `User`, `O` maps to `Group`. Both are usable independently in a `RoleBinding`'s `subjects`.
Trap: A wrongly discards the Organization field. C reverses the actual mapping.

</details>

---

**Q2. A `CertificateSigningRequest` has existed for two hours with `CONDITION: Pending`. Is this necessarily a misconfiguration?**

- A) Yes — CSRs auto-approve within minutes if functioning correctly
- B) Not necessarily — CSRs require an explicit approval action, with no timeout or implicit grant from existence alone
- C) Yes — `Pending` for more than 5 minutes always indicates a broken signer
- D) No, but only if `usages` includes `client auth`

<details>
<summary>Answer</summary>

**B** — Unlike most objects covered in this series, a CSR doesn't take effect from existing — it genuinely waits for someone with `approve` permission to act on it. Extended `Pending` time is often just "not yet approved," not broken.
Trap: A and C both invent a timeout or auto-approval behavior that doesn't exist by default.

</details>

---

**Q3. A client certificate fails validation. What HTTP status code results, and does the request reach RBAC?**

- A) `403 Forbidden`; RBAC evaluates and denies it
- B) `401 Unauthorized`; the request never reaches the Authorization stage
- C) `500 Internal Server Error`; RBAC is bypassed entirely
- D) `403 Forbidden`; RBAC is never consulted

<details>
<summary>Answer</summary>

**B** — A failed authentication produces `401`, and the request stops there — Authorization (RBAC) is never reached at all.
Trap: A and D both attach the wrong status code to a failed-AuthN scenario — `403` is reserved for requests that passed AuthN and failed at AuthZ.

</details>

---

**Q4. What does getting a `403 Forbidden` (rather than `401`) prove about a request?**

- A) Nothing — both status codes are used interchangeably
- B) That authentication already succeeded — the request reached Authorization and was denied there
- C) That the certificate has expired
- D) That the requested resource doesn't exist

<details>
<summary>Answer</summary>

**B** — `403` specifically means AuthN succeeded and AuthZ denied the request afterward — this is the direct proof this demo builds hands-on.
Trap: C and D both invent unrelated causes for a status code that specifically indicates an Authorization-stage denial.

</details>

---

**Q5. Does binding a `RoleBinding` to `Group: platform-team` (from a certificate's `O=` field) require any special ServiceAccount-style object to represent the group?**

- A) Yes — a `Group` API object must be created first
- B) No — `Group`, like `User`, has no backing API object; it's a string supplied entirely by the authenticator
- C) Only if the group name starts with `system:`
- D) Yes, but only for client-certificate-derived groups specifically

<details>
<summary>Answer</summary>

**B** — Consistent with `03`: neither `User` nor `Group` has a backing API object. The certificate's `O=` field supplies the group string directly; RBAC just matches against it.
Trap: A and D both invent an object-creation requirement that doesn't exist for any Group, regardless of which AuthN method produced it.

</details>

---

**Q6. Is there an imperative `kubectl create` command for generating a `CertificateSigningRequest` object, the way there is for `Role` or `RoleBinding`?**

- A) Yes — `kubectl create csr`
- B) No — `spec.request` is a base64-encoded real CSR that must come from an actual key-generation tool first; the object is always hand-authored or templated
- C) Yes, but only with `--dry-run=client`
- D) No — CSRs can only be created through the Kubernetes dashboard

<details>
<summary>Answer</summary>

**B** — Unlike `Role`/`RoleBinding`, there's no imperative shortcut, because the object's core content (`spec.request`) requires a real CSR generated outside `kubectl` entirely (via `openssl` or equivalent).
Trap: A invents a command that doesn't exist. D introduces an unrelated and also-incorrect restriction.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 6/6 | Import Anki cards, move to 06-service-accounts-rbac |
| 5/6 | Review the wrong answer, then proceed |
| 4/6 | Re-read the relevant section, retry those questions |
| Below 4/6 | Re-read the full demo and redo the walkthrough before proceeding |
````