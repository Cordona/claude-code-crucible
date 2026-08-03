#!/usr/bin/env sh
# lib/hub-discovery.sh — THE discovery engine. Walks a framework source tree,
#                         applies lib/hub-domains.sh's structural rules, and
#                         produces the two tables every other module reads:
#
#   HUB_UNITS   group<TAB>name<TAB>kind<TAB>src<TAB>display
#   HUB_GROUPS  group<TAB>label<TAB>domain<TAB>role<TAB>selkind<TAB>selkey<TAB>atomic<TAB>units
#
# Sourced after lib/hub-common.sh and lib/hub-domains.sh. Not executable on its
# own.
#
# A UNIT is one thing the hub symlinks into the target: an agent (one .md file,
# deployed to <target>/agents/<name>.md) or a skill (one directory containing
# SKILL.md, deployed to <target>/skills/<name>). Identity is the frontmatter
# 'name:' field, exactly as the underlying deployment already defines it — the
# path decides WHICH GROUP a unit belongs to and HOW it is displayed; the
# frontmatter decides what it is called. Nothing anywhere in the hub enumerates
# a unit by name.
#
# WHY two tables rather than one: the group table carries per-group facts that
# would otherwise be re-derived at every consumer (its display label, whether
# it is atomic, how many units it holds). Both are built by ONE scan, and every
# screen streams them — no consumer ever re-walks the filesystem.
#
# PERFORMANCE: exactly three subprocess-heavy stages, each run ONCE per hub
# invocation: the find(1) walks, one awk that reads every candidate's
# frontmatter (a single process for the whole tree, not one per file), and one
# awk that computes display names and the group table. This is what keeps the
# scan inside the spec's sub-100ms expectation on a few hundred files.
#
# Portability: POSIX sh only. -maxdepth is used (a universal BSD+GNU find
# extension, already relied on elsewhere in this repo).

# PRUNED DIRECTORY NAMES, applied uniformly to every walk below: `tests` (a
# skill's own test fixtures contain .md files that are emphatically not agents)
# and `.git`. The two prune terms are written out literally in each find(1)
# invocation rather than assembled from a shared variable: round-tripping
# shell-quoted find primaries through a variable is itself a quoting hazard, and
# two short identical clauses are the cheaper, safer duplication.
#
# ---------------------------------------------------------------------------
# Low-level walks.
# ---------------------------------------------------------------------------

# hub_disc_skill_dirs DIR [MAXDEPTH_ARGS...] -> one directory path per line for
# every skill (a directory holding SKILL.md) at or under DIR. Prints nothing
# when DIR does not exist.
#
# The `sed` strips the /SKILL.md suffix in one process instead of forking dirname
# once per hit.
hub_disc_skill_dirs() {
	hdsd_dir=$1
	shift
	[ -d "$hdsd_dir" ] || return 0
	find "$hdsd_dir" "$@" \( -name tests -o -name .git \) -prune -o \
		-type f -name SKILL.md ! -name 'template-*' -print 2>/dev/null |
		sed 's|/SKILL\.md$||' | LC_ALL=C sort
}

# hub_disc_agent_files DIR [MAXDEPTH_ARGS...] -> one file path per line for
# every agent-shaped markdown file at or under DIR (any *.md that is not a
# SKILL.md and not a template). Prints nothing when DIR does not exist.
hub_disc_agent_files() {
	hdaf_dir=$1
	shift
	[ -d "$hdaf_dir" ] || return 0
	find "$hdaf_dir" "$@" \( -name tests -o -name .git \) -prune -o \
		-type f -name '*.md' ! -name SKILL.md ! -name 'template-*' -print 2>/dev/null |
		LC_ALL=C sort
}

