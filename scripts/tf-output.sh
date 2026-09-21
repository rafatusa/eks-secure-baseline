#!/usr/bin/env bash
#
# Read one terraform output SAFELY, for callers that must distinguish
# "the value is absent" from "the value is present".
#
# WHY THIS EXISTS
# ---------------
# `terraform output -raw <name>` does NOT fail the way shell authors expect
# when the output cannot be evaluated. Observed on this project during a
# RESUMED teardown: a previous destroy had removed aws_eks_cluster.main, so
# `output "cluster_name" { value = aws_eks_cluster.main.name }` had nothing
# to evaluate. In that state terraform:
#
#   * prints a multi-line `Warning: No outputs found` banner, and
#   * EXITS 0.
#
# Worse, the pipeline runs terraform through hashicorp/setup-terraform,
# whose wrapper MERGES STDERR INTO STDOUT. So the warning banner arrives on
# stdout, where a caller expects the value. `2>/dev/null` does not suppress
# it, because by then it is no longer on stderr.
#
# The consequence is that the idiomatic guard
#
#     VALUE=$(terraform output -raw name 2>/dev/null || echo "")
#     if [ -n "$VALUE" ]; then ...
#
# is silently WRONG on every count: the redirect does not remove the banner,
# the `||` branch never runs because the status is 0, and `$VALUE` becomes a
# large chunk of diagnostic prose — non-empty, so the guard PASSES and the
# prose is handed onward as if it were an identifier.
#
# THE RULE: never trust the EXIT STATUS of `terraform output`, and never
# merely blocklist known-bad shapes. VALIDATE THE VALUE POSITIVELY — accept
# only something that looks like the identifier you asked for, and treat
# everything else as absent.
#
# (An earlier version of this script blocklisted values wrapped in angle
# brackets. That was insufficient: the real banner is multi-line prose, not
# a `<placeholder>` token, so it slipped straight through. A blocklist can
# only reject the failure modes you already thought of; an allowlist rejects
# every one you did not.)
#
# USAGE
#   VALUE="$(bash scripts/tf-output.sh <output-name> [terraform-dir])"
#
# Prints the value on stdout and exits 0 when the output genuinely exists.
# Prints NOTHING and exits 0 when it does not, so callers can write:
#
#   VALUE="$(bash scripts/tf-output.sh cluster_name infra)"
#   if [ -z "$VALUE" ]; then ... fi
#
# An absent output is a legitimate state (a resumed teardown), not an error,
# which is why this exits 0 either way — the CALLER decides whether absence
# is fatal for what it is about to do.

set -euo pipefail

NAME="${1:?usage: tf-output.sh <output-name> [terraform-dir]}"
DIR="${2:-infra}"

# stderr is redirected as well as captured: with the setup-terraform wrapper
# the warning already comes back on stdout, so the redirect alone can never
# be the defence. The decision below is made purely from the VALUE.
VALUE="$(cd "${DIR}" && terraform output -raw "${NAME}" 2>/dev/null || true)"

# A real terraform output value is a SINGLE LINE. Every diagnostic terraform
# emits ("Warning: No outputs found", "The state file either has no outputs
# defined...") is multi-line. Reject anything with a newline before doing
# anything else — this alone catches the banner regardless of its wording,
# which matters because the wording changes between terraform versions.
if [ "$(printf '%s' "${VALUE}" | wc -l)" -gt 0 ]; then
  printf ''
  exit 0
fi

# Trim surrounding whitespace only (not internal), so a trailing newline
# cannot masquerade as content.
VALUE="$(printf '%s' "${VALUE}" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if [ -z "${VALUE}" ]; then
  printf ''
  exit 0
fi

# A bare "null" is what terraform prints for an output defined but unset.
if [ "${VALUE}" = "null" ]; then
  printf ''
  exit 0
fi

# POSITIVE VALIDATION. Every output this project reads is an AWS identifier
# or URL: cluster names, VPC ids, ECR registry URLs, role ARNs, CIDRs, log
# group names. All are a single token drawn from this character set, with no
# spaces. Terraform's diagnostics always contain spaces, so requiring a
# space-free token rejects them without needing to know their text.
#
# Deliberately permissive about WHICH characters (so a new output type does
# not need a code change here) but strict about the SHAPE: one token, no
# whitespace, reasonable length.
if ! printf '%s' "${VALUE}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,511}$'; then
  printf ''
  exit 0
fi

printf '%s' "${VALUE}"
