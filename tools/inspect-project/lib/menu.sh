# shellcheck shell=sh
#
# menu.sh — the interactive collection of the same four values the flags carry,
#           for a run started with no flags or an incomplete set.
#
# CONVENTIONS INHERITED FROM deploy/hub/lib/hub-nav.sh, deliberately and
# verbatim in shape:
#   * Every prompt is LINE-based (`read -r` up to Enter), never a raw
#     single-keystroke widget. The alternative — `stty -icanon` with cursor
#     addressing — would put the caller's terminal into a state this script then
#     owns restoring on every exit path including a signal, which is a bigger
#     correctness risk than the interaction polish buys.
#   * `?` shows help, `b`/`back` steps back one question, `q`/`quit` leaves — at
#     EVERY prompt. The documented consequence of line-based reads plus global
#     keys is that a value literally equal to `b` or `q` cannot be typed; for a
#     project path and two fixed enumerations that is not reachable in practice.
#   * A reversible action is confirmed at the `[Y/n]` tier (Enter means yes).
#     There is no typed-phrase tier here, because nothing this script does is
#     irreversible: the one mutation it makes — staging the git index — is undone
#     before it exits.
#
# WHY IT ASKS FOR ALL FOUR VALUES, even ones already given as flags. Using each
# flag as that question's DEFAULT (Enter accepts it) rather than skipping the
# question keeps back-navigation a plain decrement over a fixed list, and shows
# the caller the values actually in effect. Skipping would make `b` have to hop
# over invisible steps, and a step that returns instantly is a step `b` can never
# land on.
#
# Every prompt writes to STDERR. stdout is the machine channel (see output.sh),
# and a menu that printed there would corrupt the INSPECT_* payload of any run
# whose stdout is captured.
#
# Sourced by inspect-project.sh — never executed directly.

MENU_REPLY=""

