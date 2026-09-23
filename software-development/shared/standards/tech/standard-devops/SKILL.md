---
name: standard-devops
description: The single definition of good Infrastructure-as-Code — the shared rubric the devops-engineer BUILDS to and the devops-reviewer REVIEWS against (Terraform/OpenTofu, Helm, Kustomize, Ansible, Pulumi, CloudFormation, Kubernetes manifests, Dockerfiles, CI/CD pipelines). Applies whenever infrastructure-as-code is written, changed, or reviewed. Covers infrastructure correctness/safety (contracts, naming/layout, idempotency, state discipline, destructive-change guarding, rollout/rollback), cloud security posture (least privilege, network exposure, encryption, secrets, container hardening, supply chain, audit), and static-analysis/formatting cleanliness. WHAT good looks like only — not builder workflow (build-core), the devops-engineer's IaC-manifestations bridge/validation gate, the devops-reviewer's own hunt/correctness-detective method, category vocabulary, and scope-boundary table (genuinely devops-reviewer's own), the base severity scale, handoff mechanism, and universal finding-quality/false-positive discipline (review-core / review-report-standards), or report envelopes (build-report-standards / review-report-standards).
---

# Standard: DevOps (Infrastructure as Code)

The **one** definition of what good Infrastructure-as-Code looks like. The `devops-engineer` builds to it; the `devops-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we build infrastructure and how we review it — a rule changed here moves both sides at once. Here "language" is Infrastructure-as-Code: Terraform/OpenTofu, Helm, Kustomize, Ansible, Pulumi, CloudFormation, Kubernetes manifests, Dockerfiles, CI/CD pipelines.

This skill defines **WHAT good looks like** — the idioms, safety rules, and secure-by-default posture to reach for, and the traps to avoid. It is **NOT an IaC tutorial**: assume fluent Terraform/K8s/Docker/CI-CD, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`); the engineer's IaC-manifestations bridge or validation gate; the reviewer's own hunt/correctness-detective method, `category` vocabulary, and scope-boundary table (genuinely `devops-reviewer`'s own); or the base severity scale, the handoff mechanism, and universal finding-quality/false-positive discipline (`review-core` / `review-report-standards` — `devops-reviewer` only maps its own categories onto that scale). Report envelopes live in `build-report-standards` / `review-report-standards`.

Unlike a single-language standard, this one deliberately carries **no single version/toolchain baseline** — it spans Terraform/OpenTofu, Helm, Kustomize, Ansible, Pulumi, CloudFormation, Kubernetes, Docker, and whichever CI/CD system the project uses, each with its own version cadence; pin the actual toolchain versions at the project level, not here.

Two secure-by-default defaults orient everything below: **private, least-privilege, encrypted, pinned** — and **idempotent, declarative, state-safe**. Public / wildcard / unencrypted / unpinned is opt-in, justified, and rare.

## Infrastructure Correctness & Safety

Does the configuration do what it is meant to, and is it safe to `apply`?

### Contracts & structure

- A module's **input variables and outputs are a contract** — give every input a `type` and a `validation` block; renaming or removing one is a **breaking change** for consumers.
- Configure environments through `tfvars` / overlays, **not** copy-pasted code.

### Naming & file layout

- **Resource/variable names are descriptive and consistent** — a module's naming scheme (env/region/purpose ordering) is decided once and applied everywhere, not improvised per resource.
- Split by concern, not by convenience — `main`/`variables`/`outputs`/`versions` (Terraform), one values file per environment (Helm), one manifest per resource kind (Kustomize base) — never one file holding an entire stack.

### Idempotency

- **Idempotent & declarative** — a re-apply must converge with no changes.
- Avoid `local-exec` / `null_resource` / imperative provisioners that break idempotency. In Ansible, use **modules**, not bare `command` / `shell` (without `creates` / `changed_when`).

### State discipline

- Keep **remote state** on an **encrypted backend**, with **locking** — secrets can leak into state, so this doubles as a secrets-exposure control.
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
- **Stateful workloads carry a provisioned, periodically-tested backup/PITR configuration and a defined replica/failover topology** — automated snapshots or continuous backup, a stated recovery point/time objective, and replica placement/failover behavior declared in the IaC itself, not assumed to exist because the managed service *could* provide it.

## Cloud Security Posture

The cloud-misconfiguration mechanism (CIS-style); the private/least-privilege/encrypted/pinned defaults stated above apply throughout.

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
- Mark `sensitive = true`; no hardcoded creds / keys / tokens; never echo secrets in CI logs.

### Container hardening

- **Non-root**; `readOnlyRootFilesystem`; **drop capabilities** (no added caps).
- No `privileged`, `hostPath`, or `hostNetwork`; `allowPrivilegeEscalation: false`.
- `seccompProfile: RuntimeDefault`; avoid needless `automountServiceAccountToken`.
- Namespaces under **Pod Security Admission (`restricted`)**.

### Supply chain

- **Pin every provider / module / image version** — no `:latest`.
- Pin images by **`@sha256`** digest; **commit `.terraform.lock.hcl`**.
- Trusted **registries** only; **verify image signatures** (cosign) and module sources.
- **Scan** images/dependencies for known-vulnerable versions before they ship — the scanning tooling itself is the Static-Analysis section's rule below.

### Audit & account

- **Audit logging on by default** — **CloudTrail** (multi-region), **VPC flow logs**, **K8s audit**.
- **MFA** on privileged principals; **no root access keys**.

## Static-Analysis & Formatting Cleanliness

- Clean under `terraform fmt -check` / `tflint`, with zero unjustified findings; a suppressed rule carries a written reason, same as any other language this repo builds.
- **`checkov` / `trivy config`** clean (or every finding explicitly waived with a reason) — this is `standard-devops`'s own static gate, distinct from the Supply-chain section's image/dependency scanning above. A project-specific policy-as-code tool (e.g. `conftest` against custom Rego) is a valid addition on top of this baseline, not a substitute for it — there is no universal ruleset to codify here, so this standard doesn't mandate one.
- Style/formatting conformance is the linter's job, not a manual review job.
