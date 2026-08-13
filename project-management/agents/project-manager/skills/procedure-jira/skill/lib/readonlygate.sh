# shellcheck shell=sh
#
# readonlygate.sh — the READ-ONLY gate: when $JIRA_READ_ONLY is set, refuse
#                   every WRITE invocation, fail-closed (exit 1), BEFORE any
#                   network call and before a credential is even resolved.
#
# WHY IT EXISTS. The credential a read-only analysis pass holds is the same
# kind of credential a write pass holds — a `curl -K` config with a real token
# behind it. Which COMMANDS its holder may run was, until this unit, enforced
# only by prose the holder is trusted to follow (procedure-jira's SKILL.md
# scopes the P2 credential to `view`/`search`/`workflow`/`children`/
# `transition --plan`). That is not a control: the caller reading a ticket's
# live comments and changelog is reading UNTRUSTED, attacker-authorable text
# while holding that credential, so "it was told not to write" is exactly the
# assurance an injected instruction attacks. $JIRA_READ_ONLY=1 turns the
# no-WRITE half of that scope into something the ENGINE enforces, in the same
# fail-closed, in-script style as the host allow-list and the site gate (see
# sitegate.sh) — a refusal no ticket text can talk its way past.
#
# WHAT IT DOES NOT ENFORCE, stated so nobody reads more into it: this gate
# permits every READ, which is a SUPERSET of that P2 command list — the Agile
# reads (boards/board/sprints/backlog/epics/epic, bare `sprint <ID>`),
# link-types, a bare `discover`, and the `--list` read modes of
# watch/vote/version/component/attach are all permitted here while remaining
# outside the scope SKILL.md grants that credential. Narrowing the permitted
# reads to exactly those five is still the calling flow's prose; what the
# engine guarantees is that NO invocation under $JIRA_READ_ONLY writes —
# neither to the Jira site nor (see `discover` below) to the local
# project-config the write commands later read.
#
# WHY A SEPARATE UNIT, not another half of sitegate.sh: the site gate answers
# "is THIS SITE the one the human confirmed"; this gate answers "may this
# invocation write AT ALL" — a different question, on different inputs, with
# no shared mechanism, and its write/read classification table is the longest
# single piece of policy in the engine. One concern per file, as everywhere
# else in lib/.
#
# COUPLING (the same accepted trade-off sitegate.sh documents): every function
# here reads $COMMAND and the $OPT_* globals directly rather than taking
# parameters.
# That is the engine's established plain-globals convention — see runtime.sh's
# CONVENTION note.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# Read-only gate
# ---------------------------------------------------------------------------

# is_read_only_requested -> 0 if $JIRA_READ_ONLY asks for read-only mode, 1 if
# writes are permitted.
#
# The engine's OWN boolean flags are integer-compared (`[ "$OPT_LIST" -eq 1 ]`)
# because it sets them itself and they are only ever 0 or 1. This value comes
# from OUTSIDE and may be any string, so `-eq` is not usable here: on a
# non-numeric value it is a runtime error, and an error inside a security check
# must never be the thing that lets a write through. A `case` compares as
# strings and cannot fail.
#
# The sense FAILS CLOSED: only unset, empty and an explicit "0" mean "writes
# allowed". Every other value enables the gate — "1", "true", "yes", and also
# any typo a caller makes reaching for one of those, because a misspelled
# read-only request must not silently grant write access.
is_read_only_requested() {
	case "${JIRA_READ_ONLY:-}" in
		''|0) return 1 ;;
		*)    return 0 ;;
	esac
}

