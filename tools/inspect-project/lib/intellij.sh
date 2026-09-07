# shellcheck shell=sh
#
# intellij.sh — the IntelliJ IDEA headless `inspect` engine: resolving the real
#               binary, running the inspection, reading the report directory the
#               CLI actually writes, disclosing which of the project's languages
#               the resolved profile can actually check, and emitting
#               intellij.json.
#
# TWO NON-OBVIOUS MECHANICS, both verified against a live install, both the
# reason this unit is not a one-line wrapper:
#
# 1. THE TOOLBOX SHIM IS NOT THE BINARY. On macOS, `idea` on PATH is a shell
#    script JetBrains Toolbox generates, whose body launches the real binary via
#    macOS `open -na "<real path>"`. `open` DETACHES: it returns immediately, the
#    inspection's stdout goes nowhere this script can read, and there is nothing
#    to wait on. So the shim is used ONLY as a way to DISCOVER the real path
#    (Toolbox keeps that path current across IDE updates, which is what makes it
#    a better source than any glob) and is never itself invoked for the run.
#
# 2. THE REPORT LANDS IN ./-e/, NOT IN THE PATH PASSED FOR IT. The documented
#    positional order is `inspect <project> <profile> <output>`, so in the
#    verified-working invocation below the second positional is consumed as the
#    PROFILE and the literal token `-e` is consumed as the OUTPUT PATH — which is
#    why a directory named after a flag appears, and why the path passed as the
#    output is ignored. Whatever the cause, the observable behaviour is fixed and
#    reproducible: results are read from `<project>/-e/`, one JSON file per
#    inspection id that fired plus a `.descriptions.json` of profile metadata,
#    and that directory is removed afterwards (via the EXIT trap, so an interrupt
#    does not leave it behind in someone's repository). Its name is RESERVED
#    before the CLI runs, with a sibling `-e.lock` directory — see
#    reserve_idea_report_dir for why the reservation cannot be the `-e` directory
#    itself.
#
# The run's cwd is the project root, so both readings of that output argument —
# "relative to cwd" and "relative to the project" — name the same directory.
#
# Sourced by inspect-project.sh — never executed directly.

# idea_bin_is_usable PATH -> 0 iff PATH is an existing, executable regular file.
# An unmatched glob left literal by the shell fails this, which is what lets the
# app-bundle search below be a plain `for` loop.
idea_bin_is_usable() {
	[ -n "${1:-}" ] && [ -f "$1" ] && [ -x "$1" ]
}

idea_log_attempt() {
	IDEA_RESOLUTION_LOG="${IDEA_RESOLUTION_LOG}    - $1${NL}"
}

# intellij_extract_shim_target SHIM -> the real binary path recorded inside a
# Toolbox-generated launcher, or non-zero if SHIM is not one.
#
# The extraction target is the first double-quoted argument to `open -na` (see
# mechanic 1 above). Guarded by a shebang check first, so a genuine compiled
# binary on PATH named `idea` is not scanned byte-by-byte by sed.
intellij_extract_shim_target() {
	iest_shim=$1
	[ -r "$iest_shim" ] || return 1
	case "$(head -n 1 "$iest_shim" 2>/dev/null || printf '')" in
		'#!'*) : ;;
		*) return 1 ;;
	esac
	iest_path=$(sed -n 's/.*open -na "\([^"]*\)".*/\1/p' "$iest_shim" 2>/dev/null | sed -n '1p')
	[ -n "$iest_path" ] || return 1
	printf '%s' "$iest_path"
}

# resolve_idea_bin -> sets IDEA_BIN_RESOLVED, or:
#   1  autodetection was exhausted; IDEA_RESOLUTION_LOG lists every step tried
#      and the caller is expected to report it
#   2  an explicit signal was unusable and this function ALREADY said so
#      precisely; the caller must not append a generic "steps tried" list, which
#      would bury the real diagnostic
#
# An EXPLICIT signal that does not work is a hard failure, not a fall-through:
# both --idea-bin and $IDEA_BIN name a specific binary the caller believes in, so
# silently ignoring a stale one and autodetecting a different IDE would run the
# inspection against a profile the caller never chose.
resolve_idea_bin() {
	IDEA_BIN_RESOLVED=""
	IDEA_RESOLUTION_LOG=""

	if [ -n "$OPT_IDEA_BIN" ]; then
		if idea_bin_is_usable "$OPT_IDEA_BIN"; then
			IDEA_BIN_RESOLVED=$OPT_IDEA_BIN
			return 0
		fi
		error "--idea-bin is not an executable file: $OPT_IDEA_BIN"
		return 2
	fi
	idea_log_attempt "--idea-bin was not given"

	if [ -n "${IDEA_BIN:-}" ]; then
		if idea_bin_is_usable "$IDEA_BIN"; then
			IDEA_BIN_RESOLVED=$IDEA_BIN
			return 0
		fi
		error "\$IDEA_BIN is set but is not an executable file: $IDEA_BIN"
		warn  "unset it, or point it at the real IntelliJ binary"
		return 2
	fi
	idea_log_attempt "\$IDEA_BIN was not set"

	resolve_idea_bin_from_path && return 0
	resolve_idea_bin_from_app_bundles && return 0
	return 1
}

