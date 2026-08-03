#!/usr/bin/env sh
# lib/hub-symlink.sh — the symlink write/remove primitive, with the universal
#                       foreign-file-at-target write guard.
#
# Sourced after lib/hub-common.sh and lib/hub-state.sh (uses hub_target_path,
# hub_readlink_abs). Not executable on its own.
#
# EVERY hub write to a domain-unit symlink funnels through the functions here —
# never a bare ln/rm at a call site for those — so the guard and the outcome
# vocabulary live in exactly one place for symlink installs/removals. The one
# documented exception is lib/hub-bundle.sh's CLAUDE.md backup/restore
# (plain-file cp/rm/mv, not a symlink op) — it reuses hub_assert_write_target
# directly but has no outcome-vocabulary wrapper of its own; see its own
# comment for why.
# The guard logic is carried forward unchanged in substance from the previous
# hub: it is not domain-aware and had no reason to change. What is new is the
# path-level layer (hub_symlink_at / hub_unlink_at), so the first-run bundle's
# CLAUDE.md and contract links get the identical protection as a domain unit
# instead of a second, subtly different copy of it.
#
# KNOWN, ACCEPTED, DOCUMENTED LOW-RISK RACE: the state check (a stat/readlink)
# and the later rm/ln are separate syscalls, so a TOCTOU window exists between
# them. Accepted rather than fixed: exploiting it requires the same local user
# (or another process running as that user) to swap the target path's occupant
# inside that window — at which point the attacker already has same-user write
# access to the target directory and could act on any file there regardless of
# what this script does. The race grants no privilege an attacker in that
# position does not already hold; an atomic rename-based swap would add genuine
# complexity for a same-user-only, no-escalation race.
#
# Portability: POSIX sh only.

# ===========================================================================
# THE WRITE BOUNDARY — defense in depth behind the name gate.
# ===========================================================================
# Every path this module writes to is composed from a discovered unit NAME, and
# that name is validated against HUB_NAME_CHARSET_RE the moment it enters the
# pipeline (lib/hub-discovery.sh), so a traversal sequence cannot reach here in
# the first place. The assertion below is the SECOND lock on the same door:
# it re-derives, from the path itself, that the directory about to be created,
# unlinked or linked into is one of the four the hub is permitted to touch. It
# costs one dirname per write and it means a future path-composing caller — a new
# bundle item, a new deployment layout — cannot silently widen the blast radius
# without tripping it.
#
# HUB_TARGET_DIR IS A CALLER CONTRACT: any script that performs writes sets it to
# its resolved --target before the first hub_symlink_at/hub_unlink_at with
# APPLY=1. Unset is treated as a programming error and dies loudly rather than
# defaulting to "allow anything", which is the failure mode this exists to
# prevent.

# hub_write_parent_allowed DIR ROOT -> exit 0 when DIR is one of the four
# directories the hub deploys into, relative to ROOT: ROOT itself (CLAUDE.md),
# ROOT/agents, ROOT/skills, and ROOT's contracts subdirectory. Anything else —
# including a path that merely happens to be nested deeper under ROOT — is
# refused, because the hub has no reason to write there.
hub_write_parent_allowed() {
	case $1 in
	"$2" | "$2/agents" | "$2/skills" | "$2/$HUB_BUNDLE_CONTRACTS_SUBDIR") return 0 ;;
	esac
	return 1
}

# hub_assert_write_target TARGET_PATH -> die unless TARGET_PATH's parent
# directory is an allowed deployment directory of HUB_TARGET_DIR.
#
# The check runs twice, and both runs are needed:
#   1. LEXICALLY, against HUB_TARGET_DIR as the caller spelled it. This is what
#      catches a traversal ("<target>/agents/../../tmp") — the string does not
#      match, whether or not the path exists yet, and a first run whose
#      directories do not exist yet is the normal case.
#   2. RESOLVED, only when the lexical form failed AND the parent exists. A
#      legitimate --target reached through a symlinked path (macOS's /tmp ->
#      /private/tmp, a symlinked $HOME) makes the lexical comparison fail for an
#      entirely innocent reason, so both sides are canonicalized and compared
#      again before an escape is declared. A traversal still fails this second
#      test, because its real path genuinely is outside the target.
hub_assert_write_target() {
	hawt_tp=$1
	[ -n "${HUB_TARGET_DIR:-}" ] ||
		die "hub_assert_write_target: HUB_TARGET_DIR is not set (a writing script must set it to its resolved --target)"

	hawt_parent=$(dirname "$hawt_tp")
	hub_write_parent_allowed "$hawt_parent" "$HUB_TARGET_DIR" && return 0

	if [ -d "$hawt_parent" ]; then
		hawt_real=$(hub_realpath "$hawt_parent") || hawt_real=""
		hawt_root=$(hub_realpath "$HUB_TARGET_DIR") || hawt_root=""
		if [ -n "$hawt_real" ] && [ -n "$hawt_root" ] &&
			hub_write_parent_allowed "$hawt_real" "$hawt_root"; then
			return 0
		fi
	fi

	die "refusing to write outside the deployment directories of $HUB_TARGET_DIR: $hawt_tp"
}

