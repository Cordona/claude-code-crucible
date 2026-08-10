# shellcheck shell=sh
#
# pm-glab-env.sh — glab process-environment setup for the
#                  procedure-glab-issues commands.
#
# Pins glab's own optional output/behavior so stdout stays parseable and these
# non-interactive scripts can never block on a prompt.
#
# WHY GLAB_NO_PROMPT MATTERS DIFFERENTLY PER SUBCOMMAND — both halves of this
# are true, and the inline copies this replaced each recorded only their own
# half:
#   * `glab issue create` DOES have a `--yes` flag, and the commands that call
#     it pass it as the primary guard. There GLAB_NO_PROMPT is a SECOND BELT:
#     `--yes` skips the submission confirmation, GLAB_NO_PROMPT stops glab
#     asking anything else.
#   * `glab issue update`, `glab issue note`, `glab issue close` and
#     `glab label create` have NO `--yes` flag at all (verified against glab
#     1.112.0's --help). For those, GLAB_NO_PROMPT is the ONLY prompt
#     suppression available — passing `--yes` would make glab reject the whole
#     invocation as an unknown flag. What keeps `note` out of its interactive
#     editor there is always passing `--message`.
# So this block is load-bearing everywhere, but it is the sole defense in most
# of the suite. Do not assume a `--yes` at the call site makes it redundant.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

# pm_pin_gitlab_host HOST — pin glab's target instance to the ALREADY-CONFIRMED
# host by exporting it as GITLAB_HOST for THIS process.
#
# Exported so every `glab` child of this process inherits it; nothing outside
# the process is touched. Callers invoke this BEFORE their auth precondition, so
# even that check asks about the host the caller confirmed. See any command's
# "HOST PINNING" header block for the full SEC-001 rationale — in short, the
# account gate confirms an (account, HOST) pair, and without this the write
# could still land on a different configured instance that resolves the same
# project path.
pm_pin_gitlab_host() {
	GITLAB_HOST=$1
	export GITLAB_HOST
}