# resolve_idea_bin_from_path — the `idea` launcher on PATH. On macOS this is the
# verified Toolbox-shim path; elsewhere the identical strategy is ATTEMPTED but
# UNVERIFIED, so a launcher that yields no `open -na` target falls back to being
# treated as the real binary rather than failing the whole resolution.
resolve_idea_bin_from_path() {
	if ! ribfp_shim=$(command -v idea 2>/dev/null); then
		idea_log_attempt "\`idea\` is not on PATH"
		return 1
	fi

	if ribfp_target=$(intellij_extract_shim_target "$ribfp_shim"); then
		if idea_bin_is_usable "$ribfp_target"; then
			IDEA_BIN_RESOLVED=$ribfp_target
			return 0
		fi
		idea_log_attempt "\`idea\` on PATH ($ribfp_shim) points at \"$ribfp_target\", which is not an executable file"
		return 1
	fi

	if is_macos; then
		# Never invoke a macOS launcher directly — see mechanic 1 at the top of
		# this file. Without a recoverable target there is nothing usable here.
		idea_log_attempt "\`idea\` on PATH ($ribfp_shim) is not a Toolbox launcher naming a real binary via \`open -na\`, and a macOS launcher cannot be invoked directly (it detaches via \`open\`)"
		return 1
	fi

	if idea_bin_is_usable "$ribfp_shim"; then
		IDEA_BIN_RESOLVED=$ribfp_shim
		return 0
	fi
	idea_log_attempt "\`idea\` on PATH ($ribfp_shim) is neither a Toolbox launcher nor an executable file"
	return 1
}

# resolve_idea_bin_from_app_bundles — the macOS app-bundle fallback. Both
# /Applications and ~/Applications are searched: Toolbox installs to either, and
# only ~/Applications was confirmed present on the machine this was built against.
resolve_idea_bin_from_app_bundles() {
	for ribfab_candidate in \
		"/Applications/IntelliJ IDEA"*.app/Contents/MacOS/idea \
		"$HOME/Applications/IntelliJ IDEA"*.app/Contents/MacOS/idea
	do
		if idea_bin_is_usable "$ribfab_candidate"; then
			IDEA_BIN_RESOLVED=$ribfab_candidate
			return 0
		fi
	done
	idea_log_attempt "no executable matching 'IntelliJ IDEA*.app/Contents/MacOS/idea' under /Applications or $HOME/Applications"
	return 1
}

# report_idea_resolution_failure — the exact, actionable error the contract asks
# for: every step tried, then the remedy.
report_idea_resolution_failure() {
	error "could not resolve the IntelliJ binary. Steps tried:"
	# Filtered like every other line this script writes to a terminal: the log
	# quotes paths from argv, the environment, and a launcher script's own body.
	printf '%s' "$IDEA_RESOLUTION_LOG" | strip_control_bytes >&2
	error "pass --idea-bin /path/to/idea explicitly (on macOS that is inside 'IntelliJ IDEA.app/Contents/MacOS/idea'; on Windows use Git Bash or WSL and point it at idea.bat)"
}

# ---------------------------------------------------------------------------
# Single-instance preflight
# ---------------------------------------------------------------------------
# The headless CLI refuses to start while another instance of the SAME IDE is
# already running — "Only one instance of IDEA can be run at a time", reproduced
# live. That is the ORDINARY state of a developer's machine (the GUI is open), and
# with no preflight the collision is discovered only by launching the CLI and
# waiting out the whole attempt for the CLI's own message to arrive via the log
# tail, several minutes later. This is the same refusal in milliseconds.
#
# IT REPLACES NOTHING. The match below is a heuristic with named limits, so
# run_intellij_inspection's "wrote no report directory" branch stays exactly as it
# was and remains what catches every collision this one misses.

# running_idea_pid BIN -> prints the pid of the first process whose command line
# STARTS WITH BIN and returns 0; 1 when there is no such process; 2 when the
# process table could not be read at all — which a caller must read as "cannot
# tell", never as a collision.
#
# WHY `ps` AND NOT `pgrep`. Both userlands ship pgrep, but its pattern is an
# extended regex on both, so an arbitrary binary path would have to be escaped
# into one first — and an unescaped `.` or `+` in a path silently WIDENS the
# match. A false positive here refuses a run that would have worked, so the match
# is instead a literal, anchored `case` against POSIX `ps -A -o pid= -o args=`
# (`args`, not `command`: `command` is a BSD/procps spelling, `args` is the POSIX
# keyword both accept).
#
# WHY IT IS ANCHORED AT argv[0] rather than "the path appears anywhere in the
# command line". A caller who passed --idea-bin has that exact path in THIS
# script's own argv, as does any editor, grep or sibling run that mentions it —
# matching anywhere would make the tool refuse because of itself. macOS starts an
# app bundle with the bundle's own executable as argv[0], which is exactly the
# path this unit resolves (verified against every `*.app/Contents/MacOS/*` process
# on the machine this was built against; a truncated `ps` line loses its RIGHT
# end, which an argv[0]-anchored match survives).
#
# TWO KNOWN LIMITS, stated rather than implied:
#   * LINUX IS LIKELY A MISS. There the launcher (`idea.sh`) execs a JVM, so the
#     running process's argv[0] is a `java` binary and the resolved launcher path
#     is absent from it. Nothing broader was substituted on purpose:
#     `com.intellij.idea.Main` is in EVERY JetBrains IDE's argv and the
#     single-instance lock is per-IDE, so matching it would refuse an IDEA
#     inspection because PyCharm happens to be open.
#   * A GUI STARTED FROM A DIFFERENT COPY of the same IDE — another version, or
#     /Applications when this resolved ~/Applications — is a real collision this
#     does not see.
# Both fall through to the existing failure path, which is why that path stays.
running_idea_pid() {
	rip_bin=$1
	rip_table="$WORKDIR/process-table.txt"

	command -v ps >/dev/null 2>&1 || return 2
	ps -A -o pid= -o args= >"$rip_table" 2>/dev/null || return 2

	# A FIELD-SPLITTING read, not the `IFS= read -r` the rest of this file uses:
	# the pid is wanted as its own field and the command line as the whole
	# remainder, which is what a two-variable read gives.
	while read -r rip_pid rip_cmd; do
		case "$rip_cmd" in
			"$rip_bin"|"$rip_bin "*) printf '%s' "$rip_pid"; return 0 ;;
		esac
	done <"$rip_table"
	return 1
}

