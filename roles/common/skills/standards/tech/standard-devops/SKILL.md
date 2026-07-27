---
name: standard-devops
description: The single definition of good Infrastructure-as-Code — the shared rubric the devops-engineer BUILDS to and the devops-reviewer REVIEWS against. Applies whenever IaC is written, changed, or reviewed (Terraform/OpenTofu, Helm, Kustomize, Ansible, Pulumi, CloudFormation, Kubernetes manifests, Dockerfiles, CI/CD pipelines). Defines infrastructure correctness & safety (module I/O as a typed + validated contract, idempotency, remote/locked/encrypted state discipline, moved/removed/import refactors, destructive-change guarding with create_before_destroy / prevent_destroy, rollout & rollback safety) and cloud security posture (least-privilege IAM/RBAC, IMDSv2, private-by-default networking, encryption at rest/in transit via CMK/KMS, secrets from a manager, container hardening, pinned/signed supply chain, audit logging). This is WHAT good looks like; it does not define builder workflow (build-core), the reviewer's hunt/scoring machinery — severity, category vocabulary, scope-boundary/handoff (the devops-reviewer), the IaC-manifestations bridge or validation gate (the devops-engineer), or the report envelopes (build-report-standards / review-report-standards).
---

# Standard: DevOps (Infrastructure as Code)

The **one** definition of what good Infrastructure-as-Code looks like. The `devops-engineer` builds to it; the `devops-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we build infrastructure and how we review it — a rule changed here moves both sides at once. Here "language" is Infrastructure-as-Code: Terraform/OpenTofu, Helm, Kustomize, Ansible, Pulumi, CloudFormation, Kubernetes manifests, Dockerfiles, CI/CD pipelines.

This skill defines **WHAT good looks like** — the idioms, safety rules, and secure-by-default posture to reach for, and the traps to avoid. It is **NOT an IaC tutorial**: assume fluent Terraform/K8s/Docker/CI-CD, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`), the engineer's IaC-manifestations bridge or validation gate, or the reviewer's machinery — the hunt/correctness-detective method, scope-boundary/handoff, severity, and `category` vocabulary live with the `devops-reviewer`; report envelopes live in `build-report-standards` / `review-report-standards`.

Two secure-by-default defaults orient everything below: **private, least-privilege, encrypted, pinned** — and **idempotent, declarative, state-safe**. Public / wildcard / unencrypted / unpinned is opt-in, justified, and rare.

## Infrastructure Correctness & Safety

Does the configuration do what it is meant to, and is it safe to `apply`?

### Contracts & structure

- A module's **input variables and outputs are a contract** — give every input a `type` and a `validation` block; renaming or removing one is a **breaking change** for consumers.
- Configure environments through `tfvars` / overlays, **not** copy-pasted code.

### Idempotency

- **Idempotent & declarative** — a re-apply must converge with no changes.
- Avoid `local-exec` / `null_resource` / imperative provisioners that break idempotency. In Ansible, use **modules**, not bare `command` / `shell` (without `creates` / `changed_when`).

### State discipline

- Keep **remote state** on an **encrypted backend**, with **locking**.
- A refactor must **preserve behavior** — `terraform plan` shows **no changes**. Move addresses with **`moved` / `removed` / `import`** blocks (declarative, in-plan); `state mv` is a **fallback only**.

### Destructive change & scope

- A change that forces **replacement** of a stateful resource (`force_new`, immutable-field edits) risks **data loss / downtime** — surface it.
- Use **`create_before_destroy`** for zero-downtime replacement and **`prevent_destroy`** on critical stateful resources.
- Keep the **scope bounded**.

### Rollout & rollback safety

- Liveness / readiness **probes**, resource **requests/limits**, **PDB** / replicas for HA.
- A sane update strategy — **`RollingUpdate`** maxUnavailable / maxSurge, **not `Recreate`** on an HA service; correct **Helm hook ordering**.
- A **rollback path**.
- **Gate CD deploys**; use short-lived **OIDC** credentials, not stored cloud keys.

## Cloud Security Posture

The cloud-misconfiguration mechanism (CIS-style). Secure-by-default: private, least-privilege, encrypted, pinned.

### IAM / RBAC — least privilege

- No `Action:"*"` / `Resource:"*"`, no wildcard roles, no `cluster-admin` by default.
- Watch **privilege escalation** — `iam:PassRole` with broad trust, `sts:AssumeRole` wildcards.
- Enforce **IMDSv2** (`http_tokens = "required"`).

### Network exposure — private by default

- No `0.0.0.0/0` **ingress *or* egress**; any public access is explicit opt-in.
- No **public object storage**, public IPs, **AMIs, or snapshots**.
- **Default-deny** `NetworkPolicy`.

### Encryption

- **At rest** via **CMK/KMS + rotation** (not just default SSE); **in transit** via TLS.
- No KMS key policy with `Principal:"*"`.

### Secrets

- Load secrets from a **secret manager** — never in code, state, or plaintext `ConfigMap`s.
- **Encrypt the state backend** (secrets leak into state); mark `sensitive = true`.
- No hardcoded creds / keys / tokens; never echo secrets in CI logs.

### Container hardening

- **Non-root**; `readOnlyRootFilesystem`; **drop capabilities** (no added caps).
- No `privileged`, `hostPath`, or `hostNetwork`; `allowPrivilegeEscalation: false`.
- `seccompProfile: RuntimeDefault`; avoid needless `automountServiceAccountToken`.
- Namespaces under **Pod Security Admission (`restricted`)**.

### Supply chain

- **Pin every provider / module / image version** — no `:latest`.
- Pin images by **`@sha256`** digest; **commit `.terraform.lock.hcl`**.
- Trusted **registries** only; **verify image signatures** (cosign) and module sources.
- **Scan** with `trivy config` / `checkov` (`tfsec` is now merged into Trivy).

### Audit & account

- **Audit logging on by default** — **CloudTrail** (multi-region), **VPC flow logs**, **K8s audit**.
- **MFA** on privileged principals; **no root access keys**.

---
*Standard Version: 1.0 — the shared Infrastructure-as-Code rubric. Built to by the devops-engineer (via build-core); reviewed against by the devops-reviewer. The IaC-manifestations bridge and validation gate live with the engineer; the hunt/scoring machinery lives with the reviewer.*
