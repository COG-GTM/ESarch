#!/usr/bin/env bash
# Prints the vulnerabilities: entries of ci/trivy/critical-baseline.yaml from Trivy JSON reports (--format json).
set -euo pipefail
jq -rs '
  [.[].Results[]? | .Vulnerabilities[]? | select(.Severity == "CRITICAL") | {id: .VulnerabilityID, purl: .PkgIdentifier.PURL}]
  | group_by(.id)
  | .[]
  | "  - id: \(.[0].id)\n    purls:\n" + ([.[].purl] | unique | map("      - \"\(.)\"") | join("\n"))
    + "\n    statement: pre-existing in the Boot 2.0.3 / Java 8 stack, accepted until the stack upgrade\n    expired_at: 2027-05-01"
' "$@"
