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
# That is exactly how a teardown failed here: `ci-api-access.sh` received
# `<cluster>` as its cluster argument and correctly refused it, but only
# AFTER terraform destroy had been prevented from running.
#
# THE RULE: never trust the EXIT STATUS of `terraform output` alone; always
# validate the VALUE. This helper centralises that so every call site gets
# the same behaviour instead of each reinventing a guard that looks right.
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

# stderr is discarded deliberately: when the output is missing, terraform
# writes a multi-line warning there that is noise for the caller. The
# decision is made from the VALUE below, never from stderr or the status.
VALUE="$(cd "${DIR}" && terraform output -raw "${NAME}" 2>/dev/null || true)"

# Strip whitespace/newlines so a trailing newline cannot masquerade as content.
VALUE="$(printf '%s' "${VALUE}" | tr -d '[:space:]')"

# REJECT terraform's placeholder text. When an output is undefined, terraform
# echoes the requested name wrapped in angle brackets (e.g. `<cluster>` for
# cluster_name). Angle brackets can never appear in a real AWS identifier —
# not in a cluster name, a VPC id, an ECR URL or a DNS name — so treating any
# bracketed value as absent is safe and needs no per-output special casing.
case "${VALUE}" in
  '<'*'>') VALUE="" ;;
esac

# A bare "null" is what terraform prints for an output defined but unset.
if [ "${VALUE}" = "null" ]; then
  VALUE=""
fi

printf '%s' "${VALUE}"
