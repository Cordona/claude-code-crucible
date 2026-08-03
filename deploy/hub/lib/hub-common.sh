#!/usr/bin/env sh
# lib/hub-common.sh — shared diagnostics, flag parsing, path resolution,
#                      TTY/color detection, temp-workspace management and the
#                      small column-formatting primitives every hub script
#                      sources.
#
# NOT executable on its own: sourced (". lib/hub-common.sh") by every
# capability script (hub-status.sh, hub-list.sh, hub-doctor.sh,
# hub-accounts.sh, hub-install.sh, hub-uninstall.sh) and by the crucible-hub
# entrypoint. A sourcing script must set HUB_PROG (its own display name, e.g.
# "crucible-hub install") BEFORE sourcing this file, and must itself already
# be running under `set -eu` — this file relies on the caller's strict mode
# rather than re-asserting its own (a sourced file cannot safely change the
# caller's shell options after the fact in every POSIX sh).
#
# PROVENANCE: this module is carried over, near-verbatim, from the previous
# (tier-model) hub at deploy/hub/lib/hub-common.sh. It is deliberately
# unchanged in substance because none of it is tier-aware — it is terminal
# plumbing (portable realpath, NO_COLOR handling, the TTY-in-a-command-
# substitution trap, mktemp nesting, dynamic column widths) that was already
# reviewed and proven. The domain restructuring touches DISCOVERY and SCREENS,
# not this. Two things were dropped as genuinely dead under the new model:
# HUB_KIND_SORT_ORDER / hub_sort_by_kind_then_name (the domain model orders
# rows by group and display name, never by kind-then-internal-name).
#
# Portability: POSIX sh only (no bashisms), matching this repo's existing
# shell convention. Runs identically on macOS (BSD userland / Bash 3.2) and
# Linux (GNU coreutils).

: "${HUB_PROG:=crucible-hub}"

LC_ALL=C
export LC_ALL

# HUB_TAB — a literal TAB, computed once rather than via a fresh
# `$(printf '\t')` command substitution at every `IFS=... read` call site.
# Consumed by every OTHER hub script/lib that sources this file; shellcheck,
# run against this file in isolation, cannot see those call sites and flags it
# as unused (SC2034) — confirmed clean when shellcheck runs against an actual
# entrypoint with -x, which follows the `.` source chain.
#
# ===========================================================================
# THE TAB TRAP — read this before adding any `IFS="$HUB_TAB" read` loop.
# ===========================================================================
# TAB is one of the shell's IFS *WHITESPACE* characters (space, tab, newline).
# Setting IFS to a tab therefore does NOT give you strict one-tab-one-field
# splitting: consecutive tabs COLLAPSE into a single delimiter, exactly as
# consecutive spaces would. A row like "a<TAB>b<TAB><TAB>0" reads as THREE
# fields, not four, and every variable after the empty column silently receives
# the wrong value — no error, no warning, just shifted data. (awk -F '\t' does
# not behave this way; it splits strictly. The trap is specific to `read`.)
#
# THE RULE, applied to every TSV in this hub: a table read by `read` never has
# an empty column except the LAST one. When a field can be empty, it goes last
# (a trailing delimiter is stripped and the final variable correctly ends up
# empty), or the table is read with awk instead of `read`. The group table,
# whose middle columns are legitimately empty for non-selectable groups, is read
# exclusively through awk-backed accessors for this reason.
#
# THE SECOND HALF OF THE SAME RULE — no field may CONTAIN a TAB. An embedded TAB
# inside a value is indistinguishable from a column separator, so a crafted value
# shifts every later column and can forge the fields after it (a unit name
# carrying a TAB could forge its own kind/src). Every value that reaches a TSV
# read by `read` is therefore either hub-generated (a state word, a count, a
# kind) or a DISCOVERED UNIT NAME — and a unit name cannot contain a TAB because
# HUB_NAME_CHARSET_RE below does not admit one, checked at the single point every
# name enters the pipeline (lib/hub-discovery.sh's hub_discovery_build). TAB
# rejection needs no carve-out of its own: it falls out of the charset.
# shellcheck disable=SC2034
HUB_TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Diagnostics — always stderr, so stdout stays machine-clean for HUB_* output.
# ---------------------------------------------------------------------------
warn() {
	printf '%s: %s\n' "$HUB_PROG" "$*" >&2
}

die() {
	warn "$*"
	exit 1
}

die_usage() {
	warn "$*"
	warn "run '$HUB_PROG --help' for usage"
	exit 2
}

