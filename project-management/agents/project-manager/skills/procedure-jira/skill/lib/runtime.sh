# shellcheck shell=sh
#
# runtime.sh — the engine's process-wide runtime: the tuning//layout constants,
#              every mutable global, the temp workdir, the EXIT/INT/TERM/HUP
#              teardown, and the two diagnostic writers every other unit calls.
#
# Sourced FIRST (see jira.sh's sourcing loop): the globals it declares are the
# state every later unit reads and writes, and its `trap` must be installed
# before any unit can create a temp file. It owns no command logic and makes no
# network call.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.
#
# shellcheck disable=SC2034  # file-wide, deliberately: declaring cross-unit globals IS this file's entire job, and shellcheck lints each unit in isolation so it can never see the readers in the other 45

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_PROJECTS_DIR_DEFAULT="$HOME/.claude/skills/procedure-jira/projects"
ESC=$(printf '\033')
NL='
'

# ---------------------------------------------------------------------------
# Global state (plain vars — this script is a single short-lived process,
# not a library, and POSIX sh has no `local`; every var below starts empty/0
# so cleanup() can safely check "was this actually created" on any exit path).
#
# CONVENTION for anyone adding or editing a command: every helper function's
# scratch/parameter variables are plain globals scoped ONLY by a name that is
# unique to that function. Because POSIX sh has no `local`, a name reused
# across two functions that can appear in the same call chain (e.g. one helper
# calling another) will silently clobber the caller's copy — and since the
# engine was split into 46 sourced units, the two colliding functions are
# rarely on the same screen any more.
#
# The form that survives that split is a SHORT PER-FUNCTION PREFIX, derived
# from the function's own name: resolve_account_id's `rai_value`/
# `rai_account_id`, build_search_request_body's `bsrb_*`, merge_named_refs'
# `mnr_*`, agile_paginate's `fpa_*`. Never a bare `key`/`value`/`url`/`jql`/
# `config_file` — those read as "any function's scratch", which is exactly
# what makes them collide. tests/check-variable-collisions.sh is the automated
# guard: it fails the build on a name two functions in one call chain share
# across the callee boundary.
# ---------------------------------------------------------------------------
WORKDIR=""
RESP_COUNTER=0
CURL_CONFIG_FILE=""
CURL_CONFIG_IS_OWN=0
CONFIRMED_HOST=""
PROJECT_CONFIG_FILE=""
JIRA_HTTP_BODY_FILE=""
JIRA_HTTP_CODE=""
# http.sh's fetch_attachment_content_redirect publishes its header dump here,
# the same way the two curl senders publish $JIRA_HTTP_BODY_FILE — it owns the
# $WORKDIR allocation so its two callers don't each repeat one. It is read
# IMMEDIATELY after the call and never held across another (see that function's
# header).
FACR_HEADER_FILE=""
MERGE_COUNTER=0
ADF_COUNTER=0
TRANS_COUNTER=0
APPEND_COUNTER=0
MEDIA_COUNTER=0
# The truncation verdict issue-set.sh's compute_truncation() publishes and
# both batch commands read back. BATCH_RESOLVED_LIMIT is an integer or the
# bare `null` literal, because batch-report.sh feeds it straight to
# `jq --argjson`.
BATCH_TRUNCATED=false
BATCH_RESOLVED_LIMIT=null
# The accountId `bulk --op update` pre-resolves ONCE per batch (see cmd-bulk.sh)
# and the looped cmd_update reads back via `${…:-}` in place of its own lookup.
# Declared HERE, at process level, so they can never be INHERITED FROM THE
# ENVIRONMENT — the same hazard cmd-comment-edit.sh's COMMENT_EDIT_VERIFIED_KEY
# is pre-seeded against. Declared only inside cmd_bulk, nothing defined them on
# the DIRECT `update` path (where cmd_bulk never runs), so an exported
# BULK_RESOLVED_REVIEWER_ID would have been written to the ticket verbatim in
# place of the accountId freshly resolved from the caller's own --reviewer value.
BULK_RESOLVED_ASSIGNEE_ID=""
BULK_RESOLVED_DEVELOPER_ID=""
BULK_RESOLVED_REVIEWER_ID=""
# Every directory assert_safe_dir has already WARNED about, one per line with a
# trailing newline, so one ACL-bearing directory checked twice in a process warns
# ONCE. `discover --write` gates $JIRA_PROJECTS_DIR twice by design (see
# save_discovered_config), and a warning a reader sees twice per run is one they
# learn to skip — the same train-it-away failure the ACL block's own `+`-only
# choice weighs.
#
# IT MEMOIZES THE WARNING, NEVER THE VERDICT: every refusal still re-reads the
# directory's mode immediately before the write it guards, so this cannot widen
# any check-then-use window.
#
# A LIST RATHER THAN ONE LAST-WARNED SLOT, because the calls genuinely interleave:
# $TMPDIR's gate can fall BETWEEN the projects directory's two (any path where
# ensure_workdir is first reached from inside save_discovered_config), which a
# single slot answers with three warnings for two directories. The ONE residual is
# a directory whose own name contains a newline, which could match another
# entry's line boundary — and it costs a duplicated or a suppressed WARNING only,
# never a changed verdict.
ACL_WARNED_DIRS=""
# The staging path stage_install_copy publishes for its two installers, the same
# way http.sh's fetch_attachment_content_redirect publishes $FACR_HEADER_FILE.
# Read IMMEDIATELY into the caller's own prefixed variable and never held across
# another call (see that function's header).
STAGED_INSTALL_PATH=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	ec=$?
	if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR" 2>/dev/null || true; fi
	if [ "$CURL_CONFIG_IS_OWN" -eq 1 ] && [ -n "$CURL_CONFIG_FILE" ]; then
		rm -f "$CURL_CONFIG_FILE" 2>/dev/null || true
	fi
	exit "$ec"
}
trap cleanup EXIT INT TERM HUP

ensure_workdir() {
	if [ -z "$WORKDIR" ]; then
		ew_tmpdir=${TMPDIR:-/tmp}
		assert_safe_tmpdir "$ew_tmpdir"
		WORKDIR=$(mktemp -d "$ew_tmpdir/jira.work.XXXXXX")
	fi
}

# assert_safe_tmpdir DIR — the ${TMPDIR:-/tmp} caller of assert_safe_dir below,
# naming the two artifacts this engine CREATES there and the remedy that is
# $TMPDIR's own.
#
# CALLED AT EACH OF THE TWO $TMPDIR CREATION SITES — ensure_workdir above, and
# credentials.sh's own `mktemp` for the curl `-K` config, which lands directly in
# $TMPDIR (see its note for what an attacker substitutes there). At the creation
# site rather than once at startup, so a future third site cannot be silently
# missed. ensure_workdir's call is the one EVERY invocation relies on:
# credentials.sh reaches its own only on the FALLBACK path, since the preferred
# $JIRA_CURL_CONFIG handoff returns before it.
#
# WHY A 0700 ENTRY IS NOT ENOUGH, and why this guards EVERY command rather than
# just `attach --download`: a 0700 `mktemp -d` protects what is created INSIDE it,
# never its own directory ENTRY — whether that entry can be removed or renamed is
# $TMPDIR's permissions to decide. In a group/other-writable $TMPDIR with no
# sticky bit another local user can rename $WORKDIR away and leave their own
# directory (or a symlink) at the identical name, which is then where this engine
# writes AND READS BACK every API response body and every staged download. That is
# the same parent-governed race http.sh's staging relocation closed, one level up,
# and it is a property all 46 units depend on.
#
# THE STICKY EXEMPTION IS CORRECT FOR THIS CALLER, which is why it passes
# assert_safe_dir's `replace-an-existing-entry` policy: every entry this engine
# creates under $TMPDIR is a `mktemp`-uniquified name nobody can predict, so an
# attacker cannot pre-create one — the only way in is to REMOVE or RENAME the
# entry after `mktemp` has made it, which is exactly what the sticky bit
# restrains. See assert_safe_dir's policy note for the caller where it is not.
assert_safe_tmpdir() {
	assert_safe_dir "$1" "temp directory" \
		"replace what this engine creates there — its own 0700 work directory, and, on the fallback credential path, the credential config (curl's \`-K\` file) that lands directly in \$TMPDIR" \
		"point \$TMPDIR at a PRIVATE directory you own (one that is not group- or world-writable, or that carries the sticky bit and is owned by you or root, as /tmp is) and re-run" \
		replace-an-existing-entry
}

