#!/usr/bin/env sh
# lib/hub-tools.sh — THE required-external-tools table: which tools the framework
#                     needs, why, how to install them, and whether this machine
#                     has them.
#
# Sourced after lib/hub-common.sh (uses `have`). Not executable on its own.
#
# hub-doctor.sh IS THE SOLE CONSUMER of this table today. It stays a lib rather
# than moving back inline into Doctor for one reason: this is the framework's
# definition of "required", and the moment a second surface needs it (a Main-menu
# banner, an install precondition) it must read THIS table rather than grow a
# second, drifting copy of what "required" means. Keeping it here is what makes
# that the obvious thing to do.
#
# WHAT USED TO BE HERE, AND WHY IT IS NOT: a hub_missing_required_tools helper
# answering the ONE fact "is a required tool missing", for the Main menu's warning
# banner. That banner was deliberately deleted (the Main menu is numbered options
# only now — see crucible-hub's own ch_main_menu_once), which left the helper with
# zero callers anywhere in the tree, so it is gone too. Version control is the
# archive; a lib exporting a function nobody calls only misleads the next reader
# about who depends on it. crucible-hub no longer sources this file at all.
#
# Portability: POSIX sh only.

# HUB_REQUIRED_TOOL_SLOTS — one SLOT per requirement. "gpg|ssh-keygen" is an
# OR-slot: either alternative satisfies it, so a machine with only ssh-keygen is
# not missing a requirement — it is a note about a preferred-but-optional tool,
# never a blocking problem.
#
# `gh` AND `glab` ARE BOTH LISTED, UNCONDITIONALLY, THE SAME WAY: neither VCS
# host is more "required" than the other now that Software Development's VCS
# choice and Project Management's tracker choice both offer GitHub and GitLab
# as peers (lib/hub-domains.sh §3b/§4) — treating one as baseline-required and
# the other as an afterthought would misstate the parity the framework's own
# GitHub/GitLab work established. Neither slot's absence is fatal on its own —
# a machine that never picks that host never needs its CLI — but this table
# only ever reports what a fully-equipped machine needs, the same unconditional
# treatment `gh` already had before `glab` existed.
HUB_REQUIRED_TOOL_SLOTS='git gh glab jq curl gpg|ssh-keygen'

# hub_tool_slot_primary SLOT / hub_tool_slot_fallback SLOT -> the two halves of a
# slot. The fallback is empty for a plain (non-OR) slot.
hub_tool_slot_primary() {
	printf '%s' "${1%%|*}"
}

hub_tool_slot_fallback() {
	case $1 in
	*'|'*) printf '%s' "${1#*|}" ;;
	*) printf '' ;;
	esac
}

# hub_tool_slot_state SLOT -> ok | ok-fallback | missing.
hub_tool_slot_state() {
	htss_primary=$(hub_tool_slot_primary "$1")
	htss_fallback=$(hub_tool_slot_fallback "$1")
	if have "$htss_primary"; then
		printf 'ok'
	elif [ -n "$htss_fallback" ] && have "$htss_fallback"; then
		printf 'ok-fallback'
	else
		printf 'missing'
	fi
}

# hub_tool_label TOOL -> the display name. This is the ONE lookup here with a
# passthrough default, deliberately: a tool's own command name is always a
# truthful label for it, so an unlabelled tool degrades to something correct.
hub_tool_label() {
	case $1 in
	git) printf 'Git' ;;
	gh) printf 'GitHub CLI' ;;
	glab) printf 'GitLab CLI' ;;
	jq) printf 'jq' ;;
	curl) printf 'curl' ;;
	gpg) printf 'GnuPG' ;;
	ssh-keygen) printf 'OpenSSH' ;;
	*) printf '%s' "$1" ;;
	esac
}

# hub_tool_reason / hub_tool_install_macos / hub_tool_install_linux — unlike the
# label above, these three have NO truthful fallback, so they DIE on an unknown
# tool rather than printing nothing. An empty string here is not a degraded
# answer, it is a false one: Doctor would print a finding that names no reason and
# a remediation step with no remedy in it.
# Fail-loud on an unknown key is this codebase's convention for a closed lookup —
# see lib/hub-domains.sh's hub_domain_label / hub_domain_blurb / hub_shared_consumers.
hub_tool_reason() {
	case $1 in
	git) printf 'needed by the git operator for branch/commit/push/tag and identity resolution' ;;
	gh) printf 'needed for GitHub account management, pull requests and the GitHub tracker' ;;
	glab) printf 'needed for GitLab account management, merge requests and the GitLab tracker' ;;
	jq) printf 'needed by the GTD inbox skills and the entire Jira surface' ;;
	curl) printf 'needed for every Jira REST call' ;;
	gpg) printf 'needed, as ONE of two alternatives (see OpenSSH), for git commit/tag signing' ;;
	ssh-keygen) printf 'needed, as ONE of two alternatives (see GnuPG), for git commit/tag signing' ;;
	*) die "hub_tool_reason: unknown tool slot '$1'" ;;
	esac
}

hub_tool_install_macos() {
	case $1 in
	git) printf 'brew install git' ;;
	gh) printf 'brew install gh' ;;
	glab) printf 'brew install glab' ;;
	jq) printf 'brew install jq' ;;
	curl) printf 'brew install curl (usually already present)' ;;
	gpg) printf 'brew install gnupg' ;;
	ssh-keygen) printf 'usually preinstalled; if missing, brew install openssh' ;;
	*) die "hub_tool_install_macos: unknown tool slot '$1'" ;;
	esac
}

hub_tool_install_linux() {
	case $1 in
	git) printf 'apt install git (or your distro package manager)' ;;
	gh) printf 'see https://github.com/cli/cli#installation' ;;
	glab) printf 'see https://gitlab.com/gitlab-org/cli#installation' ;;
	jq) printf 'apt install jq' ;;
	curl) printf 'apt install curl' ;;
	gpg) printf 'apt install gnupg' ;;
	ssh-keygen) printf 'apt install openssh-client' ;;
	*) die "hub_tool_install_linux: unknown tool slot '$1'" ;;
	esac
}

# hub_tools_build OUTFILE -> the whole table as
# "slot<TAB>primary<TAB>state<TAB>fallback", one row per slot.
#
# FALLBACK IS LAST, and that is load-bearing: it is empty for every plain
# (non-OR) slot, and `read` with IFS=TAB collapses consecutive tabs, so an empty
# column anywhere but the end silently shifts every field after it. It did
# exactly that here before this ordering — `state` came back empty for `git`,
# `jq` and `curl`, so their rows matched no case arm and printed no newline, and
# the whole Required-tools block rendered as a single run-together line. See
# lib/hub-common.sh's "THE TAB TRAP".
hub_tools_build() {
	: >"$1"
	for htb_slot in $HUB_REQUIRED_TOOL_SLOTS; do
		printf '%s\t%s\t%s\t%s\n' \
			"$htb_slot" "$(hub_tool_slot_primary "$htb_slot")" \
			"$(hub_tool_slot_state "$htb_slot")" "$(hub_tool_slot_fallback "$htb_slot")" >>"$1"
	done
}
