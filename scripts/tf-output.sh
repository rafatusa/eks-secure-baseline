#!/usr/bin/env bash
#
# Read one terraform output SAFELY, for callers that must distinguish
# "the value is absent" from "the value is present".
#
# WHY THIS EXISTS
# ---------------
# `terraform output -raw <name>` does NOT fail the way shell authors expect
# when the state has no outputs. Observed on this project during a RESUMED
# teardown (the cluster had already been destroyed, so the state held
# resources but no outputs):
#
#   * it prints a `Warning: No outputs found` block to STDERR, and
#   * it prints the literal placeholder text `<cluster>` to STDOUT, and
#   * it EXITS 0.
#
# The consequence is that the idiomatic guard
#
#     VALUE=$(terraform output -raw name 2>/dev/null || echo "")
#     if [ -n "$VALUE" ]; then ...
#
# is silently WRONG. `2>/dev/null` hides the warning, the `||` branch never
# runs because the exit status is 0, and `$VALUE` becomes the placeholder
# `<cluster>` — a non-empty string. The guard passes and the placeholder is
# handed onward as if it were a real cluster name.
#
# THE setup-terraform WRAPPER — THE PART THAT BIT US
# --------------------------------------------------
# `hashicorp/setup-terraform` installs a WRAPPER script on PATH as
# `terraform` unless `terraform_wrapper: false` is set (it defaults to
# true, and this repo never disables it). That wrapper runs the real
# binary, captures both streams, and re-emits the child's STDERR on the
# WRAPPER'S OWN STDOUT (so it can publish `stdout`/`stderr` step outputs).
#
# This means `2>/dev/null` on the wrapper discards NOTHING useful: the
# "Warning: No outputs found" banner has already been folded into stdout
# before our redirect is ever consulted, and it lands in $VALUE. Squeezing
# whitespace out of that banner yields a long non-empty token, and a
# `case '<'*'>'` test only matches a value that is ENTIRELY bracketed, so
# the banner sails straight through both guards and reaches the caller.
#
# That is exactly how a teardown failed here: `ci-api-access.sh` received
# the banner text as its cluster argument and correctly refused it, but
# only AFTER terraform destroy had been prevented from running.
#
# THE RULE: never trust the EXIT STATUS of `terraform output` alone, never
# trust that stdout is clean, and always validate the SHAPE of the value.
# This helper centralises that so every call site gets the same behaviour
# instead of each reinventing a guard that looks right.
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

# Prefer the REAL terraform binary over the setup-terraform wrapper.
#
# setup-terraform exports TERRAFORM_CLI_PATH pointing at the directory that
# holds the untouched binary it downloaded (as `terraform-bin`), with the
# wrapper shadowing it on PATH as `terraform`. Calling the binary directly
# keeps stdout and stderr as separate streams, which is the whole premise
# of reading a value from stdout. If the wrapper is not in use we simply
# fall back to whatever `terraform` resolves to.
TF_BIN="terraform"
if [ -n "${TERRAFORM_CLI_PATH:-}" ] && [ -x "${TERRAFORM_CLI_PATH}/terraform-bin" ]; then
  TF_BIN="${TERRAFORM_CLI_PATH}/terraform-bin"
fi

# stderr is discarded deliberately: when the output is missing, terraform
# writes a multi-line warning there that is noise for the caller. The
# decision is made from the VALUE below, never from stderr or the status.
# Belt and braces — even if a wrapper still merges the streams, the shape
# validation further down rejects the result.
VALUE="$(cd "${DIR}" && "${TF_BIN}" output -raw "${NAME}" 2>/dev/null || true)"

# A REAL `terraform output -raw` value is a single line with no newline of
# its own. Diagnostic banners are multi-line. So if more than one non-empty
# line came back, this is not a value — treat the output as absent rather
# than trying to salvage a name out of prose.
if [ "$(printf '%s' "${VALUE}" | tr -d '\r' | grep -c . || true)" -gt 1 ]; then
  VALUE=""
fi

# Strip whitespace/newlines so a trailing newline cannot masquerade as content.
VALUE="$(printf '%s' "${VALUE}" | tr -d '[:space:]')"

# REJECT anything containing terraform's placeholder brackets ANYWHERE, not
# just a value that is entirely bracketed. When an output is undefined,
# terraform echoes the requested name wrapped in angle brackets (e.g.
# `<cluster>`), and a merged-stream wrapper can surround it with banner
# text so the value is not bracketed end to end. Angle brackets can never
# appear in a real AWS identifier — not in a cluster name, a VPC id, an ECR
# URL or a DNS name — so treating ANY bracketed value as absent is safe and
# needs no per-output special casing.
case "${VALUE}" in
  *'<'*|*'>'*) VALUE="" ;;
esac

# Diagnostic text is recognisable even after whitespace has been squeezed
# out of it. Terraform prefixes every diagnostic with one of these words,
# and none of them can begin a real identifier we read from state.
case "${VALUE}" in
  Warning:*|Error:*|Note:*|Nooutputsfound*) VALUE="" ;;
esac

# A bare "null" is what terraform prints for an output defined but unset.
if [ "${VALUE}" = "null" ]; then
  VALUE=""
fi

# Final shape gate. Every output this project reads (cluster name, vpc id,
# ECR URL, role ARN, CIDR, log group) is a single token of printable,
# non-space characters drawn from a conservative identifier alphabet. Any
# leftover prose contains punctuation outside this set — a comma, a pipe
# from a diagnostic box, a quote — and is rejected as absent. This is the
# backstop that makes the helper correct no matter how the streams arrive.
if ! printf '%s' "${VALUE}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/@-]*$'; then
  VALUE=""
fi

printf '%s' "${VALUE}"