# assert_safe_download_dir DIR — the `attach --download` caller of
# assert_safe_dir below, where DIR is the DESTINATION's own parent directory.
# Called from that mode's pre-flight (cmd-attach.sh), before any network call.
#
# WHY THE DESTINATION NEEDS THIS EVEN THOUGH THE INSTALL ITSELF IS SOUND. The
# download stages inside 0700 $WORKDIR and installs with `ln -n`, so nothing an
# attacker does to the destination directory can redirect the write or make it
# follow a symlink — and this check does not exist to harden that. It exists
# because the install SUCCEEDING is not the end of the file's life: in a
# group/other-writable directory with no sticky bit, any local user may unlink the
# installed file and leave their own content at that name AT ANY TIME AFTERWARDS.
# There is no race to win, so no amount of atomicity at install time addresses it —
# they can watch the directory and act whenever they like.
#
# WHAT MAKES THAT A TRUST BOUNDARY RATHER THAN THE CALLER'S OWN BUSINESS: one path
# this mode can be aimed at is $JIRA_PROJECTS_DIR/<KEY>.json, where a missing file
# reads as "no config" rather than an error (readonlygate.sh's classification of
# `attach --download` as a WRITE rests on exactly this), so a substituted file
# there becomes the field mappings a later write pass TRUSTS.
#
# NOT THE ONLY INSTALL DESTINATION THIS GATE NOW COVERS: assert_safe_install_dir
# below applies the identical reasoning to $JIRA_PROJECTS_DIR, which an earlier
# revision of this note called a separate decision rather than a corollary. It was
# taken, for the reason that note itself gave — the file installed there is read
# back as configuration — and the two wrappers no longer differ ONLY in their
# diagnostics: that one also takes a STRICTER sticky policy, for a reason this
# caller does not share (see its own header).
#
# THE STICKY EXEMPTION IS CORRECT FOR THIS CALLER, hence the
# `replace-an-existing-entry` policy: the risk named above is an attacker
# UNLINKING the file this command already installed, and a sticky directory is
# precisely one where only the owner may do that. A pre-created entry at the
# destination is not this mode's exposure at all — `attach --download` REFUSES an
# existing destination in its pre-flight (a dangling symlink included) and installs
# with `ln -n`, which refuses one at the instant of the install.
assert_safe_download_dir() {
	assert_safe_dir "$1" "--download destination directory" \
		"unlink the file this command installs and leave their own content at that path, at any time after the download has succeeded and with no race to win" \
		"choose a --download destination inside a directory that is PRIVATE to you (one that is not group- or world-writable, or that carries the sticky bit and is owned by you or root, as /tmp is) and re-run" \
		replace-an-existing-entry
}

# assert_safe_install_dir DIR — the atomic_install caller of assert_safe_dir
# below, where DIR is the directory a config file is installed INTO.
#
# CALLED FROM atomic_install ITSELF, so every present and future caller inherits
# the check rather than each having to remember it — the same placement reasoning
# that puts assert_safe_tmpdir inside ensure_workdir. cmd-discover.sh's
# save_discovered_config calls it a SECOND time, before its own timestamped
# BACKUP, which lands in that same directory before any atomic_install runs.
#
# THE RISK IS THE FILE'S POST-INSTALL LIFE, exactly as it is for
# assert_safe_download_dir above: $JIRA_PROJECTS_DIR/<KEY>.json is the field-
# mapping config a later WRITE pass TRUSTS, so a local user who can replace an
# entry in that directory can retarget a --reviewer/--developer/--fields write at
# a field of their choosing, at any time afterwards and with no race to win.
#
# ITS REMEDY IS A `chmod`, NOT "choose somewhere else", and that difference is
# what earns this wrapper rather than a bare four-argument call: unlike a
# --download path, this directory is the engine's own documented config location,
# so a caller told to aim elsewhere has been handed a remedy for a choice they did
# not make. A directory this engine CREATES is created 0700 (see
# save_discovered_config), so the refusal is reachable only for one that already
# existed — where a `chmod go-w` is exactly the fix.
#
# THE ONE CALLER WHOSE ATTACK NEEDS NO REMOVAL, so the ONE that passes
# assert_safe_dir's STRICTER `create-a-new-entry` policy and gives up the sticky
# exemption entirely. Its two siblings above are protected by that bit because
# their attacker must get rid of an entry that already exists — an unpredictable
# `mktemp` name under $TMPDIR, or a file `attach --download` has just installed —
# and POSIX sticky semantics restrain exactly that. This destination is
# $JIRA_PROJECTS_DIR/<KEY>.json, a name derived from a project key the caller
# tells the engine, so an attacker who can write the directory can simply
# PRE-CREATE it and wait: sticky places no restriction whatever on creating a NEW
# entry. A sticky, world-writable projects directory (`--projects-dir /tmp`, say)
# therefore had to stop being accepted here — the file found at that name is read
# back as this engine's field mappings, so "no race to win" understates it; there
# is no race at all.
#
# ITS REMEDY LOSES THE "or sticky" ALTERNATIVE THE OTHER TWO KEEP for the same
# reason. A remedy that offered it would name a directory this gate then refuses.
assert_safe_install_dir() {
	assert_safe_dir "$1" "project-config directory" \
		"replace the project config this engine reads back as its field mappings — or PRE-CREATE it, at a name they can predict from the project key (\$JIRA_PROJECTS_DIR/<KEY>.json) — retargeting a later write at a field of their choosing, with no race to win either way" \
		"make that directory PRIVATE to you (\`chmod go-w\` it, or point \$JIRA_PROJECTS_DIR at a directory that is not group- or world-writable) and re-run — the sticky bit is NOT enough for this one directory, because the name installed there is one an attacker can predict and pre-create" \
		create-a-new-entry
}

