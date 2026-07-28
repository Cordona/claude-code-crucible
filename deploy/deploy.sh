#!/bin/sh
# deploy.sh — framework symlink deployer
#
# Deploy model: every agent (any *.md with name:+description: frontmatter, excluding
# SKILL.md), every skill (any directory containing SKILL.md), and every contract (any
# *.schema.json file) is discovered by MARKER anywhere under the framework root and
# symlinked by name into <target>/agents/, <target>/skills/, and
# <target>/crucible/contracts/ (contracts flat, by basename) respectively; CLAUDE.md is
# likewise found anywhere under the root — qualified by a '# Claude Code Configuration'
# marker heading, exactly one expected — and symlinked to <target>/CLAUDE.md. Source
# folder layout is organizational only — discovery is by marker, not path, so the tree can
# be reorganized freely.
#
# POSIX sh only. No bashisms (no arrays, no [[ ]], no local, no pipefail, no process
# substitution). Runs under dash and macOS /bin/sh. shellcheck -s sh clean.
#
# Pipeline: DISCOVER -> PLAN -> APPLY -> REPORT
#
# Exit codes:
#   0  success (including dry-run and "diverged copies reported")
#   2  usage / argument error
#   3  ambiguous source: a name collision (two sources resolve to the same name+type),
#      or more than one qualifying CLAUDE.md under the root; nothing applied
#   4  an agent's 'skills:' frontmatter references an undiscovered skill; nothing applied
#   5  a required agent (see --required-agents) was not discovered; nothing applied
#   6  a required runtime tool (see --required-tools) was not found on PATH; nothing
#      applied
#   1  other fatal error (missing dependency, bad source, fs failure)

set -eu

LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Constants / globals
# ---------------------------------------------------------------------------

PROG=deploy.sh
TAB=$(printf '\t')

# Default --required-agents list (space-separated; see check_required_agents).
DEFAULT_REQUIRED_AGENTS="decision-arbiter review-arbiter software-architect git-operator docs-writer"

# Default --required-tools list (space-separated "slots"; see check_required_tools). A
# slot is either a single command name, or two alternatives joined by "|" meaning at
# least one of them must be present (git's own gpg.format config picks openpgp/gpg vs
# ssh at commit/tag-signing time, and deploy.sh cannot know at deploy time which the user
# will configure — so neither alone is mandatory, but at least one must exist).
DEFAULT_REQUIRED_TOOLS="git gh jq curl gpg|ssh-keygen"

# Runtime configuration (set by parse_args)
DRY_RUN=0
NO_PRUNE=0
COPY_AGENTS=0
ONLY=""
ARG_SOURCE=""
ARG_TARGET=""
ARG_REQUIRED_AGENTS=""
ARG_REQUIRED_AGENTS_SET=0
ARG_REQUIRED_TOOLS=""
ARG_REQUIRED_TOOLS_SET=0
SKIP_SKILL_REFS_CHECK=0

# Resolved paths (set in main)
SCRIPT_DIR=""
FRAMEWORK_ROOT=""
TARGET_DIR=""
WORK=""
RUN_TS=""

# IS_OWN_TREE=1 when FRAMEWORK_ROOT is this deployer's own tree (default source); gates
# whether DEFAULT_REQUIRED_AGENTS applies (see required_agents_list). Set in main().
IS_OWN_TREE=0

# Scope flags (derived from ONLY)
RUN_AGENTS=1
RUN_SKILLS=1
RUN_CONFIG=1
RUN_CONTRACTS=1

# APPLY=1 unless dry-run
APPLY=1

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

warn() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
	warn "$*"
	exit 1
}

die_usage() {
	warn "$*"
	warn "run '$PROG --help' for usage"
	exit 2
}

