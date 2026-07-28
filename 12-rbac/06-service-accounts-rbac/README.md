# Demo: 12-rbac/06-service-accounts-rbac — Binding RBAC to Workload Identity

## Lab Overview

`01` through `05` all granted access to identities *outside* the cluster — a `User` (impersonated, then real via a client certificate), a `Group`. `01`'s Subjects concept flagged the one subject kind deliberately left untested: `ServiceAccount`, the only one that's a genuine, first-class Kubernetes API object, and the one that matters for workloads running *inside* the cluster authenticating to the API server. This demo closes that gap.

**Real-world scenario:** You're running a small custom monitoring agent — a Pod in an `agents` namespace — that needs to watch Pod status across the `ci` namespace from earlier in this series, for a dashboard. It's a workload, not a human, so it needs a `ServiceAccount` identity, not a certificate or an impersonated `User`. And it needs cross-namespace access — the agent lives in `agents`, but the Pods it watches live in `ci` — which means the RoleBinding granting that access has to reference a ServiceAccount from a *different* namespace than the one it's created in.

**What this lab covers:**
- ServiceAccount as a real API object: creating one, and what "real" actually buys you over a `User`
- Token mechanics: projected, audience-bound tokens (the modern default) vs. the deprecated long-lived Secret-based pattern, and the `serviceaccounts/token` subresource behind it
- The per-namespace default ServiceAccount every Pod gets if you don't specify one, and `automountServiceAccountToken`
- Binding a Role to a ServiceAccount **across namespaces** — the RoleBinding lives where the Role lives, not where the ServiceAccount lives
- Testing the identity for real: exec into the Pod and use its actual mounted token, not just `--as` impersonation

> **Scope note:** This lab does not cover `ClusterRole`-scoped ServiceAccount bindings (e.g. granting a ServiceAccount access across every namespace) — the mechanics are identical to `04`'s binding matrix, just with a `ServiceAccount` subject instead of `User`/`Group`, so it isn't repeated here. It does not cover OIDC/webhook-authenticated workload identity (e.g. IRSA-style patterns on managed cloud) — out of scope for this cluster.

---

## Prerequisites

**Required Software:**
- minikube `3node` profile — control plane + 2 workers, already running from earlier topic groups
- kubectl v1.35.x (matched to cluster version)

**Verify before starting:**
```bash
kubectl get nodes
```

**Knowledge Requirements:**
- **REQUIRED:** `12-rbac/01-rbac-fundamentals` (Role/RoleBinding, Subjects concept), `12-rbac/05-authentication-methods` (the four AuthN methods landscape — ServiceAccount tokens were named there, not detailed)

---

## Lab Objectives

By the end of this lab, you will be able to:

1. ✅ Create a `ServiceAccount` and explain what makes it different from a `User` beyond "it's a real object"
2. ✅ Explain the modern projected-token model and why it replaced long-lived Secret-based tokens
3. ✅ Bind a Role to a ServiceAccount from a **different** namespace than the Role itself
4. ✅ Verify a ServiceAccount's access two ways — impersonation and a real mounted token from inside a Pod — and know when each is appropriate
5. ✅ Diagnose and fix three common ServiceAccount/RBAC misconfigurations from symptoms alone

---

## Directory Structure

```
12-rbac/06-service-accounts-rbac/
├── README.md
├── 06-service-accounts-rbac-anki.csv
├── 06-service-accounts-rbac-quiz.md
└── src/
    ├── 01-namespace-agents.yaml               # where the agent Pod and its ServiceAccount live
    ├── 02-serviceaccount-pod-watcher.yaml       # the ServiceAccount identity
    ├── 03-pod-with-sa.yaml                      # a Pod using that ServiceAccount, for real testing
    ├── 04-namespace-ci.yaml                     # reused pattern from 01-rbac-fundamentals
    ├── 05-role-pod-reader.yaml                  # the Role, defined in ci (the TARGET namespace)
    ├── 06-rolebinding-cross-namespace.yaml       # binds it to the agents-namespace ServiceAccount
    └── break-fix/
        ├── 01-rolebinding-wrong-sa-namespace.yaml
        ├── 02-role-in-wrong-namespace.yaml
        └── 03-automount-false-assumption.yaml
```

---

## Recall Check — 05-authentication-methods

Answer from memory before continuing — no peeking at the previous demo.

1. What HTTP status code does a failed client certificate produce, and does the request ever reach RBAC?
2. In a client certificate's Subject, what field becomes the `User`, and what becomes a `Group`?
3. Does a `CertificateSigningRequest` take effect just by existing?

<details>
<summary>Answers</summary>

1. `401 Unauthorized` — the request never reaches the Authorization stage at all; RBAC is never consulted when AuthN itself fails.
2. Common Name (`CN=`) becomes the `User`; every Organization field (`O=`) becomes a `Group` the identity is a member of.
3. No — it requires an explicit `kubectl certificate approve` action; there's no timeout or implicit grant from existence alone.

</details>

---

## Concepts

### ServiceAccount — the One Subject Kind That's a Real API Object

**What it is:** Named in `01`'s Subjects concept and set aside until now: `ServiceAccount` is the only RBAC subject kind backed by a genuine, first-class Kubernetes API object — `kubectl get serviceaccounts` works, `kubectl describe serviceaccount <name>` works, it has a `metadata.namespace`, a lifecycle, and Kubernetes itself issues and can revoke its credential material.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-watcher
  namespace: agents
