# shellcheck shell=sh
#
# pm-validate.sh — PURE input predicates for the procedure-gh-issues scripts.
#
# Every function here is a pure predicate: it inspects its argument, returns 0
# or 1, and does NOTHING else — no printing, no exiting, no globals. The
# DIAGNOSTIC and the exit code stay at the call site, because each command's
# error wording is part of its own user-facing contract (and its tests assert
# that exact wording). That split is also what lets this file be sourced
# straight into a test harness and asserted against a full truth table without
# a $PROG, a usage(), or any binary being present.
#
# Sourced by every command in this skill via its PM_LIB_DIR preamble.
#
# NOTE ON THE GITLAB SIBLING: procedure-glab-issues has its OWN physically
# separate pm-validate.sh. The two are deliberately NOT shared — the hub
# deploys each skill directory independently (symlinking it), so a
# cross-family `source` would resolve fine in this repo and then fail only at
# RUNTIME, invisibly past a green test suite, for anyone who installs one skill
# without the other. Duplication here is the cheaper failure mode. The GitLab
# copy is also genuinely different in places (see is_valid_hex_color below).

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the number GitHub would echo back. Both used to slip through and
# surface as a confusing `gh` failure (exit 1) instead of the usage error (exit 2)
# the calling script's own header documents. Kept byte-identical to the GitLab
# siblings' (procedure-glab-issues) so the two families cannot diverge again.
is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;   # empty or a non-digit
		0*) return 1 ;;            # a bare '0', and any leading-zero form
		*) return 0 ;;
	esac
}

# is_valid_repo_slug VALUE — allow-list: letters, digits, '.', '_', '-', and
# EXACTLY ONE '/' separating owner/repo, with NO ".." path segment.
#
# THERE ARE TWO SINKS, and this one predicate guards both (the inline copies
# this replaced each documented only the sink their own script happened to use):
#   * a REST PATH — create-issue.sh and ensure-labels.sh interpolate VALUE
#     directly into `gh api repos/VALUE/...`, where a dot segment would traverse
#     to a different endpoint entirely;
#   * a plain gh ARGUMENT — the other five commands pass VALUE to `gh --repo`.
# Rejecting disallowed characters AND dot-segment traversal (e.g. "o/..",
# "../r") before either sink is reached covers both cases with one rule.
is_valid_repo_slug() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;
		..|../*|*/..|*/../*) return 1 ;;
		*/*/*) return 1 ;;
		*/*) return 0 ;;
		*) return 1 ;;
	esac
}

# is_valid_hex_color VALUE — exactly 6 hex digits, no leading '#'. `case`
# patterns have no {n} quantifier, so the 6 positions are spelled out.
#
# DELIBERATE DIVERGENCE from the GitLab sibling's same-named predicate, which
# ALSO accepts a leading '#': `gh label create --color` wants the bare form,
# whereas glab's own default is written '#428BCA'. Do not "align" these two.
is_valid_hex_color() {
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		*) return 1 ;;
	esac
}