# is_write_invocation -> 0 if the CURRENT invocation would WRITE to Jira, 1 if
# it is a pure read. Reads $COMMAND and the $OPT_* mode flags; makes no network
# call and touches no file.
#
# It runs AFTER the per-command validate_<cmd>_args() wrapper, which is what
# lets each branch below stay a single check instead of re-deriving a mode: by
# the time this runs, "exactly one mode" has already been enforced for
# version/component/attach/sprint, `--list` + `--remove` has already been
# rejected for watch/vote, and each validator's own foreign-flag refusals have
# already fired (those refusals are per-command, not exhaustive — see
# write_mode_flag's note on the two cases — watch/vote, and attach's upload
# mode — where a foreign carrier survives).
# Every branch therefore reads the SAME carrier that command's own validator and
# cmd_<name>() read — never a second, independently-drifting detection of the
# same mode.
#
# The authoritative classification is procedure-jira's SKILL.md ("The gates the
# CALLER must clear before a WRITE command"); this function is its executable
# form and must be changed together with it.
is_write_invocation() {
	case "$COMMAND" in
		# Unconditional writes: no flag turns any of these into a read.
		# bulk/schedule are writes even with --plan/--dry-run — see the
		# --plan note at the end of this function.
		create|comment|update|link|worklog|bulk|schedule)
			return 0
			;;
		# transition is a write UNLESS --plan/--dry-run, whose branch in
		# cmd_transition() computes and prints the walked path from exactly one
		# READ and returns before any POST (a test asserts zero POSTs). This is
		# the one read-mode carve-out SKILL.md's read-only credential scope
		# names explicitly ("transition --plan").
		transition)
			if [ "$OPT_PLAN" -eq 1 ]; then
				return 1
			fi
			return 0
			;;
		# --list is the single READ mode of each of these five, so everything
		# else is a write: version's --create/--update/--release/--archive/
		# --delete, component's --create/--update/--delete, attach's upload
		# (--file) and --delete, and watch/vote's default-add and --remove.
		version|component|attach|watch|vote)
			if [ "$OPT_LIST" -eq 1 ]; then
				return 1
			fi
			return 0
			;;
		# sprint is the mirror image of those five: the READ (a sprint id, plus
		# an optional --issues) is the DEFAULT, and each write is named by a
		# mode flag — the same four validate_sprint_args() counts. The plural
		# `sprints` is a separate, always-read command.
		sprint)
			if [ "$OPT_CREATE" -eq 1 ] || [ "$OPT_UPDATE" -eq 1 ] \
				|| [ "$OPT_START" -eq 1 ] || [ "$OPT_CLOSE" -eq 1 ]; then
				return 0
			fi
			return 1
			;;
		# discover writes NOTHING at the Jira site — it only GETs — but
		# `--write` makes it a real, consequential LOCAL write: it overwrites
		# $JIRA_PROJECTS_DIR/<KEY>.json, the file carrying the human-curated
		# workflows/type_aliases/subtask_parent_types/custom_fields that a later
		# transition/create/--acceptance-file/--developer call depends on
		# (--force drops them outright; even the merge path rewrites the file).
		# Under this gate's OWN threat model — an injected or confused read-only
		# analysis pass — degrading that config degrades every subsequent WRITE
		# pass, which is a consequence the gate exists to prevent even though no
		# Jira object changes. So the write flag classifies it, exactly as
		# `sprint`'s mode flags classify sprint above.
		#
		# Bare `discover` stays a read: it prints the discovered config to
		# stdout and persists nothing. So does `discover --force` without
		# `--write` — save_discovered_config() is the only reader of OPT_FORCE
		# and cmd_discover() never reaches it without OPT_WRITE.
		discover)
			if [ "$OPT_WRITE" -eq 1 ]; then
				return 0
			fi
			return 1
			;;
		# The pure reads, listed BY NAME rather than left to the `*)` below.
		# That is the point of spelling them out: a command added to jira.sh's
		# dispatch table and not to this list lands in the fail-closed default
		# and must be classified DELIBERATELY, instead of inheriting "read" by
		# omission — the direction an omission has to fail in a security gate.
		view|search|workflow|link-types|children|boards|board|sprints|backlog|epics|epic)
			return 1
			;;
		*)
			# Unreachable: jira.sh's own command `case` rejects an unknown
			# command with exit 2 long before this runs. Fails CLOSED anyway,
			# on the same "an assertion against a FUTURE bug in a
			# security-critical sink" reasoning jira_curl()'s host re-check
			# carries — an unclassified command is never assumed harmless.
			return 0
			;;
	esac
}
#
# ON --plan/--dry-run, and why only `transition` gets the carve-out. Four
# commands implement a preview that writes nothing: transition, bulk, schedule
# and version --delete. Only `transition --plan` is treated as a read here,
# because that is the only one SKILL.md's read-only credential scope actually
# authorizes. Blocking the other three under $JIRA_READ_ONLY is the
# conservative direction of a deliberately asymmetric call: the cost is a
# refused preview a caller can re-run without the read-only credential, where
# the cost of the opposite error is an unauthorized write. Widening the
# carve-out is a scope decision for that document, not for this file.