# hub_disc_contract_files SRC -> one *.schema.json path per line, anywhere
# under SRC. Contracts are part of the first-run bundle, never a domain unit,
# so they are collected separately from the unit tables.
hub_disc_contract_files() {
	[ -d "$1" ] || return 0
	find "$1" \( -name tests -o -name .git -o -path "$1/deploy" -o -path "$1/templates" \) -prune -o \
		-type f -name '*.schema.json' ! -name 'template-*' -print 2>/dev/null | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Candidate collection — path shapes to (group, kind, path) rows.
#
# Every emitter appends to HUB_DISC_OUT and reads HUB_DISC_GROUP /
# HUB_DISC_GIDX_PAD, set by hub_disc_begin_group. Group ORDER is captured as a
# zero-padded index rather than left to the group key's alphabetical accident,
# because the order groups are declared in below IS the order every screen
# renders them in (selectable groups before their domain's baseline, domains in
# HUB_DOMAIN_KEYS order, cross-domain last).
#
# hub_disc_begin_group must only ever be called from the TOP-LEVEL shell, never
# from inside a `cmd | while read` body — that body runs in a subshell and its
# increment of HUB_DISC_GIDX would be silently discarded. Every loop below
# therefore reads from a redirected file (`done <"$file"`), never from a pipe.
# ---------------------------------------------------------------------------

hub_disc_begin_group() {
	HUB_DISC_GIDX=$((HUB_DISC_GIDX + 1))
	HUB_DISC_GROUP=$1
	HUB_DISC_GIDX_PAD=$(printf '%03d' "$HUB_DISC_GIDX")
}

# hub_disc_emit_agent PATH -> one agent candidate row. Column 3 is a kind RANK
# (1 agent, 2 skill) so the final sort groups agents ahead of skills within a
# group without a second lookup table.
hub_disc_emit_agent() {
	printf '%s\t%s\t1\tagent\t%s\t%s\n' \
		"$HUB_DISC_GIDX_PAD" "$HUB_DISC_GROUP" "$1" "$1" >>"$HUB_DISC_OUT"
}

# hub_disc_emit_skill DIR -> one skill candidate row; its name comes from
# DIR/SKILL.md while its deployed source is DIR itself.
hub_disc_emit_skill() {
	printf '%s\t%s\t2\tskill\t%s\t%s/SKILL.md\n' \
		"$HUB_DISC_GIDX_PAD" "$HUB_DISC_GROUP" "$1" "$1" >>"$HUB_DISC_OUT"
}

hub_disc_emit_agents_from() {
	while IFS= read -r hdeaf_path; do
		[ -n "$hdeaf_path" ] || continue
		hub_disc_emit_agent "$hdeaf_path"
	done <"$1"
}

hub_disc_emit_skills_from() {
	while IFS= read -r hdesf_path; do
		[ -n "$hdesf_path" ] || continue
		hub_disc_emit_skill "$hdesf_path"
	done <"$1"
}

# --- Software Development -------------------------------------------------
#
# Selectable — one group per technology. A technology is discovered by scanning
# agents/developers/ for developer agents; its key is the basename minus its
# role suffix. For each key, the reviewer agent and the per-technology standard
# skill are pulled in ONLY if they actually exist — a technology is not
# required to have all three.
hub_disc_sd_technologies() {
	hdst_src=$1
	hdst_root=$2
	hdst_tmp=$(hub_mktemp_dir)
	hub_disc_agent_files "$hdst_root/$HUB_SD_DIR_DEVELOPERS" -maxdepth 1 >"$hdst_tmp/devs.txt"

	while IFS= read -r hdst_dev; do
		[ -n "$hdst_dev" ] || continue
		hdst_base=${hdst_dev##*/}
		hdst_base=${hdst_base%.md}
		# TWO rejection reasons, one warning, because both are "this file does not
		# name a technology" and the caller cannot act differently on them: no
		# recognized role suffix at all, or a suffix-stripped key that is not a legal
		# key (see hub_sd_tech_key on why a key derived from a raw basename is
		# charset-gated exactly as a unit name is).
		hdst_key=$(hub_sd_tech_key "$hdst_base") || {
			warn "ignoring unrecognized file under $HUB_SD_DIR_DEVELOPERS (needs one of the $HUB_SD_TECH_AGENT_SUFFIXES suffixes, and the name before it must match $HUB_NAME_CHARSET_RE): $hdst_dev"
			continue
		}
		hub_disc_begin_group "$(hub_group_key "$HUB_GROUP_PREFIX_TECH" "$hdst_key")"
		hub_disc_emit_agent "$hdst_dev"

		hdst_reviewer=$(hub_sd_tech_reviewer_path "$hdst_src" "$hdst_key")
		if [ -f "$hdst_reviewer" ]; then
			hub_disc_emit_agent "$hdst_reviewer"
		fi

		hdst_standard=$(hub_sd_tech_standard_path "$hdst_src" "$hdst_key")
		if [ -f "$hdst_standard/SKILL.md" ]; then
			hub_disc_emit_skill "$hdst_standard"
		fi
	done <"$hdst_tmp/devs.txt"
	rm -rf "$hdst_tmp" 2>/dev/null || :
}

# Baseline — installed the moment Software Development is chosen, never a
# selectable row:
#   * every skill under flows/
#   * every skill under shared/ EXCEPT the per-technology standards under
#     shared/standards/tech/ (those belong to their technology's group)
#   * every specialist agent plus every skill nested beneath one
#   * every lens reviewer agent (lens reviewers are unconditional baseline)
hub_disc_sd_baseline() {
	hdsb_root=$1
	hdsb_tmp=$(hub_mktemp_dir)
	hub_disc_begin_group "$(hub_group_key "$HUB_GROUP_PREFIX_BASELINE" software-development)"

	hub_disc_agent_files "$hdsb_root/$HUB_SD_DIR_LENS_REVIEWERS" -maxdepth 1 >"$hdsb_tmp/lens.txt"
	hub_disc_emit_agents_from "$hdsb_tmp/lens.txt"

	# Specialists: the agent file sits at depth 1 (a bare agent) or depth 2 (an
	# agent that owns nested skills, in its own directory) — never deeper,
	# where only its skills live.
	hub_disc_agent_files "$hdsb_root/$HUB_SD_DIR_SPECIALISTS" -maxdepth 2 >"$hdsb_tmp/specialists.txt"
	hub_disc_emit_agents_from "$hdsb_tmp/specialists.txt"

	hub_disc_skill_dirs "$hdsb_root/$HUB_SD_DIR_FLOWS" >"$hdsb_tmp/flows.txt"
	hub_disc_emit_skills_from "$hdsb_tmp/flows.txt"

	# shared/, with the per-technology standards subtree pruned. Written as its
	# own find rather than via hub_disc_skill_dirs because it needs one extra
	# prune term that no other walk wants.
	if [ -d "$hdsb_root/$HUB_SD_DIR_SHARED" ]; then
		find "$hdsb_root/$HUB_SD_DIR_SHARED" \
			\( -name tests -o -name .git -o -path "$hdsb_root/$HUB_SD_DIR_SHARED_TECH_STANDARDS" \) -prune -o \
			-type f -name SKILL.md ! -name 'template-*' -print 2>/dev/null |
			sed 's|/SKILL\.md$||' | LC_ALL=C sort >"$hdsb_tmp/shared.txt"
		hub_disc_emit_skills_from "$hdsb_tmp/shared.txt"
	fi

	hub_disc_skill_dirs "$hdsb_root/$HUB_SD_DIR_SPECIALISTS" >"$hdsb_tmp/specialist-skills.txt"
	hub_disc_emit_skills_from "$hdsb_tmp/specialist-skills.txt"

	rm -rf "$hdsb_tmp" 2>/dev/null || :
}

# --- Project Management ---------------------------------------------------
#
# A Project Management agent's skills are partitioned by hub_pm_backend_of: a
# skill whose name carries a jira token belongs to the Jira backend, one
# carrying a gh/github token belongs to the GitHub backend, and anything else
# is baseline. All three groups are populated from that ONE classification
# pass, so a skill can never end up in two of them or in none.

# hub_disc_pm_agent_dirs ROOT OUTFILE -> one directory path per Project
# Management agent that owns nested skills, i.e. every immediate subdirectory of
# the domain's agents/. Discovered, never named: this is what replaced the
# hardcoded `agents/project-manager` segment.
hub_disc_pm_agent_dirs() {
	hdpad_agents="$1/$HUB_PM_DIR_AGENTS"
	: >"$2"
	[ -d "$hdpad_agents" ] || return 0
	find "$hdpad_agents" -maxdepth 1 -type d ! -name tests ! -name .git \
		2>/dev/null | LC_ALL=C sort >"$2"
}

hub_disc_pm() {
	hdp_root=$1
	hdp_tmp=$(hub_mktemp_dir)

	# Every agent's own skills/ subtree, concatenated then re-sorted so the
	# combined list keeps the single canonical order a one-directory walk gave.
	# The walk is anchored at each agent's skills/ rather than at agents/ with a
	# deeper -maxdepth, so a stray SKILL.md somewhere else under an agent cannot
	# be mistaken for one of its skills.
	hub_disc_pm_agent_dirs "$hdp_root" "$hdp_tmp/agent-dirs.txt"
	: >"$hdp_tmp/skills-unsorted.txt"
	while IFS= read -r hdp_agent_dir; do
		[ -n "$hdp_agent_dir" ] || continue
		[ "$hdp_agent_dir" != "$hdp_root/$HUB_PM_DIR_AGENTS" ] || continue
		hub_disc_skill_dirs "$hdp_agent_dir/$HUB_PM_AGENT_SKILLS_SUBDIR" -maxdepth 2 \
			>>"$hdp_tmp/skills-unsorted.txt"
	done <"$hdp_tmp/agent-dirs.txt"
	LC_ALL=C sort -u <"$hdp_tmp/skills-unsorted.txt" >"$hdp_tmp/skills.txt"

	: >"$hdp_tmp/baseline-skills.txt"
	for hdp_backend in $HUB_PM_BACKEND_KEYS; do
		: >"$hdp_tmp/backend-$hdp_backend.txt"
	done
	while IFS= read -r hdp_skill; do
		[ -n "$hdp_skill" ] || continue
		hdp_class=$(hub_pm_backend_of "${hdp_skill##*/}")
		if [ -n "$hdp_class" ]; then
			printf '%s\n' "$hdp_skill" >>"$hdp_tmp/backend-$hdp_class.txt"
		else
			printf '%s\n' "$hdp_skill" >>"$hdp_tmp/baseline-skills.txt"
		fi
	done <"$hdp_tmp/skills.txt"

	# Selectable backends first, in HUB_PM_BACKEND_KEYS order. A backend with
	# no skills present in this source is simply not offered.
	for hdp_backend in $HUB_PM_BACKEND_KEYS; do
		if [ -s "$hdp_tmp/backend-$hdp_backend.txt" ]; then
			hub_disc_begin_group "$(hub_group_key "$HUB_GROUP_PREFIX_PM_BACKEND" "$hdp_backend")"
			hub_disc_emit_skills_from "$hdp_tmp/backend-$hdp_backend.txt"
		fi
	done

	hub_disc_begin_group "$(hub_group_key "$HUB_GROUP_PREFIX_BASELINE" project-management)"
	# -maxdepth 2 under agents/, identical to Software Development's specialists:
	# an agent file sits at depth 1 (a bare agent) or depth 2 (an agent that owns
	# nested skills, in its own directory) — never deeper, where only its skills
	# live, and SKILL.md is excluded by hub_disc_agent_files regardless.
	hub_disc_agent_files "$hdp_root/$HUB_PM_DIR_AGENTS" -maxdepth 2 >"$hdp_tmp/agents.txt"
	hub_disc_emit_agents_from "$hdp_tmp/agents.txt"
	hub_disc_skill_dirs "$hdp_root/$HUB_PM_DIR_FLOWS" >"$hdp_tmp/flows.txt"
	hub_disc_emit_skills_from "$hdp_tmp/flows.txt"
	hub_disc_emit_skills_from "$hdp_tmp/baseline-skills.txt"

	rm -rf "$hdp_tmp" 2>/dev/null || :
}

# --- Getting Things Done --------------------------------------------------
#
# Everything under gtd/ lands in ONE group, and that group is the domain itself:
# `atomic:gtd`, not `baseline:gtd`. There is no fan-out and no sub-selection
# screen, so there is nothing for a baseline group to be distinct FROM — the whole
# footprint installs together and removes together, which is what the `atomic:`
# prefix declares (see lib/hub-domains.sh's GROUP KEY GRAMMAR for why that prefix
# exists at all, and why a permanently-empty selectable set is the one shape the
# baseline cascade cannot reason about).
#
# The agent walk is depth-limited to 2 under gtd/agents/ for the same reason as
# Software Development's specialists.
hub_disc_gtd() {
	hdg_root=$1
	hdg_tmp=$(hub_mktemp_dir)
	hub_disc_begin_group "$(hub_group_key "$HUB_GROUP_PREFIX_ATOMIC" gtd)"
	hub_disc_agent_files "$hdg_root/$HUB_GTD_DIR_AGENTS" -maxdepth 2 >"$hdg_tmp/agents.txt"
	hub_disc_emit_agents_from "$hdg_tmp/agents.txt"
	hub_disc_skill_dirs "$hdg_root" >"$hdg_tmp/skills.txt"
	hub_disc_emit_skills_from "$hdg_tmp/skills.txt"
	rm -rf "$hdg_tmp" 2>/dev/null || :
}

# --- Cross-domain ---------------------------------------------------------
#
# Whatever skills live under accounts/ form the one shared group. The group key
# and its consumers are named in lib/hub-domains.sh; the unit itself is
# discovered, so renaming the skill on disk needs no code change.
hub_disc_shared() {
	hds_src=$1
	hds_tmp=$(hub_mktemp_dir)
	hub_disc_skill_dirs "$hds_src/$HUB_ACCOUNTS_DIR" -maxdepth 2 >"$hds_tmp/skills.txt"
	if [ -s "$hds_tmp/skills.txt" ]; then
		hub_disc_begin_group "$HUB_SHARED_GIT_AUTH_GROUP"
		hub_disc_emit_skills_from "$hds_tmp/skills.txt"
	fi
	rm -rf "$hds_tmp" 2>/dev/null || :
}

# hub_disc_collect SRC OUTFILE -> every candidate row, in canonical group
# order. Columns: gidx, group, kindrank, kind, src, namefile.
hub_disc_collect() {
	hdc_src=$1
	HUB_DISC_OUT=$2
	: >"$HUB_DISC_OUT"
	HUB_DISC_GIDX=0

	for hdc_domain in $HUB_DOMAIN_KEYS; do
		hub_domain_exists "$hdc_src" "$hdc_domain" || continue
		hdc_root=$(hub_domain_root "$hdc_src" "$hdc_domain")
		case $hdc_domain in
		software-development)
			hub_disc_sd_technologies "$hdc_src" "$hdc_root"
			hub_disc_sd_baseline "$hdc_root"
			;;
		project-management) hub_disc_pm "$hdc_root" ;;
		gtd) hub_disc_gtd "$hdc_root" ;;
		esac
	done

	hub_disc_shared "$hdc_src"
}