# assert_safe_dir DIR NOUN RISK REMEDY ENTRY_ATTACK — refuse (exit 1) unless
# another local user cannot put their own content at a name inside DIR. What that
# takes depends on ENTRY_ATTACK (see the policy note below): under
# `replace-an-existing-entry`, DIR must be NOT group/other-writable, or carry the
# sticky bit AND be owned by root or the invoking user (assert_sticky_dir_owner
# below owns that second half); under `create-a-new-entry`, group/other-writable
# is refused outright and the sticky bit exempts nothing.
#
# THE VERDICT IS SHARED AND THE DIAGNOSTIC DELIBERATELY IS NOT, which is what the
# three message fragments are for: all three callers above ask nearly the same
# question of a directory, but a caller told to "point $TMPDIR somewhere else" when
# what is unsafe is their own --download destination has been handed the wrong
# remedy for the wrong directory. NOUN names the directory, RISK completes "another
# local user could …", REMEDY is the action that fixes it — the same
# fragment-as-a-parameter shape validate.sh's require_flag_off and
# require_foreign_flag_unset already use for their own refusals.
#
# ENTRY_ATTACK IS THE ONE THING THAT IS NOT SHARED BEYOND THE DIAGNOSTICS, and it
# names the POSIX operation a caller's attacker actually needs rather than the
# verdict it produces, because that is the fact which decides it:
#   * `replace-an-existing-entry` — the attacker must REMOVE or RENAME an entry
#     this engine already created (an unpredictable `mktemp` name under $TMPDIR, a
#     file `attach --download` has installed). The sticky bit restrains exactly
#     that, for every user but the directory's owner, which is why a world-writable
#     /tmp is safe and the default ${TMPDIR:-/tmp} passes on every real system.
#   * `create-a-new-entry` — the attacker needs only to CREATE an entry at a name
#     they can predict, and POSIX sticky semantics place NO restriction on
#     creating one. So the exemption is withdrawn and the write bits decide alone.
#     assert_safe_install_dir is that caller and its header has the full shape.
# An unrecognized value REFUSES rather than defaulting: a future wrapper's typo
# must not silently buy the more permissive of the two.
#
# THE OWNER HALF OF THE STICKY VERDICT STILL RUNS UNDER EITHER POLICY, on any
# directory carrying the bit. Withdrawing the exemption removes a reason to
# ACCEPT, never a reason to refuse — a sticky directory owned by another user is
# unsafe for both callers alike (see assert_sticky_dir_owner).
#
# DIR IS FOLDED FOR DISPLAY, NEVER FOR THE VERDICT: every check below reads the
# RAW "$asd_dir", and only the diagnostics render it through one_line_display.
# assert_safe_download_dir's directory is derived from a caller ARGUMENT (the
# --download path), which is exactly what earns a value that fold — the sibling
# refusals in cmd-attach.sh's own pre-flight already fold the same string, and an
# unfolded newline inside it would forge a line in this engine's stderr. The
# $TMPDIR caller inherits the fold, which its own policy note calls exempt rather
# than forbidden: a real UTF-8 $TMPDIR holds none of the characters the fold
# touches, so it renders unchanged; a POSIX-legal non-UTF-8 byte in it displays
# as U+FFFD. Either way the verdict reads the raw path.
#
# COMPLETE FOR POSIX-MODE-ONLY DIRECTORIES, AND DELIBERATELY ONLY THOSE: the
# verdict is read out of the 9 traditional mode bits plus the owner uid, and an
# NFSv4-style ACL on macOS (a platform this engine supports) is not reflected in
# those bits at all. An ACL-bearing directory is FLAGGED rather than verified —
# see the ACL block at the end of the function for the marker, the warn-not-refuse
# choice, and what that flag itself still misses on macOS.
#
# WHAT A 0700 ENTRY DOES NOT BUY, and so what every caller is really asking:
# a 0700 directory protects what is created INSIDE it, never its own directory
# ENTRY — whether that entry can be removed or renamed is DIR's permissions to
# decide. Each caller above states the consequence in its own terms.
#
# THE STICKY BIT IS THE OTHER HALF FOR TWO OF THE THREE CALLERS, not an
# afterthought: it is exactly what makes a world-writable /tmp safe, so the
# DEFAULT ${TMPDIR:-/tmp} passes on every real system, while a $TMPDIR repointed at
# a shared directory — which is what a naive reading of the cross-filesystem remedy
# in http.sh would invite — does not. But even for those two it is only half a
# guarantee on its own, which is why it carries an OWNERSHIP condition too (see
# assert_sticky_dir_owner below); and for the third caller it is no guarantee at
# all, which is what ENTRY_ATTACK exists to say.
#
# `ls -ldn DIR/.`'S ONE READING IS THE MECHANISM, and every fact the verdict needs
# comes from it: the group write bit, the other write bit, the sticky bit, the
# ACL marker and — handed to assert_sticky_dir_owner rather than re-read — the
# owner's NUMERIC uid. `-n` is POSIX ("same as -l, except the owner's UID and GID
# numbers shall be written"), leaves the mode field untouched, and is what makes
# the owner comparable with no passwd lookup and no second stat of a directory
# another user may be racing. This engine's toolbox has no `stat` and no
# `find -perm`, and POSIX `test` exposes nothing about another user's write bit —
# its `-k` would have covered the sticky half alone, but `-k` is not a POSIX
# primary (SC3065) and a second mechanism for one of the bits is worse than one
# for all of them. The trailing `/.` is load-bearing: `ls -ld`/`-ldn` on a SYMLINK
# reports the link's own 0777 mode, and /tmp is a symlink to /private/tmp on
# macOS. Any mode string it cannot read as a directory's — an absent `ls`
# included — fails CLOSED.
assert_safe_dir() {
	asd_dir=$1
	asd_noun=$2
	asd_risk=$3
	asd_remedy=$4
	asd_entry_attack=$5
	# shellcheck disable=SC2012  # SC2012's `find` alternative is not in this engine's toolbox (see jira.sh's Portability header), and the parse reads a MODE STRING and a NUMERIC UID, never a filename — the non-alphanumeric-name hazard behind that check does not apply
	asd_ls=$(ls -ldn "$asd_dir/." 2>/dev/null) || asd_ls=""
	asd_mode=$(printf '%s\n' "$asd_ls" | sed -n '1s/[[:space:]].*//p')
	asd_shown=$(one_line_display "$asd_dir")
	case "$asd_mode" in
		d?????????*) : ;;
		*)
			error "could not read the permissions of the $asd_noun '$asd_shown' (is \`ls\` on \$PATH?) — refusing to use it (fail closed)"
			exit 1 ;;
	esac
	# Mode-string positions: 6 is the group write bit, 9 the other write bit, 10
	# the sticky bit (`t` with other-execute, `T` without). A trailing ACL/xattr
	# marker (`+`, `@`) is why no pattern here anchors the length. Each bit is read
	# into its own answer rather than decided inside one `case`'s arm ordering,
	# because the two bits are no longer in a fixed precedence: which of them wins
	# is ENTRY_ATTACK's to say, and an arm order cannot be parameterized.
	asd_sticky=no
	case "$asd_mode" in
		?????????[tT]*) asd_sticky=yes ;;
	esac
	asd_other_writable=no
	case "$asd_mode" in
		?????w*|????????w*) asd_other_writable=yes ;;
	esac

	# THE POLICY, VALIDATED BEFORE IT IS APPLIED and fail-closed on anything else:
	# an unknown value must not resolve to the permissive answer by falling through
	# (see the header's ENTRY_ATTACK note for what each buys and which caller
	# passes it).
	case "$asd_entry_attack" in
		replace-an-existing-entry) asd_sticky_exempts=$asd_sticky ;;
		create-a-new-entry)        asd_sticky_exempts=no ;;
		*)
			error "internal: unknown entry-attack policy '$asd_entry_attack' for the $asd_noun '$asd_shown' — refusing to use it (fail closed)"
			exit 1 ;;
	esac

	if [ "$asd_other_writable" = yes ] && [ "$asd_sticky_exempts" = no ]; then
		# The sticky half of this diagnostic is DERIVED, not two pasted messages:
		# under `create-a-new-entry` the bit can be present and still not help, and
		# a refusal that said "has no sticky bit" about a `drwxrwxrwt` directory
		# would send the reader to verify the one fact the refusal got wrong. The
		# no-sticky wording is unchanged, because for that case it is still exact.
		if [ "$asd_sticky" = yes ]; then
			asd_sticky_clause="and its sticky bit does not help here — that bit restrains only REMOVING or RENAMING an entry, never CREATING a new one at a predictable name"
		else
			asd_sticky_clause="and has no sticky bit"
		fi
		error "the $asd_noun '$asd_shown' is writable by other local users $asd_sticky_clause, so another local user could $asd_risk — $asd_remedy"
		exit 1
	fi

	# THE OWNER HALF, under either policy, for any directory carrying the bit: it
	# can only REFUSE what the write bits accepted, never re-accept what they
	# refused (the refusal above has already exited by now). Not an early return
	# either — an accepted directory falls through to the ACL flag below, which
	# must reach every directory this function ACCEPTS.
	if [ "$asd_sticky" = yes ]; then
		assert_sticky_dir_owner "$asd_shown" "$asd_ls" "$asd_noun" "$asd_remedy"
	fi
	# THE ACL BLIND SPOT, FLAGGED WHERE IT CANNOT BE CLOSED. A trailing `+` is
	# `ls`'s own "extended permissions exist here" marker on both macOS
	# (NFSv4-style ACLs) and Linux/GNU (POSIX ACLs), and those entries are invisible
	# to every check above: a `drwx------+` directory can grant another local user
	# write access while presenting nine mode bits that say nobody else has any.
	#
	# WARN, NOT REFUSE — the choice is deliberate and it is a false-positive
	# trade. An ACL-bearing directory is ordinary in CI images and sandboxed
	# environments (and on macOS, where an inherited ACL is routine), so refusing
	# would break correct setups far more often than it would catch a real
	# exposure, and it would do so on a check that cannot tell the two apart —
	# `ls` reports only that an ACL EXISTS, never who it grants what. A warning
	# reaches the one party who can answer that question.
	#
	# `+` ONLY, AND THE FLAG IS BEST-EFFORT ON macOS BECAUSE OF IT. macOS `ls`
	# prints ONE marker character and `@` (extended attributes) takes precedence
	# over `+`, so a directory carrying both an ACL and any xattr displays `@` and
	# is NOT flagged here — verified on macOS 26, where every freshly created
	# directory carries an unremovable `com.apple.provenance` xattr, which is
	# exactly that case. Matching `@` as well was rejected: it grants no access by
	# itself, and the DEFAULT macOS $TMPDIR (/var/folders/…/T) carries it, so the
	# warning would fire on every invocation on the platform and be trained away
	# within a day. A flag that is silent on some macOS ACLs is worth more than one
	# nobody reads; what closes the gap properly is an ACL reader this engine's
	# toolbox does not have.
	#
	# `$asd_shown`, NOT `$asd_dir` — the same fold every refusal above renders
	# through, applied to the one diagnostic in this function that had been reading
	# the raw value. The header's fold policy is not a display preference here:
	# assert_safe_download_dir's directory is derived from the --download ARGUMENT,
	# so a newline inside it forges a line in this engine's stderr, and a warning is
	# exactly as forgeable as a refusal.
	#
	# ONCE PER DIRECTORY PER PROCESS ($ACL_WARNED_DIRS, whose declaration has why):
	# a warning is not a refusal, so the same directory gated twice on one
	# `discover --write` run used to print it twice — and a reader who sees it twice
	# learns to skip it. The membership test wraps the candidate in the SAME newline
	# on both sides the list stores it with, so one directory's name cannot satisfy
	# it by being another's suffix or prefix. The memo keys on the RAW directory,
	# never the folded rendering, so two distinct paths cannot collapse into one by
	# having a control character folded or deleted.
	case "$asd_mode" in
		*+*)
			case "$NL$ACL_WARNED_DIRS" in
				*"$NL$asd_dir$NL"*) : ;;
				*)
					ACL_WARNED_DIRS="$ACL_WARNED_DIRS$asd_dir$NL"
					warn "the $asd_noun '$asd_shown' carries an ACL or extended permissions ($asd_mode), which this engine cannot read — its mode bits alone were checked, so another local user may hold write access to it that those bits do not show; if you did not grant that access deliberately, $asd_remedy" ;;
			esac ;;
	esac
}

