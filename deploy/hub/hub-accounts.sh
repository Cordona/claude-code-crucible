#!/usr/bin/env sh
# hub-accounts.sh — Capability: Accounts. A thin DELEGATOR only: it never
#                    reimplements the framework's GitHub/GitLab/Jira auth
#                    procedures, it invokes their own scripts.
#
# Usage:
#   hub-accounts.sh SUBCOMMAND [--target DIR] [--source DIR]
#                   [--format=text|env] [--no-color] [-h|--help]
#
#   SUBCOMMAND is one of:
#     status          Read-only: report GitHub + GitLab + Jira auth state, and
#                       which installed domains actually depend on each (used
#                       by Doctor and by the interactive Accounts screen).
#     switch-github    Interactive: the GitHub account manager.
#     reauth-github    Interactive: the SAME script as switch-github — its own
#                       menu offers both switching between authenticated
#                       accounts and logging in fresh, so the hub does not
#                       invent a second entry point for one tool.
#     switch-gitlab    Interactive: the GitLab account manager — the same
#                       shape as switch-github, one script per host.
#     reauth-gitlab    Interactive: the SAME script as switch-gitlab, for the
#                       same reason switch-github/reauth-github share one.
#     configure-jira  Interactive: the Jira login procedure.
#     reauth-jira      Interactive: the SAME script as configure-jira, for the
#                       same reason.
#
# The auth scripts are located by SCRIPT NAME within the specific structural
# subtree each is expected to live in — accounts/ for GitHub and GitLab,
# Project Management's agents/ subtree for Jira — rather than by a hardcoded
# full path OR by searching the whole framework tree. That keeps this script
# working across the domain restructuring (procedure-github-auth and
# procedure-gitlab-auth both live under accounts/, procedure-jira-auth lives
# inside project-management/) without encoding either location, while still
# refusing to execute a same-named file that happens to sit somewhere unrelated.
# Naming the three scripts is unavoidable and legitimate: this capability is by
# definition a front over those three specific procedures — the
# zero-hardcoded-names contract governs which COMPONENTS the hub installs, not
# which external tool a delegator delegates to.
#
# ===========================================================================
# WHEN A DISCOVERED SCRIPT MAY BE EXECUTED
# ===========================================================================
# Reporting account state means RUNNING code found under --source. `status` is
# read-only from the hub's point of view, but the script it runs is not the hub's
# code — and `status` is reachable from Doctor and from the interactive Accounts
# screen, i.e. from paths a user takes before ever approving an install. Pointing
# --source at an untrusted tree and running a read-only-looking command therefore
# used to execute two scripts out of that tree, unconditionally and silently.
#
# The rule, applied to EVERY delegate this script runs — the read-only status
# probes and all four interactive managers alike (ha_confirm_foreign_script):
#
#   * --source IS this hub's own framework tree (the default, and what Doctor and
#     the Main menu always use) -> the scripts run, as before. This is the same
#     tree the hub itself was launched from; refusing to run it would be theatre.
#   * --source is ANY OTHER tree -> the resolved script path is PRINTED and run
#     only on explicit y/N confirmation at a real terminal. With no terminal to
#     confirm at — which includes both of Doctor's calls, since each redirects
#     stdout — nothing is run and the state is reported as UNKNOWN
#     (HUB_GH_STATE_KNOWN / HUB_JIRA_STATE_KNOWN = false) rather than guessed at.
#   * IN EITHER CASE, the resolved file AND the directory holding it must both be
#     owned by the invoking user and not group- or other-writable
#     (ha_script_trust_ok), or it is refused outright. Confirming a PATH is not the
#     same as trusting the FILE at it: on a world-writable tree the contents can be
#     swapped between the prompt and the run, so the y/N alone anchors nothing —
#     and a writable DIRECTORY grants that same swap by unlink-and-replace even
#     when the file's own mode is tight.
#
# THE FOUR INTERACTIVE SUBCOMMANDS USED TO BE EXEMPT FROM ALL OF THIS, and that
# was exactly backwards. "The user asked for the account manager" is consent to run
# THIS framework's account manager — not consent to exec whatever executable a
# foreign --source happens to have placed at that path, which is the one delegate
# here that then writes credentials interactively. Requiring a TTY is not a trust
# check; it only means someone is watching.
#
# Exit codes: whatever the delegated script exits with; 2 on a hub usage error
#   (bad subcommand/flag) before any delegate runs.
#
# Portability: POSIX sh only.
set -eu

