# The findings of scan.sh that need action, as SARIF for GitHub code scanning:
# every secret, the pending Critical and Important Fedora security updates,
# and HIGH or CRITICAL vulnerabilities in files the image adds itself. The
# rest (RPM binaries as trivy sees them, upstream releases) stays in the step
# summary and the log: as alerts it would bury these.
#
# Inputs (jq -n): $secrets and $vulns, scan.sh's TSV files; $adv, dnf's
# advisory list (slurped); $gated, advisories.sh's lines (raw: ADVISORY
# SEVERITY PACKAGES WHY), and $rule, advisories.sh --rule; $repo, the
# repository URL.
#
# Paths are image paths, not files in this repository, so GitHub shows them
# without source. The fingerprints are this scan's own, so an alert keeps its
# identity from one build to the next and closes when a build no longer has it.

def rows: split("\n") | map(select(length > 0) | split("\t"));

# GitHub's severity bands: 9.0 and up is critical, 7.0 to 8.9 high.
def score: {"CRITICAL": "9.5", "HIGH": "8.0"}[.] // "5.0";

def advisory_uri:
    if startswith("CVE-") then "https://www.cve.org/CVERecord?id=\(.)"
    elif startswith("GHSA-") then "https://github.com/advisories/\(.)"
    elif startswith("GO-") then "https://pkg.go.dev/vuln/\(.)"
    else null end;

# scan.sh's TSV columns:
#   secrets: path, rule, severity, title, line
#   vulns:   class, path, id, severity, status, package, installed, fixed,
#            "malicious" (CWE-506) or empty
( [ $secrets | rows[] | {
      rule: "secret/\(.[1])",
      title: .[3],
      severity: "9.5",
      level: "error",
      uri: .[0],
      line: ((.[4] | tonumber?) // 1),
      text: "\(.[3]) at /\(.[0]), line \(.[4]). Anything secret in the image is the same on every machine that runs it, and public with the image.",
      help: null,
      key: "\(.[0])|\(.[4])"
  } ]
# Known-malicious code (CWE-506) in any class, as an error; otherwise the
# image's own files only.
+ [ $vulns | rows[]
    | select(.[8] == "malicious" or (.[0] == "image" and (.[3] == "CRITICAL" or .[3] == "HIGH"))) | {
      rule: .[2],
      title: (if .[8] == "malicious" then "\(.[2]): known-malicious code" else .[2] end),
      severity: (if .[8] == "malicious" then "9.5" else (.[3] | score) end),
      level: (if .[8] == "malicious" or (.[3] == "CRITICAL" and .[4] == "fixed") then "error" else "warning" end),
      uri: .[1],
      line: 1,
      text: (if .[8] == "malicious"
             then "\(.[2]): \(.[5]) \(.[6]) at /\(.[1]) is a release known to carry malicious code (CWE-506). Replace it, whoever built it."
             else "\(.[2]) (\(.[3])) in \(.[5]) \(.[6]), /\(.[1]). "
                  + (if .[7] != "" then "Fixed in \(.[7])." else "No fixed version yet." end)
             end),
      help: (.[2] | advisory_uri),
      key: "\(.[1])|\(.[5])"
  } ]
# The Fedora updates the image lacks: an error where the push fails on them
# (advisories.sh's WHY), a warning otherwise. An update a rebuild was
# started for may be one dnf does not list here (the scan read a mirror as
# far behind as the build's), hence the second source.
+ [ ($gated | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[3]}) | add // {}) as $why
    | ($adv[0]
       | map(select(.type == "security" and (.severity == "Critical" or .severity == "Important")))
       | group_by(.name) | map({name: .[0].name, severity: .[0].severity, packages: map(.nevra)}))
      + ($gated | split("\n") | map(select(length > 0) | split(" ")
         | {name: .[0], severity: .[1], packages: (.[2] | split(","))}))
    | unique_by(.name)[] | ($why[.name] // "") as $w | {
      rule: .name,
      title: "Fedora \(.severity) security update",
      severity: (if .severity == "Critical" then "9.5" else "8.0" end),
      level: (if $w == "seen" or $w == "unrecorded" or $w == "required" then "error" else "warning" end),
      uri: "usr/lib/sysimage/rpm",
      line: 1,
      text: ("Fedora's \(.severity) security update \(.name) is not in the image: \(.packages | join(", ")). "
             + {
                 seen: "Its build's own dnf knew it, so dnf could not install it or a later step replaced it: the build log says which.",
                 unrecorded: "The image has no record of what its build's dnf knew (/usr/share/fedora-bootc/advisories-at-build.json), so nothing says it could not have had it.",
                 required: "This rebuild was started for it (security.yml) and does not contain it: its build's dnf did not have it yet (a mirror behind) or could not install it (the build log says). security.yml starts the rebuild again tomorrow.",
                 newer: "It reached Fedora's mirrors after the build read them, so the next build has it. It does not fail the push (\($rule), .github/actions/scan-image/advisories.sh); security.yml releases a rebuild of the published images once it is due.",
                 "": "It does not fail the push, which takes \($rule) (.github/actions/scan-image/advisories.sh)."
               }[$w]),
      help: "https://bodhi.fedoraproject.org/updates/\(.name)",
      key: "rpm"
  } ]
) as $findings
| {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: { driver: {
        name: "scan-image",
        informationUri: "\($repo)/tree/main/.github/actions/scan-image",
        rules: ($findings | group_by(.rule) | map(.[0] | {
          id: .rule,
          shortDescription: { text: .title },
          properties: { "security-severity": .severity, tags: ["security"] }
        } + (if .help then { helpUri: .help } else {} end)))
      } },
      results: ($findings | unique_by(.rule + "|" + .key) | map({
        ruleId: .rule,
        level: .level,
        message: { text: .text },
        locations: [{ physicalLocation: {
          artifactLocation: { uri: .uri },
          region: { startLine: .line }
        } }],
        partialFingerprints: { "scanImage/v1": "\(.rule)|\(.key)" }
      }))
    }]
  }