have() {
	command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Shared flag parsing — --target/--source/--format/--json/--no-color are
# identical across every capability script; this is that one shared
# implementation instead of six near-verbatim copies of the same case arms.
# -h/--help stays local to each script (each has its own usage text), and
# every script-specific flag (--domains, --technologies, --all, ...) stays in
# that script's own case statement.
# ---------------------------------------------------------------------------

# hub_try_common_opt ARG1 ARG2 REMAINING -> if ARG1 is one of
# --target[=]/--source[=]/--format[=]/--json/--no-color, assigns the matching
# OPT_TARGET/OPT_SOURCE/OPT_FORMAT/HUB_NO_COLOR global, sets
# HUB_COMMON_OPT_SHIFT to how many positional args were consumed (1 or 2), and
# returns 0. Returns 1 (consuming nothing) for anything else, so the caller's
# own case statement handles its script-specific flags.
#
# ARG2 and REMAINING must be the caller's own "${2:-}" and "$#" AT THE TIME OF
# THE CALL — REMAINING (not "is ARG2 non-empty") is what decides whether a
# value-taking flag was actually given a following argument, so `--target`
# with nothing after it is a usage error even if some later, unrelated
# argument happens to be an empty string.
hub_try_common_opt() {
	htco_arg1=$1
	htco_arg2=$2
	htco_remaining=$3

	# shellcheck disable=SC2034 # OPT_TARGET/OPT_SOURCE/HUB_COMMON_OPT_SHIFT
	# are consumed by every CALLER of this function, never read inside this
	# file itself (unlike OPT_FORMAT/HUB_NO_COLOR, which hub_validate_format/
	# hub_color_enabled elsewhere in this same file DO read) — the same
	# disclosed cross-file false positive as HUB_TAB above.
	case $htco_arg1 in
	--target)
		[ "$htco_remaining" -ge 2 ] || die_usage "--target requires an argument"
		OPT_TARGET=$htco_arg2
		HUB_COMMON_OPT_SHIFT=2
		;;
	--target=*)
		OPT_TARGET=${htco_arg1#--target=}
		HUB_COMMON_OPT_SHIFT=1
		;;
	--source)
		[ "$htco_remaining" -ge 2 ] || die_usage "--source requires an argument"
		OPT_SOURCE=$htco_arg2
		HUB_COMMON_OPT_SHIFT=2
		;;
	--source=*)
		OPT_SOURCE=${htco_arg1#--source=}
		HUB_COMMON_OPT_SHIFT=1
		;;
	--format)
		[ "$htco_remaining" -ge 2 ] || die_usage "--format requires an argument"
		OPT_FORMAT=$htco_arg2
		HUB_COMMON_OPT_SHIFT=2
		;;
	--format=*)
		OPT_FORMAT=${htco_arg1#--format=}
		HUB_COMMON_OPT_SHIFT=1
		;;
	--json)
		OPT_FORMAT=json
		HUB_COMMON_OPT_SHIFT=1
		;;
	--no-color)
		HUB_NO_COLOR=1
		HUB_COMMON_OPT_SHIFT=1
		;;
	--accessible)
		# Exported, not merely set: hub-doctor.sh renders its Accounts block by
		# delegating to hub-accounts.sh, and a child process that did not inherit
		# the flag would print Unicode glyphs into the middle of an
		# ASCII-fallback screen.
		HUB_ASCII=1
		export HUB_ASCII
		HUB_COMMON_OPT_SHIFT=1
		;;
	*)
		return 1
		;;
	esac
	return 0
}

# hub_validate_format ALLOWED... -> die_usage unless OPT_FORMAT is one of the
# space-separated values the caller lists (e.g. `hub_validate_format text env
# json`).
hub_validate_format() {
	hvf_list=""
	for hvf_allowed in "$@"; do
		if [ "$OPT_FORMAT" = "$hvf_allowed" ]; then
			return 0
		fi
		hvf_list=$(hub_join_append "$hvf_list" "$hvf_allowed" ', ')
	done
	die_usage "--format must be one of: $hvf_list"
}

# hub_split_csv CSV FILE -> writes one non-empty, whitespace-trimmed token per
# line of FILE, from a comma-separated CSV. The single place every
# comma-list flag (--domains, --technologies, --pm-backends, --components) is
# tokenized, so trimming and empty-token rules can never drift between them.
hub_split_csv() {
	printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' >"$2" || :
}

# ---------------------------------------------------------------------------
# Unit-name validation — the trust boundary between a source tree and the
# target directory.
# ---------------------------------------------------------------------------
#
# HUB_NAME_CHARSET_RE — the ONLY shape a discovered unit name may have. A name is
# read from a source file's YAML frontmatter, which is UNTRUSTED INPUT, and it
# becomes a FILENAME under the target ($TARGET/agents/<name>.md,
# $TARGET/skills/<name>). Without this gate a source file declaring
# `name: ../../../../tmp/pwned` makes the hub mkdir/rm/ln OUTSIDE --target
# entirely — a path-traversal write with the user's own privileges, invisible on
# the consent screen because the preview shows only a mangled display name.
#
# What the charset admits, and why each exclusion matters:
#   * the first character must be alphanumeric  -> rejects a leading "-" (which a
#     later command would read as an option), a leading "." (hidden files, and
#     the "." / ".." directory entries themselves).
#   * the remainder allows only alphanumerics, ".", "_" and "-"  -> rejects "/"
#     and every path separator, so a name can never name a directory at all;
#     rejects whitespace, TAB (see "THE TAB TRAP" above), newline and every
#     control character, so a name can neither shift a TSV column nor forge a log
#     line; rejects shell metacharacters, quotes and "$", so a name cannot carry
#     a substitution into any surface that renders it.
# Anything outside it is warned about and SKIPPED, exactly as an unparsable
# `name:` already is — never silently sanitized into a different name.
HUB_NAME_CHARSET_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# ---------------------------------------------------------------------------
# Machine-output (--format=env) value quoting.
# ---------------------------------------------------------------------------