menu_help_text() {
	cat <<EOF

inspect-project — Help

  Navigation
    ?            show this help
    b, back      go back one question
    q, quit      quit without running anything

  Questions
    Project      Absolute path to the project to inspect. Enter accepts the
                 shown default (your current directory).
    Scope        all           inspect the whole project
                 changed-only  inspect only what differs from HEAD (staged,
                               unstaged and untracked)
    Engine       intellij      IntelliJ IDEA headless inspections
                 sonar         a scan against a local SonarQube server
                 both          both, and IntelliJ alone if Sonar is unavailable
    Output root  Where results are filed, as
                 <root>/YYYY/MM/DD/<project>/<HH-MM-SS>/

  Sonar availability
    Sonar needs all three of: sonar-scanner on PATH, a server answering UP, and
    Sonar config in the project. When any is missing, \`sonar\` is shown as
    unavailable with the reason, and \`both\` runs IntelliJ alone.

  Press Enter to return.
EOF
}

menu_show_help() {
	menu_help_text >&2
	IFS= read -r _ || :
}

# menu_read PROMPT DEFAULT -> 0 with the answer in MENU_REPLY, 2 to go back,
# 3 to quit. An empty line takes DEFAULT; with no default it re-prompts.
menu_read() {
	mr_prompt=$1
	mr_default=$2
	while :; do
		if [ -n "$mr_default" ]; then
			# The default is filtered, not the prompt: a default carries $PWD or a
			# path from argv, and a path is where a control byte would come from.
			printf '\n%s\n[%s]\n> ' "$mr_prompt" "$(sanitize_for_terminal "$mr_default")" >&2
		else
			printf '\n%s\n> ' "$mr_prompt" >&2
		fi
		# A closed stdin reads as a quit rather than as an empty line: an
		# interactive prompt whose input has gone away must not silently accept
		# its own default.
		IFS= read -r MENU_REPLY || MENU_REPLY=q
		case "$MENU_REPLY" in
			'?') menu_show_help ;;
			b|back) return 2 ;;
			q|quit) return 3 ;;
			'')
				if [ -n "$mr_default" ]; then
					MENU_REPLY=$mr_default
					return 0
				fi
				note "A value is required."
				;;
			*) return 0 ;;
		esac
	done
}

# menu_confirm PROMPT -> 0 to proceed, 1 to decline, 2 back, 3 quit.
# The `[Y/n]` tier: an EMPTY line proceeds, an explicit y/yes proceeds, and
# ANYTHING else declines. Garbage is never read as consent — that is the safer
# and conventional reading of a [Y/n] prompt, and it is hub_confirm_gate's.
menu_confirm() {
	mc_prompt=$1
	while :; do
		printf '\n%s [Y/n]\n> ' "$mc_prompt" >&2
		IFS= read -r mc_reply || mc_reply=q
		case "$mc_reply" in
			'?') menu_show_help; continue ;;
			b|back) return 2 ;;
			q|quit) return 3 ;;
			''|[Yy]|[Yy][Ee][Ss]) return 0 ;;
			*) return 1 ;;
		esac
	done
}

menu_step_project() {
	msp_default=${OPT_PROJECT:-$PWD}
	while :; do
		menu_read "Project to inspect (absolute path)" "$msp_default" || return $?
		case "$MENU_REPLY" in
			/*) : ;;
			*) error "the project path must be absolute: $MENU_REPLY"; continue ;;
		esac
		msp_path=$(strip_trailing_slashes "$MENU_REPLY")
		if [ ! -d "$msp_path" ]; then
			error "not a directory: $msp_path"
			continue
		fi
		# A changed project path invalidates the previous Sonar verdict, whose
		# project-config check is path-dependent.
		# shellcheck disable=SC2034  # every carrier reset here is read by lib/sonar.sh's detect_sonar(); shellcheck lints each unit in isolation and cannot see a reader in a sibling
		if [ "$msp_path" != "$OPT_PROJECT" ]; then
			SONAR_DETECTED=0
			SONAR_CHECK_SCANNER=false
			SONAR_CHECK_SERVER=false
			SONAR_CHECK_CONFIG=false
			SONAR_AVAILABLE=0
			SONAR_SKIP_REASON=""
		fi
		OPT_PROJECT=$msp_path
		return 0
	done
}

menu_step_scope() {
	while :; do
		note ""
		note "Scope"
		note "  1) all           inspect the whole project"
		note "  2) changed-only  inspect only what differs from HEAD"
		menu_read "Choose a scope (number or name)" "${OPT_SCOPE:-all}" || return $?
		case "$MENU_REPLY" in
			1|all) OPT_SCOPE=all; return 0 ;;
			2|changed-only) OPT_SCOPE=changed-only; return 0 ;;
			*) error "not a scope: $MENU_REPLY" ;;
		esac
	done
}

menu_step_engine() {
	detect_sonar
	while :; do
		note ""
		note "Engine"
		note "  1) intellij  IntelliJ IDEA headless inspections"
		if [ "$SONAR_AVAILABLE" -eq 1 ]; then
			note "  2) sonar     local SonarQube scan"
			note "  3) both      IntelliJ + SonarQube"
		else
			note "  2) sonar     UNAVAILABLE — $SONAR_SKIP_REASON"
			note "  3) both      IntelliJ only (Sonar is unavailable, see above)"
		fi
		menu_read "Choose an engine (number or name)" "${OPT_ENGINE:-intellij}" || return $?
		case "$MENU_REPLY" in
			1|intellij) OPT_ENGINE=intellij; return 0 ;;
			2|sonar)
				if [ "$SONAR_AVAILABLE" -eq 1 ]; then
					OPT_ENGINE=sonar
					return 0
				fi
				error "sonar is unavailable: $SONAR_SKIP_REASON"
				warn  "choose intellij, or both (which will run IntelliJ alone)"
				;;
			3|both) OPT_ENGINE=both; return 0 ;;
			*) error "not an engine: $MENU_REPLY" ;;
		esac
	done
}

menu_step_output_root() {
	while :; do
		menu_read "Results directory" "${OPT_OUTPUT_ROOT:-$OUTPUT_ROOT_DEFAULT}" || return $?
		case "$MENU_REPLY" in
			/*) OPT_OUTPUT_ROOT=$(strip_trailing_slashes "$MENU_REPLY"); return 0 ;;
			*) error "the results directory must be an absolute path: $MENU_REPLY" ;;
		esac
	done
}

# menu_confirm_git_staging -> 0 to proceed, 3 to quit/decline.
#
# Fires ONLY when the IntelliJ engine will run at changed-only scope, because
# that is the only combination that touches the caller's git index: Sonar's
# changed-only filtering is a read of the diff, and `all` scope stages nothing.
# Names every step, including the restore, because an unannounced `git add -A`
# in someone's repository is the kind of surprise no result is worth.
#
# It also carries the TRUST disclosure, because this is the only human-facing
# gate this script has and the assumption is the same one the git mutation rests
# on: a directory whose tooling is about to be executed is being trusted. See
# inspect-project.sh's own trust-assumption header for the full statement — the
# two are deliberately the same claim in two places, since a caller on the flag
# path never reaches this prompt.
menu_confirm_git_staging() {
	case "$OPT_ENGINE" in
		intellij|both) : ;;
		*) return 0 ;;
	esac
	[ "$OPT_SCOPE" = changed-only ] || return 0

	note ""
	note "changed-only scope needs IntelliJ's \`-changes\` mode, which reads the git index."
	note "In $OPT_PROJECT this run will:"
	note "  1. record which paths are currently staged"
	note "  2. run \`git add -A\` so every change is visible to the inspection"
	note "  3. run the inspection"
	note "  4. unstage everything, then re-stage exactly the paths from step 1"
	note ""
	note "Nothing is committed and no file content is changed. Step 4 also runs if the"
	note "inspection fails or is interrupted. Rename detection and partial (\`git add -p\`)"
	note "hunk staging are NOT reconstructed — that is a known limitation."
	note ""
	note "TRUST: this run executes the project's own tooling against it. git's"
	note "\`core.fsmonitor\` and \`core.hooksPath\` exec points are disabled for every git"
	note "call, but \`.gitattributes\` clean/smudge filters cannot be blanket-disabled, and"
	note "IntelliJ (and sonar-scanner) evaluate the project's own build configuration and"
	note "plugins. Inspecting a freshly-cloned, not-fully-trusted third-party repository"
	note "therefore runs code from it as you. That is a real risk, not an implied safety."

	mcgs_rc=0
	menu_confirm "Proceed?" || mcgs_rc=$?
	case "$mcgs_rc" in
		0) return 0 ;;
		2) return 2 ;;
		3) return 3 ;;
		*) note "Declined. Nothing changed."; return 3 ;;
	esac
}

# run_menu -> 0 once all four values are collected and confirmed, 3 if the caller
# quit. A plain forward/back walk over a fixed list of steps; `b` on the first
# question stays put rather than quitting, so quitting is always the explicit `q`.
run_menu() {
	note "inspect-project — no complete flag set given, collecting the values interactively."
	note "  ?  help    b  back    q  quit"

	rm_step=1
	while [ "$rm_step" -le 5 ]; do
		rm_rc=0
		case "$rm_step" in
			1) menu_step_project || rm_rc=$? ;;
			2) menu_step_scope || rm_rc=$? ;;
			3) menu_step_engine || rm_rc=$? ;;
			4) menu_step_output_root || rm_rc=$? ;;
			5) menu_confirm_git_staging || rm_rc=$? ;;
		esac
		case "$rm_rc" in
			0) rm_step=$((rm_step + 1)) ;;
			2)
				if [ "$rm_step" -le 1 ]; then
					note "Already at the first question."
				else
					rm_step=$((rm_step - 1))
				fi
				;;
			*)
				note "Quit. Nothing changed."
				return 3
				;;
		esac
	done
	return 0
}
