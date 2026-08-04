#!/usr/bin/env sh
# lib/hub-bundle.sh — the first-run bundle: CLAUDE.md (the operating contract)
#                      plus every *.schema.json found anywhere under the
#                      source root (not restricted to dirs literally named
#                      contracts — see hub_disc_contract_files).
#
# Sourced after lib/hub-common.sh, lib/hub-domains.sh, lib/hub-discovery.sh and
# lib/hub-symlink.sh. Not executable on its own.
#
# ===========================================================================
# WHY THIS EXISTS AND WHAT IT REPLACED
# ===========================================================================
# The bundle is not a domain capability: it is the framework's own operating
# contract and its data schemas. Every domain needs it, none of them owns it,
# and it is deliberately excluded from every domain's baseline count so a
# preview's arithmetic stays honest ("Also installing (first run only, not
# counted above)").
#
# The previous hub obtained this bundle by shelling out to `deploy.sh --only
# config` and `deploy.sh --only contract`, and gated it on a curated "core tier"
# being fully linked (CORE_NEEDED / hub_core_state). Both halves are re-keyed
# here:
#
#   * THE GATE is now CLAUDE.md's OWN symlink state. There is no core tier left
#     to be "fully linked", and CLAUDE.md is the single self-evident marker of
#     whether this hub has ever bootstrapped this target: it is one file, it is
#     always the same file, and its presence-as-a-framework-symlink is exactly
#     the question "is this a first run" is asking.
#
#   * THE MECHANISM is now this module rather than a deploy.sh subprocess.
#     deploy.sh is an all-or-nothing whole-tree deployer — precisely the model
#     the domain hub replaces — and its prune pass is actively wrong under the
#     domain model, where most discovered units are deliberately NOT installed
#     (`--no-prune` masked that, but the coupling stayed fragile). The bundle is
#     one config symlink plus N contract symlinks; implementing it directly
#     costs ~40 lines, removes an inter-process dependency on a script that
#     unconditionally runs main() when sourced, and routes these writes through
#     the same foreign-file guard every other hub write already uses instead of
#     a second, subtly different copy of that logic.
#
# The one piece of deploy.sh's config behavior that IS preserved verbatim in
# substance: a FOREIGN CLAUDE.md at the target is never silently clobbered and
# never merely refused — it is copied to a timestamped backup beside itself and
# then replaced. Losing a hand-written operating contract is not acceptable, so
# the replace is made non-destructive rather than blocked. The backup is
# faithful: `cp -RP` copies a regular file's content and preserves a symlink
# as-is, never dereferencing it.
#
# Portability: POSIX sh only.

# hub_bundle_config_src SRC -> the framework's own CLAUDE.md. Prints nothing and
# returns 1 when the source tree has none.
hub_bundle_config_src() {
	hbcs_path="$1/$HUB_BUNDLE_CONFIG_NAME"
	[ -f "$hbcs_path" ] || return 1
	printf '%s\n' "$hbcs_path"
}

# hub_bundle_config_target TARGET_DIR -> where CLAUDE.md is deployed.
hub_bundle_config_target() {
	printf '%s/%s\n' "$1" "$HUB_BUNDLE_CONFIG_NAME"
}

# hub_bundle_state SRC TARGET_DIR -> installed | "not installed".
#
# THE FIRST-RUN GATE. "installed" iff the target's CLAUDE.md is a symlink
# resolving to exactly the framework's own CLAUDE.md. A foreign CLAUDE.md, a
# stale framework link pointing at a moved source, or nothing at all all read as
# "not installed" — each of which genuinely needs the bundle written.
hub_bundle_state() {
	hbs_src=$(hub_bundle_config_src "$1") || {
		printf 'not installed\n'
		return 0
	}
	if [ "$(hub_path_state "$hbs_src" "$(hub_bundle_config_target "$2")")" = installed ]; then
		printf 'installed\n'
	else
		printf 'not installed\n'
	fi
}