# hub_env_quote VALUE -> VALUE as a single shell word: wrapped in single quotes,
# with every embedded single quote escaped the POSIX way ('\'').
#
# REQUIRED, not cosmetic: --format=env output is documented as directly
# `eval`-able, and an UNQUOTED value breaks that contract with no attacker
# involved at all — the very first HUB_MESSAGE sentence containing an apostrophe
# ("doesn't do anything without...") leaves the caller's `eval` inside an
# unterminated quote. A discovery-derived value could additionally carry
# `$(...)`, which an unquoted eval would EXECUTE. Single quotes are used rather
# than double because they suppress every expansion, not just some.
hub_env_quote() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

# hub_env_kv KEY VALUE -> one "KEY='value'" line. THE one emitter for every
# HUB_*= line in every capability script, so no site can reintroduce an unquoted
# value by writing its own printf.
hub_env_kv() {
	printf '%s=%s\n' "$1" "$(hub_env_quote "$2")"
}

# hub_env_field FILE KEY DEFAULT -> the value of a "KEY=value" line in FILE, or
# DEFAULT when the line is absent.
#
# `grep KEY= file | sed 's/KEY=//'` looks like it falls back correctly on `||`
# but does not: a pipeline's exit status is its LAST stage's, and sed succeeds on
# empty input, so a delegate crash that leaves FILE empty still reports success
# and silently yields "" instead of the documented true|false — which then breaks
# `jq --argjson`, which cannot parse an empty string as a boolean. Making grep
# alone the substituted command, and stripping the prefix with parameter
# expansion, is what makes the fallback actually fire.
#
# The value is read VERBATIM, including any surrounding quotes hub_env_quote
# added: every producer inside this hub is consumed by a caller that compares
# against true/false, so the two sides must agree. Callers therefore strip one
# layer of single quotes if present, which hub_env_field does here so no caller
# has to remember to.
hub_env_field() {
	hef_line=$(grep -m 1 "^$2=" "$1") || {
		printf '%s\n' "$3"
		return 0
	}
	hef_value=${hef_line#"$2"=}
	case $hef_value in
	"'"*"'") hef_value=${hef_value#\'}; hef_value=${hef_value%\'} ;;
	esac
	printf '%s\n' "$hef_value"
}

# ---------------------------------------------------------------------------
# Small shared primitives.
# ---------------------------------------------------------------------------

# hub_join_append LIST VALUE SEP -> LIST with VALUE appended, separated by SEP
# (or just VALUE when LIST is empty). Six sites built this by hand, and the
# separator had already drifted (five used ", ", one ","), so SEP is a REQUIRED
# argument stated explicitly at each call rather than defaulted here.
hub_join_append() {
	if [ -z "$1" ]; then
		printf '%s' "$2"
	else
		printf '%s%s%s' "$1" "$3" "$2"
	fi
}

# hub_count_lines FILE -> the number of lines in FILE, with no surrounding
# whitespace. `wc -l` pads its output on BSD/macOS, so every count in this hub
# needs the `tr -d ' '`; it is written down once here instead of at ~30 sites.
hub_count_lines() {
	wc -l <"$1" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Shared machine-output itemization — every "N names, as a machine-readable
# list" surface (foreign-blocked items, unresolved selection tokens, orphaned
# items) shares this exact shape: a COUNT, a true|false presence flag, and one
# indexed field per name (env) or one JSON array (json).
# ---------------------------------------------------------------------------

# hub_emit_itemized_env PREFIX FILE -> for --format=env: prints
# "PREFIX_COUNT=n", "PREFIX=true|false", and "PREFIX_<N>_NAME=name" for each
# non-empty line in FILE.
hub_emit_itemized_env() {
	heie_prefix=$1
	heie_file=$2
	heie_count=$(hub_count_lines "$heie_file")
	hub_env_kv "${heie_prefix}_COUNT" "$heie_count"
	if [ "$heie_count" -gt 0 ]; then
		hub_env_kv "$heie_prefix" true
	else
		hub_env_kv "$heie_prefix" false
	fi
	heie_n=0
	while IFS= read -r heie_name; do
		[ -n "$heie_name" ] || continue
		heie_n=$((heie_n + 1))
		hub_env_kv "${heie_prefix}_${heie_n}_NAME" "$heie_name"
	done <"$heie_file"
}

# hub_itemized_json_array FILE -> writes one JSON string value per non-empty
# line of FILE to a fresh scratch file (via `jq -Rn`, one call per name — never
# a raw name written straight into the file, so a name containing a quote or
# backslash still round-trips as valid JSON) and prints that scratch file's
# path, ready to hand to `jq --slurpfile`. Requires jq; the caller must
# already have checked `have jq`.
hub_itemized_json_array() {
	hija_file=$1
	hija_out="$(hub_mktemp_dir)/itemized.json"
	: >"$hija_out"
	while IFS= read -r hija_name; do
		[ -n "$hija_name" ] || continue
		jq -Rn --arg name "$hija_name" '$name' >>"$hija_out"
	done <"$hija_file"
	printf '%s\n' "$hija_out"
}

# ---------------------------------------------------------------------------
# The two published machine-status exits, shared by every mutating capability.
#
# HUB_STATUS / HUB_BLOCKED_REASON is a PUBLISHED, CLOSED contract (the base UI
# spec's "Agent-facing mode"), so it lives in exactly one place: install and
# uninstall previously carried ~40 duplicated lines each, differing only in the
# action-string literal, which meant any future field had to be added twice or
# the two scripts would silently disagree about their own contract.
#
# Both read the CALLER's OPT_FORMAT. hub_ok_exit always writes its message to
# the caller's fd 3 (the human channel every capability script opens before its
# first possible exit). hub_blocked's text-format branch writes directly to fd
# 2 instead (bypassing fd 3), and its env/json branches carry the message only
# inside the structured HUB_MESSAGE/message field — hub_blocked never writes to
# fd 3. That is the same OPT_FORMAT contract hub_validate_format already relies
# on, and it is what lets one implementation serve both scripts without a
# format argument nobody would ever pass differently.
# ---------------------------------------------------------------------------

# hub_ok_exit ACTION APPLIED MESSAGE -> report a legitimate no-op or a completed
# action and exit 0.
#
# Every no-op path routes through here so a machine caller ALWAYS receives a
# HUB_STATUS line, in every format, on every exit path — including the paths where
# the answer is "nothing needed doing". A silent exit 0 is indistinguishable, to a
# poller, from a crash before any output.
#
# APPLIED is the literal string true|false and is emitted on BOTH ok paths: a
# caller checking HUB_APPLIED must be able to tell "ok, and nothing was written"
# from "ok, and it was", which two identically-shaped HUB_STATUS=ok payloads
# cannot express if only one of them carries the field.
#
# ON A TEXT-FORMAT INTERACTIVE TTY, this now leads with hub_blocked's own
# warning glyph and PAUSES, exactly like every other screen's
# hub_press_key_to_continue. A live test session found "nothing selected —
# nothing removed" print in plain, uncoloured text immediately before the Main
# menu loop redrew straight over it — indistinguishable, at a glance, from
# nothing having printed at all. Every other no-op through this same function
# (a cancelled install, an already-up-to-date result) shared the identical gap;
# this fixes it once, here, rather than at each of this function's call sites.
hub_ok_exit() {
	hoe_action=$1
	hoe_applied=$2
	hoe_message=$3
	if [ "$OPT_FORMAT" = text ]; then
		printf '%s %s\n' "$(hub_glyph_warn)" "$hoe_message" >&3
	else
		printf '%s\n' "$hoe_message" >&3
	fi
	case $OPT_FORMAT in
	env)
		hub_env_kv HUB_STATUS ok
		hub_env_kv HUB_ACTION "$hoe_action"
		hub_env_kv HUB_APPLIED "$hoe_applied"
		hub_env_kv HUB_ACTED_ON_COUNT 0
		hub_env_kv HUB_ATTEMPTED_COUNT 0
		;;
	json)
		have jq || die "--format=json requires jq, which is not installed"
		jq -n --arg action "$hoe_action" --argjson applied "$hoe_applied" \
			--arg message "$hoe_message" \
			'{status:"ok", action:$action, applied:$applied, acted_on_count:0, attempted_count:0, message:$message}'
		;;
	esac
	if [ "$OPT_FORMAT" = text ] && hub_interactive; then
		hoe_pause=0
		hub_press_key_to_continue || hoe_pause=$?
		[ "$hoe_pause" -ne 3 ] || exit 3
	fi
	exit 0
}