HUB_PROG="crucible-hub accounts"
HUB_DIR0=$(dirname "$0")
. "$HUB_DIR0/lib/hub-common.sh"
. "$HUB_DIR0/lib/hub-domains.sh"
. "$HUB_DIR0/lib/hub-render.sh"
. "$HUB_DIR0/lib/hub-discovery.sh"
. "$HUB_DIR0/lib/hub-state.sh"

hub_workspace_init

usage() {
	cat <<EOF
Usage: $HUB_PROG SUBCOMMAND [--target DIR] [--source DIR] [--format=text|env] [--no-color] [-h|--help]

Subcommands: status | switch-github | reauth-github | switch-gitlab | reauth-gitlab | configure-jira | reauth-jira

Options:
  --target DIR   Deployed config dir (default: \$HOME/.claude) — used by status
                  to report which installed domains depend on each account.
  --source DIR   Framework root (default: the hub's own tree). Every subcommand
                  runs a script from this tree; a NON-DEFAULT --source is
                  confirmed first, or skipped when there is no terminal to
                  confirm at, and any resolved script that is not owned by you or
                  is group/world-writable is refused (see this script's header).
  --format FMT   text (default) | env — status only.
  --no-color     Disable ANSI color.
  -h, --help     Show this help.
EOF
}

[ $# -ge 1 ] || die_usage "a subcommand is required"
# -h/--help is checked BEFORE $1 is consumed as the subcommand — otherwise
# `accounts --help` would set SUBCOMMAND=--help and fall through to "unknown
# subcommand" instead of showing help.
case $1 in
-h | --help)
	usage
	exit 0
	;;
esac
SUBCOMMAND=$1
shift

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

[ -n "$OPT_TARGET" ] || OPT_TARGET=$(hub_default_target)
[ -n "$OPT_SOURCE" ] || OPT_SOURCE=$(hub_default_source)
TARGET_DIR=$(hub_abspath "$OPT_TARGET")
FRAMEWORK_ROOT=$(hub_realpath "$OPT_SOURCE") || die "cannot resolve --source: $OPT_SOURCE"

# ha_resolve_script ROOT NAME -> sets HA_SCRIPT to the one executable file named
# NAME under ROOT, or to empty when there is none. Test fixtures and .git are
# pruned so a fixture with a colliding name can never shadow the real script.
#
# TWO deliberate constraints, both of which the previous whole-tree
# `sort | head -n1` search lacked:
#
#   1. ROOT is the SPECIFIC structural subtree the script is expected to live in
#      (accounts/ for the GitHub scripts, Project Management's agents/ subtree for
#      the Jira ones), never the whole framework root. These paths get executed —
#      searching every directory for a bare basename means any file anywhere in
#      the tree that happens to share the name becomes a candidate.
#   2. MORE THAN ONE match is a hard error, not "take the first". Silently picking
#      one of several same-named executables is precisely how the wrong one ends
#      up running, and the sorted order that decides it is an accident of paths.
#
# The result is returned via a global rather than stdout so `die` actually exits
# the script: inside a `$(...)` it would only kill the substitution's subshell.
ha_resolve_script() {
	hars_root=$1
	hars_name=$2
	HA_SCRIPT=""
	[ -d "$hars_root" ] || return 0

	hars_hits="$HUB_WORK/found-$hars_name.txt"
	find "$hars_root" \( -name .git -o -name tests \) -prune -o \
		-type f -name "$hars_name" -perm -u+x -print 2>/dev/null | LC_ALL=C sort >"$hars_hits"

	hars_count=$(hub_count_lines "$hars_hits")
	case $hars_count in
	0) : ;;
	1) HA_SCRIPT=$(cat "$hars_hits") ;;
	*) die "$hars_count executables named $hars_name found under $hars_root; refusing to guess which one to run" ;;
	esac
}

# The two anchors. Both are PATH SHAPES from lib/hub-domains.sh, not names: the
# GitHub auth procedure is the cross-domain accounts/ subtree, and the Jira one
# lives inside Project Management's own agent-skills subtree (which is why it is
# not under accounts/ — only the project-manager agent uses it).
HA_ACCOUNTS_ROOT="$FRAMEWORK_ROOT/$HUB_ACCOUNTS_DIR"
HA_PM_AGENTS_ROOT="$(hub_domain_root "$FRAMEWORK_ROOT" project-management)/$HUB_PM_DIR_AGENTS"