# hub_bundle_install SRC TARGET_DIR APPLY -> install (or, with APPLY=0, preview)
# the whole bundle. Prints one "outcome<TAB>path" line per item so the caller can
# report and count without re-deriving anything; sets HUB_BUNDLE_BACKUP to the
# backup path when a foreign CLAUDE.md was preserved, else empty.
hub_bundle_install() {
	hbi_src=$1
	hbi_target=$2
	hbi_apply=$3
	HUB_BUNDLE_BACKUP=""

	hbi_config=$(hub_bundle_config_src "$hbi_src") ||
		die "no $HUB_BUNDLE_CONFIG_NAME found at the root of $hbi_src"
	hbi_tp=$(hub_bundle_config_target "$hbi_target")

	# A foreign occupant is backed up FIRST, then the link is written with
	# ALLOW_DIVERGED=1. Without the backup step, hub_symlink_at would correctly
	# refuse (foreign-blocked) and the operating contract would never install —
	# which is right for a domain unit and wrong for this one file, because the
	# whole point of the config category is that its replacement is made
	# non-destructive instead of refused.
	if [ "$(hub_path_state "$hbi_config" "$hbi_tp")" = DIVERGED ] &&
		! hub_link_is_framework_owned "$hbi_tp" "$hbi_src"; then
		# The timestamp has ONE-SECOND granularity, and `cp -RP` would silently
		# overwrite a same-named backup — losing the very file this whole code path
		# exists to preserve. Two installs inside the same second (a scripted
		# retry, a --target loop) is all it takes. A free path is therefore chosen
		# by probing, appending -2, -3, ... until one is unoccupied.
		#
		# The suffixed names still match hub_bundle_backups' CLAUDE.md.backup.*
		# glob, so uninstall's --restore-backup can still name one (as
		# "<timestamp>-2"). The probe-then-create gap is the same accepted,
		# same-user-only TOCTOU documented at the top of lib/hub-symlink.sh.
		#
		# CONSEQUENCE FOR AN APPLY=0 CALLER: the name derived here is INDICATIVE
		# only, never a commitment. A preview run stamps the moment it ran and the
		# later apply run stamps its own (and re-probes the -2, -3 suffixes against a
		# directory that may have changed meanwhile), so the two names differ as soon
		# as a second elapses between them. A caller previewing this must therefore
		# treat a non-empty HUB_BUNDLE_BACKUP as the answer to "will a backup be
		# taken", not to "what will it be called" — hub-install.sh's preview prints
		# the stable "CLAUDE.md.backup.<timestamp>" prefix for exactly this reason,
		# and only the APPLY=1 run's value names a file that exists.
		hbi_stamp=$(date -u '+%Y-%m-%dT%H-%M-%SZ')
		HUB_BUNDLE_BACKUP="$hbi_tp.backup.$hbi_stamp"
		hbi_seq=1
		while [ -e "$HUB_BUNDLE_BACKUP" ] || [ -h "$HUB_BUNDLE_BACKUP" ]; do
			hbi_seq=$((hbi_seq + 1))
			[ "$hbi_seq" -le 1000 ] ||
				die "cannot find a free backup name for $hbi_tp after 1000 attempts"
			HUB_BUNDLE_BACKUP="$hbi_tp.backup.$hbi_stamp-$hbi_seq"
		done
		if [ "$hbi_apply" -eq 1 ]; then
			# The write boundary is asserted HERE too, not only inside
			# hub_symlink_at/hub_unlink_at: these two are the bundle's own direct
			# cp/rm sinks, so without them lib/hub-symlink.sh's "called before every
			# write" claim is not literally true. Both paths are hub-composed from
			# $hbi_target today and both land in TARGET_DIR itself, so this changes
			# no behavior — it is the second lock that catches a FUTURE
			# path-composing bundle change, which is the whole point of the guard.
			hub_assert_write_target "$HUB_BUNDLE_BACKUP"
			hub_assert_write_target "$hbi_tp"
			cp -RP "$hbi_tp" "$HUB_BUNDLE_BACKUP" ||
				die "failed to back up existing $hbi_tp to $HUB_BUNDLE_BACKUP"
			rm -rf "$hbi_tp" || die "failed to remove $hbi_tp"
		fi
	fi
	# ===========================================================================
	# ASSIGN, THEN PRINT — never `printf ... "$(hub_symlink_at ...)"`.
	# ===========================================================================
	# hub_symlink_at can die (hub_assert_write_target's refusal, a failed
	# mkdir/rm/ln). Called as a command-substitution ARGUMENT to printf, that
	# `exit 1` only kills the substitution's own subshell: printf then succeeds
	# with an empty first field, the caller's `read -r outcome item` sees a
	# malformed line and skips it, and install reports HUB_STATUS=ok /
	# HUB_BUNDLE_INSTALLED=true / exit 0 for a write that never happened. An
	# ASSIGNMENT's exit status, by contrast, IS the substituted command's, so
	# `set -e` propagates the failure — which is why every write outcome in this
	# file is captured into a variable on its own line first.
	hbi_outcome=$(hub_symlink_at "$hbi_config" "$hbi_tp" "$hbi_src" 1 "$hbi_apply")
	printf '%s\t%s\n' "$hbi_outcome" "$HUB_BUNDLE_CONFIG_NAME"

	hbi_contracts="$(hub_mktemp_dir)/contracts.txt"
	hub_disc_contract_files "$hbi_src" >"$hbi_contracts"
	while IFS= read -r hbi_file; do
		[ -n "$hbi_file" ] || continue
		hbi_base=${hbi_file##*/}
		hbi_outcome=$(hub_symlink_at "$hbi_file" \
			"$hbi_target/$HUB_BUNDLE_CONTRACTS_SUBDIR/$hbi_base" "$hbi_src" 1 "$hbi_apply")
		printf '%s\t%s\n' "$hbi_outcome" "$hbi_base"
	done <"$hbi_contracts"
}

# hub_bundle_count SRC -> how many items the bundle holds (1 config + N
# contracts), for the preview's "not counted above" line.
hub_bundle_count() {
	hbc_contracts="$(hub_mktemp_dir)/contracts.txt"
	hub_disc_contract_files "$1" >"$hbc_contracts"
	printf '%s\n' "$(($(hub_count_lines "$hbc_contracts") + 1))"
}

# hub_bundle_backups TARGET_DIR -> one CLAUDE.md.backup.* path per line, oldest
# first (the timestamp format sorts lexically).
hub_bundle_backups() {
	find "$1" -maxdepth 1 -name "$HUB_BUNDLE_CONFIG_NAME.backup.*" -print 2>/dev/null | LC_ALL=C sort
}

# hub_bundle_restore_config BACKUP TARGET_PATH -> put BACKUP back at TARGET_PATH
# and consume it. Sets HUB_BUNDLE_RESTORED to BACKUP once the swap has landed.
#
# STAGE-THEN-mv, never `cp -RP` straight onto TARGET_PATH, and that is a write
# BOUNDARY fix rather than a tidiness one: if TARGET_PATH is a symlink — which is
# exactly what it normally is, the framework's own CLAUDE.md link, and what a
# foreign occupant can also be — `cp` FOLLOWS it and writes to whatever it points
# at, anywhere on the filesystem, while hub_assert_write_target only ever
# constrains the lexical path's PARENT. `mv` replaces the link itself and never
# its referent, so the write cannot escape the target directory. It is also atomic,
# so an interrupted restore can never leave a half-written operating contract at
# the one path everything else in the framework reads.
#
# The staging name is predictable ($$) and cleared with `rm -rf` first, which is
# what defeats a pre-created symlink sitting there: rm removes the link, not its
# target. The remaining window between that rm and the cp is the same accepted,
# same-user-only TOCTOU documented at the top of lib/hub-symlink.sh. It does not
# match hub_bundle_backups' own CLAUDE.md.backup.* glob, so a crashed restore can
# never be offered back as a "backup" to restore.
hub_bundle_restore_config() {
	hbrc_backup=$1
	hbrc_tp=$2
	hbrc_staged="$hbrc_tp.restoring.$$"
	hub_assert_write_target "$hbrc_tp"
	hub_assert_write_target "$hbrc_backup"
	hub_assert_write_target "$hbrc_staged"
	rm -rf "$hbrc_staged" || die "failed to clear the restore staging path $hbrc_staged"
	cp -RP "$hbrc_backup" "$hbrc_staged" ||
		die "failed to stage the restore of $hbrc_backup"
	mv -f "$hbrc_staged" "$hbrc_tp" || die "failed to restore backup: $hbrc_backup"
	rm -rf "$hbrc_backup" || die "failed to remove consumed backup: $hbrc_backup"
	HUB_BUNDLE_RESTORED=$hbrc_backup
}

# hub_bundle_remove SRC TARGET_DIR APPLY RESTORE_PATH -> remove the bundle,
# optionally restoring a chosen CLAUDE.md backup in place of the framework's
# link. Prints one "outcome<TAB>path" line per item, and sets HUB_BUNDLE_RESTORED
# to the backup that was actually consumed — empty when none was, so a caller
# reports what happened instead of what it asked for.
#
# CLAUDE.md is handled as remove-then-restore rather than a single atomic swap:
# it is a two-step on a config file whose whole flow already sits behind the
# critical typed-phrase gate, and the restore consumes the backup so a second
# uninstall cannot silently re-restore a file the user already got back.
hub_bundle_remove() {
	hbr_src=$1
	hbr_target=$2
	hbr_apply=$3
	hbr_restore=$4
	HUB_BUNDLE_RESTORED=""

	hbr_contracts="$(hub_mktemp_dir)/contracts.txt"
	hub_disc_contract_files "$hbr_src" >"$hbr_contracts"
	while IFS= read -r hbr_file; do
		[ -n "$hbr_file" ] || continue
		hbr_base=${hbr_file##*/}
		# Assign, then print — see hub_bundle_install's note above; hub_unlink_at
		# can die and a die inside a printf argument is swallowed with the subshell.
		hbr_outcome=$(hub_unlink_at "$hbr_file" \
			"$hbr_target/$HUB_BUNDLE_CONTRACTS_SUBDIR/$hbr_base" "$hbr_src" 1 "$hbr_apply")
		printf '%s\t%s\n' "$hbr_outcome" "$hbr_base"
	done <"$hbr_contracts"

	hbr_tp=$(hub_bundle_config_target "$hbr_target")
	# An empty SRC config is legitimate here: a --source whose CLAUDE.md was
	# renamed or removed still leaves a link at the target that must come out,
	# and hub_unlink_at treats an unmatched-but-framework-owned link exactly as
	# it treats an orphan.
	if ! hbr_config=$(hub_bundle_config_src "$hbr_src"); then
		hbr_config=""
	fi
	hbr_outcome=$(hub_unlink_at "$hbr_config" "$hbr_tp" "$hbr_src" 1 "$hbr_apply")
	hbr_item=$HUB_BUNDLE_CONFIG_NAME

	# THE CONFIG'S OUTCOME LINE IS PRINTED AFTER THE RESTORE DECISION, not before
	# it, so ONE occupied path produces exactly ONE outcome line. An earlier version
	# printed the unlink's outcome here and then, when the restore was skipped,
	# printed a SECOND `foreign-blocked` line for the same event — which made the
	# callers' foreign_blocked_count report 2 blocked items for 1 occupied path and
	# put a redundant second sentence on the Result screen. Deferring the print lets
	# the restore decision append to the SAME item string instead of emitting a
	# sibling of it.
	#
	# Nothing is lost by printing late: hub_bundle_restore_config dies rather than
	# returning on failure, and a die takes the whole run down before any caller
	# reads this log, so there is no path on which an emitted-then-abandoned line
	# would have been informative.
	if [ -n "$hbr_restore" ] && [ "$hbr_apply" -eq 1 ]; then
		# THE RESTORE IS GATED ON THE UNLINK'S OWN OUTCOME, and that gate is the
		# whole point of capturing hbr_outcome above. It used to run
		# unconditionally, including after `foreign-blocked` — the outcome that
		# means the occupant at $hbr_tp was NOT removed because it is not the
		# framework's. Restoring on top of it overwrote the very file the guard had
		# just refused to touch (and, when that occupant is a symlink, wrote THROUGH
		# it to wherever it pointed — see hub_bundle_restore_config), and then
		# deleted the backup in the same step, destroying the only recovery copy of
		# the contract this whole path exists to give back.
		#
		# The refusal is reported through the SAME outcome-line channel every other
		# item here uses, tagged `foreign-blocked` rather than a new word: the
		# callers' outcome vocabulary is closed (see hub-uninstall.sh's own log
		# loop), and this genuinely is the foreign-occupant refusal — a file that is
		# not framework-owned holds the config's path, so the backup could not be put
		# back and stays where it is.
		#
		# THE ITEM NAME IS THE OCCUPIED PATH, not the backup's basename, because the
		# callers render every foreign-blocked item through ONE shared sentence
		# ("<item> left untouched — a file that is not framework-owned occupies its
		# path"). Naming the backup there made that sentence say the BACKUP was the
		# foreign occupant, which is backwards: the backup is fine and still
		# recoverable by hand, and it is CLAUDE.md's path that is occupied. Naming
		# the config and parenthesizing the skipped restore keeps the one shared
		# message truthful without inventing a second one for this single case.
		#
		# The arms are EXHAUSTIVE against hub_unlink_at's closed vocabulary
		# (removed | already-absent | foreign-blocked — see lib/hub-symlink.sh)
		# rather than catch-all, so a future fourth outcome word cannot silently
		# inherit the foreign-blocked wording and be reported as a refusal it is not.
		case $hbr_outcome in
		removed | already-absent)
			hub_bundle_restore_config "$hbr_restore" "$hbr_tp"
			;;
		foreign-blocked)
			hbr_item="$hbr_item (restore of ${hbr_restore##*/} skipped)"
			;;
		*)
			die "hub_bundle_remove: unexpected outcome '$hbr_outcome' for $hbr_tp"
			;;
		esac
	fi
	printf '%s\t%s\n' "$hbr_outcome" "$hbr_item"
}