# refuse_if_idea_already_running -> non-zero ONLY for a positive match. A scan
# that could not run is a warning and a pass: an environment where `ps` is absent
# or refused is not a reason to fail an inspection that would otherwise work.
refuse_if_idea_already_running() {
	riar_rc=0
	riar_pid=$(running_idea_pid "$IDEA_BIN_RESOLVED") || riar_rc=$?

	case "$riar_rc" in
		0)
			error "IntelliJ IDEA is already running (PID $riar_pid) from $IDEA_BIN_RESOLVED"
			error "the headless \`inspect\` CLI cannot start a second instance of that IDE — quit it, then re-run"
			return 1
			;;
		2)
			warn "could not read the process table, so the \"is the IDE already running\" preflight was skipped — if it is running, the inspection will fail several minutes from now instead of immediately"
			;;
	esac
	return 0
}

# language_label_for_extension EXT — prints the IntelliJ language label EXT maps
# to, or nothing when there is no mapping. Reads its argument, writes one line to
# stdout; always returns 0, so an unmapped extension is a no-op rather than a
# failure.
#
# The labels in the first group are VERIFIED against a real `.descriptions.json`
# on a live install, INCLUDING their casing (`JAVA`, `kotlin`, `yaml`,
# `protobuf`) — IntelliJ is internally inconsistent about it and this table
# reproduces what it actually emits rather than what would look tidy.
#
# The second group is UNVERIFIED: no plugin registering those languages was
# installed on the machine this was built against, so their exact casing could
# not be observed and these labels are a best guess. That is precisely why the
# comparison in write_intellij_json is case-INSENSITIVE — it reduces, but cannot
# eliminate, the risk of a casing mismatch reporting a covered language as a gap.
language_label_for_extension() {
	case "$1" in
		md)          printf 'Markdown\n' ;;
		json)        printf 'JSON\n' ;;
		json5)       printf 'JSON5\n' ;;
		yaml|yml)    printf 'yaml\n' ;;
		toml)        printf 'TOML\n' ;;
		ts|tsx)      printf 'TypeScript\n' ;;
		js|jsx)      printf 'JavaScript\n' ;;
		java)        printf 'JAVA\n' ;;
		kt|kts)      printf 'kotlin\n' ;;
		sh)          printf 'Shell Script\n' ;;
		sql)         printf 'SQL\n' ;;
		html)        printf 'HTML\n' ;;
		css)         printf 'CSS\n' ;;
		xml)         printf 'XML\n' ;;
		proto)       printf 'protobuf\n' ;;
		properties)  printf 'Properties\n' ;;
		rs)          printf 'Rust\n' ;;
		py)          printf 'Python\n' ;;
		go)          printf 'Go\n' ;;
		rb)          printf 'Ruby\n' ;;
		php)         printf 'PHP\n' ;;
		cs)          printf 'C#\n' ;;
		c|h)         printf 'C\n' ;;
		cpp|cc|hpp)  printf 'C++\n' ;;
		*)           : ;;
	esac
}

# write_file_extensions LISTFILE OUTFILE — one extension per line (with
# duplicates) for every path in LISTFILE that has one.
write_file_extensions() {
	wfe_list=$1
	wfe_out=$2
	: >"$wfe_out"
	while IFS= read -r wfe_path; do
		wfe_name=${wfe_path##*/}
		# `?*.?*` requires a non-empty stem AND a non-empty suffix, so a dotfile
		# with no extension (.gitignore) is skipped rather than read as an
		# extension of "gitignore".
		case "$wfe_name" in
			?*.?*) printf '%s\n' "${wfe_name##*.}" >>"$wfe_out" ;;
		esac
	done <"$wfe_list"
}

# write_language_labels EXTFILE OUTFILE — the IntelliJ language label for every
# extension in EXTFILE that maps to one.
write_language_labels() {
	wll_exts=$1
	wll_out=$2
	: >"$wll_out"
	while IFS= read -r wll_ext; do
		language_label_for_extension "$wll_ext" >>"$wll_out"
	done <"$wll_exts"
}