# assert_sticky_dir_owner DIR LS_LINE NOUN REMEDY — refuse (exit 1) unless the
# STICKY directory DIR is owned by root or by the invoking user. LS_LINE is
# assert_safe_dir's own `ls -ldn "$DIR/."` reading, handed over rather than
# re-read, so both halves of that one verdict describe one stat of the directory;
# NOUN and REMEDY are its caller's diagnostic fragments, passed down for the same
# reason it takes them at all (see its header — a refusal must name the directory
# the caller actually chose, and the remedy that fixes THAT one).
#
# DIR HERE IS THE DISPLAY FORM (assert_safe_dir's already-folded rendering), and
# that is sound because this function NEVER TOUCHES THE FILESYSTEM: every fact its
# verdict rests on comes out of LS_LINE, and DIR appears in nothing but the three
# diagnostics below.
#
# WHY THE STICKY BIT ALONE IS NOT A GUARANTEE — the gap this closes. POSIX sticky
# semantics restrain every user EXCEPT the directory's OWNER (and root) from
# removing or renaming an entry inside it. So a sticky directory an ATTACKER owns
# protects this engine from nobody: its owner may still rename an entry away and
# leave their own at the identical name, which is the entire attack
# assert_safe_dir exists to refuse. Accepting "sticky" as sufficient accepted
# exactly that, with the mode string looking reassuring the whole time.
#
# ROOT COUNTS AS SAFE, deliberately: root can defeat any check this engine could
# make, and the DEFAULT ${TMPDIR:-/tmp} is root-owned 1777 on every real system —
# a condition that refused it would refuse every invocation.
#
# `id -u` IS REACHED ONLY FROM HERE, and only for a sticky directory owned by a
# NON-root uid — the single case where the invoking user's own uid decides the
# answer, so the default /tmp path never invokes it. It is the engine's only
# source for that value (`stat` and `find -perm` are outside its toolbox, and
# POSIX sh has no $UID), POSIX mandates it, and if it cannot answer this REFUSES:
# an unverifiable owner on a directory that is demonstrably not root's is the
# precise case that must not be waved through.
assert_sticky_dir_owner() {
	asdo_dir=$1
	asdo_noun=$3
	asdo_remedy=$4
	asdo_owner_uid=$(printf '%s\n' "$2" | sed -n '1s/^[^[:space:]]\{1,\}[[:space:]]\{1,\}[0-9]\{1,\}[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]].*$/\1/p')
	case "$asdo_owner_uid" in
		0) return 0 ;;
		'' | *[!0-9]*)
			error "could not read the owner of the $asdo_noun '$asdo_dir', which carries the sticky bit — that bit does not restrain the directory's OWN owner, so an unreadable owner cannot be trusted — refusing to use it (fail closed)"
			exit 1 ;;
	esac
	asdo_self_uid=$(id -u 2>/dev/null) || asdo_self_uid=""
	case "$asdo_self_uid" in
		'' | *[!0-9]*)
			error "the $asdo_noun '$asdo_dir' carries the sticky bit but is owned by uid $asdo_owner_uid rather than root, and \`id -u\` could not report your own uid to compare it against (is \`id\` on \$PATH?) — refusing to use it (fail closed)"
			exit 1 ;;
	esac
	if [ "$asdo_owner_uid" != "$asdo_self_uid" ]; then
		error "the $asdo_noun '$asdo_dir' carries the sticky bit but is owned by ANOTHER user (uid $asdo_owner_uid — neither root nor you), and the sticky bit stops only OTHER users from removing an entry, never the directory's own owner: that user could replace what this engine puts there — $asdo_remedy"
		exit 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Untrusted-response hygiene
# ---------------------------------------------------------------------------