```

- **Why "real object" matters practically:** a `User` is just a string RBAC trusts an external authenticator to have vouched for — there's nothing to `kubectl get`, nothing to audit as an object with its own history, nothing Kubernetes itself can revoke short of revoking the underlying certificate/token issuance at the authenticator level. A `ServiceAccount` can be deleted directly, immediately invalidating every token issued for it — a fundamentally different (and, for in-cluster workloads, more manageable) trust model.
- **The username a ServiceAccount produces:** every ServiceAccount authenticates as `system:serviceaccount:<namespace>:<name>` — this is the exact string used for `--as` impersonation and for `resourceNames`/subject matching, and it's why the namespace is baked into the identity itself, not just metadata about it.
- **Every ServiceAccount is automatically a member of two groups:** `system:serviceaccounts` (every ServiceAccount in the cluster, in any namespace) and `system:serviceaccounts:<namespace>` (every ServiceAccount in that one namespace specifically) — both usable as `Group` subjects in a RoleBinding, for granting access to "any workload in this namespace" without naming individual ServiceAccounts.

### Token Mechanics — Projected Tokens vs. the Deprecated Secret Pattern

**What it is:** How a Pod actually obtains and presents its ServiceAccount's credential to the API server — this has changed significantly across Kubernetes versions.

- **Modern default — projected, bound service account tokens:** since Kubernetes 1.22+, tokens are generated on-demand via the `TokenRequest` API, mounted into the Pod as a projected volume, **time-limited** (default one hour, auto-refreshed by the kubelet), and **audience-bound** (valid only for the specific API server that requested it, not replayable elsewhere). This is what `automountServiceAccountToken` (below) controls the mounting of.
- **Legacy pattern — long-lived Secret-based tokens (deprecated):** older clusters auto-created a `Secret` per ServiceAccount containing a token with no expiration at all — a credential that, once leaked, was valid forever until manually revoked. This pattern still works for compatibility but is no longer the default, and creating new long-lived tokens requires deliberately setting an annotation to opt back into it.
- **The `serviceaccounts/token` subresource is the mechanism behind the modern approach** — first surfaced in `02`'s subresource discovery (`kubectl get --raw /api/v1 | jq` listed it directly). `kubectl create token <serviceaccount-name>` uses exactly this subresource to mint a fresh, time-limited token on demand, outside of any Pod at all — useful for testing without needing to exec into anything.
- **RBAC relevance:** granting `create` on `serviceaccounts/token` for a given ServiceAccount is itself a sensitive permission — it lets the grantee mint a working credential *as* that ServiceAccount, which is functionally equivalent to granting everything that ServiceAccount can do. Treat it with the same care as granting `impersonate`.

### The Default ServiceAccount and `automountServiceAccountToken`

**What it is:** Every namespace gets a ServiceAccount named `default` automatically — if a Pod's spec doesn't specify `serviceAccountName`, it uses this one, silently.

- **Why this matters for least privilege:** a Pod that never explicitly declares a ServiceAccount still gets one mounted and usable — the `default` ServiceAccount, which in a freshly-created namespace has no RBAC grants at all (safe), but if anyone has ever bound a Role to `default` in that namespace for convenience, every Pod in it inherits that access silently, whether it needs it or not.
- **`automountServiceAccountToken: false`** (settable on the ServiceAccount itself, or overridden per-Pod) stops the token from being mounted into the Pod's filesystem at all — appropriate for Pods that never call the Kubernetes API, removing a credential they never needed in the first place.

### Cross-Namespace Binding — the RoleBinding Lives Where the Role Lives

**What it is:** A `RoleBinding`'s own namespace determines which Role it can reference (per `01`) — but its `subjects` list can name a `ServiceAccount` from **any** namespace, not just its own.

```yaml
subjects:
- kind: ServiceAccount
  name: pod-watcher
  namespace: agents          # the ServiceAccount's OWN namespace — different from the RoleBinding's
```

- **Why this is different from `01`'s namespace-scoping rule:** the Role and RoleBinding still must share a namespace (that rule is unchanged) — what's new is that the *subject being granted access* doesn't have to live in that same namespace. This is exactly how a monitoring agent in one namespace gets granted access to resources in another: the RoleBinding lives in the target namespace (`ci`, where the Role is), and its subject points across to the agent's actual namespace (`agents`).
- **Worked example, decoded:** `subjects: [{kind: ServiceAccount, name: pod-watcher, namespace: agents}]` inside a RoleBinding created in `ci` grants `pod-watcher` (which lives in, and whose Pods run in, `agents`) exactly the access that `ci`'s Role defines — nothing about the ServiceAccount's own namespace changes what it's granted; only the RoleBinding's namespace and the Role it references matter for that.

---

## Lab Step-by-Step Guide

This lab builds in two halves that mirror each other deliberately: first the identity (ServiceAccount, Pod using it), then the grant (Role in a different namespace, cross-namespace RoleBinding) — followed by verifying the same access two different ways, impersonation and a real mounted token, to see directly whether they agree.

---

### Step 1 — Create the Agent's Namespace, ServiceAccount, and Pod

Set up the identity side first — the agent and what it authenticates as, before it has any permissions at all.

**`src/01-namespace-agents.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agents
```

**`src/02-serviceaccount-pod-watcher.yaml`:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-watcher
  namespace: agents
```