cleanup() {
	# Preserve the original exit status across cleanup.
	cl_status=$?
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf "$WORK" 2>/dev/null || :
	fi
	exit "$cl_status"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $PROG [OPTIONS]

Discover agents and skills by MARKER under a framework root and symlink them by name
into a Claude Code config directory.

An existing FOREIGN operating contract at the target (a real CLAUDE.md, or a symlink
resolving outside the framework) is preserved to a timestamped
"<target>/CLAUDE.md.backup.<UTC>" and then replaced with the framework's contract — never
discarded. Agents, skills and contracts keep DIVERGED protection (left untouched).

Options:
  --dry-run              Discover, plan and report only; change nothing on disk.
                         Run this first to preview CREATE/REPLACE/DIVERGED/PRUNE.
  --target DIR           Deploy into DIR instead of \$HOME/.claude.
  --source DIR           Framework root (default: grandparent of this script's real path).
  --copy-agents          Copy agent .md files instead of symlinking them.
                         (Skills are ALWAYS symlinked so bundled scripts/ travel with them.)
                         NOTE: in this mode a DIFFERING regular file at the target agent
                         name is overwritten with no backup. Use --dry-run to preview.
  --no-prune             Do not remove stale framework symlinks from the target.
  --only TYPE            Restrict the run to one type: agents | skills | config | contract.
                         NOTE: this also skips the 'skills:' reference check (needs
                         both agents and skills in scope) and/or the required-agents
                         check (needs agents in scope) whenever they fall outside TYPE;
                         a warning is printed when that happens. The required-tools
                         check (Check 3) is deliberately EXEMPT from --only scoping — it
                         always runs regardless of TYPE (see --required-tools).
  --required-agents LIST Comma-separated agent names that MUST be discovered (checked
                         by frontmatter 'name:'). Applied by DEFAULT only when --source
                         is this deployer's own tree:
                         ${DEFAULT_REQUIRED_AGENTS}
                         A foreign/forked/subset --source tree has NO required-agents
                         check by default; opt in with this flag. Pass an empty string
                         ("") to disable the check outright.
  --required-tools LIST  Comma/space-separated runtime tool "slots" that MUST be present
                         on PATH (checked via 'command -v') — the tools the DEPLOYED
                         agents/skills need at RUNTIME, as opposed to --required-agents
                         (deploy.sh's own roster) or check_deps (deploy.sh's own
                         toolchain). A slot is a single command name, or two
                         alternatives joined by "|" meaning at least one must be present
                         (e.g. "gpg|ssh-keygen"). Applied by DEFAULT only when --source
                         is this deployer's own tree:
                         ${DEFAULT_REQUIRED_TOOLS}
                         A foreign/forked/subset --source tree has NO required-tools
                         check by default; opt in with this flag. Pass an empty string
                         ("") to disable the check outright. This check is never
                         narrowed by --only (it governs which tools are checked, not
                         which artifact types are deployed) and never installs anything
                         itself — it only detects, reports, and suggests.
  --no-verify-skill-refs Skip the 'skills:' frontmatter reference check (Check 1).
  -h, --help             Show this help and exit.

Exit codes: 0 ok, 2 usage error, 3 ambiguous source (name collision, or >1 CLAUDE.md),
            4 unresolved 'skills:' reference,
            5 missing required agent,
            6 missing required runtime tool, 1 other error.
EOF
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

have() {
	command -v "$1" >/dev/null 2>&1
}

check_deps() {
	cd_missing=""
	for cd_bin in awk cmp cp date find ln mkdir mktemp readlink rm sort basename dirname \
		sed grep head cat; do
		have "$cd_bin" || cd_missing="$cd_missing $cd_bin"
	done
	[ -z "$cd_missing" ] || die "missing required commands:$cd_missing"
}

# ---------------------------------------------------------------------------
# Portable path helpers
# ---------------------------------------------------------------------------

# abspath: make a path absolute without requiring it to exist and without resolving
# symlinks (lexical). Used for the target, which may not exist yet under --dry-run.
abspath() {
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
	esac
}

# realpath_portable: canonical absolute path of an EXISTING file/dir, resolving symlinks.
# Portable shim: does NOT use "readlink -f" or "realpath" (absent/limited on BSD/macOS).
# Uses one-level "readlink" plus "pwd -P" (both POSIX-portable on macOS and Linux).
realpath_portable() {
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

# readlink_abs: absolute target of a symlink (single level), without requiring the target
# to exist (so it works on dangling links). Not canonicalized; sufficient for a
# framework-root prefix test because we always create absolute, canonical links.
readlink_abs() {
	rla_raw=$(readlink "$1") || return 1
	case $rla_raw in
	/*) printf '%s\n' "$rla_raw" ;;
	*) printf '%s/%s\n' "$(dirname "$1")" "$rla_raw" ;;
	esac
}

# valid_name: reject names that are unsafe as a filesystem path component or that would
# corrupt the TAB-separated manifest. Allows only [A-Za-z0-9._-]; rejects empty, '.', '..',
# and anything containing '/', TAB, newline or other characters.
valid_name() {
	case $1 in
	'' | . | ..) return 1 ;;
	*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}

# inside_framework: exit 0 if PATH is a real descendant of the framework root, rejecting any
# lexical traversal (`..`) BEFORE the prefix test so a `$FRAMEWORK_ROOT/../..` target cannot
# masquerade as "inside".
inside_framework() {
	case $1 in
	../* | */../* | */..) return 1 ;;
	esac
	case $1 in
	"$FRAMEWORK_ROOT"/*) return 0 ;;
	*) return 1 ;;
	esac
}

# link_inside_framework: exit 0 if the symlink at $1 resolves to a location inside the
# framework root. Canonicalizes the resolved target (so a link created via a symlinked path
# alias such as /var vs /private/var is judged correctly); for a DANGLING link, falls back
# to the lexical, traversal-rejecting test on the raw target (so `..`-escapes stay foreign).
link_inside_framework() {
	lif_res=$(realpath_portable "$1" 2>/dev/null) || lif_res=""
	if [ -n "$lif_res" ]; then
		case $lif_res in
		"$FRAMEWORK_ROOT"/*) return 0 ;;
		*) return 1 ;;
		esac
	fi
	lif_raw=$(readlink_abs "$1") || lif_raw=""
	inside_framework "$lif_raw"
}

# canon_target: best-effort canonical absolute path for a target that may not fully exist
# yet (canonicalizes the deepest existing ancestor and re-appends the missing tail).
canon_target() {
	ct_p=$1
	if [ -e "$ct_p" ] || [ -h "$ct_p" ]; then
		realpath_portable "$ct_p" && return 0
		printf '%s\n' "$1"
		return 0
	fi
	ct_rest=""
	while [ ! -d "$ct_p" ]; do
		ct_rest="/$(basename "$ct_p")$ct_rest"
		ct_next=$(dirname "$ct_p")
		[ "$ct_next" = "$ct_p" ] && break
		ct_p=$ct_next
	done
	if [ -d "$ct_p" ]; then
		ct_base=$(cd "$ct_p" 2>/dev/null && pwd -P) || {
			printf '%s\n' "$1"
			return 0
		}
		printf '%s%s\n' "$ct_base" "$ct_rest"
	else
		printf '%s\n' "$1"
	fi
}

# resolve_script_dir: canonical directory of this script, following a symlinked $0.
resolve_script_dir() {
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

# ---------------------------------------------------------------------------
# YAML frontmatter parsing
# ---------------------------------------------------------------------------

# fm_field FILE FIELD
# Prints the trimmed, unquoted value of a top-level FIELD in the file's YAML frontmatter
# (the block between the first line that is exactly "---" and the next such line).
# Exit 0 if the field key is present (even with an empty/block value), 1 otherwise.
fm_field() {
	awk -v f="$2" '
		BEGIN { dq = "\042"; sq = "\047"; found = 0; inb = 0; done = 0 }
		{ sub(/\r$/, "") }
		done { next }
		NR == 1 { if ($0 != "---") { done = 1; next } inb = 1; next }
		inb && $0 == "---" { done = 1; next }
		inb {
			key = f ":"
			if (substr($0, 1, length(key)) == key) {
				val = substr($0, length(key) + 1)
				sub(/^[ \t]+/, "", val)
				sub(/[ \t]+$/, "", val)
				n = length(val)
				if (n >= 2) {
					c1 = substr(val, 1, 1)
					c2 = substr(val, n, 1)
					if ((c1 == dq && c2 == dq) || (c1 == sq && c2 == sq))
						val = substr(val, 2, n - 2)
				}
				print val
				found = 1
				done = 1
			}
		}
		END { exit found ? 0 : 1 }
	' "$1"
}

# is_agent FILE -> prints the agent name on success (frontmatter has name AND description,
# and the basename is not SKILL.md). Returns non-zero for non-agents.
is_agent() {
	case $(basename "$1") in
	SKILL.md) return 1 ;;
	esac
	ia_name=$(fm_field "$1" name) || return 1
	[ -n "$ia_name" ] || return 1
	fm_field "$1" description >/dev/null 2>&1 || return 1
	if ! valid_name "$ia_name"; then
		warn "skipping agent with unsafe 'name:' value: $1 (name='$ia_name')"
		return 1
	fi
	printf '%s\n' "$ia_name"
}

# fm_skills_list FILE
# Prints, one per line, the skill names listed under the top-level "skills:" block of
# FILE's YAML frontmatter: a "- name" list (indented OR unindented), where blank lines
# and "#" comment lines are skipped. The list block ends at the next top-level
# (unindented) key or the closing "---". Prints nothing if the file has no "skills:" key.
# Mirrors (does NOT share code with) fm_field's single-pass frontmatter scan.
#
# The KEY itself is matched with a real anchored pattern — not a raw prefix compare — so
# "skills:", "skills :" (space before colon), "\"skills\":" and "'skills':" (quoted key)
# are all recognized; an INDENTED "skills:"-looking line is correctly ignored (it is not
# a top-level key). An explicit empty value — "[]", "~", or "null"/"Null"/"NULL" — is
# treated as zero references (valid YAML "no skills", not an error).
#
# Fails LOUD, never silently, on anything else: any "skills:" value that is not the
# supported block-list form or one of the explicit-empty spellings above (flow style
# "skills: [a, b]", a bare scalar "skills: a", or anything else with content on the
# "skills:" line itself) is a hard error (non-zero exit, sanitized diagnostic on stderr)
# rather than being silently treated as "no references" — a gate that can be defeated by
# an unrecognized-but-valid YAML shape is worse than no gate.
fm_skills_list() {
	awk '
		BEGIN {
			dq = "\042"; sq = "\047"
			key_pat = "^(" dq "skills" dq "|" sq "skills" sq "|skills)[ \t]*:"
			inb = 0; ins = 0; done = 0; bad = 0
		}
		{ sub(/\r$/, "") }
		done { next }
		NR == 1 { if ($0 != "---") { done = 1; next } inb = 1; next }
		inb && $0 == "---" { done = 1; next }
		inb && ins && /^[ \t]*$/ { next }
		inb && ins && /^[ \t]*#/ { next }
		inb && ins && /^[ \t]*-[ \t]/ {
			item = $0
			sub(/^[ \t]*-[ \t]*/, "", item)
			sub(/[ \t]+#.*$/, "", item)
			sub(/[ \t]+$/, "", item)
			n = length(item)
			if (n >= 2) {
				c1 = substr(item, 1, 1)
				c2 = substr(item, n, 1)
				if ((c1 == dq && c2 == dq) || (c1 == sq && c2 == sq))
					item = substr(item, 2, n - 2)
			}
			if (item != "") print item
			next
		}
		inb && ins { ins = 0 }
		inb && !ins && match($0, key_pat) {
			rest = substr($0, RSTART + RLENGTH)
			sub(/[ \t]+#.*$/, "", rest)
			sub(/^[ \t]+/, "", rest)
			sub(/[ \t]+$/, "", rest)
			if (rest == "") { ins = 1; next }
			if (rest == "[]" || rest == "~" || rest == "null" || rest == "Null" || rest == "NULL") next
			t = $0
			gsub(/[^\t -~]/, "?", t)
			printf "unsupported skills: form (expected an indented/unindented block list, e.g. \"skills:\" then \"  - name\" on following lines, or an explicit empty value: [], ~, null); offending line: %s\n", t > "/dev/stderr"
			bad = 1
			done = 1
			next
		}
		END { exit bad ? 1 : 0 }
	' "$1"
}

# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------

# manifest_has FILE NAME -> exit 0 if NAME is a first-column entry (exact match).
# NAME is passed via ENVIRON, not "awk -v", because POSIX awk applies escape-sequence
# expansion to "-v" assignments (a NAME of e.g. "\163tandard-security" would expand to
# "standard-security" and wrongly match) — the environment is not subject to that
# expansion.
manifest_has() {
	mh_name=$2 awk -F "$TAB" '$1 == ENVIRON["mh_name"] { f = 1 } END { exit f ? 0 : 1 }' "$1"
}

# record ACTION CATEGORY NAME -> append to the per-action report file.
# record ACTION CATEGORY NAME [SOURCE] — SOURCE is optional and, when given, is shown in
# the report so the operator can see which file an entry resolved to.
record() {
	if [ -n "${4:-}" ]; then
		printf '%s\t%s\t%s\n' "$2" "$3" "$4" >>"$WORK/act_$1"
	else
		printf '%s\t%s\n' "$2" "$3" >>"$WORK/act_$1"
	fi
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# The prune expression is embedded directly in each find call. We prune:
#   - any .git directory
#   - any tests directory
#   - the script's own deploy directory ($SCRIPT_DIR) and the framework-root deploy dir
# and never emit .DS_Store (naturally excluded by the -name filters).

discover_skills() {
	find "$FRAMEWORK_ROOT" \
		\( -name .git -o -name tests -o -path "$SCRIPT_DIR" -o -path "$FRAMEWORK_ROOT/deploy" \) -prune -o \
		-type f -name SKILL.md -print >"$WORK/skills.raw" || die "find (skills) failed"

	while IFS= read -r ds_file; do
		[ -n "$ds_file" ] || continue
		ds_dir=$(dirname "$ds_file")
		ds_name=$(fm_field "$ds_file" name) || die "SKILL.md has no 'name:' frontmatter: $ds_file"
		[ -n "$ds_name" ] || die "SKILL.md has empty 'name:': $ds_file"
		valid_name "$ds_name" || die "SKILL.md has unsafe 'name:' value: $ds_file (name='$ds_name')"
		printf '%s\t%s\n' "$ds_name" "$ds_dir" >>"$WORK/skills.tsv"
	done <"$WORK/skills.raw"
}

discover_agents() {
	find "$FRAMEWORK_ROOT" \
		\( -name .git -o -name tests -o -path "$SCRIPT_DIR" -o -path "$FRAMEWORK_ROOT/deploy" \) -prune -o \
		-type f -name '*.md' ! -name SKILL.md -print >"$WORK/agents.raw" || die "find (agents) failed"

	while IFS= read -r da_file; do
		[ -n "$da_file" ] || continue
		da_name=$(is_agent "$da_file") || continue
		printf '%s\t%s\n' "$da_name" "$da_file" >>"$WORK/agents.tsv"
	done <"$WORK/agents.raw"
}

# CLAUDE.md is discovered by MARKER (filename), anywhere under the framework root —
# the same rule as agents and skills, so the tree stays reorganizable. It was formerly
# pinned to $FRAMEWORK_ROOT/CLAUDE.md; moving the file then silently produced a PRUNE of
# the deployed copy instead of a redeploy, because "not found" and "deliberately removed"
# were indistinguishable. Exactly one is expected: zero means no config to deploy, and
# more than one is ambiguous and fatal rather than arbitrarily resolved.
discover_config() {
	find -L "$FRAMEWORK_ROOT" \
		\( -name .git -o -name tests -o -path "$SCRIPT_DIR" -o -path "$FRAMEWORK_ROOT/deploy" \) -prune -o \
		-type f -name CLAUDE.md -print >"$WORK/config.candidates" || die "find (config) failed"

	# Qualify by CONTENT, not filename alone. An agent must carry name:+description:
	# frontmatter and a skill must be a SKILL.md dir; before this, the operating contract —
	# the highest-privilege artifact deployed — was the ONLY one admitted on its name. A
	# stray CLAUDE.md (a vendored copy, an example, a per-directory note) could therefore
	# become the user's global contract. Require the marker heading this framework's own
	# contract carries.
	: >"$WORK/config.raw"
	while IFS= read -r dcf_cand; do
		[ -n "$dcf_cand" ] || continue
		if head -n 20 "$dcf_cand" | grep -q '^# Claude Code Configuration'; then
			printf '%s\n' "$dcf_cand" >>"$WORK/config.raw"
		else
			warn "ignoring $dcf_cand — no '# Claude Code Configuration' marker heading"
		fi
	done <"$WORK/config.candidates"

	# count_lines (awk) — NOT `grep -c`: on an empty file grep -c PRINTS "0" and EXITS 1,
	# so a `|| printf '0'` fallback fires too and yields "0\n0", which then breaks the
	# numeric test. Worse, such a fallback masks a genuine grep failure as zero and skips
	# the duplicate gate entirely — deploying N configs last-wins, the exact ambiguity
	# this function exists to make fatal.
	# Ambiguity feeds the SAME collisions pipeline every other exit-3 uses: detection
	# records, report_collisions() prints the banner, main() owns the exit. Exiting from
	# inside a discover_* function would bypass all three — its siblings only ever `die`
	# on infrastructure failure, never on a policy violation.
	dcf_count=$(count_lines "$WORK/config.raw")
	if [ "$dcf_count" -gt 1 ]; then
		dcf_a=$(sed -n '1p' "$WORK/config.raw")
		dcf_b=$(sed -n '2p' "$WORK/config.raw")
		printf 'config%sCLAUDE.md%s%s%s%s\n' "$TAB" "$TAB" "$dcf_a" "$TAB" "$dcf_b" >>"$WORK/collisions"
		return 0
	fi

	while IFS= read -r dcf_file; do
		[ -n "$dcf_file" ] || continue
		printf 'CLAUDE.md\t%s\n' "$dcf_file" >>"$WORK/config.tsv"
	done <"$WORK/config.raw"
}

# Contracts are JSON-Schema data-contract files, marked by the '*.schema.json' filename
# suffix (not a directory or frontmatter marker) — the same "discover by marker, anywhere
# under the root" rule as agents/skills. Deployed FLAT by basename (no directory nesting),
# so the basename itself is the sole identity; two schemas sharing a basename anywhere in
# the tree are therefore an ambiguous-source collision, same as an agent/skill name clash.
discover_contracts() {
	find "$FRAMEWORK_ROOT" \
		\( -name .git -o -name tests -o -path "$SCRIPT_DIR" -o -path "$FRAMEWORK_ROOT/deploy" \) -prune -o \
		-type f -name '*.schema.json' -print >"$WORK/contracts.raw" || die "find (contracts) failed"

	while IFS= read -r dct_file; do
		[ -n "$dct_file" ] || continue
		dct_name=$(basename "$dct_file")
		valid_name "$dct_name" || die "schema file has unsafe basename: $dct_file (name='$dct_name')"
		printf '%s\t%s\n' "$dct_name" "$dct_file" >>"$WORK/contracts.tsv"
	done <"$WORK/contracts.raw"
}

# ---------------------------------------------------------------------------
# Collision detection
# ---------------------------------------------------------------------------

# detect_collisions TSV CATEGORY -> append collision lines to $WORK/collisions.
# A collision is the same name mapping to two different sources.
detect_collisions() {
	dc_sorted="$WORK/collide.sorted"
	LC_ALL=C sort "$1" >"$dc_sorted" || die "sort failed during collision detection"
	awk -F "$TAB" -v cat="$2" '
		{
			if ($1 == name && $2 != first) {
				printf "%s\t%s\t%s\t%s\n", cat, $1, first, $2
			} else if ($1 != name) {
				name = $1
				first = $2
			}
		}
	' "$dc_sorted" >>"$WORK/collisions"
}

# ---------------------------------------------------------------------------
# Cross-reference validation (fail-fast, before any APPLY; also enforced under
# --dry-run). All three checks (CHECK 1: skill-ref resolution, CHECK 2: required-agents
# presence, CHECK 3: required-tools presence) run after collision detection and before
# agents/skills are used to build links.
# ---------------------------------------------------------------------------

# sanitize_for_report VALUE -> prints VALUE with TAB/CR/LF replaced by '?', so an
# untrusted string pulled from file content is always safe to embed in a TAB-delimited
# report line or echo to stderr without corrupting the field layout or forging
# additional (spoofed) report lines. VALUE is passed via ENVIRON (the same idiom as
# manifest_has), not piped as awk INPUT: piping would split on the default record
# separator, so a raw embedded newline in VALUE would never reach $0 as a literal
# character for gsub to match — ENVIRON reads it as one opaque string instead.
sanitize_for_report() {
	sfr_v=$1 awk 'BEGIN { v = ENVIRON["sfr_v"]; gsub(/[\t\r\n]/, "?", v); printf "%s", v }'
}

# check_skill_refs -> for every discovered agent, verify each name in its 'skills:'
# frontmatter list resolves to a discovered skill (matched by skill frontmatter 'name:').
# Populates $WORK/skill_ref_violations (agent-name TAB agent-file TAB skill-name) with
# one line per unresolved reference. A reference that is not itself a valid_name (e.g.
# contains a raw TAB, which would otherwise corrupt the TAB-delimited violations file) is
# recorded as its own "unsafe reference" violation, sanitized before being written.
check_skill_refs() {
	while IFS="$TAB" read -r csr_name csr_file; do
		[ -n "$csr_file" ] || continue
		fm_skills_list "$csr_file" >"$WORK/skill_refs.tmp" ||
			die "cannot read agent frontmatter: $csr_file"
		while IFS= read -r csr_skill; do
			[ -n "$csr_skill" ] || continue
			if ! valid_name "$csr_skill"; then
				csr_safe=$(sanitize_for_report "$csr_skill")
				printf '%s\t%s\tunsafe skill reference: %s\n' \
					"$csr_name" "$csr_file" "$csr_safe" >>"$WORK/skill_ref_violations"
				continue
			fi
			manifest_has "$WORK/skills.tsv" "$csr_skill" ||
				printf '%s\t%s\t%s\n' "$csr_name" "$csr_file" "$csr_skill" >>"$WORK/skill_ref_violations"
		done <"$WORK/skill_refs.tmp"
	done <"$WORK/agents.tsv"
}

# report_skill_ref_violations -> print every unresolved 'skills:' reference to stderr,
# plus a hint on how to skip the check outright.
report_skill_ref_violations() {
	printf '=== %s: UNRESOLVED SKILL REFERENCES ===\n' "$PROG" >&2
	LC_ALL=C sort "$WORK/skill_ref_violations" |
		while IFS="$TAB" read -r rsv_name rsv_file rsv_skill; do
			printf '  agent "%s" (%s) references undiscovered skill "%s"\n' \
				"$rsv_name" "$rsv_file" "$rsv_skill" >&2
		done
	printf '  skip this check with --no-verify-skill-refs\n' >&2
}

# split_csv_list RAW -> prints each non-empty token in RAW split on commas/whitespace, one
# per line. Shared tokenizer for required_agents_list and required_tools_list — their
# override/default precedence differs (see each), but the splitting itself is identical.
# Splitting is delegated to awk (already a hard dependency) rather than a second parser.
split_csv_list() {
	printf '%s' "$1" | awk '
		{
			n = split($0, parts, /[,[:space:]]+/)
			for (i = 1; i <= n; i++) {
				if (parts[i] != "") print parts[i]
			}
		}
	'
}

# required_agents_list -> prints the effective required-agent names, one per line:
#   1. the --required-agents override (comma/space separated; an empty string disables
#      the check), if the caller passed one; else
#   2. DEFAULT_REQUIRED_AGENTS, but ONLY when this run targets the deployer's OWN tree
#      (IS_OWN_TREE=1); else
#   3. empty (check disabled).
# DEFAULT_REQUIRED_AGENTS is specific to this framework's own agent roster, so it must
# NOT silently apply to an arbitrary/foreign/forked --source tree — a generic deployer's
# default should never turn a legitimate foreign deploy into a hard failure. A foreign
# tree opts in explicitly via --required-agents.
required_agents_list() {
	if [ "$ARG_REQUIRED_AGENTS_SET" -eq 1 ]; then
		ral_names=$ARG_REQUIRED_AGENTS
	elif [ "$IS_OWN_TREE" -eq 1 ]; then
		ral_names=$DEFAULT_REQUIRED_AGENTS
	else
		ral_names=""
	fi
	split_csv_list "$ral_names"
}

# check_required_agents -> verify every name in the effective required-agents list is
# among the discovered agents. Populates $WORK/missing_required_agents (one name per
# line) on violation; an empty required-agents list is a no-op (check disabled).
check_required_agents() {
	required_agents_list >"$WORK/required_agents.tsv"
	while IFS= read -r cra_name; do
		[ -n "$cra_name" ] || continue
		manifest_has "$WORK/agents.tsv" "$cra_name" ||
			printf '%s\n' "$cra_name" >>"$WORK/missing_required_agents"
	done <"$WORK/required_agents.tsv"
}

# report_missing_required_agents -> print every missing required agent to stderr, plus a
# hint on how to override or disable the check.
report_missing_required_agents() {
	printf '=== %s: MISSING REQUIRED AGENTS ===\n' "$PROG" >&2
	LC_ALL=C sort "$WORK/missing_required_agents" |
		while IFS= read -r rma_name; do
			printf '  required agent not discovered: "%s"\n' "$rma_name" >&2
		done
	printf '  override with --required-agents "a,b" or disable with --required-agents ""\n' >&2
}

# required_tools_list -> prints the effective required-tool SLOTS, one per line,
# mirroring required_agents_list's override precedence exactly:
#   1. the --required-tools override (comma/space separated; an empty string disables
#      the check), if the caller passed one; else
#   2. DEFAULT_REQUIRED_TOOLS, but ONLY when this run targets the deployer's OWN tree
#      (IS_OWN_TREE=1); else
#   3. empty (check disabled).
# A slot is either a plain command name ("git") or two alternatives joined by "|" (an
# OR-slot, e.g. "gpg|ssh-keygen") meaning at least one must be present — splitting on "|"
# happens in check_required_tools, not here; this function only tokenizes the LIST on
# commas/whitespace, so a bare "|" inside one token survives intact.
required_tools_list() {
	if [ "$ARG_REQUIRED_TOOLS_SET" -eq 1 ]; then
		rtl_names=$ARG_REQUIRED_TOOLS
	elif [ "$IS_OWN_TREE" -eq 1 ]; then
		rtl_names=$DEFAULT_REQUIRED_TOOLS
	else
		rtl_names=""
	fi
	split_csv_list "$rtl_names"
}

# check_required_tools -> verify every slot in the effective required-tools list is
# satisfied: a plain slot ("git") must resolve via `have`; an OR-slot ("gpg|ssh-keygen")
# passes if EITHER alternative resolves and fails only when BOTH are absent. Populates
# $WORK/missing_required_tools (one slot per line, in its original "a" or "a|b" form) with
# EVERY unsatisfied slot — it does not stop at the first miss, so the report is complete.
# A slot is a supported OR-slot only with EXACTLY one "|" between exactly two NON-EMPTY
# alternatives:
#   - two or more "|" characters cannot be split into a sensible pair (e.g.
#     "gpg|ssh-keygen|foo" would yield a bogus alt2 of "ssh-keygen|foo" that can never
#     resolve) and is rejected loudly via die_usage rather than silently mis-split.
#   - a single "|" with an EMPTY side ("|foo", "foo|", or bare "|") is equally malformed:
#     `have ""` always fails, so an empty alternative can never resolve and the slot could
#     never mean anything but "the other side is mandatory" — reject it instead of letting
#     it silently fall through with a garbled report line. This same check is what catches
#     a spaced OR-slot like "gpg | ssh-keygen": split_csv_list's tokenizer splits on
#     whitespace too, so the spaces fragment it into THREE tokens ("gpg", "|",
#     "ssh-keygen") — the lone "|" token has both sides empty and dies right here, rather
#     than silently turning an "either one" requirement into "both mandatory, plus a bogus
#     always-missing slot".
check_required_tools() {
	required_tools_list >"$WORK/required_tools.tsv"
	while IFS= read -r crt_slot; do
		[ -n "$crt_slot" ] || continue
		case $crt_slot in
		*'|'*'|'*)
			die_usage "malformed --required-tools slot (an OR-slot supports exactly one '|' between two alternatives): $crt_slot"
			;;
		*'|'*)
			crt_alt1=${crt_slot%%|*}
			crt_alt2=${crt_slot#*|}
			if [ -z "$crt_alt1" ] || [ -z "$crt_alt2" ]; then
				die_usage "malformed --required-tools slot (an OR-slot needs two non-empty alternatives, got \"$crt_slot\") - do not put spaces around the '|', e.g. use \"gpg|ssh-keygen\" not \"gpg | ssh-keygen\""
			fi
			have "$crt_alt1" || have "$crt_alt2" || printf '%s\n' "$crt_slot" >>"$WORK/missing_required_tools"
			;;
		*)
			have "$crt_slot" || printf '%s\n' "$crt_slot" >>"$WORK/missing_required_tools"
			;;
		esac
	done <"$WORK/required_tools.tsv"
}

# tool_reason NAME -> prints a one-line reason NAME is needed at runtime by the deployed
# agents/skills (this is about what the DEPLOYED framework needs when it runs, never
# about deploy.sh's own toolchain — that is check_deps).
tool_reason() {
	case $1 in
	git)
		printf 'needed for git-operator: branch/commit/push/tag and identity resolution (procedure-git-ops, procedure-git-identity)'
		;;
	gh)
		printf 'needed for GitHub account confirmation (procedure-git-auth) and the project-manager GitHub issues/PR skills (procedure-gh-issues, procedure-gh-pr)'
		;;
	jq)
		printf 'needed for the GTD inbox skills (flow-inbox, procedure-inbox-capture) and the entire Jira surface (procedure-jira, procedure-jira-auth)'
		;;
	curl)
		printf 'needed for the Jira surface (procedure-jira, procedure-jira-auth) - every Jira REST call goes through it'
		;;
	gpg)
		printf 'needed, as ONE of two alternatives (see ssh-keygen), for git commit/tag signing when gpg.format=openpgp (procedure-git-identity, procedure-git-ops)'
		;;
	ssh-keygen)
		printf 'needed, as ONE of two alternatives (see gpg), for git commit/tag signing when gpg.format=ssh (procedure-git-identity, procedure-git-ops)'
		;;
	*)
		printf 'required at runtime by the deployed agents/skills (see --required-tools)'
		;;
	esac
}

