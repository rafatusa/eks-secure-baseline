# eks-secure-baseline

A hardened Amazon EKS cluster with automated CIS compliance scanning and
report publishing.

This repository provisions the cluster, applies an in-cluster hardening
baseline, verifies that the baseline is actually enforced, then runs
[kube-bench](https://github.com/aquasecurity/kube-bench) and
[Trivy](https://github.com/aquasecurity/trivy) and publishes a compliance
report as a CI artifact.

---

## Scope: CIS, not STIG

**This project reports against the CIS Amazon EKS Benchmark. It does not
produce DISA STIG results.** That distinction is deliberate and worth
understanding before anyone relies on these reports for an audit.

- DISA publishes STIGs for the **Kubernetes platform** and for **RHEL and
  Ubuntu** node operating systems.
- There is **no DISA STIG for Amazon EKS**.
- The Kubernetes STIG assumes you can inspect and set control-plane component
  flags (`kube-apiserver`, `etcd`, `kube-scheduler`). On EKS those components
  are managed by AWS and are **not exposed to customers** — the corresponding
  controls are *inherited* from AWS, not assessable here.
- The node OS is **Amazon Linux 2023**, which has **no published DISA SCAP
  content**. OS-level STIG scanning would require RHEL or Ubuntu nodes.

What this project therefore evaluates is the **customer-responsibility
subset**: node configuration, kubelet settings, RBAC, network policy, Pod
Security Admission, and workload configuration. That is a genuine and
defensible hardening posture. It is not a STIG compliance attestation.

If you need literal STIG artifacts, the node OS must change to RHEL or Ubuntu
and OpenSCAP must be added with the matching SCAP content. That is a
deliberate, larger piece of work.

---

## What gets deployed

| Component | Detail |
|---|---|
| EKS control plane | v1.33 (AWS standard support) |
| Node group | 2× `t3.medium`, Amazon Linux 2023, **private subnets** |
| Network | Dedicated VPC `10.20.0.0/16`, 2 AZs, 1 NAT gateway |
| Secret encryption | KMS envelope encryption for Kubernetes secrets |
| Disk encryption | KMS-encrypted gp3 root volumes |
| Audit logging | All 5 control-plane log types → CloudWatch |
| Flow logs | VPC flow logs → CloudWatch |
| Cost guardrail | CloudWatch billing alarm + SNS email |

**Estimated cost: ~$150–170/month.** EKS control plane ~$73, two `t3.medium`
nodes ~$60, NAT gateway ~$33, KMS and CloudWatch a few dollars.

---

## Hardening controls applied

**Infrastructure**
- Nodes in private subnets with **no public IP** — unreachable from the
  internet; egress via NAT only.
- **IMDSv2 required** (`http_tokens=required`, `hop_limit=1`) — blocks the
  container-escape path to node IAM credentials.
- Kubernetes secrets encrypted at rest with a **customer-managed KMS key**
  (rotation enabled), not merely base64-encoded in etcd.
- **No SSH.** No port 22 is opened anywhere; node access is via AWS SSM.
- **API endpoint locked to a single administrative host** (`/32`), with
  private endpoint access enabled — see below.

**In-cluster**
- **Pod Security Admission** in `restricted` mode on `default` and
  `compliance` namespaces (enforce + audit + warn).
- **Default-deny** ingress *and* egress NetworkPolicies, with explicit DNS
  and HTTPS carve-outs only where required.
- Egress policy explicitly blocks `169.254.169.254` (instance metadata).
- **Least-privilege RBAC** — the scanner gets read-only verbs (`get`, `list`).
  No `cluster-admin` binding exists for any workload service account.
- **ResourceQuota + LimitRange** on every non-system namespace.
- **IRSA** for AWS access — no node-wide credentials shared with pods.

---

## API server network access

The API server endpoint is **not** open to the internet. `public_access_cidrs`
is set to one administrative host, and `variables.tf` enforces this with
validation blocks that reject `0.0.0.0/0` and anything broader than `/24`. A
misconfigured deploy fails at `terraform plan` rather than silently exposing
the control plane.

### How CI reaches a locked-down endpoint

GitHub-hosted runners have ephemeral public IPs from large, rotating ranges.
Permanently allowlisting GitHub's published ranges would admit *every* GitHub
Actions runner on the platform — much weaker than it looks.

Instead, each stage that needs `kubectl` wraps its work in
`scripts/ci-api-access.sh`, which:

1. resolves the runner's own public IP,
2. adds it to the allowlist as a `/32` alongside the administrative host,
3. runs the stage's work,
4. **always** restores the allowlist to the administrative host alone.

Step 4 is a `trap ... EXIT INT TERM` inside a single step rather than a
separate cleanup step, so it fires on success, on failure, on `set -e` abort,
and on job cancellation or timeout. The reset is absolute (not a removal of
one entry), which makes it self-healing: if a run ever dies without the trap
firing, the next run's reset restores the intended state.

Steady-state exposure is therefore one host; the widened window is bounded by
the job runtime. The `verify` stage asserts this with
`scripts/verify-api-restriction.sh`, which fails the deploy if the allowlist
ever contains an open or overly broad range.

**If your IP changes**, update the `API_ALLOWED_CIDR` repository secret and
redeploy. Until then `kubectl` from your workstation will time out — CI is
unaffected, because it allowlists itself.

**Optional hardening (Tier 2):** set `endpoint_public_access = false` for a
fully private endpoint. This is genuinely stronger, but CI then requires a
self-hosted runner or VPN inside the VPC. Not enabled by default.

---

## Reading the compliance report

Every deploy publishes a `compliance-report` artifact containing:

| File | Purpose |
|---|---|
| `compliance-report.html` | Full report, per-control, with remediation |
| `summary.txt` | Terminal summary (also printed in the CI log) |
| `compliance-summary.json` | Machine-readable totals + failed checks |
| `kube-bench.json` | Raw kube-bench output |
| `trivy-cluster.json` | Raw Trivy output |

Download it from the **Actions** run page → *Artifacts*. Retention is 90 days.

The summary is printed directly in the `compliance` stage log, so a pass rate
is visible without downloading anything.

### Expected findings

Some findings are expected and are **not** bugs:

- **Control-plane checks reported as INFO/WARN** — EKS manages those
  components; the controls are inherited from AWS and cannot be evaluated
  from inside the cluster.
- **Unrestricted egress on the cluster security group** (Trivy `AWS-0104`) —
  a documented exception in `infra/eks.tf`. The EKS control plane must reach
  node kubelets and regional AWS service endpoints; AWS's own security group
  requirements specify open egress here. It is suppressed at that single
  rule, with justification and compensating controls recorded inline — not
  by filtering severities or dropping the scanner's `--exit-code`.

Every other finding fails the pipeline. The scanner is not weakened to
produce a green run; that would defeat the purpose of the project.

---

## Configuration

Set via `TF_VAR_*` in the pipeline, or as repository secrets:

| Variable | Default | Notes |
|---|---|---|
| `api_allowed_cidr` | `203.0.113.1/32` | Non-routable placeholder (RFC 5737). Supplied at deploy time from the `API_ALLOWED_CIDR` secret. Open and broad CIDRs are rejected by validation. |
| `k8s_version` | `1.33` | Must be in AWS standard support |
| `node_instance_type` | `t3.medium` | |
| `node_desired_size` | `2` | Minimum 2 (two AZs) |
| `billing_alarm_email` | *(empty)* | Empty or `"none"` disables the alarm |
| `billing_alarm_threshold_usd` | `200` | |

---

## Pipeline

```
lint → security → provision → configure → verify → compliance
```

| Stage | Does |
|---|---|
| `lint` | `terraform fmt/validate`, `bash -n`, `py_compile`, `kubeconform` |
| `security` | Trivy misconfiguration scan of `infra/` and `k8s/` |
| `provision` | `terraform apply` — VPC, EKS, nodes, KMS, alarm |
| `configure` | Applies hardening baseline and scanner resources |
| `verify` | Asserts hardening is **enforced**, not merely applied |
| `compliance` | Runs kube-bench + Trivy, publishes the report |

The `verify` stage fails the deploy if a hardening control is missing — an
applied manifest is not the same as an enforced policy.

---

## Teardown

Use the platform's **Destroy** action. The destroy workflow deletes
Kubernetes `LoadBalancer` Services and Ingress objects **before**
`terraform destroy`.

**This ordering is essential.** Load balancers created by in-cluster
controllers are not in terraform state, so `terraform destroy` leaves them
behind, where they keep billing (~$16/month each) and hold ENIs that make
`DeleteVpc` fail with `DependencyViolation`. This is not hypothetical — this
account previously accumulated orphaned ALBs, security groups and 14 stale
target groups across 11 deleted VPCs from exactly this mistake.

The destroy workflow runs that cleanup through the same temporary-API-access
wrapper, because a locked-down endpoint would otherwise make the cleanup time
out and silently skip — recreating the problem it exists to prevent.

---

## Layout

```
infra/                      Terraform (VPC, EKS, nodes, KMS, IRSA, billing)
k8s/hardening/              Namespaces, NetworkPolicies, RBAC, quotas
k8s/compliance/             kube-bench Job
scripts/                    Scan runners, report builder, verification
.udap/                      Architecture source + pipeline spec
```

Terraform state is managed by the platform (S3 backend, per-project key). The
backend block is intentionally empty — configuration arrives at `init` time.