**`src/03-pod-with-sa.yaml`:**

A minimal Pod that explicitly uses this ServiceAccount, with `kubectl` installed so we can test from inside it later:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: agent
  namespace: agents
spec:
  serviceAccountName: pod-watcher    # explicit — never rely on the implicit "default" SA
  containers:
  - name: agent
    image: bitnami/kubectl:1.30      # ships kubectl already installed, for Step 4's real-token test
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f src/01-namespace-agents.yaml
kubectl apply -f src/02-serviceaccount-pod-watcher.yaml
kubectl apply -f src/03-pod-with-sa.yaml
kubectl -n agents get pod agent
```
```
⚠️ [VERIFY]
```
```
# Observation: this Pod exists with zero RBAC grants right now — Steps 2-3
# create the Role and cross-namespace RoleBinding it needs.
```

---

### Step 2 — Confirm the Default-Deny Baseline

Before granting anything, confirm this ServiceAccount genuinely starts with nothing — the same default-deny baseline from `01`, now checked against a real workload identity instead of an impersonated one.

```bash
kubectl auth can-i get pods -n ci --as=system:serviceaccount:agents:pod-watcher
```
```
⚠️ [VERIFY]
no
```

---

### Step 3 — Create the Target Role and Cross-Namespace RoleBinding

The Role lives where the resources being watched live (`ci`); the RoleBinding also lives there, but its subject reaches across to the agent's actual namespace.

**`src/04-namespace-ci.yaml`:**

Reused pattern from `01-rbac-fundamentals` (create if not already present from an earlier demo in this session).

**`src/05-role-pod-reader.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: ci                  # lives where the Pods being watched live
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

**`src/06-rolebinding-cross-namespace.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agents-pod-watcher-pod-reader
  namespace: ci                  # matches the Role's namespace, per 01's rule — unchanged
subjects:
- kind: ServiceAccount
  name: pod-watcher
  namespace: agents               # the SUBJECT's namespace — different, and that's the point
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f src/04-namespace-ci.yaml
kubectl apply -f src/05-role-pod-reader.yaml
kubectl apply -f src/06-rolebinding-cross-namespace.yaml
kubectl -n ci describe rolebinding agents-pod-watcher-pod-reader
```
```
⚠️ [VERIFY]
```
```
# Observation: expect the Subjects table to show Kind: ServiceAccount,
# Name: pod-watcher, Namespace: agents — the one case (per 01's Subjects
# concept) where the Namespace column in a RoleBinding's subject table
# is actually populated, since ServiceAccount is the one subject kind
# with a real namespace of its own.
```

---

### Step 4 — Verify Two Ways: Impersonation, Then the Real Mounted Token

Impersonation is fast and doesn't require a running Pod; the real token is the actual mechanism a workload uses. Both should agree — checking that they do is the point.

**Impersonation, same pattern as every prior demo:**
```bash
kubectl auth can-i get pods -n ci --as=system:serviceaccount:agents:pod-watcher
```
```
⚠️ [VERIFY]
yes
```

**The real thing — exec into the Pod and use its actual mounted, projected token:**
```bash
kubectl -n agents exec -it agent -- kubectl get pods -n ci
```
```
⚠️ [VERIFY]
```
```
# Observation: no --as, no impersonation flag anywhere — this kubectl
# invocation, running INSIDE the Pod, authenticates using the projected
# token Kubernetes mounted automatically because Step 1's Pod spec named
# serviceAccountName: pod-watcher. If this succeeds and matches the
# impersonation check above, that's real confirmation the RBAC grant
# and the actual in-cluster credential mechanism agree — not just that
# a can-i prediction says so.
```

**Confirm the mounted token's location and audience-bound nature directly:**
```bash
kubectl -n agents exec -it agent -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl -n agents exec -it agent -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```
```
⚠️ [VERIFY]
ca.crt  namespace  token
```
```
# Observation: this is the projected volume from Concepts, mounted
# automatically — a JWT (token), the cluster's CA cert (ca.crt, so the
# Pod can verify the API server without extra config), and the Pod's
# own namespace (namespace) as a plain file. No Secret object needed
# anywhere for this to work — this is the modern, non-Secret-based path.
```

---

### Step 5 — Cleanup

**(a) Demo-scoped resources:** the `agents` namespace (Pod, ServiceAccount) and the `ci` namespace (Role, RoleBinding) stay in place — Break-Fix reuses this state; full teardown happens once, at the end of Break-Fix.

**(b) Cluster-scoped shared components:** none installed in this demo.

> **Stopping here without continuing to Break-Fix in this session?** Tear down manually:
> ```bash
> kubectl delete namespace agents --ignore-not-found
> kubectl delete namespace ci --ignore-not-found
> ```

---

## What You Learned

- ✅ Created a `ServiceAccount` and explained what makes it a real API object, unlike `User`
- ✅ Explained the modern projected-token model vs. the deprecated long-lived Secret pattern
- ✅ Bound a Role to a ServiceAccount from a different namespace than the Role itself
- ✅ Verified access two ways — impersonation and a real mounted token from inside a Pod — and confirmed they agree
- ✅ Diagnosed and fixed three ServiceAccount/RBAC misconfigurations from symptoms alone