# ---------------------------------------------------------------------------
# Name resolution — one awk process for the whole tree.
# ---------------------------------------------------------------------------

# hub_disc_resolve_names LISTFILE OUTFILE -> "namefile<TAB>status<TAB>name" for
# every path listed one-per-line in LISTFILE, where the name is read from that
# file's YAML frontmatter 'name:' key and status is:
#
#   ok       a name was found AND it matches HUB_NAME_CHARSET_RE.
#   missing  no parsable frontmatter 'name:' at all.
#   invalid  a name was found but is NOT a legal unit name.
#
# The caller decides what to do about the two bad statuses (hub_discovery_build
# warns and skips, per status).
#
# ===========================================================================
# WHY VALIDATION HAPPENS HERE, AT THE ONE ENTRY POINT
# ===========================================================================
# This function is the ONLY place a byte from an untrusted source file becomes a
# unit's identity, and that identity is used verbatim as a FILENAME under
# --target (lib/hub-state.sh's hub_target_path). A source declaring
# `name: ../../../../../../tmp/pwned` therefore aimed the hub's mkdir/rm/ln at a
# path outside --target entirely, while the consent preview showed only a mangled
# display name — so the escape never appeared on the screen the user approved.
# Validating at this single choke point means every downstream consumer (states,
# rows, symlink, uninstall, the bundle) inherits the guarantee without repeating
# the check, and a rejected unit never enters the pipeline at all.
#
# The status column is what makes rejection reportable: an invalid name must not
# be folded into "missing", because the two need different warnings, and it must
# not be echoed back raw either — a name may contain control characters, so the
# reported form is sanitized to printable ASCII before it reaches a diagnostic.
#
# STATUS IS COLUMN 2 AND NAME IS LAST, deliberately: name is the only column that
# can be empty, and an empty middle column collapses under `read` with IFS=TAB
# (see lib/hub-common.sh's "THE TAB TRAP"). A name can never itself contain a TAB
# once it is `ok`, because the charset does not admit one.
#
# ONE awk invocation opens every candidate itself via getline, rather than the
# obvious `while read f; do awk ... "$f"; done` which forks an awk per file —
# several hundred forks on a real tree, and the single biggest avoidable cost
# in the whole scan.
hub_disc_resolve_names() {
	awk -v list="$1" -v ok_re="$HUB_NAME_CHARSET_RE" '
		BEGIN {
			dq = "\042"; sq = "\047"
			while ((getline path < list) > 0) {
				if (path == "") continue
				name = ""; found = 0; lineno = 0
				while ((getline line < path) > 0) {
					sub(/\r$/, "", line)
					lineno++
					if (lineno == 1) {
						if (line == "---") continue
						break
					}
					if (line == "---") break
					if (substr(line, 1, 5) == "name:") {
						val = substr(line, 6)
						sub(/^[ \t]+/, "", val)
						sub(/[ \t]+$/, "", val)
						n = length(val)
						if (n >= 2) {
							c1 = substr(val, 1, 1); c2 = substr(val, n, 1)
							if ((c1 == dq && c2 == dq) || (c1 == sq && c2 == sq))
								val = substr(val, 2, n - 2)
						}
						name = val
						found = 1
						break
					}
				}
				close(path)
				if (!found || name == "") {
					print path "\tmissing\t"
				} else if (name !~ ok_re) {
					# Reported, never used: reduced to printable ASCII so a name
					# carrying a TAB, a newline or an escape sequence cannot shift a
					# column or forge a line in the diagnostic that rejects it.
					shown = name
					gsub(/[^ -~]/, "?", shown)
					print path "\tinvalid\t" shown
				} else {
					print path "\tok\t" name
				}
			}
		}
	' </dev/null >"$2"
}

