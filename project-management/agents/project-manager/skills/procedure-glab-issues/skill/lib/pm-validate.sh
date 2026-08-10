# shellcheck shell=sh
#
# pm-validate.sh — PURE input predicates for the procedure-glab-issues scripts.
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
# NOTE ON THE GITHUB SIBLING: procedure-gh-issues has its OWN physically
# separate pm-validate.sh. The two are deliberately NOT shared — the hub
# deploys each skill directory independently (symlinking it), so a
# cross-family `source` would resolve fine in this repo and then fail only at
# RUNTIME, invisibly past a green test suite, for anyone who installs one skill
# without the other. Duplication here is the cheaper failure mode. The two
# copies are also genuinely different in places (see is_valid_hex_color below,
# and note that GitHub's is_valid_repo_slug has no counterpart here at all).

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the iid GitLab would echo back. Both used to slip through — and
# in link-children.sh the consequence was worse than a confusing error:
# `--child 0` spliced a dead "- [ ] #0" line into the epic's description and
# reported PM_LINKED=1, a silently WRONG outcome, while `--child 007` would have
# linked issue 7. Elsewhere they merely surfaced as a confusing `glab` failure
# (exit 1) instead of the usage error (exit 2) they are.
is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;   # empty or a non-digit
		0*) return 1 ;;            # a bare '0', and any leading-zero form
		*) return 0 ;;
	esac
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-issues' is_valid_repo_slug: a GitHub slug is
# always exactly OWNER/REPO (that validator hard-rejects a second '/'), but
# GitLab supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is
# still rejected: a bare project name is never a valid full path.
is_valid_gitlab_project_path() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;   # character allow-list
		*//*) return 1 ;;                 # empty segment
		/*|*/) return 1 ;;                # leading / trailing slash
		..|../*|*/..|*/../*) return 1 ;;  # parent-dir traversal segment
		.|./*|*/.|*/./*) return 1 ;;      # current-dir segment
		*/*) return 0 ;;                  # at least one separator: accept
		*) return 1 ;;                    # a single bare segment: reject
	esac
}

# is_valid_confirmed_host VALUE — allow-list for the host the ACCOUNT GATE
# confirmed, before it becomes the calling process's GITLAB_HOST: letters,
# digits, '.', '-', '_' and an optional ':port'. Rejects whitespace, shell
# metacharacters, a leading '-', and any empty label. Spelled the way
# `glab auth status` reports a host — and the way manage_glab_accounts.sh's own
# is_valid_hostname accepts one — so the gate's answer can be passed straight
# through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of that flag is a single unambiguous target
# the caller and the script agree on.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# is_valid_hex_color VALUE — exactly 6 hex digits, with an OPTIONAL leading '#'
# (glab's own default is written '#428BCA', so both spellings are natural
# here). `case` patterns have no {n} quantifier, so the 6 positions are spelled
# out.
#
# DELIBERATE DIVERGENCE from the GitHub sibling's same-named predicate, which
# accepts the bare 6-digit form ONLY, because `gh label create --color` wants it
# without the '#'. Do not "align" these two.
is_valid_hex_color() {
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		'#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		*) return 1 ;;
	esac
}