**Key Takeaway:** A ServiceAccount is the one RBAC subject kind Kubernetes itself creates, issues credentials for, and can revoke directly — everything else in this series (`User`, `Group`) is a string RBAC trusts some external authenticator to have already vouched for. Cross-namespace binding means the Role and RoleBinding still share a namespace (unchanged from `01`), but the *subject* granted access can live anywhere — which is exactly how in-cluster workloads get scoped access to resources outside their own namespace without needing a broader, riskier grant.

---

## Break-Fix

Three scenarios below. Diagnose from the symptom command output alone before opening the reveal.

**Restore known-good state before starting** (skip this if continuing directly from Step 4):
```bash
kubectl apply -f ../01-namespace-agents.yaml
kubectl apply -f ../02-serviceaccount-pod-watcher.yaml
kubectl apply -f ../03-pod-with-sa.yaml
kubectl apply -f ../04-namespace-ci.yaml
kubectl apply -f ../05-role-pod-reader.yaml
kubectl apply -f ../06-rolebinding-cross-namespace.yaml
```
```bash
cd src/break-fix/
```

### Error-1 — the ServiceAccount's namespace is wrong in the RoleBinding

**`src/break-fix/01-rolebinding-wrong-sa-namespace.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agents-pod-watcher-pod-reader
  namespace: ci
subjects:
- kind: ServiceAccount
  name: pod-watcher
  namespace: ci                  # wrong — pod-watcher actually lives in "agents"
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 01-rolebinding-wrong-sa-namespace.yaml
kubectl auth can-i get pods -n ci --as=system:serviceaccount:agents:pod-watcher
```
```
⚠️ [VERIFY]
rolebinding.rbac.authorization.k8s.io/agents-pod-watcher-pod-reader configured
no
```

The apply succeeded — RoleBinding subjects don't require the named ServiceAccount to actually exist in the stated namespace. Why does the real agent still get denied?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** The `subjects[].namespace` field is just a string, matched exactly against the requesting identity's `system:serviceaccount:<namespace>:<name>` — there's no existence check against a real ServiceAccount at apply time, the same lazy-evaluation pattern from `01`'s `roleRef`. This binding now grants access to a ServiceAccount named `pod-watcher` *in `ci`* (which may not even exist), not the real one in `agents`.

**Fix:** Correct `subjects[].namespace` to `agents`.

**Cascade:** A single wrong character in a namespace field silently redirects an entire grant to a different (possibly nonexistent) identity — with no error anywhere in the pipeline, the same silent-failure shape as every `roleRef`/`apiGroups` typo earlier in this series, just on a different field.

</details>

**Cleanup:**
```bash
kubectl apply -f ../06-rolebinding-cross-namespace.yaml
```

---

### Error-2 — the Role is defined in the wrong namespace

**`src/break-fix/02-role-in-wrong-namespace.yaml`:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: agents               # wrong — should be "ci", where the target Pods actually live
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f 02-role-in-wrong-namespace.yaml
kubectl auth can-i get pods -n ci --as=system:serviceaccount:agents:pod-watcher
```
```
⚠️ [VERIFY]
role.rbac.authorization.k8s.io/pod-reader created
no
```

A Role named `pod-reader` now exists, with exactly the right rules. Why is access to `ci` Pods still denied?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** This creates a *second, separate* `pod-reader` Role — in `agents`, not `ci` — that has nothing to do with the existing `ci`-namespace Role the RoleBinding actually references. A Role's `metadata.namespace` determines where its grant applies (per `01`); a same-named Role in a different namespace is a completely different object, invisible to a RoleBinding that lives in (and is scoped to) `ci`.

**Fix:** Delete this Role from `agents` (it grants nothing useful there) — the correct `pod-reader` Role already exists in `ci` from Step 3 and was never actually broken.

**Cascade:** Same-named objects in different namespaces are fully independent in Kubernetes — this is a reminder that "the Role exists" is never sufficient without also confirming *which namespace*, especially in a cross-namespace-subject setup like this demo's, where it's easy to lose track of which namespace a given object is supposed to live in.

</details>

**Cleanup:**
```bash
kubectl delete role pod-reader -n agents --ignore-not-found
```

---

### Error-3 — `automountServiceAccountToken: false` silently removes the token

**`src/break-fix/03-automount-false-assumption.yaml`:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: agent-no-token
  namespace: agents
spec:
  serviceAccountName: pod-watcher
  automountServiceAccountToken: false   # BUG: the agent needs to call the API — this removes its credential
  containers:
  - name: agent
    image: bitnami/kubectl:1.30
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f 03-automount-false-assumption.yaml
kubectl -n agents exec -it agent-no-token -- kubectl get pods -n ci
```
```
⚠️ [VERIFY]
pod/agent-no-token created
error: no configuration has been provided, try setting KUBERNETES_MASTER environment variable
```

The RoleBinding from Step 3 still exists and is still correct — the exact same grant that worked for `agent` in Step 4. Why does this Pod fail differently, not even reaching an RBAC decision?

<details>
<summary>Reveal answer — attempt diagnosis first</summary>

