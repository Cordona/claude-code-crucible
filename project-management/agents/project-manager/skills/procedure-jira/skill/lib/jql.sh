# shellcheck shell=sh
#
# jql.sh — the engine's ONLY JQL-construction sink.
#
# JQL has no bind-variable API, so safety comes from three rules enforced here
# and nowhere else: field names and operators are a FIXED hardcoded allow-list;
# every user-supplied VALUE is emitted as a quoted JQL string literal with
# backslash escaped FIRST then the double quote; and the literal "me" maps to
# the JQL function currentUser() rather than being quoted as a user named "me".
# `jq --arg` does NOT protect this sink — jql_quoted()/jql_escape_value() do.
#
# COUPLING (accepted for this pass): build_jql() reads the search command's
# OPT_* globals directly rather than taking them as parameters.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# The JQL builder (see the header's Security note)
# ---------------------------------------------------------------------------

# jql_escape_value VALUE -> VALUE with backslash escaped FIRST, then the
# double quote (Atlassian's documented JQL string-literal escape order).
jql_escape_value() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# jql_quoted VALUE -> a properly escaped, double-quoted JQL string literal.
# This — NOT `jq --arg` — is the actual control on the JQL sink (see header).
jql_quoted() {
	jqq_esc=$(jql_escape_value "$1")
	printf '"%s"' "$jqq_esc"
}

JQL_CLAUSES=""

# add_jql_clause CLAUSE — appends CLAUSE to the module-global $JQL_CLAUSES,
# AND-joined. Only ever called with a clause this script itself constructed
# from the fixed field/operator allow-list below — never with a raw user string.
add_jql_clause() {
	if [ -z "$JQL_CLAUSES" ]; then JQL_CLAUSES=$1
	else JQL_CLAUSES="$JQL_CLAUSES AND $1"
	fi
}

# build_jql — reads the search command's OPT_* globals, returns the final
# JQL string on stdout. Field names/operators below are a FIXED, hardcoded
# allow-list; the only thing that varies with user input is the escaped,
# quoted VALUE on the right-hand side of each "=".
build_jql() {
	if [ -n "$OPT_JQL" ]; then
		# Raw passthrough — see the header's Security note: this is the
		# caller querying their OWN instance with their OWN token, not
		# something this builder's escaping applies to.
		printf '%s' "$OPT_JQL"
		return 0
	fi

	JQL_CLAUSES=""

	if [ -n "$OPT_PROJECT" ]; then
		add_jql_clause "project = $(jql_quoted "$OPT_PROJECT")"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		case "$OPT_ASSIGNEE" in
			[Mm][Ee])
				add_jql_clause "assignee = currentUser()"
				;;
			*)
				bjq_resolved_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
				add_jql_clause "assignee = $(jql_quoted "$bjq_resolved_account_id")"
				;;
		esac
	fi

	if [ -n "$OPT_STATUS" ]; then
		add_jql_clause "status = $(jql_quoted "$OPT_STATUS")"
	fi

	if [ -n "$OPT_TYPE" ]; then
		bjq_resolved_type=$(resolve_type_alias "$PROJECT_CONFIG_FILE" "$OPT_TYPE")
		add_jql_clause "type = $(jql_quoted "$bjq_resolved_type")"
	fi

	if [ -n "$OPT_LABELS" ]; then
		bjq_label_clauses=""
		bjq_old_ifs=$IFS
		IFS=','
		set -f
		# shellcheck disable=SC2086  # deliberate comma-split; -f (above) blocks globbing
		set -- $OPT_LABELS
		set +f
		IFS=$bjq_old_ifs
		for bjq_lbl in "$@"; do
			bjq_trimmed=$(printf '%s' "$bjq_lbl" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -n "$bjq_trimmed" ] || continue
			bjq_one="labels = $(jql_quoted "$bjq_trimmed")"
			if [ -z "$bjq_label_clauses" ]; then bjq_label_clauses=$bjq_one
			else bjq_label_clauses="$bjq_label_clauses OR $bjq_one"
			fi
		done
		[ -z "$bjq_label_clauses" ] || add_jql_clause "($bjq_label_clauses)"
	fi

	[ -n "$JQL_CLAUSES" ] || {
		usage >&2
		error "search requires at least one filter: --project/--assignee/--status/--type/--labels/--jql"
		exit 2
	}
	printf '%s' "$JQL_CLAUSES"
}
