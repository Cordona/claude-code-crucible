# shellcheck shell=sh
#
# pm-glab-url.sh — locate issue/note URLs in glab's human-oriented output.
#
# glab's output decoration is NOT a documented contract (and `glab issue
# create`/`update`/`note` support no `--output json`), so a URL is located by
# SHAPE rather than by line or column position. awk always exits 0, so none of
# this ever trips `set -e`.
#
# WHY BOTH PATH SEGMENTS ARE ACCEPTED: GitLab migrated issue URLs to the
# work-items path, and current glab prints ".../-/work_items/<iid>" —
# live-confirmed against a real project, where matching only "/issues/" made
# the extractor return nothing (create-issue.sh then aborted with "reported
# success but printed no issue URL" even though the issue HAD been created, and
# update/comment left their URL key empty despite glab printing a perfectly good
# URL). The classic "/issues/<iid>" shape is KEPT rather than swapped out,
# because an older self-managed instance or a future glab talking to a
# differently-configured server may still emit it; accepting either is strictly
# safer than trading one hard assumption for another.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# points here instead of restating it:
#   * glab prints the issue TITLE on the line BEFORE the URL, so a title (or a
#     comment body) that merely LOOKS like an issue URL used to be picked up
#     instead of the real one: the first shape match in the whole captured
#     output won, and the reported URL then pointed at something the caller
#     never created or never touched — which a follow-up comment.sh or
#     link-children.sh would then target.
#   * So a candidate must be a URL of the CONFIRMED --repo project ON the
#     CONFIRMED --confirmed-host instance, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat. DISTINCT is judged on the
#     CASE-NORMALIZED url, not on raw bytes — see SHELL-006 below.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller
#     never chooses between occurrences: it either has exactly one surviving
#     line and takes it, or it has 2+ — which can only mean genuinely different
#     URLs, i.e. ambiguity or a spoof — and fails closed. Identical repeats
#     collapse to one candidate, so a title quoting the real URL verbatim is
#     harmless.
#
# WHAT IS DELIBERATELY *NOT* HERE: the policy for 0 / 1 / 2+ candidates. That
# diverges per call site and must stay there — create-issue.sh EXITS 1 on
# ambiguity (its URL is load-bearing: PM_ISSUE_NUMBER is derived from it and
# every follow-up operation is keyed off it), whereas update-issue.sh and
# comment.sh only empty their key and warn (their URL is a documented courtesy
# field, and the write already succeeded, so inventing a failure would turn a
# completed edit into a false error).
#
# HOW THE PROJECT MATCH IS ANCHORED: the repo path must follow the HOST
# DIRECTLY. An unanchored `index($i, "/" repo "/")` substring test accepted the
# project path at ANY depth under ANY host, so
# "https://attacker.example/x/<repo>/-/issues/5" qualified — the ambiguity guard
# usually caught it (a genuine URL is normally present too, making 2+
# candidates), but the filter must not lean on that backstop alone. So: scheme +
# authority are split off, the remaining path's LITERAL prefix must be "<repo>/",
# and what follows must be one of GitLab's own issue routes. The prefix test is a
# literal string compare, never a regex, so a '.' in a project path cannot act as
# a wildcard and no metacharacter escaping is needed.
#
# HOW THE HOST IS CONSTRAINED (SEC-002): anchoring the path was not enough on its
# own, because it said nothing about WHICH SERVER the URL names. The same project
# path and the same iid exist on any host an attacker controls, so
# "https://evil.example/<repo>/-/issues/5" satisfied every path test and could be
# relayed as the genuine issue URL. Each extractor therefore takes the
# ALREADY-CONFIRMED host (the very value --confirmed-host pins GITLAB_HOST to, so
# it is the only host glab can legitimately have printed) as a third parameter
# and requires the candidate's AUTHORITY COMPONENT — everything between "://" and
# the next "/" — to equal it, WHOLE and with only ASCII case folded away. Whole,
# not a suffix test, and never a regex: a suffix test would accept
# "evil-gitlab.com" for "gitlab.com", and a regex would let a '.' in the host
# match anything. A URL on any other host is not a candidate at all, so it can
# neither be relayed NOR inflate the candidate count into a spurious ambiguity
# failure.
#
# WHY THE COMPARE IS CASE-INSENSITIVE (SHELL-001): host names are case-insensitive
# by definition (RFC 4343), so "GitLab.Example.com" and "gitlab.example.com" name
# ONE server — but a byte-literal compare called them different and rejected EVERY
# candidate. The consequence was strictly worse than the attack SEC-002 closed:
# with zero candidates, create-issue.sh exits 1 with "printed no issue URL" for an
# issue it HAD genuinely created — a false failure on a completed, unretractable
# write, which then invites a duplicate. Both sides go through awk's tolower()
# (the confirmed host once, in BEGIN, since it is loop-invariant). This costs no
# security: case folding maps distinct host names onto each other only when they
# were already the same name, and both sides are constrained to ASCII —
# is_valid_confirmed_host allows only [A-Za-z0-9._:-], and a non-ASCII host would
# reach glab punycoded.
#
# WHY THE DEDUP KEY IS NORMALIZED TOO (SHELL-006): folding the HOST TEST without
# folding the DEDUP KEY left the two halves disagreeing about what "the same URL"
# means. Before the fold, the byte-literal host test admitted at most the ONE
# spelling that matched --confirmed-host exactly, so keying `seen[]` on the raw
# token was sufficient — every survivor already had a byte-identical authority.
# After it, "https://GitLab.example.com/<repo>/-/issues/5" and
# "https://gitlab.example.com/<repo>/-/issues/5" BOTH pass the host test and, on a
# raw-token key, are then counted as TWO DISTINCT candidates for ONE issue. That
# hands the ambiguity guard a false positive on a single real URL, and in
# create-issue.sh — where the guard is EXIT 1 — it fails a completed,
# unretractable create, the very class of false failure SHELL-001 existed to
# remove. So the key is the candidate rebuilt with its AUTHORITY lowercased
# (scheme + tolower(authority) + path): exactly the difference the host test has
# already agreed to ignore, and nothing more. The SCHEME, the PORT and the PATH
# stay byte-literal in the key, so http vs https, ':8443' vs none, and two
# different iids all remain DISTINCT candidates — the guard's real job, catching
# genuinely different URLs, is untouched. What is PRINTED is still the ORIGINAL
# first-seen spelling, never the normalized form: the caller relays the URL glab
# actually emitted, not one this code invented.
#
# WHY THE PORT IS STILL COMPARED LITERALLY: the fold is applied to CASE only. A
# ':port' difference is a real signal — a different port is a different endpoint,
# possibly a different service on the same box — so "gitlab.example.com:8443" does
# NOT match "gitlab.example.com". The residual risk is a self-managed instance
# whose external_url (which is what GitLab puts in web_url, and therefore what
# glab prints) disagrees with how the caller reaches it — e.g. a port-qualified
# --confirmed-host behind a proxy that terminates on the default port. That cannot
# be settled from here: it is a property of a live instance's configuration, not of
# this code, and normalizing it away (dropping the port, or treating :443/:80 as
# absent) would be guessing at a deployment we have never observed. It is recorded
# instead as a live-verification item in SKILL.md ("Genuinely open"), where the
# other unprovable-by-stub host contracts live. If it is ever observed in the
# field, fix it HERE — never by loosening the whole-authority compare.

