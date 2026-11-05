#!/usr/bin/env bash
# Regenerates ci/trivy/critical-baseline.yaml (a Trivy --ignorefile) from Trivy JSON reports (--format json):
#   ci/trivy/baseline.sh target/trivy-reports/*.json > ci/trivy/critical-baseline.yaml
set -euo pipefail
cat <<'HEADER'
# Critical CVEs that already ship in the Spring Boot 2.0.3 / Java 8 / Axon 3 images (baseline taken 2026-11-05 with
# Trivy 0.76.0). CI (.github/workflows/ci.yml) fails on any critical CVE that is NOT listed here, so a new dependency,
# a new vulnerable version or a newly published CVE still breaks the build. Each entry is pinned to the exact package
# version (purl): upgrading a library drops it out of the baseline instead of carrying the exception forward.
# Most of these are only fixed in Spring Boot 2.5+/3.x, Spring Framework 6/7 and Tomcat 9+, i.e. a stack upgrade
# beyond this migration; the whole file expires so the exception has to be revisited.
# Regenerate with ci/trivy/baseline.sh (see there).
vulnerabilities:
HEADER
jq -rs '
  [.[].Results[]? | .Vulnerabilities[]? | select(.Severity == "CRITICAL") | {id: .VulnerabilityID, purl: .PkgIdentifier.PURL}]
  | group_by(.id)
  | .[]
  | "  - id: \(.[0].id)\n    purls:\n" + ([.[].purl] | unique | map("      - \"\(.)\"") | join("\n"))
    + "\n    statement: pre-existing in the Boot 2.0.3 / Java 8 stack, accepted until the stack upgrade\n    expired_at: 2027-05-01"
' "$@"