# strip_control_ansi — reads stdin, writes stdout with ANSI CSI sequences
# and C0/DEL control bytes removed. Deliberately implemented with sed/tr
# (not jq regex) so this helper has no Oniguruma dependency.
#
# TAB (\011) and NEWLINE (\012) are the two C0 bytes deliberately KEPT: callers
# split multi-line values on newlines, and a tab is legitimate text (cmd-version.sh
# and version --list's test both turn on that fact). CR (\015) is NOT kept, and it
# is the one byte whose treatment changed: on a real terminal a CR returns the
# cursor to column 0, so a CR inside a quoted, untrusted value could visually
# overwrite the "  | " prefix cmd-comment-edit.sh uses to keep attacker-authorable
# text off column 0 — defeating for a watching human what still held at the byte
# level for grep. Nothing in this engine parses CRLF through this helper (http.sh's
# redirect-Location parsing greps the raw header dump and never routes it here),
# so deleting it is safe for all 45 other units.
#
# The C1 range (\200-\237) is deliberately NOT stripped here, even though it holds
# NEL (\205) and other bytes an 8-bit-control terminal honors as a line break: those
# same bytes are valid UTF-8 CONTINUATION bytes ("Á" is \303\201, an em dash is
# \342\200\224, curly quotes \342\200\230-\235), and this helper's input is arbitrary
# user-authored UTF-8 — display names, summaries, comment bodies — so a byte-level
# C1 deletion here would corrupt legitimate text at every one of its 40-odd call
# sites. The call sites that genuinely need C1 folded go through one_line_display
# below, which folds it at the CODEPOINT level and so leaves UTF-8 intact.
strip_control_ansi() {
	sed "s/${ESC}\\[[0-9;]*[a-zA-Z]//g" | tr -d '\000-\010\013-\037\177'
}

# JQ_ONE_LINE_DEF — a jq `one_line` def that maps to a space every codepoint
# that strip_control_ansi (whose job is bytes) lets through and that a reader
# could honor as a break or a control: TAB, LF, CR, the whole C1 range
# U+0080-U+009F (NEL, and the 8-bit CSI U+009B among them), LINE SEPARATOR
# (U+2028) and PARAGRAPH SEPARATOR (U+2029). The remaining C0 controls (VT, FF,
# FS/GS/RS, ESC sequences) are left to strip_control_ansi, which every caller
# still pipes through afterwards. Codepoints, not bytes, which is the point:
# under this engine's LC_ALL=C a `tr -d '\200-\237'` deletes BYTES, which are
# also UTF-8 continuation bytes and so mangle "ß" (C3 9F) or an em dash
# (E2 80 94); here U+0085 is one codepoint and "ß" is another. explode/implode,
# not gsub, so this needs no Oniguruma-enabled jq.
#
# Prepended to a caller's STATIC program (`jq "$JQ_ONE_LINE_DEF"'…'`): two
# constants joined, never data, so the jq-program-is-never-built-from-input
# rule holds.
JQ_ONE_LINE_DEF='def one_line: tostring | explode | map(if . == 9 or . == 10 or . == 13 or (. >= 128 and . <= 159) or . == 8232 or . == 8233 then 32 else . end) | implode;'

# one_line_display VALUE -> VALUE on one line: JQ_ONE_LINE_DEF's fold, then
# strip_control_ansi. No line break, no C0/C1 control and no ANSI sequence
# survives, and valid UTF-8 stays valid. Bytes that are NOT valid UTF-8 arrive
# as U+FFFD (jq's --arg decoding), so a lone raw C1 byte cannot survive either.
#
# Its callers render an API-, caller- or config-supplied value into a line whose
# integrity is load-bearing: a consent gate a human reads line by line
# (cmd-update.sh's --plan field summary, cmd-bulk.sh's --plan intent phrase,
# cmd-transition.sh's plan), a JIRA_*= machine line, or a diagnostic on stderr an
# agent reads as this engine's own output. A raw newline inside such a value
# FORGES a line there — the closing "NOTHING WAS WRITTEN (dry-run / --plan)"
# row, an extra issue key, a second "jira.sh: error:".
#
# Folded to a SPACE rather than deleted: the value stays inside the engine's own
# quoted or delimited slot on that one line, as visibly inert data, and the
# write itself always sends the untouched carrier, never this rendering.
#
# ENVIRONMENT-DERIVED PATHS ARE EXEMPT RATHER THAN FORBIDDEN, stated here because
# this is the policy's home and several diagnostics rely on it: cmd-discover.sh
# renders $JIRA_PROJECTS_DIR's derived config path unfolded, and http.sh renders
# $WORKDIR the same way. What EARNS a value this fold is being an ARGUMENT or an
# API/config value — a --download path, a --status value, a field id — a string
# some other party may have chosen for a line this engine then emits. $TMPDIR and
# $JIRA_PROJECTS_DIR come from the environment of whoever launched the process,
# i.e. the same party reading the output, so there is no second party for the
# fold to defend against. assert_safe_dir folds BOTH of its directories rather
# than branching, because one of its callers passes a directory derived from the
# --download argument, and a real UTF-8 $TMPDIR renders unchanged either way
# (non-UTF-8 bytes display as U+FFFD; assert_safe_dir's verdict reads the raw
# path). Exempt means "not required", never "must not".
#
# ONE jq PROCESS PER CALL, so it is for single values in diagnostics and plan
# lines; a per-row render folds inside its own jq program via JQ_ONE_LINE_DEF
# (cmd-users.sh, cmd-workflow.sh). The per-command validators call it too
# (update/bulk who-flags via has_update_field_request, attach --download via
# assert_safe_dir), which is why jira.sh checks for jq before any validation.
one_line_display() {
	jq -rn --arg v "$1" "$JQ_ONE_LINE_DEF"'$v | one_line' | strip_control_ansi
}

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------

urlencode() {
	jq -rn --arg v "$1" '$v | @uri'
}