# tool_install_macos / tool_install_debian / tool_install_general NAME -> print accurate,
# per-OS install guidance for NAME. deploy.sh never RUNS any of these commands itself —
# it only detects, reports, and suggests; installing system packages is an outward,
# system-mutating action left to a human (or an agent the human directs) to run.
tool_install_macos() {
	case $1 in
	git) printf 'brew install git' ;;
	gh) printf 'brew install gh' ;;
	jq) printf 'brew install jq' ;;
	curl) printf 'brew install curl (usually already present)' ;;
	gpg) printf 'brew install gnupg' ;;
	ssh-keygen) printf 'usually preinstalled; if missing, brew install openssh' ;;
	*) printf 'use Homebrew: brew install <package>' ;;
	esac
}

tool_install_debian() {
	case $1 in
	git) printf 'sudo apt-get install git' ;;
	gh) printf 'needs GitHub own apt repository added first (a bare "apt-get install gh" does not work on stock Ubuntu) - see https://cli.github.com/' ;;
	jq) printf 'sudo apt-get install jq' ;;
	curl) printf 'sudo apt-get install curl' ;;
	gpg) printf 'sudo apt-get install gnupg' ;;
	ssh-keygen) printf 'sudo apt-get install openssh-client' ;;
	*) printf 'use your distro package manager, e.g. apt-get install <package>' ;;
	esac
}

