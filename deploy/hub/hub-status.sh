#!/usr/bin/env sh
# hub-status.sh — Capability: the domain status block. What the Main menu shows
#                  at its top, available as a standalone, non-interactive
#                  command so an agent has an exact equivalent of the screen a
#                  human reads (the human/agent parity requirement — a status
#                  block a human can see and an agent cannot would be a
#                  capability gap).
#
# Usage:
#   hub-status.sh [--target DIR] [--source DIR] [--format=text|env|json]
#                 [--no-color] [-h|--help]
#
# Output (text): one labeled line per domain — its install state plus its own
#   sub-selection detail ("(2/9 technologies)", "(GitHub, Jira)").
# Output (env/json): per-domain state, the installed/available selection keys as
#   comma-lists, the four component counts, and the first-run bundle's state.
#
# Exit codes: 0 on success; 1 on an operational failure (--source doesn't
#   resolve, or --format=json is requested without jq installed); 2 usage
#   error; 3 if the user quits from the interactive pause (text format only).
#
# Portability: POSIX sh only. jq is required ONLY for --format=json.
set -eu

HUB_PROG="crucible-hub status"
HUB_DIR0=$(dirname "$0")
. "$HUB_DIR0/lib/hub-common.sh"
. "$HUB_DIR0/lib/hub-domains.sh"
. "$HUB_DIR0/lib/hub-render.sh"
. "$HUB_DIR0/lib/hub-nav.sh"
. "$HUB_DIR0/lib/hub-discovery.sh"
. "$HUB_DIR0/lib/hub-state.sh"
. "$HUB_DIR0/lib/hub-symlink.sh"
. "$HUB_DIR0/lib/hub-bundle.sh"

hub_workspace_init

usage() {
	cat <<EOF
Usage: $HUB_PROG [--target DIR] [--source DIR] [--format=text|env|json] [--no-color] [-h|--help]

Which domains are installed, and what each domain's own selection currently is.

Options:
  --target DIR   Deployed config dir to inspect (default: \$HOME/.claude).
  --source DIR   Framework root to scan (default: the hub's own tree).
  --format FMT   text (default) | env | json.
  --no-color     Disable ANSI color.
  -h, --help     Show this help.
EOF
}

OPT_TARGET=""
OPT_SOURCE=""
OPT_FORMAT=text
HUB_NO_COLOR=${HUB_NO_COLOR:-0}

while [ $# -gt 0 ]; do
	if hub_try_common_opt "$1" "${2:-}" "$#"; then
		shift "$HUB_COMMON_OPT_SHIFT"
		continue
	fi
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	*) die_usage "unknown argument: $1" ;;
	esac
done

hub_validate_format text env json

[ -n "$OPT_TARGET" ] || OPT_TARGET=$(hub_default_target)
[ -n "$OPT_SOURCE" ] || OPT_SOURCE=$(hub_default_source)
TARGET_DIR=$(hub_abspath "$OPT_TARGET")
FRAMEWORK_ROOT=$(hub_realpath "$OPT_SOURCE") || die "cannot resolve --source: $OPT_SOURCE"

hub_discovery_build "$FRAMEWORK_ROOT"
hub_states_build "$TARGET_DIR"
hub_state_counts
BUNDLE_STATE=$(hub_bundle_state "$FRAMEWORK_ROOT" "$TARGET_DIR")

# hub_status_selection_keys SELKIND WANT_INSTALLED -> the comma-list of
# selection keys of one kind whose groups are (WANT_INSTALLED=1) present in any
# form, or (0) entirely absent. One helper for both directions so the "installed"
# and "available" lists can never drift apart in how they classify "partial".
hub_status_selection_keys() {
	hssk_kind=$1
	hssk_want=$2
	hssk_out=""
	for hssk_group in $(hub_selectable_groups "$hssk_kind"); do
		if [ "$(hub_group_state "$hssk_group")" = available ]; then
			[ "$hssk_want" -eq 0 ] || continue
		else
			[ "$hssk_want" -eq 1 ] || continue
		fi
		# A BARE comma, deliberately, unlike the ", " every human-facing list in
		# this hub uses: this value is a machine field (HUB_TECHNOLOGIES) that a
		# caller splits on "," and jq turns into an array, so a space would end up
		# inside every element after the first.
		hssk_out=$(hub_join_append "$hssk_out" "$(hub_group_field "$hssk_group" 6)" ',')
	done
	printf '%s\n' "$hssk_out"
}

TECHNOLOGIES=$(hub_status_selection_keys technology 1)
TECHNOLOGIES_AVAILABLE=$(hub_status_selection_keys technology 0)
PM_BACKENDS=$(hub_status_selection_keys pm-backend 1)
PM_BACKENDS_AVAILABLE=$(hub_status_selection_keys pm-backend 0)

case $OPT_FORMAT in
env)
	hub_env_kv HUB_STATUS ok
	hub_env_kv HUB_ACTION status
	hub_env_kv HUB_TARGET "$TARGET_DIR"
	hub_env_kv HUB_BUNDLE_INSTALLED "$([ "$BUNDLE_STATE" = installed ] && printf true || printf false)"
	HS_N=0
	for HS_DOMAIN in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$HS_DOMAIN" || continue
		HS_N=$((HS_N + 1))
		hub_env_kv "HUB_DOMAIN_${HS_N}_KEY" "$HS_DOMAIN"
		# LABEL is emitted here as well as in the JSON branch: env and json are two
		# first-class equivalent renderings of the same answer, so a field present
		# in one and missing from the other makes the env caller the second-class
		# one for no reason.
		hub_env_kv "HUB_DOMAIN_${HS_N}_LABEL" "$(hub_domain_short_label "$HS_DOMAIN")"
		hub_env_kv "HUB_DOMAIN_${HS_N}_STATE" "$(hub_domain_state "$HS_DOMAIN")"
	done
	hub_env_kv HUB_DOMAIN_COUNT "$HS_N"
	hub_env_kv HUB_TECHNOLOGIES "$TECHNOLOGIES"
	hub_env_kv HUB_TECHNOLOGIES_AVAILABLE "$TECHNOLOGIES_AVAILABLE"
	hub_env_kv HUB_PM_BACKENDS "$PM_BACKENDS"
	hub_env_kv HUB_PM_BACKENDS_AVAILABLE "$PM_BACKENDS_AVAILABLE"
	hub_env_kv HUB_INSTALLED_COUNT "$HUB_COUNT_INSTALLED"
	hub_env_kv HUB_DIVERGED_COUNT "$HUB_COUNT_DIVERGED"
	hub_env_kv HUB_AVAILABLE_COUNT "$HUB_COUNT_AVAILABLE"
	hub_env_kv HUB_DISCOVERED_COUNT "$HUB_COUNT_DISCOVERED"
	;;