ha_resolve_script "$HA_ACCOUNTS_ROOT" gh-auth-status.sh
GH_STATUS_SCRIPT=$HA_SCRIPT
ha_resolve_script "$HA_ACCOUNTS_ROOT" manage_gh_accounts.sh
GH_MANAGE_SCRIPT=$HA_SCRIPT
ha_resolve_script "$HA_ACCOUNTS_ROOT" glab-auth-status.sh
GL_STATUS_SCRIPT=$HA_SCRIPT
ha_resolve_script "$HA_ACCOUNTS_ROOT" manage_glab_accounts.sh
GL_MANAGE_SCRIPT=$HA_SCRIPT
ha_resolve_script "$HA_PM_AGENTS_ROOT" jira-auth-status.sh
JIRA_STATUS_SCRIPT=$HA_SCRIPT
ha_resolve_script "$HA_PM_AGENTS_ROOT" jira-login.sh
JIRA_LOGIN_SCRIPT=$HA_SCRIPT

# HA_SOURCE_TRUSTED — whether --source resolved to this hub's OWN framework tree.
# Both sides are already canonical absolute paths (hub_default_source and the
# FRAMEWORK_ROOT above each go through hub_realpath), so this is a plain string
# comparison and not a path-prefix guess.
HA_SOURCE_TRUSTED=0
[ "$FRAMEWORK_ROOT" != "$(hub_default_source)" ] || HA_SOURCE_TRUSTED=1

# ha_script_trust_ok SCRIPT -> exit 0 when SCRIPT is safe to EXECUTE as a file,
# independent of which tree it came from. Two questions, asked about BOTH the
# script AND the directory holding it, because either one lets another account
# decide what runs:
#
#   * GROUP- OR OTHER-WRITABLE. Anyone in the group (or anyone at all) can rewrite
#     the file between the moment it is resolved/approved and the moment it runs,
#     so approving the PATH says nothing about what will actually execute. On the
#     DIRECTORY the same permission is just as fatal by a different route: write on
#     a directory is the right to unlink its entries, so an attacker who cannot
#     touch the script's own bytes can still delete it and drop their own file at
#     that exact path. A STICKY world-writable directory (/tmp) is refused along
#     with the rest rather than special-cased: the sticky bit does prevent the
#     unlink, but a delegate living directly in a shared scratch directory is not a
#     tree worth executing from, and the extra mode probe would only buy that case.
#   * NOT OWNED BY THE INVOKING USER. A script owned by someone else is that
#     someone's code, running with this user's privileges — and a DIRECTORY owned by
#     someone else is that someone's right to swap its entries, script permissions
#     notwithstanding.
#
# This is the trust ANCHOR the y/N confirmation below lacks on its own: the prompt
# approves a path, this approves the file at it. It does not close the race
# entirely (nothing short of opening the file and executing that handle can), but
# with the directory covered too it narrows the attacker set to the invoking user
# — the same accepted same-user-only window documented at the top of
# lib/hub-symlink.sh. The parent chain ABOVE that directory is deliberately not
# walked: a traversable-but-unwritable ancestor cannot reach this entry, and an
# attacker who owns $HOME already owns the hub itself.
#
# find(1), not stat(1): `stat` takes incompatible flags on BSD (macOS) and GNU,
# while `find -perm -g+w` / `-uid` behave identically on both. The owner NAME for
# the message comes from `ls -ld`, which is only ever used as prose.
ha_path_owner() {
	# shellcheck disable=SC2012 # SC2012 warns that parsing `ls` mishandles exotic
	# filenames — which cannot affect this use: the owner is field 3, ahead of the
	# name, so a name containing anything at all leaves it in place, and the result
	# is only ever prose inside a refusal message, never a value anything acts on.
	# The portable alternatives do not exist: `find -printf '%u'` is GNU-only and
	# `stat` takes incompatible flags on BSD vs GNU, which is the whole reason this
	# file's checks use find(1) primaries in the first place.
	ls -ld "$1" | awk '{ print $3 }'
}