tool_install_general() {
	case $1 in
	git) printf 'https://git-scm.com/downloads' ;;
	gh) printf 'https://cli.github.com/' ;;
	jq) printf 'https://jqlang.github.io/jq/' ;;
	curl) printf 'https://curl.se/' ;;
	gpg) printf 'https://gnupg.org/' ;;
	ssh-keygen) printf 'https://www.openssh.com/' ;;
	*) printf 'consult your OS package manager or the relevant official site' ;;
	esac
}

# print_tool_guidance NAME -> print NAME's reason and per-OS install guidance to stderr
# (the block shared by both the plain-slot and OR-slot arms of report_missing_required_tools).
# Does NOT touch $WORK/missing_tools_flat — the caller decides what goes into that file,
# since an OR-slot and a plain slot contribute to it differently (see SH-003 below).
print_tool_guidance() {
	ptg_name=$1
	printf '    reason ("%s"): %s\n' "$ptg_name" "$(tool_reason "$ptg_name")" >&2
	printf '    install "%s" - macOS: %s\n' "$ptg_name" "$(tool_install_macos "$ptg_name")" >&2
	printf '    install "%s" - Debian/Ubuntu: %s\n' "$ptg_name" "$(tool_install_debian "$ptg_name")" >&2
	printf '    install "%s" - general: %s\n' "$ptg_name" "$(tool_install_general "$ptg_name")" >&2
}