# hub_blocked ACTION REASON MESSAGE -> report a gated refusal and exit 1. REASON
# is a member of the published closed HUB_BLOCKED_REASON set; each capability
# script's own header names which members it emits.
hub_blocked() {
	hb_action=$1
	hb_reason=$2
	hb_message=$3
	case $OPT_FORMAT in
	env)
		hub_env_kv HUB_STATUS blocked
		hub_env_kv HUB_ACTION "$hb_action"
		hub_env_kv HUB_BLOCKED_REASON "$hb_reason"
		hub_env_kv HUB_MESSAGE "$hb_message"
		;;
	json)
		have jq || die "--format=json requires jq, which is not installed"
		jq -n --arg action "$hb_action" --arg reason "$hb_reason" --arg message "$hb_message" \
			'{status:"blocked", action:$action, blocked_reason:$reason, message:$message}'
		;;
	text) printf '%s %s\n' "$(hub_glyph_warn)" "$hb_message" >&2 ;;
	esac
	exit 1
}

# ---------------------------------------------------------------------------
# Column formatting — dynamic name-column width, truncation, right-padding.
# The width is ALWAYS computed from the actual data, never hardcoded: a
# hardcoded `%-Ns` misaligns the moment a name is longer than N (it runs into
# its own trailing text) or the header's separately-hardcoded width is tuned
# alone.
# ---------------------------------------------------------------------------

