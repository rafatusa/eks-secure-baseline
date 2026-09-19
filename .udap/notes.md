# eks-secure-baseline — working notes

## Objective
Deploy a hardened EKS cluster on AWS, run CIS compliance scanning (kube-bench
+ Trivy), and publish a compliance report as a CI artifact.

## Key decisions

### Scope clarification: STIG vs CIS  (IMPORTANT — stated in README + report)
User originally asked for "STIGs". Clarified up front:
- DISA publishes STIGs for Kubernetes platform + RHEL/Ubuntu node OS.
- There is NO DISA STIG for Amazon EKS.
- Kubernetes STIG assumes control-plane flag access; EKS does NOT expose it.
- AL2023 has NO published DISA SCAP content.
=> Deliverable is CIS Amazon EKS Benchmark (kube-bench eks-1.5.0) + Trivy.
   The scope statement is reproduced in README.md AND in every generated
   report (SCOPE_NOTE in scripts/build_report.py) so it can't be lost.
If real STIG artifacts are ever needed: node OS must become RHEL/Ubuntu and
OpenSCAP + matching SCAP content added. Larger piece of work.

### Marketplace: declined (3 candidates were all APP blueprints, not clusters)

### Kubernetes version: 1.33
Skill terraform_aws: standard support = 1.33-1.36 (as of 2026-07).
1.30-1.32 = extended support = EXTRA COST. variables.tf has a validation
block enforcing 1.33-1.36 so nobody downgrades into paid support by accident.

## Account cleanup (completed 2026-09-19, before build)
Removed ~$195/mo of waste. Final state before build: 1 empty default VPC,
0 LB, 0 EIP, 0 TG, 0 compute, 0 RDS. See git history / earlier notes.
Cost Explorer NOT enabled on the account (AccessDeniedException) — could not
read real billing figures; told the user honestly, pointed at Billing > Bills.
=> Added a CloudWatch billing alarm to this build ($200 default threshold).

### CRITICAL: the orphaned-ALB pattern (drove a real design decision)
14 orphaned target groups across 11 long-deleted VPCs + 2 orphaned k8s-* ALBs
+ 3 orphaned SGs were found. Cause: EKS clusters destroyed WITHOUT first
deleting their k8s LoadBalancer Services. The AWS LB Controller creates those
ALBs/SGs OUTSIDE terraform state, so destroy leaves them billing (~$16/mo ea)
AND holding ENIs that make DeleteVpc fail with DependencyViolation.
=> scripts/pre-destroy-cleanup.sh deletes LB Services + Ingresses and waits
   for the AWS LBs to disappear BEFORE terraform destroy. Wired into the
   destroy workflow. Documented in README teardown section.

## Bugs I caught in my own pre-flight self-review (before shipping)
1. write_file CANNOT set the executable bit, and git preserves mode.
   `./scripts/x.sh` would have failed with "Permission denied" in CI.
   FIX: pipeline invokes everything as `bash scripts/x.sh`.
2. destroy workflow ran pre-destroy-cleanup.sh WITHOUT configuring kubectl
   first => `kubectl cluster-info` always fails => script silently no-ops =>
   the orphan protection would never have run. FIX: added an
   `aws eks update-kubeconfig` step before it in the destroy spec.
3. verify-pss.sh had a nested-quote bug: `subject.get(\"name\")` inside a
   single-quoted python heredoc inside bash. FIX: rewrote using kubectl
   jsonpath + pure bash string splitting, no embedded Python.
4. pre-destroy-cleanup.sh: piped `while` loop runs in a subshell; classic-ELB
   call lacked --region. FIX: here-strings + explicit --region.

## Sandbox limitations encountered
- test_project => SKIPPED: "No test-run recipe for language 'unknown'".
  Infra-only repo, no app language to detect. Not a defect, does not block.
- console sandbox only allows: aws, doctl, gh, git, glab, helm, kubectl,
  kustomize, terraform. NO python3/bash => could not execute my scripts there.
=> MITIGATION: the `lint` stage now runs `bash -n` on every scripts/*.sh and
   `python3 -m py_compile` on build_report.py. Real syntax gates, run in CI
   BEFORE provisioning, so a typo fails in ~1min instead of 25min deep.

## Secrets to set AFTER create_repo_and_push, BEFORE deploy
- API_ALLOWED_CIDR      — default 0.0.0.0/0; user may lock to x.x.x.x/32
- BILLING_ALARM_EMAIL   — empty string disables the alarm (count=0 guard)
(Platform provides: PROJECT_NAME, TF_STATE_BUCKET, AWS_ACCESS_KEY_ID,
 AWS_SECRET_ACCESS_KEY)

## Environment facts
- AWS account 241533126054, IAM user `talha`, us-east-1
- VPC quota 5/region — 1 used after cleanup, 4 free. This build adds 1 => 2/5.
- On-demand standard vCPU quota 64 (2x t3.medium = 4 vCPU, fine)
- GitHub connected; GitLab not

## Expected first-run findings (NOT bugs — explain, don't "fix")
- Open API endpoint if API_ALLOWED_CIDR stays 0.0.0.0/0 => genuine CIS finding
- Control-plane checks INFO/WARN => AWS-inherited, not assessable on EKS

## Status
- [x] Discovery + cloud probe
- [x] Account cleanup (~$195/mo recovered)
- [x] Project meta approved
- [x] Architecture + pipeline (rev 2)
- [x] Design approved
- [x] Plan approved
- [x] Generation (27 files)
- [x] validate_project PASS
- [x] test_project SKIPPED (sandbox gap, documented above)
- [ ] create_repo_and_push
- [ ] set secrets
- [ ] deploy