# detect_project_languages -> one distinct IntelliJ language label per line in
# $WORKDIR/project-languages.txt.
#
# WHY THIS EXISTS. When a language's IntelliJ plugin is not installed, the
# headless inspection reports ZERO findings for that language's files — no error,
# no warning, indistinguishable from clean code. This was observed live against a
# real Rust project on a machine with no Rust plugin. Knowing what the project is
# WRITTEN IN is half of what it takes to say so out loud; read_profile_metadata
# supplies the other half.
#
# CALLED BEFORE THE INSPECTION RUNS, deliberately: the CLI writes its report into
# `<project>/-e/` as a directory full of .json files, which this scan would
# otherwise count as project source and report JSON coverage for.
#
# FIVE SEPARATELY-CHECKED STAGES, NOT ONE PIPELINE, and that is the point: every
# file under the project (minus the pruned directories) -> its extension ->
# lowercased -> the DISTINCT extensions -> their labels. POSIX sh has no
# `pipefail`, so a single pipe would report only the LAST stage's status and a
# half-failed scan (an interrupted `find`, an exhausted TMPDIR) would silently
# under-report the detected languages — which is precisely the "empty means
# not-checked" blindness this whole function exists to remove. Each stage writes
# a file and each status is tested; the same shape collect_changed_files uses.
#
# Narrowing to distinct extensions before mapping is what keeps the mapping cost
# proportional to the language count (tens) rather than to the file count
# (potentially tens of thousands).
#
# The prune list is a deliberately blunt hardcoded set of names, not a
# .gitignore reading: it needs to keep a scan cheap, not to be exactly right.
detect_project_languages() {
	dpl_out="$WORKDIR/project-languages.txt"
	dpl_files="$WORKDIR/project-files.txt"
	dpl_raw_exts="$WORKDIR/project-extensions-raw.txt"
	dpl_lower_exts="$WORKDIR/project-extensions-lower.txt"
	dpl_exts="$WORKDIR/project-extensions.txt"
	dpl_labels="$WORKDIR/project-language-labels.txt"
	: >"$dpl_out"

	# find's own stderr is discarded (an unreadable subdirectory is noise here,
	# not news) but its STATUS is not: a scan that failed must not be reported as
	# a project with no languages in it.
	if ! find "$OPT_PROJECT" \
			-type d \( \
				-name node_modules -o -name .git -o -name dist -o -name build \
				-o -name target -o -name vendor -o -name .wrangler \
				-o -name .idea -o -name .scannerwork \
			\) -prune \
			-o -type f -print >"$dpl_files" 2>/dev/null
	then
		warn "could not enumerate the files under $OPT_PROJECT — intellij.json will report no detected languages and no coverage gaps"
		return 0
	fi

	write_file_extensions "$dpl_files" "$dpl_raw_exts"

	if ! tr '[:upper:]' '[:lower:]' <"$dpl_raw_exts" >"$dpl_lower_exts" ||
		! sort -u "$dpl_lower_exts" >"$dpl_exts"
	then
		warn "could not normalize the file extensions under $OPT_PROJECT — intellij.json will report no detected languages and no coverage gaps"
		return 0
	fi

	write_language_labels "$dpl_exts" "$dpl_labels"

	if ! sort -u "$dpl_labels" >"$dpl_out"; then
		warn "could not collate the detected languages of $OPT_PROJECT — intellij.json will report no detected languages and no coverage gaps"
		: >"$dpl_out"
	fi
}

