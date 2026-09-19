#!/usr/bin/env bash
#
# Run the full compliance sweep and build the report.
#
# Invoked through scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and configured kubectl.
#
# Deliberately does NOT use `set -e` around the scanners themselves: a scan
# that FINDS problems is a successful scan. The report is the deliverable,
# and it must still be produced (and uploaded) when findings exist. Only a
# failure to actually RUN a scanner, or to build the report, fails the stage.

set -uo pipefail

FAILED=0

echo "::group::kube-bench (CIS Amazon EKS Benchmark)"
if ! bash scripts/run-kube-bench.sh; then
  echo "ERROR: kube-bench failed to run (this is a tooling failure, not a finding)" >&2
  FAILED=1
fi
echo "::endgroup::"

echo "::group::Trivy cluster misconfiguration scan"
if ! bash scripts/run-trivy-cluster.sh; then
  # Non-fatal: Trivy exits non-zero when it finds misconfigurations, which
  # is expected output for a compliance report rather than a broken stage.
  echo "NOTE: Trivy reported findings or failed; see the report for detail."
fi
echo "::endgroup::"

echo "::group::Generate compliance report"
if ! bash scripts/generate-report.sh; then
  echo "ERROR: failed to generate the compliance report" >&2
  FAILED=1
fi
echo "::endgroup::"

if [ -f reports/summary.txt ]; then
  echo "::group::Compliance summary"
  cat reports/summary.txt
  echo "::endgroup::"
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "Compliance stage failed: a scanner or the report builder did not run." >&2
  exit 1
fi

echo "Compliance sweep complete; report written to reports/."