# report_missing_required_tools -> print every missing required-tool slot to stderr, each
# with its reason and per-OS install guidance, then ONE consolidated "agentic install"
# suggestion listing every actually-missing command name (never the "a|b" slot
# notation) built dynamically from what is actually missing. deploy.sh NEVER executes an
# install itself — see tool_install_*.
#
# Deliberate divergence from the CHECK1/CHECK2 one-line-per-violation convention (see
# report_skill_ref_violations / report_missing_required_agents): a missing TOOL is
# actionable in a way a missing agent name is not (there is somewhere concrete to go
# install it), so this report enriches each violation with a reason plus per-OS install
# guidance and a closing agentic-install paragraph. This is CHECK-3-only enrichment, not
# drift from the shared convention.
report_missing_required_tools() {
	printf '=== %s: MISSING REQUIRED RUNTIME TOOLS ===\n' "$PROG" >&2
	: >"$WORK/missing_tools_flat"
	LC_ALL=C sort "$WORK/missing_required_tools" |
		while IFS= read -r rmt_slot; do
			[ -n "$rmt_slot" ] || continue
			case $rmt_slot in
			*'|'*)
				rmt_alt1=${rmt_slot%%|*}
				rmt_alt2=${rmt_slot#*|}
				printf '  missing required tool: "%s" or "%s" (either one satisfies this requirement)\n' \
					"$rmt_alt1" "$rmt_alt2" >&2
				print_tool_guidance "$rmt_alt1"
				print_tool_guidance "$rmt_alt2"
				# Only ONE representative alternative goes into the agentic-install
				# suggestion below — flattening BOTH would tell an agent to install both
				# when only one is needed, contradicting the "either one satisfies this
				# requirement" line above (SH-003).
				printf '%s\n' "$rmt_alt1" >>"$WORK/missing_tools_flat"
				;;
			*)
				printf '  missing required tool: "%s"\n' "$rmt_slot" >&2
				print_tool_guidance "$rmt_slot"
				printf '%s\n' "$rmt_slot" >>"$WORK/missing_tools_flat"
				;;
			esac
		done
	printf '  override with --required-tools "a,b" or disable with --required-tools ""\n' >&2

	rmt_joined=$(awk '{printf "%s%s", (NR > 1 ? " " : ""), $0}' "$WORK/missing_tools_flat")
	printf '\nTo install these automatically with an AI agent, run Claude Code (or another agent) and say:\n' >&2
	printf '  "Install these missing dependencies on my system: %s. Use the appropriate package manager for my OS (Homebrew on macOS, apt on Debian/Ubuntu) and confirm each install succeeded."\n' \
		"$rmt_joined" >&2
}