# downcase VALUE -> VALUE lowercased. Portable (`tr`, not the bashism
# `${var,,}`) — used to compare a Jira-reported status against a caller's
# possibly differently-cased --status/--resolution value; the
# CANONICAL (API-reported or config-graph) casing is always what gets
# displayed/stored, never the downcased form itself.
#
# SECOND CALLER, and the reason a change here is not local: credentials.sh's
# resolve_credential_config() folds both halves of its $JIRA_CURL_CONFIG-
# basename-vs-$CONFIRMED_HOST binding check through this helper — a fail-closed
# SECURITY comparison (hostnames are case-insensitive, so a byte-exact compare
# would refuse a credential that does belong to the confirmed site and report it
# as a cross-site violation). Which bytes this folds is therefore part of that
# gate, not a display detail.
downcase() {
	# shellcheck disable=SC2018,SC2019  # deliberately ASCII-only (LC_ALL=C, matches this script's ascii_downcase-based jq comparisons — Jira status names are ASCII), not locale-dependent [:upper:]/[:lower:]
	printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# parent_dir PATH -> prints the directory component of PATH, matching what
# `dirname` would print. Pure parameter expansion, never dirname — see jira.sh's
# own SCRIPT_DIR derivation for the toolbox reason (the engine and write-test
# suites run under a PATH that deliberately excludes dirname/basename/readlink/
# realpath). Two cases the `%/*` expansion alone gets wrong, both handled here:
# a bare filename with no slash is ".", and a path whose only slash is the
# leading one ("/out.png") is "/", where `%/*` strips to the empty string.
#
# TWO CALLERS, and they must agree: cmd-attach.sh's `--download` pre-flight
# checks this directory exists and is writable, and http.sh's
# download_attachment_content asks whether it is on a different filesystem than
# $WORKDIR. A second, hand-rolled copy of this derivation that disagreed with
# the first would check one directory and install into another.
parent_dir() {
	case "$1" in
		*/*)
			pd_dir=${1%/*}
			[ -n "$pd_dir" ] || pd_dir=/
			;;
		*)  pd_dir=. ;;
	esac
	printf '%s' "$pd_dir"
}

# is_known_cross_device DIR_A DIR_B -> 0 iff `df -P` POSITIVELY reports the two
# directories on different filesystems. Anything it cannot establish returns 1,
# which means "NO CONFIDENT VERDICT", never "same filesystem".
#
# A FAST-FAIL COURTESY, NOT A SAFETY BOUNDARY — which is exactly why it may
# answer "don't know" and let the caller proceed. Its one consumer, http.sh's
# download_attachment_content, installs with `ln`, and link(2) cannot cross a
# filesystem by construction, so the refusal that matters is the kernel's; this
# only spares a wasted media-JWT round-trip on an already-doomed destination, and
# a wrong answer here costs that round-trip, never an unsafe install.
#
# `df -P` is the only device identity in this engine's toolbox (POSIX defines its
# output format, BSD and GNU both honor it, and `stat`'s device field is spelled
# differently on each). The field split is anchored on the numeric columns `df -P`
# guarantees between the device and mount point — capacity only has to be
# NON-BLANK, since GNU prints a bare `-` on a zero-sized filesystem — never on
# whitespace tokens: both surrounding fields can contain a space (`map auto_home`,
# `/Volumes/VS Code`), so a first/last-token grab reads `map` and `Code`, which
# two different filesystems can share and which therefore compared EQUAL.
#
# ONLY THE DEVICE DECIDES, though the pattern spans the mount point to anchor the
# split: two devices are two filesystems, but a same-device/different-mount pair
# is a bind mount where `ln` works, and refusing that early would block a
# legitimate download. `df`'s stderr is deliberately not suppressed — this
# returns only a verdict, so its own "not found"/"Permission denied" is the
# caller's only trace of why there wasn't one.
is_known_cross_device() {
	ikcd_devices=$(df -P "$1" "$2" \
		| sed -n '2,3s/^\(.*[^[:space:]]\)[[:space:]]\{1,\}[0-9]\{1,\}[[:space:]]\{1,\}[0-9]\{1,\}[[:space:]]\{1,\}[0-9]\{1,\}[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}.*[^[:space:]][[:space:]]*$/\1/p')
	ikcd_a=$(printf '%s\n' "$ikcd_devices" | sed -n '1p')
	ikcd_b=$(printf '%s\n' "$ikcd_devices" | sed -n '2p')
	[ -n "$ikcd_a" ] && [ -n "$ikcd_b" ] && [ "$ikcd_a" != "$ikcd_b" ]
}

# atomic_install SRC DEST — install SRC's bytes at DEST atomically, REPLACING
# whatever file is already there: stage beside DEST (stage_install_copy below),
# rename the staged copy into place, and VERIFY what landed. An interrupted write
# can never leave a truncated or partial DEST — a reader sees either the old file
# or the whole new one, never a half-written one. DEST's directory must already
# exist (each caller checks or creates it first). Every step reports through
# error() and this engine's exit 1.
#
# FOR THE REPLACE PATHS ONLY — install_new_file below is the one to use when
# nothing is being replaced, and it is strictly safer (it refuses an existing
# destination instead of conceding the residual two paragraphs down). Its header
# has the division of labour; do not route a create through here for symmetry.
#
# ONE CONSUMER TODAY — cmd-discover.sh's save_discovered_config, from its three
# REPLACE call sites (http.sh's download_attachment_content deliberately does not
# use it; its own header states why) — and it stays in this shared unit rather than
# moving beside it because the install sequence is a security property worth
# reviewing in one place, on the same reasoning that keeps every curl in http.sh.
#
# THE STAGING IS GATED, MINTED AND FILLED BY stage_install_copy, shared with
# install_new_file: the destination directory's own safety gate, the `mktemp -u`
# name and the single O_EXCL create-and-write are the part of an install that is a
# security property, so both installers reach it through one reviewed function
# rather than two copies. Read its header before changing either.
#
# THE RENAME'S OWN RESIDUAL IS NARROWER THAN THE STAGING ONE BUT REAL, AND IT IS
# NOT THE SAME AS THE HARD-LINK INSTALL'S. `mv -f` STATS its destination, so a
# SYMLINK TO A DIRECTORY at DEST makes it deposit the staged copy INSIDE that
# directory on every platform — where `ln -n` refuses that outright wherever `-n`
# is honored. assert_install_landed below catches it and refuses, but it
# deliberately removes NOTHING through a symlinked path (its header has why), so
# the deposited copy stays in the attacker's directory.
#
# WHAT ACTUALLY BOUNDS THAT RESIDUAL, stated carefully because an earlier revision
# of this note got it wrong and the wrong version is the reassuring one. It claimed
# reaching the residual "takes write access the mode bits deny (an ACL)". That was
# false at the time: the shared gate then exempted any STICKY directory from its
# write-bit refusal, so a sticky world-writable $JIRA_PROJECTS_DIR (`/tmp` itself)
# was ACCEPTED, and an attacker needed no ACL at all. assert_safe_install_dir now
# passes the `create-a-new-entry` policy, which withdraws that exemption for this
# directory (its header has why), so what remains is genuinely narrow — and it is
# two things, not one:
#   * an ACL that grants another local user write access, which the gate reads as
#     a warning and then ACCEPTS by design (assert_safe_dir's ACL note);
#   * a permission change made AFTER the gate's single `ls` reading — the
#     irreducible check-then-act gap of any mode-bit gate, not an ACL.
# Neither is closed here, and both are bounded by the same last fact: what gets
# deposited is this engine's own project config, never a credential. A future
# weakening of that gate's policy re-opens the wider hole, which is why the policy
# and this residual are documented as one decision.
#
# WHY NOT TRADE THE RENAME FOR AN UNLINK-THEN-`ln -n`, which would refuse a
# symlinked destination the way the download install does: that sequence has a
# window in which DEST does not exist at all, which is precisely the atomicity
# this function is named for and which a concurrent reader (a missing project
# config reads as "no config", never as an error) depends on. A rename cannot
# have both properties, and the one it keeps is the one the callers rely on. That
# trade is only worth making when something IS being replaced, which is exactly
# why the create path does not make it (install_new_file).
#
# WHY THE STAGING STAYS BESIDE DEST rather than moving into $WORKDIR the way
# download_attachment_content's did. This install's last step must REPLACE an
# existing file, which needs a RENAME — where that install can use a hard link,
# whose refusal of an existing name is the very property it wants. Neither a
# rename nor a hard link can cross a filesystem, and $TMPDIR against
# $JIRA_PROJECTS_DIR routinely IS two filesystems (a tmpfs /tmp against a home
# directory on disk), so staging in $WORKDIR would have traded this vulnerability
# for a feature that cannot work on those machines. The O_EXCL create-and-write is
# what makes staying beside DEST safe, and it is available here for the reason it
# was not available there: the SHELL writes this file, where curl wrote that one.
atomic_install() {
	ai_src=$1
	ai_dest=$2
	ai_label="install $ai_dest"
	stage_install_copy "$ai_src" "$ai_dest" "$ai_label"
	ai_staged=$STAGED_INSTALL_PATH
	# `-f` because this engine is never interactive: POSIX `mv` PROMPTS when the
	# destination exists and denies write, which would hang an agent-driven run.
	# The staged sibling is withdrawn on failure so no `.tmp.` entry survives a
	# refused install; a failing `rm` must not change the reported reason.
	if ! mv -f "$ai_staged" "$ai_dest"; then
		error "$ai_label: could not move the staged copy into place"
		rm -f "$ai_staged" 2>/dev/null || true
		exit 1
	fi
	assert_install_landed "$ai_dest" "${ai_staged##*/}" file "$ai_label"
}