# The two probes, one function each and asked of two different paths, so the file
# check and the directory check can never drift into testing different things.
ha_path_writable_by_others() {
	[ -n "$(find "$1" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ]
}

ha_path_owned_by_invoker() {
	[ -n "$(find "$1" -maxdepth 0 -uid "$(id -u)" 2>/dev/null)" ]
}

ha_script_trust_ok() {
	hasto_script=$1
	hasto_dir=$(dirname "$hasto_script")
	if ha_path_writable_by_others "$hasto_script"; then
		warn "refusing to run $hasto_script: it is group- or world-writable, so its contents can be replaced by another account before it runs"
		return 1
	fi
	if ! ha_path_owned_by_invoker "$hasto_script"; then
		warn "refusing to run $hasto_script: it is owned by $(ha_path_owner "$hasto_script"), not by the invoking user ($(id -un))"
		return 1
	fi
	if ha_path_writable_by_others "$hasto_dir"; then
		warn "refusing to run $hasto_script: its directory $hasto_dir is group- or world-writable, so another account can unlink the script and leave its own file at that path before it runs"
		return 1
	fi
	if ! ha_path_owned_by_invoker "$hasto_dir"; then
		warn "refusing to run $hasto_script: its directory $hasto_dir is owned by $(ha_path_owner "$hasto_dir"), not by the invoking user ($(id -un)), so that owner can swap the script out before it runs"
		return 1
	fi
	return 0
}

# ha_confirm_foreign_script SCRIPT -> the --source trust gate, as this script's
# header states it: a script from this hub's OWN tree runs unchallenged, one from
# any other tree is printed and run only on an explicit y/N at a real terminal.
# Exit 0 to proceed, 1 to refuse (declined, or no terminal to ask at).
#
# ONE implementation for all five delegate call sites. The four interactive
# subcommands used to exec their script with NO gate whatsoever — only the
# read-only `status` path had one, which is exactly backwards from a blast-radius
# point of view: `status` runs a documented read-only probe, while those four run
# an interactive account manager that writes credentials. "The user asked for the
# account manager" is consent to run THIS FRAMEWORK'S account manager, not consent
# to run an arbitrary executable that a foreign --source happens to have put at
# that path.
ha_confirm_foreign_script() {
	hacfs_script=$1
	ha_script_trust_ok "$hacfs_script" || return 1
	[ "$HA_SOURCE_TRUSTED" -eq 0 ] || return 0
	if ! hub_is_tty; then
		warn "not running $hacfs_script: --source is not this hub's own framework tree and there is no terminal to confirm at"
		return 1
	fi
	printf 'This runs a script from a non-default --source:\n' >&2
	printf '  %s\n' "$hacfs_script" >&2
	printf 'Run it? [%s/%s]: ' "$(hub_key y)" "$(hub_key N)" >&2
	IFS= read -r hacfs_reply || hacfs_reply=""
	case $hacfs_reply in
	[Yy] | [Yy][Ee][Ss]) return 0 ;;
	esac
	warn "skipped $hacfs_script"
	return 1
}

# ha_reason_line FILE -> the first non-empty line of FILE, for use as the human
# reason a state could not be resolved. Empty when FILE has nothing to say.
ha_reason_line() {
	awk 'NF { print; exit }' "$1"
}

# ha_exec_delegate SCRIPT -> hand this process over to one of the four interactive
# account managers, gated exactly as the read-only status probe is
# (ha_confirm_foreign_script, which also applies the ownership/writability check).
#
# THE WORKSPACE IS REMOVED IMMEDIATELY BEFORE THE exec, because `exec` replaces
# this process and hub_workspace_init's EXIT trap therefore never fires: every
# trip through the interactive Accounts submenu used to leave its whole `mktemp -d`
# workspace behind. It is removed rather than left for the trap precisely because
# there will BE no trap after this line.
ha_exec_delegate() {
	haed_script=$1
	ha_confirm_foreign_script "$haed_script" || die "refusing to run $haed_script"
	rm -rf "$HUB_WORK" 2>/dev/null || :
	HUB_NO_COLOR=${HUB_NO_COLOR:-0} exec "$haed_script"
}