# ---------------------------------------------------------------------------
# Display naming + the group table.
# ---------------------------------------------------------------------------

# HUB_DISPLAY_ACRONYMS — the ONE display-only capitalization exception list.
# Every human-facing name is otherwise a mechanical kebab-to-Sentence-case
# conversion; these tokens keep their real-world capitalization because
# "Php"/"Devops"/"Gtd"/"Github" would misrepresent an acronym or a brand.
#
# This is presentation polish, NOT a registry: a technology or skill absent
# from this list still discovers, installs and lists correctly — it just
# sentence-cases mechanically. Nothing here affects behavior, flag spellings or
# on-disk names.
HUB_DISPLAY_ACRONYMS='php=PHP devops=DevOps gtd=GTD github=GitHub jira=Jira'

# hub_discovery_build SRC -> runs the whole scan ONCE and sets:
#   HUB_UNITS   group  name  kind  src  display
#   HUB_GROUPS  group  label  domain  role  selkind  selkey  atomic  units
#
# Per the spec's caching rule, a discovery result is captured once per screen
# render and reused for that screen's lifetime; it is invalidated only by a
# completed mutating action or by re-entering a screen. Callers therefore call
# this explicitly — it is deliberately NOT lazily self-building-and-kept-
# forever, which would let the interactive Main menu show stale counts right
# after an install.
hub_discovery_build() {
	hdb_src=$1
	hdb_tmp=$(hub_mktemp_dir)

	hub_disc_collect "$hdb_src" "$hdb_tmp/candidates.tsv"

	awk -F '\t' '{ print $6 }' "$hdb_tmp/candidates.tsv" | LC_ALL=C sort -u >"$hdb_tmp/namefiles.txt"
	hub_disc_resolve_names "$hdb_tmp/namefiles.txt" "$hdb_tmp/namemap.tsv"

	# Attach each candidate's resolved name, then sort: group order (col 1),
	# agents before skills (col 3), name (col 4). Any candidate whose frontmatter
	# name could not be read, OR whose name is not a legal unit name, is dropped
	# and reported — it cannot enter the pipeline at all, since identity is what
	# the deployed symlink is named after and where it is written. Truncated up
	# front so a run with no rejects still leaves a readable (empty) file for the
	# loop below.
	# FNR == NR alone does NOT mean "still reading the first file" — with an empty
	# first file awk reads no record from it, so the second file's first record
	# satisfies FNR == NR too and would be swallowed as a name-map entry.
	# FILENAME == ARGV[1] states the intended phase test directly.
	#
	# REJECTED columns are "reason<TAB>path<TAB>detail", and DETAIL IS LAST for the
	# same reason the name map's own name column is (see "THE TAB TRAP" in
	# lib/hub-common.sh): detail carries the sanitized offending name for an
	# `invalid` row and is EMPTY for a `missing` one, and this table is read by
	# `read` with IFS=TAB just below. With detail in the middle, a `missing` row's
	# empty column collapsed, the path landed in the detail variable, the path
	# variable came out empty, and the `[ -n ... ] || continue` guard silently
	# dropped the row — so a source file with no parsable `name:` produced no
	# diagnostic at all. reason and path can never be empty or contain a TAB
	# (reason is a hub-generated word; path came from find(1) and holds no TAB
	# because a TAB in a discovered path would already have broken the candidate
	# table it was carried in).
	: >"$hdb_tmp/rejected.tsv"
	awk -F '\t' -v OFS='\t' -v rejected="$hdb_tmp/rejected.tsv" '
		FNR == NR && FILENAME == ARGV[1] { st[$1] = $2; nm[$1] = $3; next }
		{
			if (st[$6] != "ok") {
				print (st[$6] == "invalid" ? "invalid" : "missing"), $5, nm[$6] > rejected
				next
			}
			print $1, $2, $3, nm[$6], $4, $5
		}
	' "$hdb_tmp/namemap.tsv" "$hdb_tmp/candidates.tsv" |
		LC_ALL=C sort -t "$HUB_TAB" -k1,1 -k3,3 -k4,4 >"$hdb_tmp/ordered.tsv"

	while IFS="$HUB_TAB" read -r hdb_reason hdb_bad_path hdb_detail; do
		[ -n "$hdb_bad_path" ] || continue
		case $hdb_reason in
		invalid)
			warn "skipping $hdb_bad_path: 'name: $hdb_detail' is not a usable unit name — a name becomes a file or directory name under the target, so it must match $HUB_NAME_CHARSET_RE"
			;;
		*) warn "skipping: no 'name:' frontmatter in $hdb_bad_path" ;;
		esac
	done <"$hdb_tmp/rejected.tsv"

	HUB_UNITS="$hdb_tmp/units.tsv"
	HUB_GROUPS="$hdb_tmp/groups.tsv"
	hub_disc_render_tables "$hdb_tmp/ordered.tsv" "$HUB_UNITS" "$HUB_GROUPS"

	HUB_DISCOVERY_READY=1
}

