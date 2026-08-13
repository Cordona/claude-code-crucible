# shellcheck shell=sh
#
# credentials.sh — the curl -K credential-config lifecycle: prefer the
#                  externally-supplied $JIRA_CURL_CONFIG (procedure-jira-auth's
#                  handoff, never deleted here), else build an own 600 mktemp
#                  config from $JIRA_EMAIL/$JIRA_TOKEN.
#
# The token NEVER touches argv — only the config FILENAME does. runtime.sh's
# cleanup() removes the file when (and only when) this unit created it
# ($CURL_CONFIG_IS_OWN).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# Credential handoff
# ---------------------------------------------------------------------------

# curl_config_escape VALUE -> VALUE with backslash escaped FIRST, then the
# double quote — curl's -K config file quoted-string escaping. Order matters
# (same rule as JQL below): escaping the quote first would double-escape a
# backslash that precedes a real quote.
curl_config_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# resolve_credential_config — sets $CURL_CONFIG_FILE to a curl -K config
# file. Prefers the Phase-3 contract ($JIRA_CURL_CONFIG, produced elsewhere
# and never deleted by this script — it treats an externally-supplied file as
# "not its own", and requires its basename to match the confirmed site: see
# the binding check below); falls back to building
# its OWN 600 mktemp file from $JIRA_EMAIL/$JIRA_TOKEN (the Phase-2
# stand-in), whose random mktemp name that check deliberately does NOT apply
# to. Fails closed (exit 1) if neither is available.
resolve_credential_config() {
	if [ -n "${JIRA_CURL_CONFIG:-}" ]; then
		if [ ! -f "$JIRA_CURL_CONFIG" ] || [ ! -r "$JIRA_CURL_CONFIG" ]; then
			error "\$JIRA_CURL_CONFIG points to a missing/unreadable file: $JIRA_CURL_CONFIG"
			exit 1
		fi
		# BIND the supplied file to the CONFIRMED SITE before using it.
		#
		# The calling procedure is required to resolve $JIRA_CURL_CONFIG fresh,
		# in its own process, immediately before every call — precisely so a
		# path can never drift from the site it was confirmed against. Until
		# now nothing here CHECKED that: a stale or mis-paired path (one
		# client's credential, another client's --confirmed-site) was accepted
		# silently and spent against the wrong Jira. This is the same class of
		# guard as require_confirmed_site()'s intended-vs-confirmed comparison,
		# and the same reason it exists — a rule enforced only by the caller's
		# discipline is not enforced.
		#
		# The name is the binding: procedure-jira-auth stores exactly one file
		# per site, at ${JIRA_CRED_DIR}/<site>.cfg, and `jira-curl-config.sh
		# --site <host>` prints that path — so a file resolved for THIS
		# confirmed host is named "<host>.cfg" and a file resolved for another
		# host cannot be. Only the BASENAME is compared: the directory is
		# $JIRA_CRED_DIR's business (it is relocatable), the filename is the
		# contract. Parameter expansion, never `basename` — see jira.sh's
		# Portability header.
		#
		# EXTERNAL CONSTRAINT: this holds for jira-curl-config.sh's DEFAULT
		# output (the persistent store entry), which is the only form the
		# calling procedure uses. Its `--copy` mode prints an mktemp path that
		# carries no site in its name, so it cannot satisfy this assertion —
		# and cannot be made to, since an unnameable file is exactly what
		# there is nothing to bind. --copy is therefore not usable with this
		# engine.
		#
		# CONFIRMED_HOST is set by require_confirmed_site(), which jira.sh runs
		# BEFORE this function; were it ever empty the comparison would look
		# for a file literally named ".cfg" and refuse — fail closed, the
		# correct direction.
		#
		# CASE-INSENSITIVE, because HOSTNAMES ARE: `Foo.atlassian.net` and
		# `foo.atlassian.net` are the same site, and in an agent-relayed
		# pipeline the --confirmed-site spelling and the stored credential
		# file's name diverge easily. A byte-exact compare would refuse a
		# credential that genuinely belongs to the confirmed site, and report
		# it as a cross-site security violation — a false refusal that reads
		# like a real attack. Compared through runtime.sh's `tr`-based
		# downcase() (portable to Bash 3.2 / dash, unlike ${var,,}); the
		# CANONICAL casing is what both halves of the message still show.
		#
		# normalize_site() itself is deliberately left alone: $CONFIRMED_HOST
		# also builds every request URL and feeds jira_curl()'s own host
		# re-check, so case-folding it there has a far wider blast radius than
		# this one comparison needs.
		rcc_config_basename=${JIRA_CURL_CONFIG##*/}
		rcc_expected_basename="${CONFIRMED_HOST}.cfg"
		rcc_config_basename_lc=$(downcase "$rcc_config_basename")
		rcc_expected_basename_lc=$(downcase "$rcc_expected_basename")
		if [ "$rcc_config_basename_lc" != "$rcc_expected_basename_lc" ]; then
			error "\$JIRA_CURL_CONFIG basename '$rcc_config_basename' does not match the confirmed site '$rcc_expected_basename' (compared case-insensitively) — refusing to use a credential file that may belong to a different site"
			exit 1
		fi
		CURL_CONFIG_FILE=$JIRA_CURL_CONFIG
		CURL_CONFIG_IS_OWN=0
		return 0
	fi

	if [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_TOKEN:-}" ]; then
		error "no credentials available: set \$JIRA_CURL_CONFIG (preferred, from procedure-jira-auth) or both \$JIRA_EMAIL and \$JIRA_TOKEN"
		exit 1
	fi

	case "$JIRA_EMAIL" in *"$NL"*) error "\$JIRA_EMAIL must not contain a newline"; exit 1 ;; esac
	case "$JIRA_TOKEN" in *"$NL"*) error "\$JIRA_TOKEN must not contain a newline"; exit 1 ;; esac

	esc_email=$(curl_config_escape "$JIRA_EMAIL")
	esc_token=$(curl_config_escape "$JIRA_TOKEN")

	old_umask=$(umask)
	umask 077
	CURL_CONFIG_FILE=$(mktemp "${TMPDIR:-/tmp}/jira.curlconfig.XXXXXX")
	umask "$old_umask"
	chmod 600 "$CURL_CONFIG_FILE"
	printf 'user = "%s:%s"\n' "$esc_email" "$esc_token" >"$CURL_CONFIG_FILE"
	# shellcheck disable=SC2034  # read by runtime.sh's cleanup() to decide whether this engine owns (and must delete) the config file
	CURL_CONFIG_IS_OWN=1
}