**Cause:** `automountServiceAccountToken: false` stops the projected token volume from being mounted into the Pod at all. There's no credential file anywhere in the container's filesystem for `kubectl` to even attempt authenticating with — this fails before AuthN, let alone AuthZ, which is why the error looks nothing like a `Forbidden` response; `kubectl` inside the Pod has no cluster configuration to work with in the first place.

**Fix:** Remove `automountServiceAccountToken: false` (or set it `true` explicitly) if the Pod genuinely needs to call the API — which this one does, by design.

**Cascade:** This is a different failure category from every RBAC misconfiguration elsewhere in this demo/series — it's not a permissions problem at all, it's a missing-credential problem, one layer earlier than AuthZ or even AuthN. Worth recognizing the error shape so it isn't mistaken for a Role/RoleBinding issue and debugged in the wrong place.

</details>

**Cleanup — full teardown (end of Break-Fix):**
```bash
kubectl delete pod agent-no-token -n agents --ignore-not-found
kubectl delete namespace agents --ignore-not-found
kubectl delete namespace ci --ignore-not-found
cd ../..
```

---

## Interview Prep

**Q1. What's the practical difference between a `User` and a `ServiceAccount` that matters for revoking access quickly?**
A `ServiceAccount` is a real API object — deleting it (or its projected tokens becoming invalid) directly and immediately cuts off access, something Kubernetes itself controls. A `User` has no backing object at all; revoking a `User`'s access means revoking whatever external credential (certificate, OIDC session) the authenticator issued, which Kubernetes itself has no direct control over — that's the authenticator's responsibility, not the API server's.

**Q2. Why did Kubernetes move away from long-lived, Secret-based ServiceAccount tokens toward the projected-token model?**
Long-lived tokens had no expiration — a leaked one was valid indefinitely until someone manually noticed and revoked it. Projected tokens are time-limited (auto-refreshed by the kubelet, typically hourly) and audience-bound (valid only for the specific API server that requested them), which drastically shrinks the blast radius of a leaked token compared to a credential that, once out, worked forever, anywhere it was presented.

**Q3. A RoleBinding created in namespace `ci` has a subject naming a ServiceAccount in namespace `agents`. Is this valid, and what does it actually grant?**
Valid — a RoleBinding's `subjects` can reference a ServiceAccount from any namespace, even though the RoleBinding itself must share a namespace with the Role it references (that part is unchanged from `01`). It grants exactly what `ci`'s Role defines, to the `agents`-namespace ServiceAccount specifically — this is the standard pattern for letting a workload in one namespace access resources in another without a broader, cluster-wide grant.

**Q4. A Pod fails to authenticate to the API server entirely — not a `Forbidden`, but an error suggesting no cluster configuration exists. RBAC looks correctly configured. What's the likely cause?**
Check `automountServiceAccountToken` on the ServiceAccount or the Pod spec. If it's `false`, no token gets mounted into the Pod at all — there's no credential for `kubectl` (or any client) to authenticate with, so the failure happens before AuthN is even attempted, not at the Authorization stage RBAC governs. This produces a fundamentally different error shape than any RBAC misconfiguration.

**Q5. Why is granting `create` on `serviceaccounts/token` for a given ServiceAccount considered a sensitive permission, comparable to `impersonate`?**
It lets the grantee mint a fresh, valid token *as* that ServiceAccount on demand — functionally equivalent to being able to act as that ServiceAccount for anything it's permitted to do. Granting this permission broadly is effectively granting everything that ServiceAccount's own RBAC bindings allow, to whoever holds this one narrower-looking permission.

---

## CKA/CKAD Certification Tips

### Exam Objective Mapping

| Demo concept / command | CKA objective | CKAD objective | Notes |
|---|---|---|---|
| ServiceAccount creation and binding | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | CKAD leans heavily on this — workload identity is a core app-configuration skill |
| `system:serviceaccount:<ns>:<name>` impersonation | Troubleshooting (30%) | Application Environment, Configuration and Security (25%) | Exact string format is commonly required verbatim in exam tasks |
| Cross-namespace RoleBinding subjects | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | A frequently-missed valid pattern — many assume RoleBinding subjects must share its namespace |
| `automountServiceAccountToken` | Application Environment, Configuration and Security (25%) | — | Security-hardening exam tasks often require disabling this explicitly |
| `kubectl create token` | Cluster Architecture, Installation & Configuration (25%) | Application Environment, Configuration and Security (25%) | Fast way to get a testable token without execing into a Pod |

### Common Exam Traps

| Scenario | What the task actually requires | Common wrong approach |
|---|---|---|
| "Grant a Pod in namespace X access to resources in namespace Y" | Role in `Y`, RoleBinding in `Y` with a `ServiceAccount` subject naming namespace `X` | Assuming the RoleBinding must live in the Pod's own namespace |
| Verifying ServiceAccount access without a running Pod | `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<name>` | Believing a real Pod must be exec'd into just to test a permission |
| "Harden this Pod to not call the API" | `automountServiceAccountToken: false` on the Pod or ServiceAccount | Relying on RBAC alone (an empty Role) — leaves a mounted, usable token in place even if nothing is currently granted |
| Testing a ServiceAccount's token quickly | `kubectl create token <sa-name> -n <namespace>` | Manually execing into a Pod and reading the projected token file when a direct token mint would do |

### Exam Task — Write it from scratch