# hub_disc_render_tables ORDERED UNITS_OUT GROUPS_OUT -> computes every unit's
# display name and every group's metadata, in one two-pass awk over ORDERED
# (pass 1 counts units per group and finds each technology's developer agent;
# pass 2 emits both tables).
#
# The display rules are all PATH-SHAPE rules — that is why they can live in one
# place and cover every unit the framework will ever grow:
#
#   agents/developers/{k}-developer.md   "{K} agent developer", or, when the
#                                        technology has no counterpart at all,
#                                        just the agent's own sentence-cased
#                                        name (a lone developer is not a
#                                        "technology pair", so naming it after
#                                        a technology would overstate it)
#   agents/reviewers/tech/{k}-reviewer   "{K} agent reviewer"
#   agents/reviewers/lens/lens-{n}-...   "{N} review lens"
#   shared/standards/**/standard-{n}     "{N} standard"
#   accounts/**/procedure-{n}            "{N} procedure"
#   anything else                        sentence-cased as-is
#
# Two of those move a leading type word to the end ("standard-python" ->
# "Python standard") while a sibling deliberately does not ("standard-judging"
# -> "Standard judging"). That is not an inconsistency: the moved form applies
# only under shared/standards/ and accounts/, where the type word is a
# CLASSIFICATION of a family of items; elsewhere it is simply part of the
# item's own name.
#
# EVERY SHAPE THIS AWK DECIDES ON IS PASSED IN VIA -v — the directory segments,
# the role suffixes, the type-word prefixes and the four group-key prefixes. None
# of them is re-spelled here as an awk literal, and no group key is parsed by a
# magic substr() offset. Both were true before this pass, and both were silent
# failure modes: adding a suffix to HUB_SD_TECH_AGENT_SUFFIXES fixed discovery and
# left display naming behind with no error, and a substr(group, 12) offset breaks
# the moment a prefix is renamed by a character.
#
# Path matching uses index(src, "/" dir "/") rather than a dynamic regex, so a
# directory constant containing a regex metacharacter cannot change what matches.
#
# ===========================================================================
# A GROUP LABEL IS BARE, AND THE CONTEXT-FREE SCREENS QUALIFY IT THEMSELVES
# ===========================================================================
# A Project Management backend used to be labelled "GitHub backend" here, so that
# the label could stand alone. It read correctly on the two surfaces that show no
# domain heading and wrongly on every surface that does: List, both Install
# screens, Uninstall's receipt and Doctor all print the label under a "Project
# Management" heading, where the suffix repeats the heading on every row — and
# Install's own sub-selection screen, already titled "select backend(s)", had to
# strip the suffix back off, which is a label being un-built one screen after it
# was built.
#
# The default is inverted: the label is now BARE, and the two screens with no
# heading (hub-uninstall.sh's flat checklist, hub-accounts.sh's "used by" line)
# compose the fuller form themselves — through hub_group_label_in_context below,
# which asks lib/hub-domains.sh's hub_selection_kind_needs_domain which kinds need
# it. A technology label is unaffected: it names itself, so no kind-specific
# suffix ever existed for it and none is added now.
hub_disc_render_tables() {
	# BOTH OUTPUT FILES ARE PRE-CREATED, exactly as hub_discovery_build pre-creates
	# rejected.tsv and for the same reason: awk's `print > file` only creates a file
	# when a record is actually written to it, so a source with ZERO discovered
	# candidates left units_out and groups_out nonexistent. The next reader
	# (hub_states_build's `done <"$HUB_UNITS"`) then failed with a raw shell "No such
	# file or directory" under set -e, in place of the "(no components discovered)"
	# message the empty case is written to produce.
	: >"$2"
	: >"$3"
	awk -F '\t' -v OFS='\t' \
		-v acronyms="$HUB_DISPLAY_ACRONYMS" \
		-v units_out="$2" -v groups_out="$3" \
		-v sd_label="$(hub_domain_label software-development)" \
		-v pm_label="$(hub_domain_label project-management)" \
		-v gtd_label="$(hub_domain_label gtd)" \
		-v shared_label='Cross-domain' \
		-v dir_developers="$HUB_SD_DIR_DEVELOPERS" \
		-v dir_tech_reviewers="$HUB_SD_DIR_TECH_REVIEWERS" \
		-v dir_lens_reviewers="$HUB_SD_DIR_LENS_REVIEWERS" \
		-v dir_standards="$HUB_SD_DIR_SHARED_STANDARDS" \
		-v dir_accounts="$HUB_ACCOUNTS_DIR" \
		-v dev_suffixes="$HUB_SD_TECH_AGENT_SUFFIXES" \
		-v reviewer_suffix="$HUB_SD_TECH_REVIEWER_SUFFIX" \
		-v lens_prefix="$HUB_SD_LENS_AGENT_PREFIX" \
		-v standard_prefix="$HUB_STANDARD_SKILL_PREFIX" \
		-v procedure_prefix="$HUB_PROCEDURE_SKILL_PREFIX" \
		-v p_baseline="$HUB_GROUP_PREFIX_BASELINE" \
		-v p_tech="$HUB_GROUP_PREFIX_TECH" \
		-v p_pm_backend="$HUB_GROUP_PREFIX_PM_BACKEND" \
		-v p_atomic="$HUB_GROUP_PREFIX_ATOMIC" \
		-v p_shared="$HUB_GROUP_PREFIX_SHARED" '
		function titlecase(s,   n, i, parts, out, w) {
			n = split(s, parts, "-")
			out = ""
			for (i = 1; i <= n; i++) {
				w = parts[i]
				if (w in ACR) w = ACR[w]
				else if (i == 1) w = toupper(substr(w, 1, 1)) substr(w, 2)
				out = (out == "" ? w : out " " w)
			}
			return out
		}
		function strip_suffix(s, suf) {
			if (length(s) > length(suf) && substr(s, length(s) - length(suf) + 1) == suf)
				return substr(s, 1, length(s) - length(suf))
			return s
		}
		# strip_any_suffix — the LIST form, so HUB_SD_TECH_AGENT_SUFFIXES stays the
		# single source of truth for which role suffixes exist.
		function strip_any_suffix(s, list,   n, i, parts, stripped) {
			n = split(list, parts, " ")
			for (i = 1; i <= n; i++) {
				stripped = strip_suffix(s, parts[i])
				if (stripped != s) return stripped
			}
			return s
		}
		function strip_prefix(s, pre) {
			if (substr(s, 1, length(pre)) == pre) return substr(s, length(pre) + 1)
			return s
		}
		function in_dir(src, dir) {
			return index(src, "/" dir "/") > 0
		}
		# has_group_prefix / group_selkey — the group-key grammar, read from the
		# passed-in prefixes instead of a hardcoded offset. The +2 is the ":"
		# separator plus awk 1-based indexing, derived from the prefix length.
		function has_group_prefix(group, pre) {
			return index(group, pre ":") == 1
		}
		function group_selkey(group, pre) {
			return substr(group, length(pre) + 2)
		}
		function domain_label(d) {
			if (d == "software-development") return sd_label
			if (d == "project-management") return pm_label
			if (d == "gtd") return gtd_label
			return shared_label
		}
		BEGIN {
			n = split(acronyms, pairs, " ")
			for (i = 1; i <= n; i++) {
				eq = index(pairs[i], "=")
				if (eq > 1) ACR[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
			}
		}
		# Pass 1: per-group unit counts, plus the developer-agent name owned by
		# each technology group (needed for the lone-developer display case).
		NR == FNR {
			count[$2]++
			if (has_group_prefix($2, p_tech) && in_dir($6, dir_developers)) devname[$2] = $4
			next
		}
		# Pass 2: emit both tables. Each group row is emitted at the FIRST unit
		# of that group, so groups_out preserves the same canonical order
		# units_out has.
		{
			group = $2; name = $4; kind = $5; src = $6

			if (in_dir(src, dir_developers)) {
				key = strip_any_suffix(name, dev_suffixes)
				display = (count[group] > 1) ? titlecase(key) " agent developer" : titlecase(name)
			} else if (in_dir(src, dir_tech_reviewers)) {
				display = titlecase(strip_suffix(name, reviewer_suffix)) " agent reviewer"
			} else if (in_dir(src, dir_lens_reviewers)) {
				key = strip_suffix(strip_prefix(name, lens_prefix), reviewer_suffix)
				display = titlecase(key) " review lens"
			} else if (in_dir(src, dir_standards)) {
				display = titlecase(strip_prefix(name, standard_prefix)) " standard"
			} else if (in_dir(src, dir_accounts)) {
				display = titlecase(strip_prefix(name, procedure_prefix)) " procedure"
			} else {
				display = titlecase(name)
			}
			print group, name, kind, src, display > units_out

			if (!(group in seen)) {
				seen[group] = 1
				role = "baseline"; domain = ""; selkind = ""; selkey = ""; atomic = 0
				if (has_group_prefix(group, p_tech)) {
					role = "selectable"; domain = "software-development"
					selkind = "technology"; selkey = group_selkey(group, p_tech)
					label = (count[group] > 1) ? titlecase(selkey) : titlecase(devname[group])
				} else if (has_group_prefix(group, p_pm_backend)) {
					role = "selectable"; domain = "project-management"
					selkind = "pm-backend"; selkey = group_selkey(group, p_pm_backend); atomic = 1
					# BARE — "GitHub", not "GitHub backend". See the note above this
					# function on why the suffix is gone and where the two screens
					# that still need it get it from instead
					# (hub_group_label_in_context).
					#
					# NO APOSTROPHE ANYWHERE IN THIS awk PROGRAM, here or in any
					# comment inside it: the whole program is one single-quoted shell
					# word, so an apostrophe ends the quoting and the rest of the awk
					# source is parsed by the shell. It is a syntax error at source
					# time, not a subtle one, but it is invisible while writing prose.
					label = titlecase(selkey)
				} else if (has_group_prefix(group, p_atomic)) {
					# A DOMAIN THAT IS ITS OWN ONE SELECTABLE GROUP. Its selection
					# key is the domain key itself, so an agent removes it with
					# --components=<domain> and the checklist offers it as one row.
					#
					# selkind AND atomic are spelled out even though both are the
					# initialised defaults just above, because each has a plausible
					# wrong value that breaks a real invariant elsewhere:
					#   * atomic = 1 routes this group into hub_group_row_key, which
					#     dies on anything but a pm-backend group — and hub_rows_build
					#     calls it at top level, so List, Doctor and Uninstall would
					#     all abort at startup. Removal atomicity comes from the role
					#     column, not from here (see lib/hub-domains.sh, WHICH GROUPS
					#     ARE ATOMIC).
					#   * a made-up selkind ("domain", "none") would be looked up by
					#     hub_selection_kind_prefix/_prompt/_noun/_flag, which die on
					#     an unknown kind, and the literal "none" would additionally be
					#     matched by hub_selectable_groups none. EMPTY is the truthful
					#     value: this group is governed by no sub-selection screen, the
					#     same as every baseline and shared group.
					role = "selectable"; domain = group_selkey(group, p_atomic)
					selkind = ""; selkey = domain; atomic = 0
					label = domain_label(domain)
				} else if (has_group_prefix(group, p_shared)) {
					role = "shared"; domain = "_shared"
					label = shared_label
				} else {
					domain = group_selkey(group, p_baseline)
					label = domain_label(domain)
				}
				print group, label, domain, role, selkind, selkey, atomic, count[group] > groups_out
			}
		}
	' "$1" "$1"
}

# hub_discovery_require -> die unless hub_discovery_build has run for SRC. A
# caller-contract assertion, not a runtime condition: every consumer below
# reads HUB_UNITS/HUB_GROUPS, and reading them unbuilt is a programming error
# that must fail loudly rather than silently report an empty framework.
hub_discovery_require() {
	[ "${HUB_DISCOVERY_READY:-0}" -eq 1 ] || die "hub_discovery_require: discovery has not been built (call hub_discovery_build first)"
}

# ---------------------------------------------------------------------------
# Table readers — the only interface other modules use.
# ---------------------------------------------------------------------------

# hub_groups_of_role ROLE... -> every group key whose role is one of ROLE, in
# canonical order.
#
# awk, not a `read` loop: the group table has legitimately EMPTY middle columns
# (selkind/selkey are blank for every non-selectable group) and `read` with
# IFS=TAB collapses consecutive tabs, silently shifting every later field. See
# lib/hub-common.sh's "THE TAB TRAP" for the full statement. Every accessor below
# reads this table through awk for the same reason.
hub_groups_of_role() {
	hub_discovery_require
	hgor_wanted=" $* "
	hgor_wanted="$hgor_wanted" awk -F '\t' \
		'index(ENVIRON["hgor_wanted"], " " $4 " ") > 0 { print $1 }' "$HUB_GROUPS"
}

# hub_group_keys -> every group key, in canonical order.
hub_group_keys() {
	hub_discovery_require
	awk -F '\t' '{ print $1 }' "$HUB_GROUPS"
}

# hub_group_field GROUP FIELD -> one column of a group's row (2=label,
# 3=domain, 4=role, 5=selkind, 6=selkey, 7=atomic, 8=units). Empty when the
# group does not exist.
hub_group_field() {
	hub_discovery_require
	hgf_group="$1" hgf_field="$2" awk -F '\t' \
		'$1 == ENVIRON["hgf_group"] { print $ENVIRON["hgf_field"]; exit }' "$HUB_GROUPS"
}

# hub_group_label_in_context GROUP -> the group's label as it must read on a
# screen that shows NO domain heading above it: the plain label for a group whose
# label names itself, and "<Domain> (<label>)" for one whose label does not.
#
# THE COUNTERPART OF THE BARE LABEL, and the reason the bare label is safe. Every
# domain-grouped surface reads column 2 directly and gets "GitHub" under a
# "Project Management" heading; the two surfaces with no heading at all —
# hub-uninstall.sh's flat checklist, which mixes every domain's rows under one
# generic title — call this instead and get "Project Management (GitHub)". A
# technology is unaffected: hub_selection_kind_needs_domain answers `no` for it,
# so "Java" stays "Java" rather than becoming "Software Development (Java)",
# which would add a word to every row of the longest list on that screen to
# disambiguate something that was never ambiguous.
#
# WHICH groups need it is the KIND's own fact, read from the group table's selkind
# column and answered by lib/hub-domains.sh — never a domain literal or a group-key
# prefix test here.
#
# EVERY accessor result is assigned before it is used, never inlined as a printf
# argument: hub_group_field dies (via hub_discovery_require) on an unbuilt
# discovery and hub_domain_label dies on a key outside its closed set, and a die
# inside a command substitution used as an ARGUMENT is swallowed — the
# substitution yields empty, printf still succeeds, and a checklist row loses
# its subject while still being selectable. The same hoisting lib/hub-state.sh's
# hub_rows_build states.
hub_group_label_in_context() {
	hglic_label=$(hub_group_field "$1" 2)
	hglic_kind=$(hub_group_field "$1" 5)
	if hub_selection_kind_needs_domain "$hglic_kind"; then
		hglic_domain=$(hub_group_field "$1" 3)
		hglic_domain_label=$(hub_domain_label "$hglic_domain")
		printf '%s (%s)' "$hglic_domain_label" "$hglic_label"
		return 0
	fi
	printf '%s' "$hglic_label"
}

# hub_selectable_groups SELKIND -> every selectable group of one kind
# ("technology" | "pm-backend"), in canonical order.
hub_selectable_groups() {
	hub_discovery_require
	hsg_kind="$1" awk -F '\t' '$5 == ENVIRON["hsg_kind"] { print $1 }' "$HUB_GROUPS"
}

# hub_domain_selectable_groups DOMAIN -> every SELECTABLE group belonging to one
# domain, in canonical order.
#
# Filtered on the group table's own DOMAIN column, never on the domain's
# selection kind: hub_selectable_groups above answers "every group of this KIND",
# and lib/hub-domains.sh's blast-radius note names two domains sharing one kind
# as a state the registry permits — under which a kind-filtered answer would hand
# one domain the other domain's groups. hub-uninstall.sh's own per-domain scan
# already filters by domain for the same reason.
hub_domain_selectable_groups() {
	hub_discovery_require
	hdsg_domain="$1" awk -F '\t' \
		'$4 == "selectable" && $3 == ENVIRON["hdsg_domain"] { print $1 }' "$HUB_GROUPS"
}

# hub_domain_baseline_group DOMAIN -> DOMAIN's baseline group key, or NOTHING AT ALL
# when the domain has no baseline group (a domain registered under the `atomic:`
# prefix has none — its selectable content IS its whole footprint; see
# lib/hub-domains.sh's GROUP KEY GRAMMAR).
#
# THE OWNER OF A QUESTION THAT USED TO BE ASSUMED. Every caller that needed a
# domain's baseline CONSTRUCTED `hub_group_key "$HUB_GROUP_PREFIX_BASELINE" "$domain"`
# and used the result unchecked, so a domain without one silently got a key naming no
# row — and the two functions that then asked for that row's STATE got `available`
# back (hub_group_state answers `available` for a group with zero units), which is
# indistinguishable from "installed nothing yet". That made a fully-installed such
# domain a live installable checkbox forever, and published `available` in
# --format=env|json's own domain-state field. An accessor that can answer "it has
# none" is what lets each of those callers branch instead of guess.
#
# EMPTY OUTPUT IS THE ANSWER, not an error, and this deliberately does not die: every
# caller asks it of whichever domain it is rendering. Same non-dying shape, for the
# same reason, as hub_domain_is_registered and hub_domain_feature_keys.
#
# EXISTENCE IS TESTED ON THE GROUP TABLE, through hub_group_field, rather than by
# asking whether the domain has a selection kind: a source that ships a domain
# subtree containing nothing discoverable produces no group for it either, and the
# table is the only thing that knows.
hub_domain_baseline_group() {
	hdbg_group=$(hub_group_key "$HUB_GROUP_PREFIX_BASELINE" "$1")
	# Column 1 is the group key itself, so a non-empty answer means the row exists.
	hdbg_found=$(hub_group_field "$hdbg_group" 1)
	[ -n "$hdbg_found" ] || return 0
	printf '%s\n' "$hdbg_group"
}

# hub_domain_content_groups DOMAIN -> the group(s) holding the content DOMAIN
# installs UNCONDITIONALLY once it is chosen, one per line: its baseline group when
# it has one, ELSE every selectable group of its own that no sub-selection screen
# governs (an empty selkind).
#
# ONE RULE, TWO CONSUMERS, and they must not disagree: hub-install.sh's plan assembly
# (which groups does picking this domain add) and lib/hub-state.sh's feature
# projection (over which units are this domain's named features computed). Both used
# to spell `baseline:<domain>` themselves, which is exactly the assumption a domain
# with no baseline group breaks.
#
# THE selkind FILTER IS WHAT KEEPS THE `else` HONEST. Without it this would hand a
# baseline-less domain every technology-shaped group it owns, i.e. select the entire
# fan-out that a sub-selection screen exists to let the user choose from. A domain
# whose one group is its whole footprint carries an empty selkind precisely because no
# screen governs it (see lib/hub-discovery.sh's role-classification pass).
hub_domain_content_groups() {
	hdcg_baseline=$(hub_domain_baseline_group "$1")
	if [ -n "$hdcg_baseline" ]; then
		printf '%s\n' "$hdcg_baseline"
		return 0
	fi
	hub_discovery_require
	hdcg_domain="$1" awk -F '\t' \
		'$4 == "selectable" && $3 == ENVIRON["hdcg_domain"] && $5 == "" { print $1 }' "$HUB_GROUPS"
}

# hub_selection_keys SELKIND -> every SELECTION KEY of one kind (the token a
# human types on the checklist and an agent passes to --technologies /
# --pm-backends), in canonical order.
#
# Read from the group table's own selkey column, never by stripping the group-key
# prefix off the group key with sed: the column is the authoritative answer, and a
# `sed 's/^tech://'` at the call site is a fourth place the grammar gets spelled.
hub_selection_keys() {
	hub_discovery_require
	hsk_kind="$1" awk -F '\t' '$5 == ENVIRON["hsk_kind"] { print $6 }' "$HUB_GROUPS"
}

# hub_group_units GROUP -> "name<TAB>kind<TAB>src<TAB>display" for each unit in
# GROUP, in canonical order.
hub_group_units() {
	hub_discovery_require
	hgu_group="$1" awk -F '\t' -v OFS='\t' \
		'$1 == ENVIRON["hgu_group"] { print $2, $3, $4, $5 }' "$HUB_UNITS"
}

# hub_units_of_groups GROUPFILE -> every unit belonging to any group listed
# one-per-line in GROUPFILE, deduplicated by unit NAME (a unit reachable
# through two selected groups is installed once), in canonical order.
#
# The phase test is FNR == NR && FILENAME == ARGV[1], not a bare FNR == NR: an
# EMPTY GROUPFILE is a legitimate input (nothing selected), and with a bare test
# the first unit of HUB_UNITS would be read as a wanted-group name instead.
hub_units_of_groups() {
	hub_discovery_require
	awk -F '\t' -v OFS='\t' '
		FNR == NR && FILENAME == ARGV[1] { want[$1] = 1; next }
		($1 in want) && !($2 in seen) { seen[$2] = 1; print $1, $2, $3, $4, $5 }
	' "$1" "$HUB_UNITS"
}