# ha_run_status_script SCRIPT OUTFILE SENTINEL_KEY -> run one discovered
# *-auth-status.sh and capture its env-shaped output, subject to the trust gate
# above. Sets HA_RAN=1 when the script actually produced its documented status
# payload, 0 otherwise (not found, not trusted, declined, or it never got far
# enough to answer) — the caller reports that as HUB_*_STATE_KNOWN. Sets HA_REASON
# to a one-line explanation whenever HA_RAN is 0.
#
# A NON-ZERO EXIT IS NOT, BY ITSELF, A FAILURE TO MEASURE, and that distinction is
# the whole reason SENTINEL_KEY exists. Both delegates document exit 1 as "do NOT
# act" for entirely ordinary states — gh absent, nobody logged in, no Jira
# credential stored — and both still emit their FULL machine block on that path
# ("always emitted, even on failure"). Treating every non-zero exit as unknown
# would report "not checked" on every unauthenticated machine and make
# hub-accounts.sh's own "gh not installed" branch unreachable, which is the same
# false report as the bug this fixes, just pointing the other way.
#
# What genuinely means "could not answer" is the ABSENCE of that block: the
# delegate crashed, was killed, or died before emitting. SENTINEL_KEY is one key
# the delegate documents as always present, so its presence is the measurement's
# own receipt. Its stderr is captured rather than discarded for the same reason —
# it holds the delegate's own account of what went wrong, which is the only useful
# thing to show a user whose state came back unknown.
ha_run_status_script() {
	hars_script=$1
	hars_out=$2
	hars_key=$3
	HA_RAN=0
	HA_REASON=""
	HA_STDERR=""
	if [ -z "$hars_script" ]; then
		HA_REASON="no status script was found under $FRAMEWORK_ROOT"
		return 0
	fi
	if ! ha_confirm_foreign_script "$hars_script"; then
		HA_REASON="the status script under --source was not run"
		return 0
	fi

	HA_STDERR="$HUB_WORK/${hars_script##*/}.stderr"
	hars_rc=0
	"$hars_script" >"$hars_out" 2>"$HA_STDERR" || hars_rc=$?
	if ! grep -q "^$hars_key=" "$hars_out"; then
		HA_REASON=$(ha_reason_line "$HA_STDERR")
		[ -n "$HA_REASON" ] ||
			HA_REASON="${hars_script##*/} exited $hars_rc without reporting a state"
		return 0
	fi
	HA_RAN=1
}

