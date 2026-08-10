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
# "not its own"); falls back to building
# its OWN 600 mktemp file from $JIRA_EMAIL/$JIRA_TOKEN (the Phase-2
# stand-in). Fails closed (exit 1) if neither is available.
resolve_credential_config() {
	if [ -n "${JIRA_CURL_CONFIG:-}" ]; then
		if [ ! -f "$JIRA_CURL_CONFIG" ] || [ ! -r "$JIRA_CURL_CONFIG" ]; then
			error "\$JIRA_CURL_CONFIG points to a missing/unreadable file: $JIRA_CURL_CONFIG"
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