json)
	have jq || die "--format=json requires jq, which is not installed"
	HS_DOMAIN_JSON="$(hub_mktemp_dir)/domains.json"
	: >"$HS_DOMAIN_JSON"
	for HS_DOMAIN in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$HS_DOMAIN" || continue
		jq -cn --arg key "$HS_DOMAIN" --arg state "$(hub_domain_state "$HS_DOMAIN")" \
			--arg label "$(hub_domain_short_label "$HS_DOMAIN")" \
			'{key:$key, label:$label, state:$state}' >>"$HS_DOMAIN_JSON"
	done
	jq -n \
		--arg status ok --arg action status --arg target "$TARGET_DIR" \
		--argjson bundle_installed "$([ "$BUNDLE_STATE" = installed ] && printf true || printf false)" \
		--arg technologies "$TECHNOLOGIES" --arg technologies_available "$TECHNOLOGIES_AVAILABLE" \
		--arg pm_backends "$PM_BACKENDS" --arg pm_backends_available "$PM_BACKENDS_AVAILABLE" \
		--argjson installed_count "$HUB_COUNT_INSTALLED" \
		--argjson diverged_count "$HUB_COUNT_DIVERGED" \
		--argjson available_count "$HUB_COUNT_AVAILABLE" \
		--argjson discovered_count "$HUB_COUNT_DISCOVERED" \
		--slurpfile domains "$HS_DOMAIN_JSON" \
		'{status:$status, action:$action, target:$target, bundle_installed:$bundle_installed,
		  domains:$domains,
		  technologies:($technologies | if . == "" then [] else split(",") end),
		  technologies_available:($technologies_available | if . == "" then [] else split(",") end),
		  pm_backends:($pm_backends | if . == "" then [] else split(",") end),
		  pm_backends_available:($pm_backends_available | if . == "" then [] else split(",") end),
		  installed_count:$installed_count, diverged_count:$diverged_count,
		  available_count:$available_count, discovered_count:$discovered_count}'
	;;
text)
	# A live test session found two things worth fixing here, both the same
	# "glyph leads the thing it describes" rule already applied everywhere else
	# in this hub: (1) the glyph now comes BEFORE the domain label, not after a
	# now-redundant "installed"/"partially installed" word — the glyph already
	# says that; (2) "not installed" leads with its own glyph (a yellow hollow
	# circle, hub_glyph_absent — an absent domain is expected, never a failure,
	# so it is neither the same glyph nor color as a genuine problem) and is
	# full-brightness text, not dimmed: a domain being absent is exactly the
	# fact this screen exists to report, not a footnote about it.
	hub_print_header 'Status'
	printf '\n'
	for HS_DOMAIN in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$FRAMEWORK_ROOT" "$HS_DOMAIN" || continue
		HS_STATE=$(hub_domain_state "$HS_DOMAIN")
		HS_DETAIL=$(hub_domain_detail "$HS_DOMAIN")
		case $HS_STATE in
		installed) HS_GLYPH=$(hub_glyph_ok) ;;
		partial) HS_GLYPH=$(hub_glyph_warn) ;;
		*)
			printf '  %s %s: not installed\n' "$(hub_glyph_absent)" "$(hub_domain_short_label "$HS_DOMAIN")"
			continue
			;;
		esac
		# The colon belongs to the DETAIL, not to the label on its own: a domain
		# with no sub-selection (GTD) has no detail to introduce, and printing
		# the colon anyway left it dangling with nothing after it once installed
		# — a gap the mockup never showed because its one worked example had GTD
		# not-installed, where the "not installed" branch above fills the line.
		if [ -n "$HS_DETAIL" ]; then
			printf '  %s %s: %s\n' "$HS_GLYPH" "$(hub_domain_short_label "$HS_DOMAIN")" "$HS_DETAIL"
		else
			printf '  %s %s\n' "$HS_GLYPH" "$(hub_domain_short_label "$HS_DOMAIN")"
		fi
	done
	if [ "$HUB_COUNT_DIVERGED" -gt 0 ]; then
		printf '\n  %s %s installed %s no longer %s source — run "Install" and choose %s to re-sync (see "List").\n' \
			"$(hub_glyph_warn)" "$HUB_COUNT_DIVERGED" \
			"$(hub_plural "$HUB_COUNT_DIVERGED" item items)" \
			"$(hub_plural "$HUB_COUNT_DIVERGED" matches match)" \
			"$(hub_plural "$HUB_COUNT_DIVERGED" it them)"
	fi

	if hub_interactive; then
		HS_PAUSE=0
		hub_press_key_to_continue || HS_PAUSE=$?
		[ "$HS_PAUSE" -ne 3 ] || exit 3
	fi
	;;
esac

exit 0