# HUB_NAME_COL_MAX_WIDTH — the name column's cap, regardless of how long the
# longest actual discovered name is. Without a cap, one absurdly long name (a
# malformed frontmatter 'name:', or a future component nobody named sensibly)
# would stretch every row to match it. 36 is generous headroom over every real
# display name in this framework today while still bounding the worst case to
# a sane terminal width.
HUB_NAME_COL_MAX_WIDTH=36

# hub_name_column_width FIELD FILE... -> the column width to use for a table's
# header row AND every one of its data rows — both MUST read this SAME
# computed value. Computed from the longest value of the TAB-separated column
# FIELD across every FILE given, capped at HUB_NAME_COL_MAX_WIDTH and floored
# at 4. A FILE that does not exist or is empty is silently skipped (a caller
# with nothing to show for one section is the normal case, not an error).
hub_name_column_width() {
	hncw_field=$1
	shift
	hncw_max=4
	for hncw_file in "$@"; do
		[ -s "$hncw_file" ] || continue
		hncw_file_max=$(awk -F '\t' -v f="$hncw_field" '{ if (length($f) > m) m = length($f) } END { print m + 0 }' "$hncw_file")
		if [ "$hncw_file_max" -gt "$hncw_max" ]; then
			hncw_max=$hncw_file_max
		fi
	done
	if [ "$hncw_max" -gt "$HUB_NAME_COL_MAX_WIDTH" ]; then
		hncw_max=$HUB_NAME_COL_MAX_WIDTH
	fi
	printf '%s\n' "$hncw_max"
}

# hub_truncate_name NAME WIDTH -> NAME unchanged if it already fits within WIDTH
# characters; otherwise NAME cut short and given a trailing ellipsis, so the
# printed result is exactly WIDTH COLUMNS wide either way.
#
# The ellipsis is a single "…" normally and "..." under accessible mode, and the
# cut length is derived from its DISPLAY WIDTH rather than hardcoded to WIDTH-1 —
# otherwise the ASCII form would print three characters where one was budgeted
# and blow the column alignment it exists to preserve.
#
# THE WIDTH IS A CONSTANT PER FORM, NEVER ${#htn_ellipsis}, and that distinction
# is a live bug this replaced. lib/hub-common.sh exports LC_ALL=C, under which
# ${#…} counts BYTES: the Unicode ellipsis is 3 bytes and exactly 1 display
# column, so every truncated name budgeted 3 columns for a 1-column character and
# pushed its trailing annotation 2 characters left of the column it was aligned
# to. The ASCII "..." was never affected (3 bytes, 3 columns), which is why this
# only ever misaligned in the default, non-accessible mode.
#
# hub_pad_right below measures the SAME byte length, and that is consistent with
# this arithmetic rather than a second copy of the bug: a truncated name comes back
# WIDTH-1+3 = WIDTH+2 bytes long in the Unicode form, so hub_pad_right sees it as
# already at least WIDTH wide, adds no padding, and the row lands at exactly WIDTH
# printed columns. Both halves therefore have to change together if either
# convention ever does.
HUB_ELLIPSIS_COLUMNS_UNICODE=1
HUB_ELLIPSIS_COLUMNS_ASCII=3
hub_truncate_name() {
	htn_name=$1
	htn_width=$2
	if [ "${#htn_name}" -le "$htn_width" ]; then
		printf '%s\n' "$htn_name"
		return 0
	fi
	if [ "${HUB_ASCII:-0}" = 1 ]; then
		htn_ellipsis='...'
		htn_ellipsis_cols=$HUB_ELLIPSIS_COLUMNS_ASCII
	else
		htn_ellipsis='…'
		htn_ellipsis_cols=$HUB_ELLIPSIS_COLUMNS_UNICODE
	fi
	htn_keep=$((htn_width - htn_ellipsis_cols))
	[ "$htn_keep" -ge 1 ] || htn_keep=1
	printf '%s%s\n' "$(printf '%s' "$htn_name" | cut -c "1-${htn_keep}")" "$htn_ellipsis"
}