**Task:** Create a ServiceAccount `deployer` in namespace `apps`, and grant it `get`/`list`/`watch` on Deployments in namespace `prod` — a genuine cross-namespace grant.

**Official documentation:**
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) — subject field reference, including `ServiceAccount`

**What to practise:**
1. `kubectl create serviceaccount deployer -n apps`
2. Generate the Role skeleton in `prod`: `kubectl create role deployment-reader -n prod --verb=get,list,watch --resource=deployments --dry-run=client -o yaml > task.yaml`
3. Generate the cross-namespace RoleBinding: `kubectl create rolebinding deployer-deployment-reader -n prod --role=deployment-reader --serviceaccount=apps:deployer --dry-run=client -o yaml >> task.yaml`
4. Apply and verify with `kubectl auth can-i get deployments -n prod --as=system:serviceaccount:apps:deployer`

<details>
<summary>Reference solution (open only after attempting)</summary>

```bash
kubectl create serviceaccount deployer -n apps
```
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployment-reader
  namespace: prod
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-deployment-reader
  namespace: prod
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: apps
roleRef:
  kind: Role
  name: deployment-reader
  apiGroup: rbac.authorization.k8s.io
```

**Fields you must know without looking up:**
- `--serviceaccount=apps:deployer` on `kubectl create rolebinding` — the `namespace:name` colon-separated format, distinct from `--user=`/`--group=`
- The RoleBinding's own `metadata.namespace` is `prod` (matching the Role), not `apps` (the ServiceAccount's namespace) — the single most common mistake in this exact task shape
- `system:serviceaccount:apps:deployer` for `--as` verification — colon-separated, not slash-separated

</details>

---

## Key Takeaways

| Concept | Detail |
|---|---|
| `ServiceAccount` is the only subject kind backed by a real API object | Kubernetes itself creates, issues credentials for, and can revoke it directly — `User`/`Group` are external, authenticator-supplied strings only |
| A ServiceAccount authenticates as `system:serviceaccount:<namespace>:<name>` | This exact string is what `--as` impersonation and subject matching both use |
| Every ServiceAccount belongs to `system:serviceaccounts` and `system:serviceaccounts:<namespace>` | Usable as `Group` subjects for granting access to every workload in a namespace at once |
| Modern tokens are projected, time-limited, and audience-bound | Auto-refreshed hourly by the kubelet, valid only for the requesting API server — a major security improvement over the deprecated long-lived Secret-based pattern |
| `serviceaccounts/token` is the subresource behind `kubectl create token` | Granting `create` on it is functionally equivalent to granting everything that ServiceAccount can do — treat it like `impersonate` |
| Every namespace has a `default` ServiceAccount, used implicitly | A Pod with no `serviceAccountName` set still gets a mounted, usable identity — silently |
| `automountServiceAccountToken: false` removes the credential file entirely | Failures from this look like "no cluster configuration," not `Forbidden` — a different failure category than any RBAC misconfiguration |
| A RoleBinding's namespace must match its Role's namespace — unchanged from `01` | But its subject's namespace can differ freely — that's the cross-namespace pattern this demo builds |
| Real mounted tokens and `--as` impersonation should agree | Checking both, as this demo does, confirms the RBAC grant and the actual in-cluster credential mechanism match — not just that a prediction says so |

> **Demo scope:** Primary concept: binding RBAC to ServiceAccount identities, including cross-namespace grants. Supporting concepts: token mechanics (projected vs. deprecated Secret-based), the default ServiceAccount, `automountServiceAccountToken`.
> Estimated completion time: 60–65 minutes.
> Checkpoints: 2 natural stopping points — after Step 3 (Role + cross-namespace RoleBinding created) and after Step 4 (both verification methods confirmed to agree, before Break-Fix — an explicit off-ramp is called out in Step 5).

---

## Quick Commands Reference

| Command | Description |
|---|---|
| `kubectl create serviceaccount <name> -n <namespace>` | Creates a ServiceAccount |
| `kubectl create token <name> -n <namespace>` | Mints a fresh, time-limited token for a ServiceAccount directly, without execing into any Pod |
| `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<name>` | Impersonation check for a ServiceAccount identity |
| `kubectl create rolebinding <name> --role=<role> --serviceaccount=<ns>:<sa-name> -n <namespace>` | Imperatively creates a (potentially cross-namespace) ServiceAccount RoleBinding |

### Generating YAML skeletons with --dry-run

**Supported:**
```bash
kubectl create serviceaccount NAME -n NAMESPACE --dry-run=client -o yaml
kubectl create role NAME --verb=get,list,watch --resource=deployments --dry-run=client -o yaml
kubectl create rolebinding NAME --role=ROLE --serviceaccount=NS:SA --dry-run=client -o yaml
```

**Not supported:** `automountServiceAccountToken` has no imperative flag on `kubectl create serviceaccount` — always requires hand-editing the generated skeleton; `kubectl get`, `describe`, `logs`, `exec`, `delete`, `apply`, `patch`, `label`

**Exam workflow:**
1. Generate the skeleton → edit what you need (including `automountServiceAccountToken`, if needed) → `kubectl apply -f file.yaml`

### Imperative Quick-Create Commands

| Object | Imperative command | Notes |
|---|---|---|
| ServiceAccount | `kubectl create serviceaccount NAME -n NAMESPACE` | |
| RoleBinding (cross-namespace SA) | `kubectl create rolebinding NAME --role=ROLE --serviceaccount=NS:SA -n NAMESPACE` | The RoleBinding's own `-n` is the Role's namespace, not the ServiceAccount's — `NS:SA` supplies the ServiceAccount's namespace separately |

---

## Troubleshooting

**A ServiceAccount's access doesn't work despite an apparently-correct cross-namespace RoleBinding:**
```bash
kubectl -n <role-namespace> describe rolebinding <name>
```
```
# Cause: subjects[].namespace likely has a typo or points at the wrong
#        namespace — this field isn't validated against a real
#        ServiceAccount at apply time.
# Fix: Confirm the exact namespace the ServiceAccount actually lives in
#      (kubectl get sa -A | grep <name>) and correct the subject.
```

**A Pod can't reach the API server at all — not `Forbidden`, something about missing configuration:**
```bash
kubectl -n <namespace> get pod <name> -o jsonpath='{.spec.automountServiceAccountToken}'
```
```
# Cause: automountServiceAccountToken is false — no credential was ever
#        mounted, so this fails before authentication is even attempted.
# Fix: Remove the field or set it true, if API access is actually needed.
```

**A Role appears to exist with the right rules, but a cross-namespace grant still fails:**
```bash
kubectl get role <name> --all-namespaces
```
```
# Cause: a same-named Role likely exists in the WRONG namespace — Role
#        objects with the same name in different namespaces are fully
#        independent; the RoleBinding only sees the one in its own
#        namespace.
# Fix: Confirm the Role exists specifically in the RoleBinding's
#      namespace, not just "somewhere."
```

---

## Appendix — Anki Cards

**`06-service-accounts-rbac-anki.csv`:**

```
#deck:k8s-platform-labs::12-rbac::06-service-accounts-rbac
#separator:Comma
#columns:Front,Back,Tags
"What makes ServiceAccount different from User as an RBAC subject, beyond both being usable in a RoleBinding?","ServiceAccount is a real, first-class API object — kubectl get serviceaccounts works, it has a lifecycle, and Kubernetes itself issues and can revoke its credentials. User is just a string an external authenticator vouches for, with no backing object at all.","service-accounts,subjects,cka-cluster-architecture-installation-configuration"
"What exact username string does a ServiceAccount authenticate as?","system:serviceaccount:<namespace>:<name> — this is what --as impersonation uses and what subject matching checks against.","service-accounts,username-format,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"What two Groups is every ServiceAccount automatically a member of?","system:serviceaccounts (every ServiceAccount in the cluster) and system:serviceaccounts:<namespace> (every ServiceAccount in that specific namespace) — both usable as Group subjects in a RoleBinding.","service-accounts,groups,cka-cluster-architecture-installation-configuration"
"Why did Kubernetes move away from long-lived, Secret-based ServiceAccount tokens?","Long-lived tokens never expired — a leak was valid indefinitely. The modern projected-token model is time-limited (kubelet auto-refreshes, ~hourly) and audience-bound (valid only for the requesting API server), shrinking the blast radius of a leaked token dramatically.","service-accounts,tokens,security,cka-cluster-architecture-installation-configuration"
"What subresource does kubectl create token actually use to mint a ServiceAccount token?","serviceaccounts/token — the TokenRequest API mechanism. Granting create on it is functionally equivalent to granting everything that ServiceAccount can do, comparable in sensitivity to granting impersonate.","service-accounts,tokens,serviceaccounts-token,cka-cluster-architecture-installation-configuration"
"Does every namespace have a default ServiceAccount, and what happens if a Pod spec doesn't set serviceAccountName?","Yes — every namespace gets one named 'default' automatically. A Pod with no serviceAccountName set silently uses it, mounting whatever token and RBAC access that default identity has.","service-accounts,default-serviceaccount,cka-cluster-architecture-installation-configuration"
"Must a RoleBinding's subject (a ServiceAccount) live in the same namespace as the RoleBinding itself?","No. The RoleBinding must share a namespace with the Role it references (unchanged from 01), but its subjects can name a ServiceAccount from any namespace — this is how cross-namespace access grants work.","service-accounts,cross-namespace,rolebinding,cka-cluster-architecture-installation-configuration,ckad-application-environment-configuration-security"
"A RoleBinding's subjects list names a ServiceAccount in a namespace where it doesn't actually exist. Does the RoleBinding still apply?","Yes. subjects[].namespace is just a string matched against the request's identity — there's no existence check against a real ServiceAccount at apply time, the same lazy-evaluation pattern as roleRef.","service-accounts,cross-namespace,troubleshooting,cka-troubleshooting"
"What does automountServiceAccountToken: false actually do, and how does the resulting failure differ from an RBAC Forbidden?","It stops the projected token from being mounted into the Pod at all — there's no credential for any client to authenticate with, so the failure happens before AuthN is even attempted. The error looks like missing cluster configuration, not Forbidden.","service-accounts,automount,troubleshooting,cka-troubleshooting"
"What's the fastest way to get a testable ServiceAccount token without execing into a Pod?","kubectl create token <serviceaccount-name> -n <namespace> — mints a fresh, time-limited token directly via the serviceaccounts/token subresource.","service-accounts,tokens,imperative-commands,cka-cluster-architecture-installation-configuration"
"In kubectl create rolebinding --serviceaccount=NS:SA, what does the -n flag on the overall command refer to — the ServiceAccount's namespace or the Role's?","The Role's namespace (and thus the RoleBinding's own namespace) — the ServiceAccount's namespace is supplied separately via the NS:SA colon syntax inside --serviceaccount=.","service-accounts,imperative-commands,cross-namespace,cka-cluster-architecture-installation-configuration"
```

## Appendix — Quiz

**`06-service-accounts-rbac-quiz.md`:**

````markdown
# Quiz — 12-rbac/06-service-accounts-rbac: Binding RBAC to Workload Identity

> One correct answer per question unless stated otherwise.
> Target: 80% or above before moving to next demo.

**Q1. What structurally distinguishes a `ServiceAccount` from a `User` as an RBAC subject?**

- A) `ServiceAccount` supports more verbs than `User`
- B) `ServiceAccount` is a real, first-class API object with its own lifecycle; `User` has no backing object at all
- C) `ServiceAccount` can only be used in `ClusterRoleBinding`
- D) There is no structural difference

<details>
<summary>Answer</summary>

**B** — `kubectl get serviceaccounts` works; there's no equivalent for `User`, which is purely a string an authenticator vouches for.
Trap: C is false — this entire demo uses `ServiceAccount` with an ordinary `RoleBinding`.

</details>

---

**Q2. What username string does a ServiceAccount named `deployer` in namespace `apps` authenticate as?**

- A) `deployer@apps`
- B) `apps/deployer`
- C) `system:serviceaccount:apps:deployer`
- D) `serviceaccount:deployer.apps`

<details>
<summary>Answer</summary>

**C** — Colon-separated, in the exact form `system:serviceaccount:<namespace>:<name>` — this is what both `--as` impersonation and RBAC subject matching use.
Trap: A, B, and D all invent plausible-looking but incorrect formats.

</details>

---

**Q3. Why did Kubernetes move away from long-lived, Secret-based ServiceAccount tokens as the default?**

- A) Secrets are deprecated entirely in modern Kubernetes
- B) Long-lived tokens never expired, so a leaked one was valid indefinitely; projected tokens are time-limited and audience-bound
- C) Secret-based tokens don't work with RBAC
- D) Performance — projected tokens are faster to validate

<details>
<summary>Answer</summary>

**B** — The security improvement is about blast radius: a leaked long-lived token worked forever, anywhere; a projected token expires (kubelet auto-refreshes hourly) and only works against the API server that requested it.
Trap: A overstates the change — Secrets themselves aren't deprecated, just this specific long-lived-token pattern. C is false; both patterns work with RBAC identically.

</details>

---

**Q4. Must a RoleBinding's subject (a `ServiceAccount`) live in the same namespace as the RoleBinding itself?**

- A) Yes, always
- B) No — the RoleBinding must share a namespace with the Role it references, but its subject can be a ServiceAccount from any namespace
- C) Only if the Role uses a wildcard
- D) No — RoleBindings and their subjects are never namespace-scoped

<details>
<summary>Answer</summary>

**B** — This is the cross-namespace pattern the demo builds directly: RoleBinding and Role share a namespace (unchanged from `01`), but the subject's namespace is independent.
Trap: A wrongly assumes subject and binding must match. D overcorrects — RoleBindings are absolutely namespace-scoped; only the subject's namespace is the flexible part.

</details>

---

**Q5. A RoleBinding names a ServiceAccount in a namespace where that ServiceAccount doesn't actually exist. Does the RoleBinding still apply successfully?**

- A) No — the API server validates the ServiceAccount exists first
- B) Yes — `subjects[].namespace` is just a string matched at authorization time, with no existence check at apply time
- C) It applies but is automatically deleted after a grace period
- D) It's silently rewritten to reference the correct namespace

<details>
<summary>Answer</summary>

**B** — Same lazy-evaluation pattern as `roleRef` from `01` — the RoleBinding applies cleanly regardless, and the mismatch only surfaces as a denied `can-i` check.
Trap: A assumes a validation step that doesn't exist. C and D invent behaviors Kubernetes doesn't have.

</details>

---

**Q6. A Pod has `automountServiceAccountToken: false`. It tries to call the Kubernetes API and fails. What does the failure look like, compared to an RBAC denial?**

- A) Identical `403 Forbidden` — RBAC still evaluates the request
- B) An error indicating no credential/cluster configuration exists — the request never reaches AuthN, let alone AuthZ
- C) `401 Unauthorized`, since the ServiceAccount itself is invalid
- D) The Pod fails to start entirely

<details>
<summary>Answer</summary>

**B** — With no token mounted, there's no credential for the client to even attempt authenticating with — this fails at a layer before AuthN is attempted, producing a distinctly different error than any RBAC-related response.
Trap: A and C both assume the request reaches the API server's auth pipeline at all — it doesn't, because there's no credential to send in the first place.

</details>

---

Score guide:
| Score | Action |
|---|---|
| 6/6 | Import Anki cards, move to 07-aggregated-clusterroles |
| 5/6 | Review the wrong answer, then proceed |
| 4/6 | Re-read the relevant section, retry those questions |
| Below 4/6 | Re-read the full demo and redo the walkthrough before proceeding |
````