# ---------------------------------------------------------------------------
# Content comparison
# ---------------------------------------------------------------------------

# same_content SRC TARGET -> exit 0 if TARGET (a real copy) is identical to SRC.
# Files compared with cmp; directories with diff -qr (if diff is unavailable, treat as
# different so we never clobber an unverifiable copy).
same_content() {
	if [ -d "$1" ]; then
		have diff || return 1
		diff -qr "$1" "$2" >/dev/null 2>&1
	else
		[ -f "$2" ] || return 1
		cmp -s "$1" "$2"
	fi
}

# ---------------------------------------------------------------------------
# Deploy one item
# ---------------------------------------------------------------------------

# config_backup_and_replace TARGET_PATH SRC NAME RSRC
# For the operating contract ONLY: an existing FOREIGN CLAUDE.md at the target — a real
# file, or a symlink resolving outside the framework — is preserved to a timestamped
# backup beside it ("<target>.backup.<RUN_TS>") and then replaced with the framework's
# symlink, rather than left untouched as DIVERGED. Losing a hand-written operating
# contract is not acceptable, so the replace is made non-destructive instead of refused.
# The backup is faithful: `cp -RP` copies a regular file's content, and preserves a
# symlink as-is (never dereferences it). Agents/skills/contracts keep DIVERGED protection;
# only the config category routes here.
config_backup_and_replace() {
	cbr_tp=$1
	cbr_src=$2
	cbr_name=$3
	cbr_rsrc=$4
	cbr_bak="$cbr_tp.backup.$RUN_TS"
	record backup config "$cbr_name" "$cbr_bak"
	record replace config "$cbr_name" "$cbr_rsrc"
	if [ "$APPLY" -eq 1 ]; then
		cp -RP "$cbr_tp" "$cbr_bak" || die "failed to back up existing $cbr_tp to $cbr_bak"
		rm -rf "$cbr_tp" || die "failed to remove $cbr_tp"
		ln -sfn "$cbr_src" "$cbr_tp" || die "failed to link $cbr_tp"
	fi
}

# deploy_symlink CATEGORY NAME SRC TARGET_PATH
# Symlink deployment with idempotency, safe copy replacement and diverged protection.
deploy_symlink() {
	dl_cat=$1
	dl_name=$2
	dl_src=$3
	dl_tp=$4

	# Only the config row carries its source into the report: its name is the fixed literal
	# "CLAUDE.md", so without the path an operator cannot tell WHICH file became the
	# operating contract. Agents and skills are named after their source, so a path there
	# would be noise.
	if [ "$dl_cat" = config ]; then dl_rsrc=$dl_src; else dl_rsrc=""; fi

	if [ -h "$dl_tp" ]; then
		dl_raw=$(readlink_abs "$dl_tp") || dl_raw=""
		if [ "$dl_raw" = "$dl_src" ]; then
			record skip "$dl_cat" "$dl_name" "$dl_rsrc"
			return 0
		fi
		# An existing symlink that resolves OUTSIDE the framework root is a user artifact.
		# For every category but the operating contract, protect it (DIVERGED) rather than
		# clobbering. The contract is instead backed up then replaced (see
		# config_backup_and_replace). Only relink framework-owned links.
		if ! link_inside_framework "$dl_tp"; then
			if [ "$dl_cat" = config ]; then
				config_backup_and_replace "$dl_tp" "$dl_src" "$dl_name" "$dl_rsrc"
				return 0
			fi
			record diverged "$dl_cat" "$dl_name" "$dl_rsrc"
			return 0
		fi
		record replace "$dl_cat" "$dl_name" "$dl_rsrc"
		if [ "$APPLY" -eq 1 ]; then
			ln -sfn "$dl_src" "$dl_tp" || die "failed to relink $dl_tp"
		fi
	elif [ -e "$dl_tp" ]; then
		if same_content "$dl_src" "$dl_tp"; then
			record replace "$dl_cat" "$dl_name" "$dl_rsrc"
			if [ "$APPLY" -eq 1 ]; then
				rm -rf "$dl_tp" || die "failed to remove $dl_tp"
				ln -sfn "$dl_src" "$dl_tp" || die "failed to link $dl_tp"
			fi
		elif [ "$dl_cat" = config ]; then
			config_backup_and_replace "$dl_tp" "$dl_src" "$dl_name" "$dl_rsrc"
		else
			record diverged "$dl_cat" "$dl_name" "$dl_rsrc"
		fi
	else
		record create "$dl_cat" "$dl_name" "$dl_rsrc"
		if [ "$APPLY" -eq 1 ]; then
			ln -sfn "$dl_src" "$dl_tp" || die "failed to link $dl_tp"
		fi
	fi
}

# deploy_copy CATEGORY NAME SRC TARGET_PATH
# Copy deployment for agents under --copy-agents. Copies are the managed state, so a
# differing regular file is updated (REPLACE), not treated as diverged.
deploy_copy() {
	dc_cat=$1
	dc_name=$2
	dc_src=$3
	dc_tp=$4

	if [ -h "$dc_tp" ]; then
		# Protect a user-owned (foreign) symlink; only replace framework-owned links.
		if ! link_inside_framework "$dc_tp"; then
			record diverged "$dc_cat" "$dc_name"
			return 0
		fi
		record replace "$dc_cat" "$dc_name"
		if [ "$APPLY" -eq 1 ]; then
			rm -f "$dc_tp" || die "failed to remove link $dc_tp"
			cp "$dc_src" "$dc_tp" || die "failed to copy $dc_src"
		fi
	elif [ -e "$dc_tp" ]; then
		if cmp -s "$dc_src" "$dc_tp"; then
			record skip "$dc_cat" "$dc_name"
		else
			record replace "$dc_cat" "$dc_name"
			if [ "$APPLY" -eq 1 ]; then
				cp "$dc_src" "$dc_tp" || die "failed to copy $dc_src"
			fi
		fi
	else
		record create "$dc_cat" "$dc_name"
		if [ "$APPLY" -eq 1 ]; then
			cp "$dc_src" "$dc_tp" || die "failed to copy $dc_src"
		fi
	fi
}

# ---------------------------------------------------------------------------
# Processing (PLAN + APPLY)
# ---------------------------------------------------------------------------

process_agents() {
	[ -s "$WORK/agents.tsv" ] || return 0
	LC_ALL=C sort "$WORK/agents.tsv" >"$WORK/agents.sorted"
	while IFS="$TAB" read -r pa_name pa_src; do
		[ -n "$pa_name" ] || continue
		pa_tp="$TARGET_DIR/agents/$pa_name.md"
		if [ "$COPY_AGENTS" -eq 1 ]; then
			deploy_copy agent "$pa_name" "$pa_src" "$pa_tp"
		else
			deploy_symlink agent "$pa_name" "$pa_src" "$pa_tp"
		fi
	done <"$WORK/agents.sorted"
}