case $SUBCOMMAND in
status)
	hub_validate_format text env

	GH_OUT="$HUB_WORK/gh.env"
	GL_OUT="$HUB_WORK/gl.env"
	JIRA_OUT="$HUB_WORK/jira.env"
	: >"$GH_OUT"
	: >"$GL_OUT"
	: >"$JIRA_OUT"
	# The SENTINEL each delegate documents as always emitted, even on its own
	# failure paths — see ha_run_status_script for why a key rather than an exit
	# status is what decides "did this actually measure anything".
	ha_run_status_script "$GH_STATUS_SCRIPT" "$GH_OUT" GH_INSTALLED
	GH_STATE_KNOWN=$([ "$HA_RAN" -eq 1 ] && printf true || printf false)
	GH_REASON=$HA_REASON
	GH_STDERR=$HA_STDERR
	ha_run_status_script "$GL_STATUS_SCRIPT" "$GL_OUT" GLAB_INSTALLED
	GL_STATE_KNOWN=$([ "$HA_RAN" -eq 1 ] && printf true || printf false)
	GL_REASON=$HA_REASON
	GL_STDERR=$HA_STDERR
	ha_run_status_script "$JIRA_STATUS_SCRIPT" "$JIRA_OUT" JIRA_AUTH_CONFIGURED
	JIRA_STATE_KNOWN=$([ "$HA_RAN" -eq 1 ] && printf true || printf false)
	JIRA_REASON=$HA_REASON

	GH_INSTALLED=$(hub_env_field "$GH_OUT" GH_INSTALLED false)
	GH_AUTHENTICATED=$(hub_env_field "$GH_OUT" GH_AUTHENTICATED false)
	GH_ACCOUNT=$(hub_env_field "$GH_OUT" GH_ACTIVE_ACCOUNT '')
	GH_HOST=$(hub_env_field "$GH_OUT" GH_HOST '')
	# GL_* mirrors GH_* field-for-field, reading the GitLab delegate's own
	# GLAB_-prefixed vocabulary (glab-auth-status.sh's own naming, distinct from
	# this script's GH_/GL_ internal prefixes) exactly the way the GitHub block
	# reads gh-auth-status.sh's GH_-prefixed one.
	GL_INSTALLED=$(hub_env_field "$GL_OUT" GLAB_INSTALLED false)
	GL_AUTHENTICATED=$(hub_env_field "$GL_OUT" GLAB_AUTHENTICATED false)
	GL_ACCOUNT=$(hub_env_field "$GL_OUT" GLAB_ACTIVE_ACCOUNT '')
	GL_HOST=$(hub_env_field "$GL_OUT" GLAB_HOST '')
	JIRA_CONFIGURED=$(hub_env_field "$JIRA_OUT" JIRA_AUTH_SITE_CONFIGURED false)
	JIRA_SITE=$(hub_env_field "$JIRA_OUT" JIRA_AUTH_SITE '')
	JIRA_ACCOUNT=$(hub_env_field "$JIRA_OUT" JIRA_AUTH_ACCOUNT '')

	# AUTHENTICATED-BUT-UNRESOLVED IS NOT A KNOWN STATE, and this is where that is
	# decided rather than inside ha_run_status_script, which knows nothing about
	# either delegate's fields. gh-auth-status.sh documents two outcomes where it
	# reports GH_AUTHENTICATED=true and still resolves NO single active account: more
	# than one host is active (GH_ACTIVE_AMBIGUOUS=true), or none could be resolved
	# at all. Both used to render as a green checkmark reading "authenticated as
	# ()" — an empty account name — and to publish HUB_GH_STATE_KNOWN=true, which is
	# precisely the "checked and definitively answered" claim that field exists to
	# make. Nothing was answered, so the state is not known, and the delegate's own
	# stderr says why.
	if [ "$GH_STATE_KNOWN" = true ] && [ "$GH_AUTHENTICATED" = true ] && [ -z "$GH_ACCOUNT" ]; then
		GH_STATE_KNOWN=false
		GH_REASON=$(ha_reason_line "$GH_STDERR")
		[ -n "$GH_REASON" ] || GH_REASON='no single active GitHub account could be resolved'
	fi
	# The identical GitLab check, against glab-auth-status.sh's own documented
	# GLAB_ACTIVE_AMBIGUOUS shape — same rationale as the GitHub block above.
	if [ "$GL_STATE_KNOWN" = true ] && [ "$GL_AUTHENTICATED" = true ] && [ -z "$GL_ACCOUNT" ]; then
		GL_STATE_KNOWN=false
		GL_REASON=$(ha_reason_line "$GL_STDERR")
		[ -n "$GL_REASON" ] || GL_REASON='no single active GitLab account could be resolved'
	fi

	# "used by" is derived from the SAME cross-domain consumer rule the installer
	# walks (lib/hub-domains.sh's hub_shared_consumers), not from a second
	# hand-written list — so a change to who needs GitHub auth moves both the
	# installer and this screen at once. Jira has no cross-domain entry by
	# construction: its auth lives inside Project Management's own Jira tracker.
	hub_discovery_build "$FRAMEWORK_ROOT"
	hub_states_build "$TARGET_DIR"

	# Materialized to a file, then read with a redirect — never a `while read`
	# fed by a heredoc-wrapped command substitution, which is the construction
	# hub-uninstall.sh's own comment calls out as unsafe. All three consumers of
	# hub_shared_consumers now read it the same, plainer way.
	HA_CONSUMERS="$HUB_WORK/shared-consumers.tsv"
	hub_shared_consumers "$HUB_SHARED_GITHUB_AUTH_GROUP" >"$HA_CONSUMERS"
	# THE "— not installed" ANNOTATION SITS OUTSIDE the consumer's own parentheses, on
	# every line of this screen. Here that is automatic (the annotation is appended to a
	# complete label), and the Jira line below now does the same rather than reaching
	# inside a half-built parenthesis — see there.
	GH_USED_BY=""
	while IFS="$HUB_TAB" read -r HA_CONSUMER HA_NOTE; do
		[ -n "$HA_CONSUMER" ] || continue
		if [ "$(hub_group_state "$HA_CONSUMER")" = available ]; then
			HA_NOTE="$HA_NOTE — not installed"
		fi
		GH_USED_BY=$(hub_join_append "$GH_USED_BY" "$HA_NOTE" ', ')
	done <"$HA_CONSUMERS"

	# The identical shape for GitLab-auth's own consumers (Software Development's
	# GitLab VCS choice, Project Management's GitLab tracker choice) — a second
	# call, not a generalized loop over HUB_SHARED_GROUPS, because GH_USED_BY and
	# GL_USED_BY are two DISTINCT machine fields this screen renders on two
	# distinct lines; collapsing them into one loop would need the same per-host
	# variable dispatch this avoids by just calling the pattern twice.
	hub_shared_consumers "$HUB_SHARED_GITLAB_AUTH_GROUP" >"$HA_CONSUMERS"
	GL_USED_BY=""
	while IFS="$HUB_TAB" read -r HA_CONSUMER HA_NOTE; do
		[ -n "$HA_CONSUMER" ] || continue
		if [ "$(hub_group_state "$HA_CONSUMER")" = available ]; then
			HA_NOTE="$HA_NOTE — not installed"
		fi
		GL_USED_BY=$(hub_join_append "$GL_USED_BY" "$HA_NOTE" ', ')
	done <"$HA_CONSUMERS"

	# THE FIRST Jira tracker group wins and the loop STOPS there. Without the break it
	# kept the LAST match, which is the same answer today (there is exactly one Jira
	# tracker) and quietly the wrong shape: "which group is the Jira tracker" is a
	# lookup, and a lookup that keeps scanning after it has found its answer reads as
	# though later rows could legitimately override earlier ones.
	JIRA_TRACKER_STATE=available
	JIRA_TRACKER_GROUP=""
	for HA_GROUP in $(hub_selectable_groups pm-tracker); do
		[ "$(hub_group_field "$HA_GROUP" 6)" = jira ] || continue
		JIRA_TRACKER_GROUP=$HA_GROUP
		JIRA_TRACKER_STATE=$(hub_group_state "$HA_GROUP")
		break
	done
	# "Project Management (Jira)" — the domain named, then the tracker, because this
	# line stands alone with no domain heading anywhere near it. Through
	# hub_group_label_in_context, the ONE owner of that qualification (the same call
	# hub-uninstall.sh's own heading-less Remove:/Result receipt and
	# lib/hub-domains.sh's consumer annotations make — NOT hub-uninstall.sh's
	# interactive checklist any more, which now shows the bare label under a domain
	# heading of its own — see that file's CHECKLIST_ROWS header), rather than
	# composed here from hub_domain_label plus a hardcoded "Jira": the
	# hand-built version existed only so that "— not installed" could be appended
	# INSIDE the parenthesis, which is the opposite of what the GitHub line above does
	# with the identical annotation — two punctuation conventions for one concept on one
	# screen. The annotation goes outside on both now, and the tracker word comes from
	# the group table like every other label in the hub.
	#
	# An `if`, never `[ -n "$G" ] || JIRA_USED_BY=$(…)`: an assignment on the right of
	# `||` is exempt from `set -e`, so a die inside the substitution (this one reaches
	# hub_discovery_require and hub_domain_label) would be downgraded to an empty label
	# and quietly absorbed by the fallback below. As the last command of an `if` body it
	# fails the script instead.
	JIRA_USED_BY=""
	if [ -n "$JIRA_TRACKER_GROUP" ]; then
		JIRA_USED_BY=$(hub_group_label_in_context "$JIRA_TRACKER_GROUP")
	fi
	# A source shipping no Jira tracker at all has no group row to name, so the
	# qualified form comes back empty and the domain alone is the honest subject — never
	# an empty "used by:" line. Same fallback, for the same reason, as
	# hub_shared_consumers' own GitHub-tracker annotation.
	if [ -z "$JIRA_USED_BY" ]; then
		JIRA_USED_BY=$(hub_domain_label project-management)
	fi
	if [ "$JIRA_TRACKER_STATE" = available ]; then
		JIRA_USED_BY="$JIRA_USED_BY — not installed"
	fi

	if [ "$OPT_FORMAT" = env ]; then
		hub_env_kv HUB_STATUS ok
		hub_env_kv HUB_ACTION accounts-status
		# STATE_KNOWN says whether the two booleans below were MEASURED or are
		# just their defaults because the status script was not run. Without it a
		# caller cannot tell "not authenticated" from "not checked", and Doctor
		# would report the first when it only knows the second.
		hub_env_kv HUB_GH_STATE_KNOWN "$GH_STATE_KNOWN"
		hub_env_kv HUB_GH_INSTALLED "$GH_INSTALLED"
		hub_env_kv HUB_GH_AUTHENTICATED "$GH_AUTHENTICATED"
		hub_env_kv HUB_GH_ACCOUNT "$GH_ACCOUNT"
		hub_env_kv HUB_GH_HOST "$GH_HOST"
		hub_env_kv HUB_GH_USED_BY "$GH_USED_BY"
		hub_env_kv HUB_GL_STATE_KNOWN "$GL_STATE_KNOWN"
		hub_env_kv HUB_GL_INSTALLED "$GL_INSTALLED"
		hub_env_kv HUB_GL_AUTHENTICATED "$GL_AUTHENTICATED"
		hub_env_kv HUB_GL_ACCOUNT "$GL_ACCOUNT"
		hub_env_kv HUB_GL_HOST "$GL_HOST"
		hub_env_kv HUB_GL_USED_BY "$GL_USED_BY"
		hub_env_kv HUB_JIRA_STATE_KNOWN "$JIRA_STATE_KNOWN"
		hub_env_kv HUB_JIRA_CONFIGURED "$JIRA_CONFIGURED"
		hub_env_kv HUB_JIRA_SITE "$JIRA_SITE"
		hub_env_kv HUB_JIRA_ACCOUNT "$JIRA_ACCOUNT"
		hub_env_kv HUB_JIRA_USED_BY "$JIRA_USED_BY"
		hub_env_kv HUB_JIRA_TRACKER_INSTALLED "$([ "$JIRA_TRACKER_STATE" = available ] && printf false || printf true)"
		exit 0
	fi

	# "not authenticated"/"not checked" are dimmed, never glyphed — an expected
	# state, not a failure. The glyph now LEADS the account name on a genuine
	# pass (a live test session asked for this consistently everywhere: the
	# status icon always comes before the thing it reports on), with a matching
	# 4-space indent on the no-glyph branches so "GitHub"/"Jira" still line up.
	# The REASON is the delegate's own first stderr line where it has one (ambiguity,
	# a crash), else ha_run_status_script's own account of why nothing ran. A bare
	# "not checked" with no reason was the previous shape, and on the ambiguous path
	# it was not even reached — the screen claimed success instead.
	if [ "$GH_STATE_KNOWN" != true ]; then
		hub_print_hint "$(printf '    GitHub   not checked — %s' "$GH_REASON")"
	elif [ "$GH_INSTALLED" != true ]; then
		hub_print_hint '    GitHub   gh not installed — install it, then re-run "Doctor"'
	elif [ "$GH_AUTHENTICATED" = true ]; then
		printf '  %s GitHub   authenticated as %s (%s)\n' "$(hub_glyph_ok)" "$GH_ACCOUNT" "$GH_HOST"
	else
		hub_print_hint '    GitHub   not authenticated'
	fi
	hub_print_hint "$(printf '             used by: %s' "$GH_USED_BY")"
	if [ "$GL_STATE_KNOWN" != true ]; then
		hub_print_hint "$(printf '    GitLab   not checked — %s' "$GL_REASON")"
	elif [ "$GL_INSTALLED" != true ]; then
		hub_print_hint '    GitLab   glab not installed — install it, then re-run "Doctor"'
	elif [ "$GL_AUTHENTICATED" = true ]; then
		printf '  %s GitLab   authenticated as %s (%s)\n' "$(hub_glyph_ok)" "$GL_ACCOUNT" "$GL_HOST"
	else
		hub_print_hint '    GitLab   not authenticated'
	fi
	hub_print_hint "$(printf '             used by: %s' "$GL_USED_BY")"
	if [ "$JIRA_STATE_KNOWN" != true ]; then
		hub_print_hint "$(printf '    Jira     not checked — %s' "$JIRA_REASON")"
	elif [ "$JIRA_CONFIGURED" = true ]; then
		printf '  %s Jira     authenticated as %s (%s)\n' "$(hub_glyph_ok)" "$JIRA_ACCOUNT" "$JIRA_SITE"
	else
		hub_print_hint '    Jira     not authenticated'
	fi
	hub_print_hint "$(printf '             used by: %s' "$JIRA_USED_BY")"
	exit 0
	;;
switch-github | reauth-github)
	hub_is_tty || die "switch-github/reauth-github require an interactive terminal"
	[ -n "$GH_MANAGE_SCRIPT" ] || die "GitHub account manager script not found under $FRAMEWORK_ROOT"
	ha_exec_delegate "$GH_MANAGE_SCRIPT"
	;;
switch-gitlab | reauth-gitlab)
	hub_is_tty || die "switch-gitlab/reauth-gitlab require an interactive terminal"
	[ -n "$GL_MANAGE_SCRIPT" ] || die "GitLab account manager script not found under $FRAMEWORK_ROOT"
	ha_exec_delegate "$GL_MANAGE_SCRIPT"
	;;
configure-jira | reauth-jira)
	hub_is_tty || die "configure-jira/reauth-jira require an interactive terminal"
	[ -n "$JIRA_LOGIN_SCRIPT" ] || die "Jira login script not found under $FRAMEWORK_ROOT"
	ha_exec_delegate "$JIRA_LOGIN_SCRIPT"
	;;
*)
	die_usage "unknown subcommand: $SUBCOMMAND"
	;;
esac