# hub_pad_right TEXT WIDTH -> TEXT followed by spaces until the printed result
# is WIDTH columns wide (no trailing newline); TEXT already >= WIDTH prints
# unchanged. A manual space-fill loop, not `printf '%-*s'`: a fixed literal
# width works with any POSIX sh's printf, but a WIDTH computed at runtime
# needs this instead, since `*`-width support is not reliably portable across
# every sh implementation's printf builtin.
hub_pad_right() {
	hpr_text=$1
	hpr_width=$2
	printf '%s' "$hpr_text"
	hpr_i=${#hpr_text}
	while [ "$hpr_i" -lt "$hpr_width" ]; do
		printf ' '
		hpr_i=$((hpr_i + 1))
	done
}

# hub_dedup_first_field FILE -> rewrite FILE in place, keeping the FIRST
# occurrence of each distinct TAB-separated column 1 and preserving line order.
# Order-preserving on purpose: every table in this hub carries a deliberate
# canonical order (group order, then agents before skills, then name) that
# `sort -u` would silently replace with an alphabetical one.
hub_dedup_first_field() {
	hdff_tmp="$(hub_mktemp_dir)/dedup.tsv"
	awk -F '\t' '!seen[$1]++' "$1" >"$hdff_tmp"
	cat "$hdff_tmp" >"$1"
}

# hub_remove_line FILE VALUE -> rewrite FILE in place without any line equal to
# VALUE. `grep -vxF --`, never a sed expression built from VALUE: a name
# reaching sed as a pattern would let a metacharacter in it match the wrong
# lines. `|| :` because grep exits 1 when it removes everything, which is a
# legitimate outcome here, not a failure.
#
# IT RECLAIMS ITS OWN SCRATCH DIRECTORY, unlike its siblings above and below, and
# the asymmetry is deliberate rather than an inconsistency to tidy up. The
# HUB_WORK trap is a SESSION-level net: it fires once, at exit, so a function that
# allocates a fresh dir per call and returns without cleaning up holds every one of
# them for the rest of the run. That is free for a function called once per flow,
# which is what hub_dedup_first_field and hub_remove_row_by_key are — but this one
# is called from inside a PER-ROW loop (lib/hub-checklist.sh's toggle loop, once
# for every row being deselected), where a single "1-100" reply would otherwise
# strand up to a hundred directories, and two forks each, in one keystroke. The
# directory is created here and its path never escapes this function, so nothing
# outside can hold a reference to it and removing it is safe.
hub_remove_line() {
	hrl_dir=$(hub_mktemp_dir)
	hrl_tmp="$hrl_dir/without.txt"
	grep -vxF -- "$2" "$1" >"$hrl_tmp" || :
	cat "$hrl_tmp" >"$1"
	rm -rf "$hrl_dir" 2>/dev/null || :
}

# hub_remove_row_by_key FILE KEY -> rewrite FILE in place without any row whose
# TAB-separated column 1 equals KEY, preserving the order of the rest. The
# TSV-aware sibling of hub_remove_line above; awk with an exact field comparison,
# never a grep pattern, so a key containing a regex metacharacter cannot match a
# row it should not.
hub_remove_row_by_key() {
	hrrbk_tmp="$(hub_mktemp_dir)/without-row.tsv"
	hrrbk_key="$2" awk -F '\t' '$1 != ENVIRON["hrrbk_key"]' "$1" >"$hrrbk_tmp"
	cat "$hrrbk_tmp" >"$1"
}

# hub_plural COUNT SINGULAR PLURAL -> SINGULAR when COUNT is exactly 1, else
# PLURAL. Every count-bearing line in the hub needs this; without it each site
# grows its own `$([ "$n" -eq 1 ] && printf '' || printf s)` inline, which is
# both noisy and wrong for irregular words ("1 note"/"2 notes" is regular,
# "1 technology"/"2 technologies" is not).
hub_plural() {
	if [ "$1" -eq 1 ]; then
		printf '%s' "$2"
	else
		printf '%s' "$3"
	fi
}

# ---------------------------------------------------------------------------
# Portable path helpers.
# ---------------------------------------------------------------------------

# hub_abspath PATH -> an absolute path, lexical only (no symlink resolution,
# does not require PATH to exist), with any TRAILING SLASH stripped. Used for a
# --target that may not exist yet.
#
# ===========================================================================
# WHY THE TRAILING SLASH IS STRIPPED HERE, AT THE ONE ENTRY POINT
# ===========================================================================
# This is where a raw --target becomes the HUB_TARGET_DIR that
# lib/hub-symlink.sh's hub_assert_write_target compares every write against, and
# that comparison is LEXICAL. `--target ~/.claude/` left the trailing slash on
# HUB_TARGET_DIR while the root-level CLAUDE.md write's own `dirname` collapsed to
# "<t>/.claude" — so the two strings never matched. On a genuinely FIRST run the
# resolved-realpath fallback could not save it either (it is gated on the parent
# existing, and on a first run it does not yet), so a perfectly legitimate install
# died with "refusing to write outside the deployment directories". Normalizing
# once, where the path is first resolved, is what keeps every later comparison
# site — here, hub_write_parent_allowed's four cases, hub_target_path's
# composition — free of its own copy of this rule.
#
# "/" is preserved as "/": stripping to an empty string would silently turn an
# absolute path into a relative one.
hub_abspath() {
	hap_path=$1
	case $hap_path in
	/*) : ;;
	*) hap_path=$(pwd -P)/$hap_path ;;
	esac
	while :; do
		case $hap_path in
		/) break ;;
		*/) hap_path=${hap_path%/} ;;
		*) break ;;
		esac
	done
	printf '%s\n' "$hap_path"
}