process_skills() {
	[ -s "$WORK/skills.tsv" ] || return 0
	LC_ALL=C sort "$WORK/skills.tsv" >"$WORK/skills.sorted"
	while IFS="$TAB" read -r ps_name ps_src; do
		[ -n "$ps_name" ] || continue
		ps_tp="$TARGET_DIR/skills/$ps_name"
		deploy_symlink skill "$ps_name" "$ps_src" "$ps_tp"
	done <"$WORK/skills.sorted"
}

process_config() {
	[ -s "$WORK/config.tsv" ] || return 0
	while IFS="$TAB" read -r pc_name pc_src; do
		[ -n "$pc_name" ] || continue
		deploy_symlink config "$pc_name" "$pc_src" "$TARGET_DIR/CLAUDE.md"
	done <"$WORK/config.tsv"
}

process_contracts() {
	[ -s "$WORK/contracts.tsv" ] || return 0
	LC_ALL=C sort "$WORK/contracts.tsv" >"$WORK/contracts.sorted"
	while IFS="$TAB" read -r pco_name pco_src; do
		[ -n "$pco_name" ] || continue
		pco_tp="$TARGET_DIR/crucible/contracts/$pco_name"
		deploy_symlink contract "$pco_name" "$pco_src" "$pco_tp"
	done <"$WORK/contracts.sorted"
}

# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------