# extract_issue_url_candidates TEXT REPO HOST — print every DISTINCT
# whitespace-delimited token in TEXT that is an ISSUE URL of THIS project ON
# THIS host, one per line, in first-appearance order.
#
# THESE TWO EXTRACTORS ARE DELIBERATELY SEPARATE FUNCTIONS, NOT ONE WITH A MODE
# FLAG. They differ by exactly one regex anchor — the optional "#note_<id>"
# suffix below — and that single character class is load-bearing in OPPOSITE
# directions: comment.sh MUST accept a note anchor (that is what glab prints for
# a note), while create-issue.sh and update-issue.sh MUST reject it, because a
# note URL is not the issue URL they are reporting. Unifying them behind a
# boolean/mode parameter would be a flag argument switching behavior — the
# pattern this codebase's conventions reject — and would make the one difference
# that matters invisible at the call site. A test pins the difference from the
# update side; see the harness's "note-anchor" section.
extract_issue_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" -v host="$3" '
		BEGIN { host_lower = tolower(host) }
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				authority_and_path = tok
				sub(/^https?:\/\//, "", authority_and_path)
				scheme_prefix = substr(tok, 1, length(tok) - length(authority_and_path))
				authority = authority_and_path
				sub(/\/.*$/, "", authority)
				if (tolower(authority) != host_lower) continue
				path = authority_and_path
				sub(/^[^\/]*\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				route = substr(path, length(repo) + 2)
				if (route !~ /^(-\/)?(issues|work_items)\/[0-9]+$/) continue
				# Keyed on the CASE-NORMALIZED url, never the raw token — see
				# SHELL-006 in the header. What is PRINTED stays the original
				# first-seen spelling.
				url_key = scheme_prefix tolower(authority) "/" path
				if (url_key in seen) continue
				seen[url_key] = 1
				print tok
			}
		}
	'
}