# hub_realpath PATH -> canonical absolute path of an EXISTING file/dir,
# resolving symlinks. No "readlink -f"/"realpath" (absent/limited on BSD).
hub_realpath() {
	rp_target=$1
	case $rp_target in
	/*) : ;;
	*) rp_target=$(pwd -P)/$rp_target ;;
	esac

	rp_count=0
	while :; do
		rp_dir=$(dirname "$rp_target")
		rp_base=$(basename "$rp_target")
		rp_dir=$(cd "$rp_dir" 2>/dev/null && pwd -P) || return 1
		rp_target=$rp_dir/$rp_base

		[ -h "$rp_target" ] || break

		rp_count=$((rp_count + 1))
		[ "$rp_count" -le 64 ] || return 1

		rp_link=$(readlink "$rp_target") || return 1
		case $rp_link in
		/*) rp_target=$rp_link ;;
		*) rp_target=$rp_dir/$rp_link ;;
		esac
	done

	if [ -d "$rp_target" ]; then
		rp_target=$(cd "$rp_target" 2>/dev/null && pwd -P) || return 1
	fi
	printf '%s\n' "$rp_target"
}

# hub_readlink_abs PATH -> absolute target of a symlink (single level), without
# requiring the target to exist (works on a dangling link).
hub_readlink_abs() {
	rla_raw=$(readlink "$1") || return 1
	case $rla_raw in
	/*) printf '%s\n' "$rla_raw" ;;
	*) printf '%s/%s\n' "$(dirname "$1")" "$rla_raw" ;;
	esac
}

# hub_resolve_script_dir SCRIPT_PATH -> canonical directory containing
# SCRIPT_PATH, following a symlinked $0 (so a "crucible-hub" convenience
# symlink elsewhere on PATH still resolves to this repo's deploy/hub/).
hub_resolve_script_dir() {
	rsd_src=$1
	rsd_count=0
	while [ -h "$rsd_src" ]; do
		rsd_count=$((rsd_count + 1))
		[ "$rsd_count" -le 64 ] || die "too many symlink levels resolving script path"
		rsd_link=$(readlink "$rsd_src") || die "cannot readlink '$rsd_src'"
		case $rsd_link in
		/*) rsd_src=$rsd_link ;;
		*) rsd_src=$(dirname "$rsd_src")/$rsd_link ;;
		esac
	done
	rsd_dir=$(cd "$(dirname "$rsd_src")" 2>/dev/null && pwd -P) || die "cannot resolve script directory"
	printf '%s\n' "$rsd_dir"
}

# HUB_DIR: absolute directory of the hub's OWN scripts (deploy/hub/), resolved
# once here so every sourcing script (which may be invoked via a relative
# path, or via a symlink) agrees on where lib/ and its sibling capability
# scripts live. $0 is the SOURCING script's own path (POSIX: $0 is unchanged
# by `.`).
HUB_DIR=$(hub_resolve_script_dir "$0")
export HUB_DIR

# hub_default_source -> the framework root: deploy/hub/'s own grandparent
# (deploy/hub -> deploy -> framework root). Overridable per-script via
# --source.
hub_default_source() {
	hub_realpath "$HUB_DIR/../.." || die "cannot resolve default framework source"
}

# hub_default_target -> $HOME/.claude.
hub_default_target() {
	[ -n "${HOME:-}" ] || die "HOME is not set; use --target"
	hub_abspath "$HOME/.claude"
}

# ---------------------------------------------------------------------------
# TTY / color helpers
# ---------------------------------------------------------------------------

# hub_is_tty -> exit 0 when BOTH stdin and stdout are a terminal. Every
# capability script that offers an interactive path gates it on this, per the
# spec's "Non-TTY detection gates interactivity, not just styling."
#
# Every call site of THIS function is a bare condition (`if hub_is_tty`),
# never `$(hub_is_tty)` — which matters, because `[ -t 1 ]` reports on
# whatever fd 1 CURRENTLY is, and a command substitution always redirects the
# substituted command's fd 1 to a pipe. Called bare, this sees the real
# process's fd 1; called via `$(...)`, it would always report false.
hub_is_tty() {
	[ -t 0 ] && [ -t 1 ]
}

# HUB_STDOUT_IS_TTY — whether the REAL process's stdout is a terminal,
# captured ONCE here at source time (sourcing via `.` never forks a subshell,
# so this `[ -t 1 ]` sees the genuine fd 1). hub_color_enabled below reads
# this cached value instead of calling `[ -t 1 ]` itself.
#
# WHY this indirection is required, not stylistic: every hub_glyph_* helper is
# invoked via `$(hub_glyph_ok)`-style command substitution at its call sites,
# by design — that is how a caller captures the printed glyph text to
# interpolate into a `printf` format string. A command substitution ALWAYS
# redirects fd 1 to a pipe for the lifetime of that substitution, so a bare
# `[ -t 1 ]` evaluated from inside a glyph helper is structurally always
# false, on a real terminal or not. Capturing the answer once, outside any
# subshell boundary, and threading it down as data is the standard fix.
#
# HONOURS AN INHERITED VALUE, when one is already set in the environment,
# rather than always recomputing it. This is what lets a script that DELEGATES
# to another script's process (hub-doctor.sh piping hub-accounts.sh's text
# output through `sed`, say) hand its own, already-correct TTY decision down
# to the child. Without this, the child's own `[ -t 1 ]` sees the pipe fd the
# delegator's redirect created for ITS purposes (indenting the child's output),
# not the real terminal several levels up — silently disabling color in
# exactly the delegated block, while the delegator's own directly-printed
# lines on the same screen stayed colored. A live test session found precisely
# this: green checkmarks next to white ones on the same Doctor screen. The
# delegator is expected to pass its own value forward explicitly (e.g.
# `HUB_STDOUT_IS_TTY=$HUB_STDOUT_IS_TTY HUB_NO_COLOR=$HUB_NO_COLOR child.sh`),
# never left to leak in by accident — a script run standalone has nothing set
# yet, so it falls through to the real `[ -t 1 ]` check exactly as before.
if [ -z "${HUB_STDOUT_IS_TTY:-}" ]; then
	if [ -t 1 ]; then
		HUB_STDOUT_IS_TTY=1
	else
		HUB_STDOUT_IS_TTY=0
	fi
fi

# hub_color_enabled -> exit 0 when ANSI color should be emitted: not disabled
# by the standard NO_COLOR env var (per no-color.org, checked by PRESENCE —
# an empty NO_COLOR="" still disables color), not disabled by --no-color, and
# stdout is a real terminal.
#
# Both HUB_NO_COLOR checks are STRING comparisons (`case`), never
# `-eq`/arithmetic: an unsanitized HUB_NO_COLOR inherited from the environment
# must never crash this function with "[: integer expression expected" — every
# glyph decision runs through here, so a crash would abort the hub on its very
# first colored line. Any non-"0"/empty value means "disabled" (fail toward
# no-color, never toward a crash).
hub_color_enabled() {
	[ -z "${NO_COLOR+x}" ] || return 1
	case ${HUB_NO_COLOR:-0} in
	0 | '') : ;;
	*) return 1 ;;
	esac
	[ "$HUB_STDOUT_IS_TTY" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Temp workspace
# ---------------------------------------------------------------------------
#
# Every capability script (never a lib function) calls hub_workspace_init once,
# near the top of its own flow; that is what sets HUB_WORK and traps its removal
# on EXIT/INT/TERM.
#
# lib functions never allocate an independent, untracked temp directory — they
# call hub_mktemp_dir below, which nests a fresh scratch dir INSIDE the
# script's own HUB_WORK, so a single top-level trap reclaims every scratch file
# any lib function created, even on a `die()` partway through.
# hub_workspace_init -> create this script's temp workspace and trap its removal
# on EXIT/INT/TERM. Every capability script calls this ONCE, near the top of its
# own flow, before any lib function that allocates scratch space (see
# hub_mktemp_dir below).
#
# The traps are set here rather than at each call site because a script that
# creates the directory and forgets one signal trap leaks a temp tree on ^C, and
# that is not visible in review by reading the one line that created it.
hub_workspace_init() {
	HUB_WORK=$(mktemp -d) || die "mktemp -d failed"
	trap 'rm -rf "$HUB_WORK" 2>/dev/null || :' EXIT
	trap 'rm -rf "$HUB_WORK" 2>/dev/null || :; exit 130' INT
	trap 'rm -rf "$HUB_WORK" 2>/dev/null || :; exit 143' TERM
}

# hub_mktemp_dir -> a fresh scratch directory nested under HUB_WORK, or die
# loudly. Dies if HUB_WORK is unset/empty — that is a caller-contract bug (a
# capability script forgot to set it up), not a runtime condition to paper
# over silently. mktemp (never a predictable/fixed name) keeps the hub clear
# of the symlink-attack and race surface a guessable temp path opens.
hub_mktemp_dir() {
	[ -n "${HUB_WORK:-}" ] || die "hub_mktemp_dir: HUB_WORK is not set (the calling script must create it and trap its cleanup)"
	mktemp -d "$HUB_WORK/tmp.XXXXXX" 2>/dev/null || die "mktemp -d failed"
}