# write_mode_flag -> prints the mode FLAG that made the current invocation a
# write ("--remove", "--close", "--write", …), or nothing when that command's
# write mode is its DEFAULT (watch/vote's add). Reads the same OPT_* carriers
# is_write_invocation() reads.
#
# The lookup is COMMAND-AGNOSTIC and first-match-wins across all ten carriers,
# so it names the flag the caller actually passed only where that command's
# validate_<cmd>_args() has already ruled out every carrier tested AHEAD of the
# real one. That holds for version/component/sprint: each counts exactly one of
# its OWN modes, and the foreign carriers are either refused by name (sprint's
# --delete/--release/--archive/--list) or tested after the command's own modes.
# It does NOT hold in two places, each of which yields an imprecise refusal
# WORDING and never a permitted write:
#   - watch/vote, whose validators enforce only --list-vs---remove exclusivity
#     (plus watch's --list-vs---account) and no one-of-N mode set at all, so any
#     other carrier reaches this lookup: `watch --create` is refused as
#     "'watch --create'", naming a mode cmd_watch() never defines.
#   - attach's upload mode, tested LAST (--file), so an unrejected
#     --start/--close/--remove/--write is printed ahead of it.
# Both stay fail-closed: is_write_invocation() classifies from the same carriers
# and makes watch/vote/attach a write whenever --list is absent, so the
# invocation is refused either way — only the mode it is refused BY is misnamed.
# Making the wording exact means scoping this lookup to the flags $COMMAND
# implements, a behaviour change deliberately not made here.
write_mode_flag() {
	if [ "$OPT_CREATE"  -eq 1 ]; then printf '%s' '--create';  return 0; fi
	if [ "$OPT_UPDATE"  -eq 1 ]; then printf '%s' '--update';  return 0; fi
	if [ "$OPT_DELETE"  -eq 1 ]; then printf '%s' '--delete';  return 0; fi
	if [ "$OPT_RELEASE" -eq 1 ]; then printf '%s' '--release'; return 0; fi
	if [ "$OPT_ARCHIVE" -eq 1 ]; then printf '%s' '--archive'; return 0; fi
	if [ "$OPT_START"   -eq 1 ]; then printf '%s' '--start';   return 0; fi
	if [ "$OPT_CLOSE"   -eq 1 ]; then printf '%s' '--close';   return 0; fi
	if [ "$OPT_REMOVE"  -eq 1 ]; then printf '%s' '--remove';  return 0; fi
	if [ "$OPT_WRITE"   -eq 1 ]; then printf '%s' '--write';   return 0; fi
	if [ -n "$OPT_FILES" ];      then printf '%s' '--file';    return 0; fi
	return 0
}

# write_refusal_phrase -> prints the refusal's two halves as one phrase: the
# exact invocation being refused, and the read this same command still permits
# — e.g. "'watch --remove' — only 'watch --list' is permitted".
#
# WHY the mode and not just $COMMAND: for the six commands whose read and write
# modes share a command name (watch/vote/version/component/attach and sprint),
# "refusing the write command 'watch'" reads as "watch is unavailable at all".
# The consumer of this message is an AGENT, not a human at a terminal, so that
# reading costs a read it WAS authorized to perform (`watch --list`). Naming
# both halves keeps the refusal honest about its own scope.
write_refusal_phrase() {
	wrp_mode=$(write_mode_flag)
	case "$COMMAND" in
		transition)
			printf "'transition' without --plan — only 'transition --plan' is permitted"
			;;
		version|component|attach|watch|vote)
			if [ -n "$wrp_mode" ]; then
				printf "'%s %s' — only '%s --list' is permitted" "$COMMAND" "$wrp_mode" "$COMMAND"
			else
				printf "'%s' in its default (add) mode — only '%s --list' is permitted" "$COMMAND" "$COMMAND"
			fi
			;;
		sprint)
			printf "'sprint %s' — only the bare 'sprint <ID>' read (optionally with --issues) is permitted" "$wrp_mode"
			;;
		discover)
			printf "'discover --write' — only 'discover' without --write is permitted (it prints the config and persists nothing)"
			;;
		bulk|schedule)
			printf "'%s' — it stays a write even under --plan/--dry-run, and has no permitted read mode" "$COMMAND"
			;;
		create|comment|update|link|worklog)
			printf "'%s' — that command has no read mode" "$COMMAND"
			;;
		*)
			printf "'%s' — a command is_write_invocation() does not classify, treated as a write (fail closed)" "$COMMAND"
			;;
	esac
}

# require_write_allowed — the gate itself. Refuses (exit 1) when read-only mode
# is requested and this invocation is a write; returns 0 otherwise, including
# whenever the gate is off.
#
# Exit 1, not 2: this is a security refusal that fails closed, exactly like the
# host allow-list and the intended-vs-confirmed site mismatch in
# require_confirmed_site(). Exit 2 is reserved for a caller's own usage errors,
# and a correctly-formed write command is not a usage error — it is a
# permitted-elsewhere command refused HERE.
require_write_allowed() {
	is_read_only_requested || return 0
	is_write_invocation || return 0
	error "\$JIRA_READ_ONLY is set: refusing $(write_refusal_phrase). A read-only analysis credential may not write — neither to Jira nor to the local project config."
	exit 1
}