# extract_note_url_candidates TEXT REPO HOST — as above, but ALSO accepts an
# issue-note URL: the same issue routes with an optional "#note_<id>" anchor.
# See the note on extract_issue_url_candidates for why this is a second function
# rather than a mode of the first.
extract_note_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" -v host="$3" '
		BEGIN { host_lower = tolower(host) }
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				authority_and_path = tok
				sub(/^https?:\/\//, "", authority_and_path)
				scheme_prefix = substr(tok, 1, length(tok) - length(authority_and_path))
				authority = authority_and_path
				sub(/\/.*$/, "", authority)
				if (tolower(authority) != host_lower) continue
				path = authority_and_path
				sub(/^[^\/]*\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				route = substr(path, length(repo) + 2)
				if (route !~ /^(-\/)?(issues|work_items)\/[0-9]+(#note_[0-9]+)?$/) continue
				# Keyed on the CASE-NORMALIZED url, never the raw token — see
				# SHELL-006 in the header. What is PRINTED stays the original
				# first-seen spelling.
				url_key = scheme_prefix tolower(authority) "/" path
				if (url_key in seen) continue
				seen[url_key] = 1
				print tok
			}
		}
	'
}

# ---------------------------------------------------------------------------
# Resolving the ONE surviving candidate against an iid the caller already knows.
#
# comment.sh and update-issue.sh both reach a point where the ambiguity guard has
# left exactly one candidate and the script was HANDED, as an argument, the iid it
# just wrote to. That makes the argument authoritative ground truth, so the
# candidate's own iid must equal it literally — otherwise a project-matching URL
# for some OTHER issue (a URL-shaped title or comment naming a different iid)
# would be relayed as this operation's URL.
#
# The two sites hand-rolled that comparison and had already DRIFTED: comment.sh
# stripped the '#note_<id>' anchor before taking the trailing segment, while
# update-issue.sh did not. The anchor strip is correct in both — it is a no-op for
# update-issue.sh, whose extractor rejects anchored URLs outright — so the merged
# form below is the comment.sh behavior, applied to both.
#
# CALLER CONTRACT — WHY THERE IS NO HOST CHECK HERE: the input MUST be output of
# one of the two extractors above, which is the only way a value reaches these
# functions today. Those already require the confirmed host and the confirmed
# project path, so re-testing the host here would be unreachable code that no test
# could ever exercise. Anything that starts feeding these a URL from another
# source must run it through an extractor FIRST.
# ---------------------------------------------------------------------------

# pm_url_iid URL — print URL's ISSUE iid: its trailing path segment, with any
# '#note_<id>' anchor removed FIRST so the ISSUE iid is read rather than the NOTE
# id. Used for the mismatch diagnostic as well as by pm_url_matching_iid.
pm_url_iid() {
	_pm_url_iid=${1%%#*}
	printf '%s' "${_pm_url_iid##*/}"
}

# pm_url_matching_iid URL IID — print URL if its own issue iid equals IID, and
# print NOTHING otherwise.
#
# ALWAYS RETURNS 0, deliberately: every caller assigns this through a command
# substitution, and under `set -e` a non-zero return would abort the script on the
# mismatch branch — which is explicitly NOT a failure here (the tracker write
# already succeeded; only the courtesy URL key is withheld). The caller detects a
# mismatch by the empty result.
pm_url_matching_iid() {
	[ "$(pm_url_iid "$1")" = "$2" ] || return 0
	printf '%s' "$1"
}