# hub_link_is_framework_owned PATH FRAMEWORK_ROOT -> exit 0 when PATH is a
# symlink resolving to somewhere inside FRAMEWORK_ROOT. A plain file or
# directory is never framework-owned, and neither is a symlink pointing
# elsewhere. Works on a DANGLING link (readlink succeeds even when the target is
# gone), which matters: a stale framework link is framework-owned and removable,
# a stale foreign link is not.
hub_link_is_framework_owned() {
	[ -h "$1" ] || return 1
	hlifo_raw=$(hub_readlink_abs "$1") || return 1
	case $hlifo_raw in
	"$2"/*) return 0 ;;
	*) return 1 ;;
	esac
}

# hub_path_state SRC TARGET_PATH -> installed | DIVERGED | available for one
# concrete target path, independent of any agent/skill naming convention. The
# path-level twin of lib/hub-state.sh's hub_state_set.
#
# SRC IS LEGITIMATELY EMPTY on the orphan-removal path (hub_unlink_orphan passes
# ""), which is exactly why a failed readlink must be classified EXPLICITLY as
# DIVERGED rather than defaulted to "": an empty readlink result compared against
# an empty expected SRC would test equal and report a symlink the hub cannot even
# read as "installed" — skipping hub_unlink_at's framework-ownership check
# entirely and letting an unreadable foreign link be deleted unguarded.
hub_path_state() {
	if [ -h "$2" ]; then
		if ! hps_raw=$(hub_readlink_abs "$2"); then
			printf 'DIVERGED\n'
		elif [ "$hps_raw" = "$1" ]; then
			printf 'installed\n'
		else
			printf 'DIVERGED\n'
		fi
	elif [ -e "$2" ]; then
		printf 'DIVERGED\n'
	else
		printf 'available\n'
	fi
}

# hub_symlink_at SRC TARGET_PATH FRAMEWORK_ROOT ALLOW_DIVERGED APPLY -> writes
# (or, with APPLY=0, previews) one symlink and prints exactly one outcome word:
#
#   create           nothing occupied the target; a fresh symlink is made.
#   replace          a framework-owned-but-mismatched occupant is re-synced
#                    (requires ALLOW_DIVERGED=1 — the informed consent the
#                    checklist's "[!] selected-but-diverged" annotation
#                    represents).
#   skip             already installed and correct; no change needed.
#   foreign-blocked  either a genuinely foreign occupant (NEVER overwritten,
#                    regardless of ALLOW_DIVERGED), or a framework-owned
#                    mismatch the caller did not consent to touch.
#
# The state is re-checked HERE, at write time, rather than trusted from the
# discovery snapshot the preview was built from — closing the gap between "the
# checklist said this was available" and "the disk still agrees", which matters
# most precisely when APPLY=1.
#
# Informed per-item consent can only ever cover the framework's OWN mismatched
# symlink, never someone else's unrelated file: deleting an arbitrary foreign
# file because a component name happened to collide with its path is exactly the
# failure the universal guard exists to prevent.
hub_symlink_at() {
	hsa_src=$1
	hsa_tp=$2
	hsa_root=$3
	hsa_allow_diverged=$4
	hsa_apply=$5

	case $(hub_path_state "$hsa_src" "$hsa_tp") in
	installed)
		printf 'skip\n'
		return 0
		;;
	DIVERGED)
		if ! hub_link_is_framework_owned "$hsa_tp" "$hsa_root"; then
			printf 'foreign-blocked\n'
			return 0
		fi
		if [ "$hsa_allow_diverged" -ne 1 ]; then
			printf 'foreign-blocked\n'
			return 0
		fi
		hsa_outcome=replace
		;;
	available)
		hsa_outcome=create
		;;
	esac

	if [ "$hsa_apply" -eq 1 ]; then
		hub_assert_write_target "$hsa_tp"
		hsa_parent=$(dirname "$hsa_tp")
		# umask 077 IN A SUBSHELL, so the restriction applies to these mkdirs and
		# to nothing else. Under the ambient umask these directories inherit
		# whatever the environment happens to allow — group-writable on a
		# `umask 002` system, which would let any member of the user's primary
		# group replace an agent definition the framework then executes. The
		# subshell is what keeps the umask from leaking into the caller's own
		# later file creation.
		if [ ! -d "$hsa_parent" ]; then
			(umask 077 && mkdir -p "$hsa_parent") || die "cannot create directory: $hsa_parent"
		fi
		rm -rf "$hsa_tp" || die "failed to remove existing target: $hsa_tp"
		ln -sfn "$hsa_src" "$hsa_tp" || die "failed to link $hsa_tp -> $hsa_src"
	fi
	printf '%s\n' "$hsa_outcome"
}

# hub_unlink_at SRC TARGET_PATH FRAMEWORK_ROOT ALLOW_DIVERGED APPLY -> removes
# one target occupant and prints removed | already-absent | foreign-blocked.
#
# The decision is a strict THREE-way classification in two stages:
#   Stage 1 — does the target resolve to precisely this SRC?
#     1. EXACT MATCH: a live, correct framework symlink. Always removed, no
#        gate — unambiguously the framework's own link to this exact source.
#   Stage 2 — only when stage 1 says no: is the occupant at least a symlink
#             resolving somewhere inside FRAMEWORK_ROOT?
#     2. FRAMEWORK-OWNED, WRONG TARGET: a stale/mismatched framework link,
#        gated by ALLOW_DIVERGED — the case informed per-item consent is about.
#     3. FOREIGN: a plain file/dir, or a symlink resolving outside the framework
#        entirely. NEVER removed, regardless of ALLOW_DIVERGED. There is no
#        consent mechanism for this case; the guard is unconditional.
#
# SRC may be empty, which is how an ORPHAN is removed: an orphan has no source
# left to compare against (that absence is what makes it an orphan), so stage 1
# can never match and the decision falls through to the framework-ownership
# test — which is precisely the right question for a stale link.
hub_unlink_at() {
	hua_src=$1
	hua_tp=$2
	hua_root=$3
	hua_allow_diverged=$4
	hua_apply=$5

	if [ ! -e "$hua_tp" ] && [ ! -h "$hua_tp" ]; then
		printf 'already-absent\n'
		return 0
	fi

	if [ "$(hub_path_state "$hua_src" "$hua_tp")" != installed ]; then
		if ! hub_link_is_framework_owned "$hua_tp" "$hua_root"; then
			printf 'foreign-blocked\n'
			return 0
		fi
		if [ "$hua_allow_diverged" -ne 1 ]; then
			printf 'foreign-blocked\n'
			return 0
		fi
	fi

	if [ "$hua_apply" -eq 1 ]; then
		hub_assert_write_target "$hua_tp"
		rm -rf "$hua_tp" || die "failed to remove $hua_tp"
	fi
	printf 'removed\n'
}

# THE THREE WRAPPERS BELOW RESOLVE THE TARGET PATH ON ITS OWN LINE, never inline
# as `hub_symlink_at "$3" "$(hub_target_path ...)" ...`. hub_target_path dies on
# an unknown kind, and a die inside a command substitution used as an ARGUMENT
# only exits that substitution's subshell — the outer command still runs, here
# with an EMPTY target path, which an APPLY=0 preview would happily classify as
# "available/create". An assignment propagates the exit status under `set -e`, so
# the caller-contract violation actually stops the run. Same shape, same reason,
# as lib/hub-bundle.sh's assign-then-printf note.

# hub_symlink_unit KIND NAME SRC TARGET_DIR FRAMEWORK_ROOT ALLOW_DIVERGED APPLY
# -> hub_symlink_at for one discovered unit, resolving the deployed path through
# the single hub_target_path mapping.
hub_symlink_unit() {
	hsu_tp=$(hub_target_path "$1" "$2" "$4")
	hub_symlink_at "$3" "$hsu_tp" "$5" "$6" "$7"
}

# hub_unlink_unit KIND NAME SRC TARGET_DIR FRAMEWORK_ROOT ALLOW_DIVERGED APPLY
# -> hub_unlink_at for one discovered unit.
hub_unlink_unit() {
	huu_tp=$(hub_target_path "$1" "$2" "$4")
	hub_unlink_at "$3" "$huu_tp" "$5" "$6" "$7"
}

# hub_unlink_orphan NAME KIND TARGET_DIR FRAMEWORK_ROOT APPLY -> remove one
# orphaned symlink. An empty SRC is passed deliberately (see hub_unlink_at), and
# ALLOW_DIVERGED=1 because "framework-owned but matching nothing" is exactly the
# state being cleaned up here.
hub_unlink_orphan() {
	huo_tp=$(hub_target_path "$2" "$1" "$3")
	hub_unlink_at "" "$huo_tp" "$4" 1 "$5"
}