# prune_dir DIR CATEGORY MANIFEST STRIP_MD
# Remove stale framework symlinks under DIR: entries that ARE symlinks resolving INSIDE
# the framework root but whose name is no longer a discovered item. Never touches real
# files/dirs or foreign symlinks.
prune_dir() {
	pd_dir=$1
	pd_cat=$2
	pd_manifest=$3
	pd_strip=$4

	[ -d "$pd_dir" ] || return 0

	for pd_entry in "$pd_dir"/*; do
		[ -h "$pd_entry" ] || continue
		link_inside_framework "$pd_entry" || continue
		pd_base=$(basename "$pd_entry")
		if [ "$pd_strip" -eq 1 ]; then
			pd_name=${pd_base%.md}
		else
			pd_name=$pd_base
		fi
		if manifest_has "$pd_manifest" "$pd_name"; then
			continue
		fi
		record prune "$pd_cat" "$pd_name"
		if [ "$APPLY" -eq 1 ]; then
			rm -f "$pd_entry" || die "failed to prune $pd_entry"
		fi
	done
}

prune_config() {
	pc_tp="$TARGET_DIR/CLAUDE.md"
	[ -h "$pc_tp" ] || return 0
	# Only a candidate when no CLAUDE.md source is currently discovered.
	[ -s "$WORK/config.tsv" ] && return 0
	link_inside_framework "$pc_tp" || return 0
	# Deleting the operating contract is NOT symmetric with pruning a stale agent or skill:
	# it removes every invariant the assistant runs under, and a session that loads no
	# contract gives no sign of it. Zero-discovered can mean "deliberately removed" OR
	# "renamed / moved into a pruned directory / behind a broken symlink" — so say so
	# loudly rather than treating silence as intent.
	warn "no CLAUDE.md discovered under $FRAMEWORK_ROOT — the deployed operating contract at $pc_tp will be PRUNED"
	record prune config CLAUDE.md
	if [ "$APPLY" -eq 1 ]; then
		rm -f "$pc_tp" || die "failed to prune $pc_tp"
	fi
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

count_lines() {
	awk 'END { print NR + 0 }' "$1"
}

report_section() {
	rs_title=$1
	rs_file=$2
	rs_count=$(count_lines "$rs_file")
	printf '%s (%s):\n' "$rs_title" "$rs_count"
	if [ "$rs_count" -gt 0 ]; then
		# A 3rd field (the resolved source) is optional and shown when present. The config
		# row carries it because "CLAUDE.md" alone cannot tell an operator WHICH file just
		# became the operating contract — under marker-based discovery that is variable,
		# and a change of source would otherwise render identically to no change at all.
		LC_ALL=C sort "$rs_file" | while IFS="$TAB" read -r rs_cat rs_name rs_src; do
			if [ -n "$rs_src" ]; then
				printf '  %-8s %s  <- %s\n' "$rs_cat" "$rs_name" "$rs_src"
			else
				printf '  %-8s %s\n' "$rs_cat" "$rs_name"
			fi
		done
	fi
}

report() {
	printf '=== %s report ===\n' "$PROG"
	printf 'Source : %s\n' "$FRAMEWORK_ROOT"
	printf 'Target : %s\n' "$TARGET_DIR"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'Mode   : dry-run (no changes applied)\n'
	else
		printf 'Mode   : apply\n'
	fi
	printf 'Options: copy-agents=%s prune=%s only=%s\n' \
		"$COPY_AGENTS" \
		"$([ "$NO_PRUNE" -eq 1 ] && printf off || printf on)" \
		"$([ -n "$ONLY" ] && printf '%s' "$ONLY" || printf all)"
	printf '\n'
	report_section CREATE "$WORK/act_create"
	report_section SKIP "$WORK/act_skip"
	report_section REPLACE "$WORK/act_replace"
	report_section BACKUP "$WORK/act_backup"
	report_section DIVERGED "$WORK/act_diverged"
	report_section PRUNE "$WORK/act_prune"
}

report_collisions() {
	printf '=== %s: COLLISIONS ===\n' "$PROG" >&2
	LC_ALL=C sort "$WORK/collisions" | while IFS="$TAB" read -r rc_cat rc_name rc_a rc_b; do
		printf '  %s "%s":\n    %s\n    %s\n' "$rc_cat" "$rc_name" "$rc_a" "$rc_b" >&2
	done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--no-prune)
			NO_PRUNE=1
			shift
			;;
		--copy-agents)
			COPY_AGENTS=1
			shift
			;;
		--no-verify-skill-refs)
			SKIP_SKILL_REFS_CHECK=1
			shift
			;;
		--target)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--target requires a non-empty argument"
			ARG_TARGET=$2
			shift 2
			;;
		--target=*)
			ARG_TARGET=${1#--target=}
			[ -n "$ARG_TARGET" ] || die_usage "--target requires a non-empty argument"
			shift
			;;
		--source)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--source requires a non-empty argument"
			ARG_SOURCE=$2
			shift 2
			;;
		--source=*)
			ARG_SOURCE=${1#--source=}
			[ -n "$ARG_SOURCE" ] || die_usage "--source requires a non-empty argument"
			shift
			;;
		--only)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--only requires a non-empty argument"
			ONLY=$2
			shift 2
			;;
		--only=*)
			ONLY=${1#--only=}
			[ -n "$ONLY" ] || die_usage "--only requires a non-empty argument"
			shift
			;;
		--required-agents)
			# Unlike --only/--source/--target, an EMPTY argument is valid here (it
			# deliberately disables the required-agents check), so only the argument's
			# presence is required, not its non-emptiness.
			[ $# -ge 2 ] || die_usage "--required-agents requires an argument"
			ARG_REQUIRED_AGENTS=$2
			ARG_REQUIRED_AGENTS_SET=1
			shift 2
			;;
		--required-agents=*)
			ARG_REQUIRED_AGENTS=${1#--required-agents=}
			ARG_REQUIRED_AGENTS_SET=1
			shift
			;;
		--required-tools)
			# Unlike --only/--source/--target, an EMPTY argument is valid here (it
			# deliberately disables the required-tools check), so only the argument's
			# presence is required, not its non-emptiness.
			[ $# -ge 2 ] || die_usage "--required-tools requires an argument"
			ARG_REQUIRED_TOOLS=$2
			ARG_REQUIRED_TOOLS_SET=1
			shift 2
			;;
		--required-tools=*)
			ARG_REQUIRED_TOOLS=${1#--required-tools=}
			ARG_REQUIRED_TOOLS_SET=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die_usage "unknown option: $1"
			;;
		*)
			die_usage "unexpected argument: $1"
			;;
		esac
	done

	case $ONLY in
	"" | agents | skills | config | contract) : ;;
	*) die_usage "--only must be one of: agents, skills, config, contract" ;;
	esac
}

apply_scope() {
	case $ONLY in
	agents)
		RUN_AGENTS=1
		RUN_SKILLS=0
		RUN_CONFIG=0
		RUN_CONTRACTS=0
		;;
	skills)
		RUN_AGENTS=0
		RUN_SKILLS=1
		RUN_CONFIG=0
		RUN_CONTRACTS=0
		;;
	config)
		RUN_AGENTS=0
		RUN_SKILLS=0
		RUN_CONFIG=1
		RUN_CONTRACTS=0
		;;
	contract)
		RUN_AGENTS=0
		RUN_SKILLS=0
		RUN_CONFIG=0
		RUN_CONTRACTS=1
		;;
	*) : ;;
	esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	parse_args "$@"
	check_deps
	apply_scope

	[ "$DRY_RUN" -eq 1 ] && APPLY=0

	SCRIPT_DIR=$(resolve_script_dir "$0")
	own_root=$(realpath_portable "$SCRIPT_DIR/..") || own_root=""

	# Resolve source (framework root).
	if [ -n "$ARG_SOURCE" ]; then
		[ -d "$ARG_SOURCE" ] || die "source is not a directory: $ARG_SOURCE"
		FRAMEWORK_ROOT=$(realpath_portable "$ARG_SOURCE") || die "cannot resolve source: $ARG_SOURCE"
	else
		[ -n "$own_root" ] || die "cannot resolve default source"
		FRAMEWORK_ROOT=$own_root
	fi
	[ -d "$FRAMEWORK_ROOT" ] || die "framework root is not a directory: $FRAMEWORK_ROOT"

	# Determine whether this run targets the deployer's OWN tree (default source), so
	# DEFAULT_REQUIRED_AGENTS (see required_agents_list) applies only there.
	if [ "$FRAMEWORK_ROOT" = "$own_root" ]; then
		IS_OWN_TREE=1
	else
		IS_OWN_TREE=0
	fi

	# Resolve target.
	if [ -n "$ARG_TARGET" ]; then
		TARGET_DIR=$(abspath "$ARG_TARGET")
	else
		[ -n "${HOME:-}" ] || die "HOME is not set; use --target"
		TARGET_DIR=$(abspath "$HOME/.claude")
	fi

	# Refuse a self-referential run where the target sits inside the framework root.
	canon_tgt=$(canon_target "$TARGET_DIR")
	if [ "$canon_tgt" = "$FRAMEWORK_ROOT" ]; then
		die "target must not be the framework root: $FRAMEWORK_ROOT"
	fi
	case $canon_tgt in
	"$FRAMEWORK_ROOT"/*) die "target must not be inside the framework root: $canon_tgt" ;;
	esac

	WORK=$(mktemp -d 2>/dev/null) || die "mktemp failed"
	trap cleanup EXIT INT TERM

	# One UTC stamp per run, used for any CLAUDE.md backup name so a dry-run preview and
	# the applied backup path agree, and repeat deploys never clobber a prior backup.
	RUN_TS=$(date -u +%Y%m%dT%H%M%SZ) || die "date failed"

	# Initialize manifests and action files.
	for f in agents.tsv skills.tsv config.tsv contracts.tsv collisions \
		skill_ref_violations missing_required_agents missing_required_tools \
		act_create act_skip act_replace act_backup act_diverged act_prune; do
		: >"$WORK/$f"
	done

	# DISCOVER
	[ "$RUN_SKILLS" -eq 1 ] && discover_skills
	[ "$RUN_AGENTS" -eq 1 ] && discover_agents
	[ "$RUN_CONFIG" -eq 1 ] && discover_config
	[ "$RUN_CONTRACTS" -eq 1 ] && discover_contracts

	# COLLISION detection (hard error, before any apply).
	[ "$RUN_AGENTS" -eq 1 ] && detect_collisions "$WORK/agents.tsv" agent
	[ "$RUN_SKILLS" -eq 1 ] && detect_collisions "$WORK/skills.tsv" skill
	[ "$RUN_CONTRACTS" -eq 1 ] && detect_collisions "$WORK/contracts.tsv" contract
	if [ -s "$WORK/collisions" ]; then
		report_collisions
		exit 3
	fi

	# CHECK 1: every agent's 'skills:' frontmatter reference must resolve to a discovered
	# skill. Explicitly disabled by --no-verify-skill-refs (silent, intentional); needs
	# both agents and skills in --only scope to be meaningful, so a scope that excludes
	# either SKIPS it too, but with a warning (an --only side effect is not obviously an
	# intentional disable of this specific check).
	if [ "$SKIP_SKILL_REFS_CHECK" -eq 1 ]; then
		:
	elif [ "$RUN_AGENTS" -eq 1 ] && [ "$RUN_SKILLS" -eq 1 ]; then
		check_skill_refs
	else
		warn "'skills:' reference check (Check 1) skipped: agents and/or skills are outside --only scope"
	fi
	if [ -s "$WORK/skill_ref_violations" ]; then
		report_skill_ref_violations
		exit 4
	fi

	# CHECK 2: every configured required agent must be discovered. Disabled entirely by
	# --required-agents "" (silent, intentional); skipped (with a warning, same reasoning
	# as above) when agents are outside --only scope.
	if [ "$RUN_AGENTS" -eq 1 ]; then
		check_required_agents
	else
		warn "required-agents check (Check 2) skipped: agents are outside --only scope"
	fi
	if [ -s "$WORK/missing_required_agents" ]; then
		report_missing_required_agents
		exit 5
	fi

	# CHECK 3: every configured required runtime tool must be present (checked via PATH
	# lookup; an OR-slot like "gpg|ssh-keygen" needs only one alternative). Disabled
	# entirely by --required-tools "" (silent, intentional; also the default outcome for
	# a foreign --source tree — see required_tools_list). Unlike CHECK 1/2 this is NOT
	# gated by --only scope: --only controls WHICH ARTIFACT TYPES get deployed, not which
	# OS-level tools the deployed agents/skills need at runtime, so this always runs when
	# otherwise enabled, regardless of --only.
	check_required_tools
	if [ -s "$WORK/missing_required_tools" ]; then
		report_missing_required_tools
		exit 6
	fi

	# APPLY setup (create target dirs) — only when actually applying.
	if [ "$APPLY" -eq 1 ]; then
		mkdir -p "$TARGET_DIR" || die "cannot create target: $TARGET_DIR"
		[ "$RUN_AGENTS" -eq 1 ] && { mkdir -p "$TARGET_DIR/agents" || die "cannot create agents dir"; }
		[ "$RUN_SKILLS" -eq 1 ] && { mkdir -p "$TARGET_DIR/skills" || die "cannot create skills dir"; }
		[ "$RUN_CONTRACTS" -eq 1 ] && { mkdir -p "$TARGET_DIR/crucible/contracts" || die "cannot create contracts dir"; }
	fi

	# PLAN + APPLY
	[ "$RUN_AGENTS" -eq 1 ] && process_agents
	[ "$RUN_SKILLS" -eq 1 ] && process_skills
	[ "$RUN_CONFIG" -eq 1 ] && process_config
	[ "$RUN_CONTRACTS" -eq 1 ] && process_contracts

	# PRUNE
	if [ "$NO_PRUNE" -eq 0 ]; then
		[ "$RUN_AGENTS" -eq 1 ] && prune_dir "$TARGET_DIR/agents" agent "$WORK/agents.tsv" 1
		[ "$RUN_SKILLS" -eq 1 ] && prune_dir "$TARGET_DIR/skills" skill "$WORK/skills.tsv" 0
		[ "$RUN_CONFIG" -eq 1 ] && prune_config
		[ "$RUN_CONTRACTS" -eq 1 ] && prune_dir "$TARGET_DIR/crucible/contracts" contract "$WORK/contracts.tsv" 0
	fi

	# REPORT
	report
}

main "$@"
