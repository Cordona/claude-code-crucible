# Evidence run for the software-development domain's trackers/ scripts, run
# through the installed layout: a scratch Claude folder linked with
# install-entries.sh's own commands, every script called through its link.
R=/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite
S="/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/tracker test"; rm -rf "$S"; mkdir -p "$S/bin"
# The Claude folder's path has no space, as the paths below go unquoted.
CFG=/private/tmp/claude-501/-Users-cordona-IdeaProjects-cordona-claude-code-crucible/480d0359-cf0d-4c14-a59e-2a72be5dba4f/scratchpad/tracker-cfg; rm -rf "$CFG"; mkdir -p "$CFG"
export CRUCIBLE_HOME="$S/space" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID=sess-t
sh $R/framework/core/install/install-entries.sh | sed -n '/^# Links/,/^$/p' | sed '1d' | sh
T=$CFG/skills/trackers/scripts; C=$CFG/skills; X=$C/crucible-context/scripts; E=$C/crucible-effort/scripts
cd /
F=$(sh $E/effort-start.sh --name trackers)
show() { echo "$1" | sed "s|$PATH|<PATH>|g;s|$T/||g;s|$X/||g;s|$C/||g;s|$F|<F>|g;s|$S|<S>|g"; }
run() { show "\$ $*"; out=$("$@" 2>&1); e=$?; show "$out" | sed 's|^|    |'; echo "    [exit $e]"; }
runhead() { show "\$ $*"; "$@" >"$S/o" 2>"$S/e"; e=$?; sed -n '1,8p' "$S/o" | sed 's|^|    |'; echo "    ... ($(awk 'END{print NR}' "$S/o") lines on stdout)"; show "$(cat "$S/e")" | sed 's|^|    stderr: |'; echo "    [exit $e]"; }

echo "--- contracts"
run sh $T/tracker-read.sh --help
run sh $T/context-add-ticket.sh --help

echo "--- usage errors"
run sh $T/tracker-read.sh
run sh $T/tracker-read.sh --url
run sh $T/tracker-read.sh --url a --url b
run sh $T/context-add-ticket.sh --effort "$F"

echo "--- the link rule: tracker-read.sh and core's context-add.sh --link give the same verdict"
for u in 'https://github.com/cli/cli/issues/1' 'HTTP://Example.com:8080/a?b=c#d' 'https://example.com/a b' \
	"https://example.com/a'b" 'https://example.com/$(id)' 'https://example.com/a;b' 'ftp://example.com/x' \
	'https://example.com/a&b' 'https://example.com/`x`' 'github.com/cli/cli/issues/1'; do
	sh $T/tracker-read.sh --url "$u" >/dev/null 2>&1; tr=$?
	[ $tr -eq 2 ] && tv=refused || tv=accepted
	sh $X/context-add.sh --effort "$F" --link "$u" --why "rule check" >/dev/null 2>&1; cx=$?
	[ $cx -eq 2 ] && cv=refused || cv=accepted
	[ $tv = $cv ] && same=same || same=DIFFERENT
	printf '    %-42s tracker-read: %-8s context-add: %-8s %s\n' "$u" "$tv" "$cv" "$same"
done

echo "--- not a tracker link (exit 3)"
run sh $T/tracker-read.sh --url 'https://example.com/page'
run sh $T/tracker-read.sh --url 'https://github.com/cli/cli/pull/1'
run sh $T/tracker-read.sh --url 'https://github.com/cli/cli/-/issues/1'
run sh $T/tracker-read.sh --url 'https://gitlab.example.com:8443/g/p/-/issues/1'

echo "--- GitHub: a real issue, body and comments"
runhead sh $T/tracker-read.sh --url 'https://github.com/cli/cli/issues/1'
grep -c '^### ' "$S/o" | sed 's/^/    comment headings: /'

echo "--- GitHub: no such issue (exit 1)"
run sh $T/tracker-read.sh --url 'https://github.com/cli/cli/issues/999999999'

echo "--- GitHub: a long issue is cut at 500 lines"
runhead sh $T/tracker-read.sh --url 'https://github.com/golang/go/issues/15292'

echo "--- GitLab: a public issue on gitlab.com with no login: body read, comments not"
runhead sh $T/tracker-read.sh --url 'https://gitlab.com/gitlab-org/cli/-/issues/1'
grep '^## Comments' "$S/o" | sed 's|^|    |'

echo "--- GitLab: the copy of a partial ticket says so in its header and on stderr"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://gitlab.com/gitlab-org/cli/-/issues/1'
sed -n '1,4p' "$(sh $X/context-docs.sh --effort "$F")/ticket-gitlab.com-gitlab-org-cli-issues-1.md" | sed 's|^|    |'

echo "--- gh missing (exit 1)"
mkdir -p "$S/nogh"; for b in sh jq grep tr awk mktemp rm cut head sleep kill cat; do ln -sf "$(command -v $b)" "$S/nogh/$b"; done
run env PATH="$S/nogh" sh $T/tracker-read.sh --url 'https://github.com/cli/cli/issues/1'

echo "--- a hanging gh is stopped after 30 s (exit 1), nothing left running"
printf '#!/bin/sh\nexec sleep 300\n' >"$S/bin/gh"; chmod +x "$S/bin/gh"
start=$(date +%s); run env PATH="$S/bin:$PATH" sh $T/tracker-read.sh --url 'https://github.com/cli/cli/issues/1'
echo "    took $(( $(date +%s) - start )) s"; sleep 1
pgrep -f 'sleep 300' >/dev/null && echo "    LEFT RUNNING: sleep 300" || echo "    nothing left running"
ls "${TMPDIR:-/tmp}" | grep -c '^tracker-read\.' | sed 's/^/    tracker-read temp dirs left: /'

echo "--- copy into the context"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://github.com/cli/cli/issues/1'
P=$(ls "$(sh $X/context-docs.sh --effort "$F")"/ticket-*.md); sed -n '1,6p' "$P" | sed 's|^|    |'
echo "--- the same issue again replaces it"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://github.com/cli/cli/issues/1/'
ls "$(sh $X/context-docs.sh --effort "$F")" | sed 's|^|    |'
echo "--- a cut-off copy says so in its header"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://github.com/golang/go/issues/15292'
sed -n '1,4p' "$(sh $X/context-docs.sh --effort "$F")/ticket-github.com-golang-go-issues-15292.md" | sed 's|^|    |'
echo "--- the docs rule takes the names: the fingerprint is given"
run sh $X/context-fingerprint.sh --effort "$F"
echo "--- not a tracker link: exit 3, nothing written"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://example.com/page'
echo "--- a failed read: exit 1, nothing written"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://github.com/cli/cli/issues/999999999'
ls "$(sh $X/context-docs.sh --effort "$F")" | sed 's|^|    |'
echo "--- a paused effort: refused (exit 2)"
run sh $E/effort-pause.sh --effort "$F" --words "break"
run sh $T/context-add-ticket.sh --effort "$F" --url 'https://github.com/cli/cli/issues/2'