# detect_sonarlint_plugin -> `true`/`false`. Best-effort and non-blocking: it
# answers "is the SonarLint plugin installed for some JetBrains IDE", which is a
# weaker claim than sonarlint_rules_registered_in_profile below and is reported
# as its own separate field for exactly that reason.
detect_sonarlint_plugin() {
	for dsp_dir in \
		"$HOME/Library/Application Support/JetBrains"/*/plugins/sonarlint-intellij \
		"$HOME/.local/share/JetBrains"/*/plugins/sonarlint-intellij \
		"$HOME/.config/JetBrains"/*/plugins/sonarlint-intellij
	do
		if [ -d "$dsp_dir" ]; then
			printf 'true'
			return 0
		fi
	done
	printf 'false'
}

# write_empty_profile_metadata FILE — the distilled shape below, with every
# signal at its conservative value. Written on EVERY path where
# `.descriptions.json` could not be read or parsed, because that file is an
# unconditional --slurpfile input to write_intellij_json and a
# conditionally-absent input is a conditionally-broken invocation.
write_empty_profile_metadata() {
	jq -n '{
		inspection_profile: "",
		sonarlint_rules_registered: false,
		sonarlint_rules_enabled: false,
		enabled_languages: [],
		all_seen_languages: [],
		enabled_plugins: []
	}' >"$1"
}

# json_bool_or_false VALUE -> VALUE when it is exactly `true` or `false`, else
# `false`. Both SonarLint signals pass through here, so a parse failure can only
# ever produce the reading that makes a caller DISTRUST an empty result set.
json_bool_or_false() {
	case "${1:-}" in
		true|false) printf '%s' "$1" ;;
		*) printf 'false' ;;
	esac
}

# read_profile_field NAME -> the value of NAME in the distilled metadata, or the
# empty string. Booleans come back as the literal text `true`/`false`; jq's `//`
# is deliberately not used to default them, because it treats `false` as absent.
read_profile_field() {
	jq -r --arg field "$1" '
		.[$field] | if . == null then "" else tostring end
	' "$WORKDIR/profile-metadata.json" 2>/dev/null || printf ''
}

# read_profile_metadata — distill `.descriptions.json` into
# $WORKDIR/profile-metadata.json, and lift the profile name and the two SonarLint
# booleans out of it into globals.
#
# ONE PASS OVER `.descriptions.json`, BY CONTRACT. That file lives in the report
# directory, which run_intellij_engine deletes as soon as the output is written,
# so everything anyone downstream needs has to come out of it here — the profile
# name, the SonarLint signals, AND the language-coverage sets. The distilled file
# is small and is what every later reader (read_profile_field,
# write_intellij_json) consults instead.
#
# THE SCHEMA IT READS, captured empirically: `.groups[].inspections[]`, where
# each inspection carries `language`, `pluginId`, `pluginVersion` and a boolean
# `enabled`. Flattening the groups yields every inspection in the resolved
# profile, enabled and disabled alike — which is what makes the three-way
# diagnosis below possible at all.
#
# WHY BOTH LANGUAGE SETS EXIST. `enabled_languages` answers "can this profile
# actually check that language"; `all_seen_languages` separates the two ways the
# answer can be no — a plugin that was never installed (absent from both sets)
# from one that is installed with its inspections switched off in this profile
# (in the second set only). Those are different problems with different fixes, so
# reporting them as one would tell a reader to install something they already
# have.
#
# WHY THE SONARLINT SIGNALS EXIST. `.descriptions.json` lists every inspection in
# the RESOLVED PROFILE, not only the ones that fired. So it is the only place that
# can distinguish "Sonar's rules ran and found nothing" from "Sonar's rules were
# never enabled in this profile" — two readings of an empty result set that mean
# opposite things. `registered` is any entry contributed by a plugin whose id
# mentions sonar; `enabled` narrows that to entries the profile actually switches
# on. Matching on `pluginId` replaced an earlier whole-document substring scan
# now that the per-entry schema above is known: the field is exact, where the scan
# also matched the word "sonar" appearing anywhere in a rule's HTML description.
read_profile_metadata() {
	rpm_desc="$IDEA_EDIR/.descriptions.json"
	rpm_meta="$WORKDIR/profile-metadata.json"

	INTELLIJ_PROFILE="unknown"
	SONARLINT_RULES_REGISTERED=false
	SONARLINT_RULES_ENABLED=false

	if [ ! -r "$rpm_desc" ]; then
		warn "no .descriptions.json in $IDEA_EDIR — reporting the inspection profile as \"unknown\", both SonarLint signals as false, and every detected language's coverage as \"not_installed\""
		write_empty_profile_metadata "$rpm_meta"
		return 0
	fi

	# Language keys are lowercased HERE so every later comparison is against an
	# already-normalized set — IntelliJ's own labels are inconsistently cased
	# (`JAVA`, `kotlin`, `yaml`) and the extension table cannot be sure it
	# reproduces that casing for a plugin nobody has installed to check against.
	if ! jq '
		def as_key: if type == "string" then ascii_downcase else "" end;
		def sonarish: (.pluginId? // "") | as_key | contains("sonar");

		[ .groups[]? | .inspections[]? ] as $inspections
		| [ $inspections[] | select(.enabled == true) ] as $enabled
		| {
			inspection_profile: (
				[ .profile_name?, .profile?, .name?, .profileName? ]
				| map(select(type == "string" and length > 0))
				| .[0] // ""
			),
			sonarlint_rules_registered: ($inspections | any(sonarish)),
			sonarlint_rules_enabled: ($enabled | any(sonarish)),
			enabled_languages: (
				[ $enabled[] | (.language | as_key) | select(length > 0) ] | unique
			),
			all_seen_languages: (
				[ $inspections[] | (.language | as_key) | select(length > 0) ] | unique
			),
			enabled_plugins: (
				[ $enabled[]
					| {
						language_key: (.language | as_key),
						plugin_id: ((.pluginId // "") | tostring),
						plugin_version: ((.pluginVersion // "") | tostring)
					}
					| select(.language_key != "" and .plugin_id != "")
				] | unique
			)
		}
	' "$rpm_desc" >"$rpm_meta" 2>/dev/null
	then
		warn "could not parse $rpm_desc — reporting the inspection profile as \"unknown\", both SonarLint signals as false, and every detected language's coverage as \"not_installed\""
		write_empty_profile_metadata "$rpm_meta"
		return 0
	fi

	rpm_name=$(read_profile_field inspection_profile)
	[ -z "$rpm_name" ] || INTELLIJ_PROFILE=$rpm_name
	SONARLINT_RULES_REGISTERED=$(json_bool_or_false "$(read_profile_field sonarlint_rules_registered)")
	SONARLINT_RULES_ENABLED=$(json_bool_or_false "$(read_profile_field sonarlint_rules_enabled)")
}

# reserve_idea_report_dir — claim `<project>/-e` for THIS run, atomically, before
# the CLI is launched.
#
# WHY A SIBLING LOCK RATHER THAN `mkdir` OF `-e` ITSELF. The refusal below has to
# be a RESERVATION, not a check: `-e` is created by the CLI, so a bare
# `[ -e ] && refuse` leaves a window in which two concurrent runs on one project
# both pass the check, both let the CLI write `<project>/-e`, and the first to
# finish `rm -rf`s it out from under the other. `mkdir` is the atomic primitive
# that closes it — but it is applied to `-e.lock`, not to `-e`, because whether
# the real `idea inspect` CLI tolerates an output directory it did not create
# itself could not be verified here, and pre-creating `-e` on a guess would
# trade a race for a possible hard failure of the inspection.
#
# `[ -L ]` is tested alongside `[ -e ]`: `[ -e ]` follows symlinks and is FALSE
# for a DANGLING one, so a symlink named `-e` pointing nowhere would otherwise
# slip past the refusal and be followed by the CLI's own writes.
#
# ACCEPTED RESIDUAL RISK, STATED RATHER THAN IMPLIED. A pre-planted `-e` of any
# kind is refused above, and the teardown can only ever delete inside the project
# — but a window remains between that refusal and the CLI actually creating `-e`,
# and a local user with WRITE ACCESS TO THE PROJECT DIRECTORY can win it by
# planting a symlink there for the CLI to write its report through. It cannot be
# closed from here: `-e` must be created by the CLI, not by this script (see the
# sibling-lock rationale above), so there is no atomic create-or-fail this tool
# can perform on the name it needs.
#
# THE ASSUMPTION THIS TOOL THEREFORE MAKES: the project directory is not writable
# by anyone but the invoking user for the duration of the run. That is a
# reasonable assumption for a local developer tool on a single-user machine, and
# it is the same assumption every other build tool pointed at the same directory
# already makes — but it IS an assumption, and it does not hold on a shared or
# multi-tenant host. The one case where it is cheaply detectable is warned about
# below; group-writability deliberately is not, because a per-user group with a
# 002 umask makes group-writable project directories ordinary on some systems and
# a refusal there would be a false positive.
reserve_idea_report_dir() {
	rird_edir=$1
	rird_lock="$rird_edir.lock"
	rird_parent=${rird_edir%/*}

	# A warning, never a refusal: the run is still the caller's to make, and this
	# says out loud that the assumption documented above does not hold here.
	# `find … -prune -perm` rather than `stat`, whose flags differ between the GNU
	# and BSD userlands this script supports.
	if [ -n "$(find "$rird_parent" -prune -perm -0002 2>/dev/null)" ]; then
		warn "$rird_parent is world-writable: any local user can plant a symlink at $rird_edir in the window between this run's check and the IntelliJ CLI creating it, and the report would be written through it — tighten the directory's permissions before inspecting it"
	fi

	if ! mkdir "$rird_lock" 2>/dev/null; then
		error "'$rird_lock' already exists in the target project"
		error "another inspect-project run is inspecting it (or one died hard) — wait for it to finish, or remove that directory once none is running, then re-run"
		return 1
	fi
	# Armed the instant the reservation succeeds, so an interrupt one line later
	# still releases it.
	IDEA_EDIR_LOCK=$rird_lock

	# Refuse rather than clobber. This script DELETES its report directory
	# afterwards, so finding one already there means either a previous run died
	# hard or the path is genuinely the user's — and deleting somebody's
	# directory to make room for a report is not a call this script may make.
	# Tested only now that the name is reserved: no other run of this script can
	# create it between here and the launch below.
	if [ -e "$rird_edir" ] || [ -L "$rird_edir" ]; then
		error "'$rird_edir' already exists in the target project"
		error "the IntelliJ CLI writes its report there and this script removes it afterwards — move or remove it, then re-run"
		return 1
	fi
}

# run_intellij_inspection — the inspection itself.
run_intellij_inspection() {
	rii_edir="$OPT_PROJECT/-e"

	reserve_idea_report_dir "$rii_edir" || return 1

	rii_log="$WORKDIR/intellij.log"
	rii_ignored_out="$WORKDIR/idea-output-arg"
	mkdir -p "$rii_ignored_out"

	# The two verified invocations, written out rather than assembled from a
	# conditional flag, so each is readable exactly as it was confirmed to work.
	if [ "$OPT_SCOPE" = changed-only ]; then
		set -- inspect "$OPT_PROJECT" "$rii_ignored_out" -e -changes -format json -v1
	else
		set -- inspect "$OPT_PROJECT" "$rii_ignored_out" -e -format json -v1
	fi

	note "Running the IntelliJ inspection ($OPT_SCOPE scope) — this can take several minutes..."

	# Armed BEFORE the run: the CLI creates ./-e/ early, so an interrupt must
	# already have something to clean up. OWNED because the reservation above
	# established that nothing was there beforehand — so whatever is there after
	# the run is this tool's own litter, whatever kind of node it turns out to be.
	IDEA_EDIR=$rii_edir
	IDEA_EDIR_OWNED=1

	rii_rc=0
	(
		cd "$OPT_PROJECT" || exit 1
		umask "$ORIG_UMASK"
		# THE SONAR CREDENTIAL IS SCRUBBED FROM THIS CHILD'S ENVIRONMENT, and it
		# is not hygiene for its own sake. $SONAR_TOKEN is the channel this tool
		# actively RECOMMENDS over --sonar-token, so an operator who followed that
		# advice has it exported in the shell that runs this script — and
		# importing a project into IntelliJ evaluates the project's OWN build
		# logic (Gradle/Maven) and loads its plugins. Inheriting the token here
		# would hand the inspected repository's code a live credential it has no
		# use for. Only lib/sonar.sh's own subshell exports it, which is the one
		# child that genuinely needs it.
		unset SONAR_TOKEN
		exec "$IDEA_BIN_RESOLVED" "$@"
	) >"$rii_log" 2>&1 || rii_rc=$?

	if [ ! -d "$rii_edir" ]; then
		error "the IntelliJ inspection wrote no report directory ($rii_edir); the CLI exited $rii_rc"
		report_log_tail "$rii_log"
		# IDEA_EDIR is deliberately LEFT SET so the teardown still removes
		# whatever the CLI left at that path — a file or a symlink where a
		# directory was expected is this tool's litter too, and leaving it there
		# would make every later run refuse until a human deleted it by hand.
		return 1
	fi

	# A non-zero exit alongside a written report is the IntelliJ CLI's normal
	# behaviour for several benign conditions (an unresolved module, a plugin
	# warning). The report is the artifact that matters, so it is parsed — but
	# loudly, with the log tail, never silently.
	if [ "$rii_rc" -ne 0 ]; then
		warn "the IntelliJ CLI exited $rii_rc but did write $rii_edir — parsing it anyway"
		report_log_tail "$rii_log"
	fi
}

# collect_intellij_issues -> one compact JSON issue per line in
# $WORKDIR/intellij-issues.jsonl.
#
# `source_inspection` is carried alongside each issue purely so --exclude-ids can
# match EITHER the id the report declares or the report file it came from (they
# diverge for several inspections, and the linguistic-noise defaults are named by
# file). It is stripped from the emitted JSON — see write_intellij_json.
#
# No jq regex anywhere (`ltrimstr`, never `sub`): this repository's scripts
# deliberately avoid depending on jq being built with Oniguruma. The three chained
# `ltrimstr` calls cover the report's two observed `file` spellings — a
# `$PROJECT_DIR$` macro and a plain absolute URL — and each is a no-op when its
# prefix is absent.
#
# A FILE THAT FAILS TO PARSE IS COUNTED, not only warned about. The warning goes
# to stderr, which the machine-readable channel an agent reads does not carry —
# so with every report file unparseable, intellij.json's `total_issues: 0` would
# read as "clean" with nothing in it saying otherwise. The count reaches
# write_intellij_json and lands in the metadata.
collect_intellij_issues() {
	cii_out="$WORKDIR/intellij-issues.jsonl"
	: >"$cii_out"
	INTELLIJ_UNPARSED_REPORT_FILES=0

	# `.descriptions.json` needs no skip guard: a POSIX glob never matches a
	# leading-dot name, so this loop cannot see it in the first place.
	for cii_file in "$IDEA_EDIR"/*.json; do
		[ -f "$cii_file" ] || continue
		cii_stem=${cii_file##*/}
		cii_stem=${cii_stem%.json}

		if ! jq -c --arg stem "$cii_stem" --arg proot "$OPT_PROJECT" '
			(.problems // [])[]
			| {
				id: ((.problem_class.id // "") | if . == "" then $stem else . end),
				severity: ((.problem_class.severity // "") | if . == "" then "UNKNOWN" else . end),
				file: ((.file // "")
					| ltrimstr("file://$PROJECT_DIR$/")
					| ltrimstr("file://")
					| ltrimstr($proot + "/")),
				line: (.line | if type == "number" then . elif type == "string" then (tonumber? // null) else null end),
				language: (.language // null),
				description: (.description // ""),
				highlighted_element: (.highlighted_element // null),
				source_inspection: $stem
			}' "$cii_file" >>"$cii_out" 2>/dev/null
		then
			INTELLIJ_UNPARSED_REPORT_FILES=$((INTELLIJ_UNPARSED_REPORT_FILES + 1))
			warn "could not parse the IntelliJ report file $cii_file — its findings are NOT in the output"
		fi
	done
}

# resolve_exclude_ids -> one id per line in $WORKDIR/exclude-ids.txt.
# Precedence: an unset flag takes the default; `+IDS` extends the default; any
# other value (including the empty string) replaces it outright.
resolve_exclude_ids() {
	rei_out="$WORKDIR/exclude-ids.txt"
	if [ "$OPT_EXCLUDE_IDS_GIVEN" -eq 0 ]; then
		csv_to_lines "$EXCLUDE_IDS_DEFAULT" >"$rei_out"
		return 0
	fi
	case "$OPT_EXCLUDE_IDS" in
		+*) csv_to_lines "$EXCLUDE_IDS_DEFAULT,${OPT_EXCLUDE_IDS#+}" >"$rei_out" ;;
		*)  csv_to_lines "$OPT_EXCLUDE_IDS" >"$rei_out" ;;
	esac
}

# write_intellij_json OUTFILE — assemble the metadata + filtered issues.
#
# Every value reaches jq as an --arg/--argjson/--rawfile/--slurpfile VALUE fed to
# a STATIC program; nothing is concatenated into the program text. The exclusion
# is applied HERE rather than during collection so excluded_count is the honest
# difference between what was found and what was kept — the contract forbids
# dropping findings without disclosing how many.
#
# `language_coverage` is where detect_project_languages and read_profile_metadata
# meet: what the project is written in, matched against what the resolved profile
# can actually check. The match is case-INSENSITIVE on purpose — see
# language_label_for_extension for which labels are verified and which are a
# guess. `plugins` is populated only for a covered language, because the catalog
# it draws from holds enabled entries only; for either gap status there is by
# definition no enabled plugin to name.
write_intellij_json() {
	wij_out=$1
	jq -n \
		--slurpfile raw "$WORKDIR/intellij-issues.jsonl" \
		--slurpfile profile_meta "$WORKDIR/profile-metadata.json" \
		--rawfile excl "$WORKDIR/exclude-ids.txt" \
		--rawfile langs "$WORKDIR/project-languages.txt" \
		--arg project "$OPT_PROJECT" \
		--arg project_name "$PROJECT_NAME" \
		--arg scope "$OPT_SCOPE" \
		--arg generated_at "$GENERATED_AT" \
		--arg profile "$INTELLIJ_PROFILE" \
		--argjson plugin "$SONARLINT_PLUGIN_INSTALLED" \
		--argjson registered "$SONARLINT_RULES_REGISTERED" \
		--argjson rules_enabled "$SONARLINT_RULES_ENABLED" \
		--argjson unparsed_report_files "$INTELLIJ_UNPARSED_REPORT_FILES" \
		'
		($profile_meta[0] // {}) as $pm
		| ($langs | split("\n") | map(select(length > 0))) as $languages
		| ($excl | split("\n") | map(select(length > 0))) as $ex
		| ($raw | map(
				# Bound to names FIRST: inside `index(...)` the input `.` is the
				# array being searched, not the issue, so `index(.id)` would look
				# up the exclusion list its own `.id` and fail.
				.id as $issue_id
				| .source_inspection as $issue_source
				| select(
					($ex | index($issue_id)) == null
					and ($ex | index($issue_source)) == null
				)
			)) as $kept
		| {
			metadata: {
				engine: "intellij-inspect",
				project: $project,
				project_name: $project_name,
				scope: $scope,
				generated_at: $generated_at,
				inspection_profile: $profile,
				sonarlint_plugin_installed: $plugin,
				sonarlint_rules_registered_in_profile: $registered,
				sonarlint_rules_enabled_in_profile: $rules_enabled,
				languages_detected_in_project: $languages,
				language_coverage: [
					$languages[]
					| . as $language
					| ($language | ascii_downcase) as $key
					| {
						language: $language,
						status: (
							if (($pm.enabled_languages // []) | index($key)) != null
							then "covered"
							elif (($pm.all_seen_languages // []) | index($key)) != null
							then "disabled_in_profile"
							else "not_installed"
							end
						),
						plugins: [
							($pm.enabled_plugins // [])[]
							| select(.language_key == $key)
							| { plugin_id: .plugin_id, plugin_version: .plugin_version }
						]
					}
				],
				excluded_ids: $ex,
				excluded_count: (($raw | length) - ($kept | length)),
				# Non-zero means total_issues is INCOMPLETE: that many report
				# files could not be parsed and their findings are absent.
				unparsed_report_files: $unparsed_report_files,
				total_issues: ($kept | length)
			},
			issues: ($kept | map(del(.source_inspection)))
		}
		' >"$wij_out"
}

# run_intellij_engine — the unit's one entry point: resolve, detect, run, read,
# write.
run_intellij_engine() {
	rie_rc=0
	resolve_idea_bin || rie_rc=$?
	if [ "$rie_rc" -eq 1 ]; then
		report_idea_resolution_failure
		return 1
	fi
	if [ "$rie_rc" -ne 0 ]; then
		return 1
	fi
	note "IntelliJ binary: $IDEA_BIN_RESOLVED"

	# The engine's cheapest failure, so it goes before its most expensive work —
	# ahead of the filesystem scan below as well as the run itself.
	refuse_if_idea_already_running || return 1

	# Before the run, not after: the inspection writes a directory of .json files
	# into the project, which this scan would otherwise read as project source.
	detect_project_languages

	if ! run_intellij_inspection; then
		return 1
	fi

	SONARLINT_PLUGIN_INSTALLED=$(detect_sonarlint_plugin)
	read_profile_metadata
	collect_intellij_issues
	resolve_exclude_ids

	rie_out="$RUN_DIR/intellij.json"
	if ! write_intellij_json "$rie_out"; then
		error "could not write $rie_out"
		return 1
	fi
	# shellcheck disable=SC2034  # read by lib/output.sh's print_run_summary()/print_machine_keys(); shellcheck lints each unit in isolation and cannot see a reader in a sibling
	INTELLIJ_OUTPUT=$rie_out

	# Released here as well as from cleanup(): the happy path should not leave a
	# directory in someone's repository for the length of a Sonar scan.
	release_idea_report_dir
}

# release_idea_report_dir — remove `<project>/-e` (whatever node is there) and
# then the reservation that held its name. Called from the happy path above AND
# from lib/runtime.sh's cleanup() on every exit path, so it must be safe to call
# when nothing was ever reserved, and safe to call twice.
#
# THE ORDER IS THE POINT: the lock goes LAST, so the name stays reserved against
# a concurrent run for as long as there is still something of this run's to
# remove there.
release_idea_report_dir() {
	if [ -n "$IDEA_EDIR" ] && [ "$IDEA_EDIR_OWNED" -eq 1 ]; then
		rm -rf -- "$IDEA_EDIR" 2>/dev/null || true
		IDEA_EDIR=""
	fi
	if [ -n "$IDEA_EDIR_LOCK" ]; then
		rm -rf -- "$IDEA_EDIR_LOCK" 2>/dev/null || true
		IDEA_EDIR_LOCK=""
		IDEA_EDIR_OWNED=0
	fi
}
