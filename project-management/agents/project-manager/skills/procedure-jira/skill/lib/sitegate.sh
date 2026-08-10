# shellcheck shell=sh
#
# sitegate.sh — the site gate, in two halves:
#   * the PRESENCE half (assert_confirmed_site_given) — a usage error, run
#     early alongside the per-command argument validation;
#   * the SECURITY half (require_confirmed_site) — the host allow-list and the
#     intended-vs-confirmed site comparison, both of which fail CLOSED.
#
# COUPLING (accepted for this pass, not a defect to fix here): the two
# assertions read $OPT_CONFIRMED_SITE and $JIRA_SITE directly rather than
# taking them as parameters, and set the $CONFIRMED_HOST global every request
# URL is later built from. That is the engine's established plain-globals
# convention (see runtime.sh's CONVENTION note).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# Site gate
# ---------------------------------------------------------------------------

# normalize_site VALUE -> a bare host: strips an optional "http(s)://"
# prefix and anything from the first "/" onward (a path/query, if given).
normalize_site() {
	raw=$1
	host=$(printf '%s' "$raw" | sed -E 's#^[Hh][Tt][Tt][Pp][Ss]?://##')
	host=${host%%/*}
	printf '%s' "$host"
}

# assert_host_allowed HOST -> 0 if HOST matches the allow-list shape and
# contains only host-safe characters, 1 otherwise. The pattern is matched as
# a shell glob (not a literal string) — that IS the allow-list mechanism.
assert_host_allowed() {
	aha_host=$1
	case "$aha_host" in
		*[!A-Za-z0-9.-]*) return 1 ;;
	esac
	# shellcheck disable=SC2254  # deliberate glob match against the configured allow-list pattern, not a literal
	case "$aha_host" in
		$JIRA_HOST_ALLOWLIST_PATTERN) return 0 ;;
		*) return 1 ;;
	esac
}

# assert_confirmed_site_given — the presence half of the site gate.
# A plain usage error (exit 2), so it is checked early, alongside the other
# per-command required-argument validation — before any tool/network check.
assert_confirmed_site_given() {
	[ -n "$OPT_CONFIRMED_SITE" ] || {
		usage >&2
		error "--confirmed-site is required on every command"
		exit 2
	}
}

# require_confirmed_site — the security half of the site gate: assumes
# assert_confirmed_site_given() already ran. Fails closed (exit 1) if the
# host is outside the allow-list, and fails closed (exit 1) if an intended
# site (JIRA_SITE, from the Phase-2 fallback credential path) disagrees with
# it. Sets $CONFIRMED_HOST.
require_confirmed_site() {
	CONFIRMED_HOST=$(normalize_site "$OPT_CONFIRMED_SITE")
	[ -n "$CONFIRMED_HOST" ] || { error "--confirmed-site is empty after normalization"; exit 2; }

	if ! assert_host_allowed "$CONFIRMED_HOST"; then
		error "confirmed site host is not in the allow-list ($JIRA_HOST_ALLOWLIST_PATTERN): $CONFIRMED_HOST"
		exit 1
	fi

	if [ -n "${JIRA_SITE:-}" ]; then
		intended_host=$(normalize_site "$JIRA_SITE")
		if [ "$intended_host" != "$CONFIRMED_HOST" ]; then
			error "site mismatch: intended site '$intended_host' (from \$JIRA_SITE) != confirmed site '$CONFIRMED_HOST' — refusing to proceed"
			exit 1
		fi
	fi
}