# install_new_file SRC DEST — install SRC's bytes at DEST, which must NOT already
# exist: stage beside DEST (stage_install_copy below), hard-link the staged copy
# to DEST, VERIFY what landed, then drop the staging link. The install shape
# http.sh's download_attachment_content already uses, for the same reasons.
#
# FOR THE CREATE PATHS ONLY, and it is the one to prefer wherever a caller has
# nothing to replace: `link(2)` REFUSES an existing destination name outright
# rather than following or replacing it, so this install concedes NEITHER of
# atomic_install's two rename residuals — not the symlink-to-a-directory deposit,
# and not the clobber.
#
# THE CLOBBER IS WHY THIS EXISTS, not tidiness. save_discovered_config's create
# path decides "no config is there" with a `[ ! -f ]` and installs some seven HTTP
# round-trips later; `mv -f` would silently overwrite anything that appeared in
# between, with no backup taken (the create path backs nothing up, having nothing
# to back up), destroying exactly the human curation that function's contract
# promises never to clobber. `ln` turns that window into a refusal.
#
# AND IT COSTS NO ATOMICITY, which is the whole reason the trade atomic_install
# documents does not apply here: atomicity only matters while something is being
# REPLACED — a concurrent reader must never observe a config mid-swap. With
# nothing at DEST there is nothing to observe, so the reader sees "no config"
# (never an error) right up to the instant link(2) publishes the whole file.
#
# SAME FILESYSTEM BY CONSTRUCTION, which is the other precondition a hard link
# imposes: the staging sibling is created BESIDE DEST, so the link can never be
# the cross-device one `attach --download` has to pre-check for (its staging lives
# in $WORKDIR, a different filesystem from the destination on many machines).
install_new_file() {
	inf_src=$1
	inf_dest=$2
	inf_label="install $inf_dest"
	stage_install_copy "$inf_src" "$inf_dest" "$inf_label"
	inf_staged=$STAGED_INSTALL_PATH
	# GUARDED, AND THE MESSAGE NAMES THE EXISTING-DESTINATION CAUSE FIRST because
	# it is the one this install exists to refuse — but not as the only cause, since
	# `ln` reports a full filesystem, a lost write permission and a missing `-n` the
	# same way and its exit status cannot portably tell them apart. `ln`'s own
	# stderr is deliberately not redirected (as at http.sh's install): it is what a
	# human diagnoses from, and this guard replaces only the exit status.
	if ! ln -n "$inf_staged" "$inf_dest"; then
		error "$inf_label: could not link the staged copy into place — the destination must not already exist, and an entry at that name is refused rather than replaced"
		rm -f "$inf_staged" 2>/dev/null || true
		exit 1
	fi
	assert_install_landed "$inf_dest" "${inf_staged##*/}" link "$inf_label"
	# DEST is now a second link to the staged copy, so dropping this one leaves the
	# caller a single-link file rather than one with a stray `.tmp.` sibling beside
	# it. Non-fatal (cleanup()'s idiom, and download_attachment_content's): an `rm`
	# failure must not turn a completed install into an error.
	rm -f "$inf_staged" 2>/dev/null || true
}

# stage_install_copy SRC DEST LABEL — the part of an install that is a security
# property, shared by the two installers above: gate DEST's own directory, mint a
# staging name beside DEST that nothing has created, and fill it with SRC's bytes
# in ONE O_EXCL operation. Publishes the staged path as $STAGED_INSTALL_PATH (read
# it into the caller's own prefixed variable IMMEDIATELY, per that global's note).
# Refuses through error() + exit 1, LABEL prefixing every diagnostic.
#
# THE DESTINATION DIRECTORY IS GATED HERE rather than at the call sites, so every
# present and future installer inherits it — the same placement reasoning that puts
# assert_safe_tmpdir inside ensure_workdir. See assert_safe_install_dir for what it
# refuses, why this directory earns a stricter policy than the other two callers of
# that gate, and why its remedy differs from the --download one's.
#
# `-u` MINTS THE NAME WITHOUT CREATING IT, which is what lets the create and the
# write be one operation; mktemp's uniquifier is still what keeps two concurrent
# runs apart. The name it would otherwise have created is exactly the re-openable
# entry this sequence exists not to leave lying around.
#
# THAT ONE O_EXCL OPERATION (copy_to_new_file below) IS THE FIX FOR A REAL
# VULNERABILITY, not a tidiness change. The earlier shape was `mktemp` beside DEST
# and then `cp` INTO THAT NAME: mktemp's own creation cannot be hijacked, but the
# `cp` RE-OPENS the name, so any local user able to write the directory could
# unlink the staged entry and leave a symlink at it in between — the config write
# redirected to a path of their choosing, as the invoking user. It is the same
# vulnerability class http.sh's download install was rebuilt to close.
stage_install_copy() {
	sic_src=$1
	sic_dest=$2
	sic_label=$3
	assert_safe_install_dir "$(parent_dir "$sic_dest")"
	STAGED_INSTALL_PATH=$(mktemp -u "${sic_dest}.tmp.XXXXXX") || {
		error "$sic_label: could not derive a staging name beside the destination (is \`mktemp\` on \$PATH, and does it support \`-u\`?)"
		exit 1
	}
	copy_to_new_file "$sic_src" "$STAGED_INSTALL_PATH" "$sic_label"
}

