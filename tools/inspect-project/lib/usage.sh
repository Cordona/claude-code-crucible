# shellcheck shell=sh
#
# usage.sh — the `--help` text and the two argument-presence assertions the
#            dispatcher's parse loop calls. Split out for the same reason
#            procedure-jira splits its own: the usage text is the ONE artifact a
#            flag change must not be allowed to drift from, so it lives next to
#            nothing else.
#
# Sourced by inspect-project.sh — never executed directly.

usage() {
	cat <<EOF
Usage: $PROG --project /abs/path --scope changed-only|all --engine intellij|sonar|both
              [--output-root /abs/path] [--idea-bin /path/to/idea]
              [--sonar-host-url URL] [--sonar-token TOKEN] [--allow-plaintext-token]
              [--exclude-ids ID1,ID2,...]
       $PROG                 (no flags — collect the same values interactively)

Run static-analysis inspections (IntelliJ IDEA headless \`inspect\` and/or a local
SonarQube scan) against a project and normalize the results into JSON.

Required (omit any and the interactive menu runs instead, when on a terminal):
  --project PATH       Absolute path to the target project.
  --scope SCOPE        changed-only (staged+unstaged+untracked vs HEAD) or all.
  --engine ENGINE      intellij, sonar, or both.

Optional:
  --output-root PATH   Absolute results base directory.
                         Default: $OUTPUT_ROOT_DEFAULT
  --idea-bin PATH      The real IntelliJ binary. Wins over \$IDEA_BIN and over
                         every autodetection step.
  --sonar-host-url URL SonarQube server. Default: \$SONAR_HOST_URL, else
                         $SONAR_HOST_URL_DEFAULT
  --sonar-token TOKEN  SonarQube token. PREFER \$SONAR_TOKEN — an argv token is
                         visible to any local user via \`ps\`, and this script
                         warns when the flag is used for exactly that reason.
  --allow-plaintext-token
                       Permit a token to cross plaintext http to a NON-loopback
                         host. Without it that combination is REFUSED: Sonar is
                         reported unavailable, so \`--engine sonar\` exits 1 and
                         \`--engine both\` runs IntelliJ alone. With it, the
                         exposure is also reported on stdout as
                         INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING. A host URL
                         carrying \`user:pass@\` credentials is always refused.
  --exclude-ids IDS    Comma-separated IntelliJ inspection ids to drop from the
                         output. Replaces the default list; a leading \`+\`
                         extends it instead; an empty value disables exclusion.
                         Default: $EXCLUDE_IDS_DEFAULT
  -h, --help           Show this help.

Output layout:
  <output-root>/YYYY/MM/DD/<project-name>/<HH-MM-SS>/{intellij.json,sonar.json}

On success, stdout carries the machine-parseable keys:
  INSPECT_RUN_DIR=<dir>
  INSPECT_INTELLIJ_OUTPUT=<file>        (only when the IntelliJ engine ran)
  INSPECT_SONAR_OUTPUT=<file>           (only when the Sonar engine ran)
  INSPECT_SONAR_SKIPPED_REASON=<text>   (only when --engine both degraded)
  INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING=<text>
                                        (only when --allow-plaintext-token let
                                         the token cross plaintext http)
Everything else — progress, warnings, the human summary — goes to stderr.

Inspecting a project runs the project's OWN tooling against it (IntelliJ
evaluates its build logic and plugins; git may run its clean/smudge filters), so
pointing this at a repository you do not trust runs code from it as you. See the
trust-assumption header in this script for what is and is not mitigated.

Exit codes:
  0  the requested engines ran (finding issues is NOT a failure)
  1  unresolvable IntelliJ binary · an IntelliJ IDE already running from the
     resolved binary (the headless CLI cannot be a second instance) · an
     explicitly requested \`--engine sonar\` unavailable · an engine or a git index
     restore failed · a required tool absent
  2  usage error (missing/unknown option, bad --scope/--engine value,
     non-absolute or missing --project, an incomplete flag set with no terminal
     to prompt on)
EOF
}

# need_arg FLAG VALUE — the ordinary "this option takes a value" assertion.
# Rejects an empty value, which for every flag here is a caller mistake rather
# than a meaningful input.
need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# need_arg_allow_empty FLAG ARGC — the same assertion for the ONE flag whose
# empty value is meaningful: `--exclude-ids ''` means "exclude nothing". It
# cannot test the value (an empty value is legal), so it tests that a value was
# supplied at all, by argument count.
need_arg_allow_empty() {
	[ "${2:-0}" -ge 2 ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}