# copy_to_new_file SRC DEST LABEL — copy SRC's bytes to DEST, which must NOT
# already exist, and refuse unless DEST is afterwards the fresh REGULAR FILE this
# created. Refuses with exit 1 on any failure, LABEL naming the operation the
# caller is performing.
#
# `set -C` (noclobber) MAKES THE REDIRECTION AN O_CREAT|O_EXCL OPEN, and that is
# the primary mechanism: the create and the write become ONE operation with no
# re-openable name in between. So do not "simplify" this back to a `mktemp` + `cp`
# pair: that pair is exactly the vulnerability both callers were changed to close
# (stage_install_copy's header has the full shape of it).
#
# WHAT O_EXCL DOES AND DOES NOT REFUSE — narrower than an earlier revision of this
# note claimed, and the overclaim is worth naming because it is the one a reader
# would otherwise rely on. That note said an entry already at DEST is refused
# "including a symlink", citing POSIX open()'s O_EXCL. True of open(2) — but
# `set -C` is NOT open(2) with O_EXCL; it is POSIX's NOCLOBBER, whose specified
# behavior is to fail only "if the file exists and is a REGULAR file". Both
# `bash`-as-`sh` and `dash` implement exactly that. So:
#   * an existing REGULAR file at DEST is refused — the case both callers care
#     about, and the one actually under test;
#   * a symlink RESOLVING to a regular file is refused too, by the same rule
#     applied to the resolved target;
#   * a symlink resolving to a FIFO, a device or a socket is NOT refused: the
#     shell opens and writes THROUGH it. A FIFO with no reader makes that open
#     BLOCK, hanging the engine indefinitely.
# Reaching any of that means guessing an unpredictable `mktemp -u` suffix in a
# directory assert_safe_install_dir has already refused to other local users, so
# it is a latent trap rather than a live hole — but the trap is real and the
# verification below is what converts it into a refusal.
#
# THE POST-WRITE VERIFICATION CONVERTS WHAT NOCLOBBER CONCEDES INTO A REFUSAL —
# which is not the same as preventing it, and the difference is worth being exact
# about. Any write that COMPLETED through something other than a fresh regular
# file leaves DEST a symlink or a non-regular file, and both are refused here
# rather than reported as a successful copy, so nothing is ever installed off such
# a write. What the check cannot undo is the write ITSELF: by the time it runs, the
# bytes have already gone through the symlink to whatever was behind it. For these
# callers those bytes are this engine's own project config — never a credential —
# and reaching this at all means having guessed an unpredictable `mktemp -u`
# suffix in a directory assert_safe_install_dir refuses to other local users.
#
# THE BLOCKING FIFO IS NOT COVERED EVEN TO THAT EXTENT: that write never
# completes, so no post-write check is ever reached, and this engine's toolbox has
# no portable way to open with O_NONBLOCK or to time the write out. It is
# disclosed rather than closed.
#
# NOTHING IS REMOVED ON THAT REFUSAL, deliberately, and for
# assert_install_landed's reason: whatever is at DEST was not created by this
# engine, an `rm` through it would resolve a path this engine never chose, and the
# directory it would resolve into is the attacker's.
#
# BOTH OPERANDS ARE REDIRECTIONS, NEVER ARGV, so neither a SRC nor a DEST
# beginning with `-` can be read as an option — the hazard `attach --download`
# has to refuse in its pre-flight for the `ln` and `df` that do take paths as
# arguments.
#
# SRC IS OPENED FIRST, AND THE ORDER IS LOAD-BEARING. Redirections apply LEFT TO
# RIGHT, so the earlier `cat >DEST <SRC` spelling CREATED DEST before it ever
# tried to open SRC: an absent, unreadable or directory SRC then left a stray
# empty file at DEST that this function did not clean up, while reporting a
# diagnostic that blamed a leftover it had itself just created. With SRC first, a
# SRC that cannot be opened creates nothing at all.
#
# `umask 077` scopes to this subshell alone (the engine's own umask is untouched)
# and is what gives DEST its 0600. Both callers install a config this engine keeps
# private, and for atomic_install the mode survives the rename that installs it —
# dropping this publishes that config at the caller's umask, 0644 on a default
# login. The shell's own redirection diagnostic is deliberately left unsuppressed,
# as `ln`'s is at http.sh's install: it names the errno this cannot portably
# distinguish, and the guard replaces only the exit status.
#
# TWO CALLERS: stage_install_copy's staging sibling above (for both installers),
# and save_discovered_config's timestamped backup — the same mechanism, and the
# same vulnerability closed, at both. Both write into a directory
# assert_safe_install_dir has already gated, and this is deliberately the second
# layer rather than a substitute for it: that gate reads POSIX mode bits only and
# ACCEPTS an ACL-bearing directory with a warning (see assert_safe_dir).
copy_to_new_file() {
	ctnf_src=$1
	ctnf_dest=$2
	ctnf_label=$3
	# ATTRIBUTION FOR THE CLEANUP BELOW, never a safety check — the O_EXCL open is
	# what decides whether the write may happen, and this test's answer can be
	# stale by then without affecting that. It exists only so the failure path can
	# tell "the entry at DEST is the partial one I just created" (remove it) from
	# "something was already there" (leave it: a refusal that deletes what it
	# refused to overwrite is worse than the stray file it tidies). `-L` as well as
	# `-e`, since `-e` is false for a dangling symlink that O_EXCL still refuses.
	if [ -e "$ctnf_dest" ] || [ -L "$ctnf_dest" ]; then
		ctnf_preexisting=yes
	else
		ctnf_preexisting=no
	fi
	if ! (umask 077; set -C; cat <"$ctnf_src" >"$ctnf_dest"); then
		# A partial DEST is possible even with SRC opened first — a read error, a
		# full filesystem or an interrupt part-way through the copy all leave one —
		# and atomic_install's own `mv` failure path sets the precedent for
		# withdrawing it. A failing `rm` must not change the reported reason.
		if [ "$ctnf_preexisting" = no ]; then
			rm -f "$ctnf_dest" 2>/dev/null || true
		fi
		# THE CAUSES ARE NAMED AS POSSIBILITIES, NOT AS THE cause: the earlier
		# wording asserted DEST "must not already exist … remove a leftover from an
		# interrupted run", which is wrong for every read-side failure and actively
		# misleading when the entry it described had just been created here.
		error "$ctnf_label: could not create '$ctnf_dest' — possible causes: an entry already at that name, which is refused rather than written through (remove a leftover from an interrupted run); a source that could not be read ('$ctnf_src'); or no room to write the copy"
		exit 1
	fi
	# WHAT NOCLOBBER CANNOT REFUSE, REFUSED HERE (see the header): `-f` alone is not
	# enough, because it DEREFERENCES — a symlink to a regular file satisfies it.
	if [ ! -f "$ctnf_dest" ] || [ -L "$ctnf_dest" ]; then
		error "$ctnf_label: '$ctnf_dest' is not the regular file this copy created — the write went through something else (a symlink, or a device/FIFO/socket behind one), so the copy is refused and nothing is removed (whatever is at the path now was not created by this engine)"
		exit 1
	fi
}

# assert_install_landed DEST STRAY_NAME STRAY_NOUN LABEL — refuse (exit 1) unless
# an install that just reported success really left DEST as the regular file it
# created. STRAY_NAME is the basename of the entity that was installed, so the one
# branch that can clean up knows what to withdraw; STRAY_NOUN names it in that
# diagnostic ("link" for a hard-linked install, "file" for a renamed one); LABEL
# prefixes every refusal with the operation the caller is performing.
#
# A VERIFICATION OF WHAT JUST HAPPENED, not a re-check before acting, so it adds no
# TOCTOU gap of its own: it converts what neither install mechanism can refuse into
# a refusal instead of a false success. `ln -n` concedes a REAL directory raced in
# at DEST everywhere, plus a symlink to one on the platforms where `-n` is a silent
# no-op (http.sh's install header has both); `mv -f` concedes a real directory the
# same way and a symlink to one ON EVERY PLATFORM, since it stats its destination
# and reads either as "move INTO that directory" (atomic_install's header has why
# it accepts that and what bounds it).
#
# `-L` FIRST, BECAUSE `[ -d ]` DEREFERENCES. A symlink at DEST after a successful
# install means our own entry at that name is ALREADY GONE, replaced by something
# this engine did not create — so there is nothing OF OURS there to clean up, while
# an `rm "$DEST/$STRAY_NAME"` would resolve the whole path THROUGH the attacker's
# symlink and unlink <attacker-chosen-directory>/<STRAY_NAME> as the invoking user.
# That branch therefore refuses with NO `rm` attempted, the only shape that cannot
# be redirected.
#
# THREE CALLERS, and the sequence is identical at all of them: http.sh's
# download_attachment_content and install_new_file above (each after its
# `ln -n`), and atomic_install above (after its `mv -f`). It lives here, with the
# installers, for the reason atomic_install itself does — one place to review, one
# place to harden.
assert_install_landed() {
	ail_dest=$1
	ail_stray_name=$2
	ail_stray_noun=$3
	ail_label=$4
	if [ -L "$ail_dest" ]; then
		error "$ail_label: a symlink replaced the destination while the file was being installed — refusing to follow it, and deliberately removing nothing (the path now resolves somewhere this engine never chose)"
		exit 1
	fi
	# A REAL directory: the install put its payload INSIDE it, so the misplaced
	# entry comes back out. `! -L` is RE-TAKEN here rather than inherited from the
	# test above, whose answer is already stale — the one branch that runs an `rm`
	# through DEST establishes the non-symlink half immediately beside the `-d` it
	# qualifies, leaving only the irreducible test→act gap. Reaching that gap now
	# costs an attacker a SECOND won race (unlinking the very entry this `rm`
	# targets, `rmdir`ing the directory and symlinking over it, all between these
	# two lines), where a bare `-d` conceded it for free.
	if [ -d "$ail_dest" ] && [ ! -L "$ail_dest" ]; then
		rm -f "$ail_dest/$ail_stray_name" 2>/dev/null || true
		error "$ail_label: the destination became a directory while the file was being installed — the misplaced $ail_stray_noun inside it was removed (best effort), and nothing was installed at the destination itself"
		exit 1
	fi
	# NEITHER, so the install did not leave what it reported: the name was unlinked
	# outright, or holds something that is not a regular file (a `-d` that became
	# true only through a symlink raced in between the two tests above lands here
	# too). Generic because this is exactly the state that cannot be characterized,
	# and it removes nothing, for the `-L` branch's reason.
	if [ ! -f "$ail_dest" ]; then
		error "$ail_label: the destination is not the regular file the install created — refusing to report the install as complete, and deliberately removing nothing (whatever is at the path now was not created by this engine)"
		exit 1
	fi
}
