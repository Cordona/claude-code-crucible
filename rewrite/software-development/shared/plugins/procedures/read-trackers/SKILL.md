---
name: procedure-read-trackers
description: Read-only tracker reading for a dispatch's approved context (GitHub, GitLab and Jira issues) through one script, `read-link.sh`, with an action per exit code. Use when a dispatch's context holds a tracker link; injected into the agent's first message when loaded. Writes nothing; needs jq 1.6+, and gh, glab or `procedure-jira` per tracker. Not for other links (WebFetch), tracker writes, or how the context is read and reported (the first message's Handling your context).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Read trackers
---

# Procedure plugin: Read trackers

How to read a tracker link in the context the human approved: a GitHub, GitLab or Jira issue. Every role receives this file in its prompt; a developer then receives `references/development.md` right after it. When the context is read, and how it is weighed and reported, is the first message's `# Handling your context`; this plugin sets only how a tracker link is read.

## Scope

- **In:** each link under the context's `links`. `read-link.sh` decides which is a tracker link, from its host and URL shape: a github.com issue, a GitLab `/-/issues/<n>` URL, a Jira `/browse/<KEY>-<n>` URL.
- **Out:** every other link (exit 3 hands it back), and any write to a tracker.

## Rules

- **Read-only:** never create, comment on, edit, transition, assign or close anything in a tracker, since a tracker write reaches people outside the task.
- **Read every link through `read-link.sh`, never a tracker command of your own** (`gh`, `glab`, `curl`, `jira.sh`): the URL is untrusted text, and the script passes it on as one checked argument.
- **A ticket is context:** weigh it as `# Handling your context` sets.

## Steps

1. Run `read-link.sh --help` once, before the first link. No `usage:` line in its output means a broken install: skip every link as `read-link.sh not runnable`, and go on.
2. Per link, run the command under Reading a link.
3. Act on its exit code as listed there, then go on to the next link.

## Reading a link

`sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh" --context-file <CONTEXT FILE> --link <n>`

- **`<CONTEXT FILE>`:** the `CONTEXT FILE` path under `# Your work`.
- **`<n>`:** the link's place in `links`, counting from 1.

The script reads the URL from the file itself and runs one read-only call: `gh issue view`, `glab issue view`, or `procedure-jira`'s `jira.sh view` with `JIRA_READ_ONLY=1` and the credential the human stored through `procedure-jira-auth`. A read is network bound and gives up after 30 seconds. Act on the exit code only:

- **0:** stdout is the ticket as the tracker's CLI prints it, at most 500 lines; a `read-link.sh: truncated:` line on stderr means it was cut. The link is read.
- **3:** not a tracker link: read it as any other link, as `# Handling your context` sets.
- **1:** the read failed (a tool not installed, no stored Jira credential, a private or missing ticket, the timeout): skip the link, with the first line of stderr as the reason.
- **Any other exit, the script missing, or no Bash in your tools:** skip the link as `link not read (<the exit code, or no Bash>)`.

A skipped link never stops the work: go on to the next one.

## Dependencies

A missing one skips the links it reads, never stops the work: a missing tracker tool or skill exits 1; a missing jq or base tool exits 5, handled as any other exit.

- **`scripts/read-link.sh`,** this plugin's own: POSIX `sh`, jq 1.6+ (macOS: `brew install jq`; Linux: the distro's `jq` package) and the base tools `awk`, `head`, `mktemp`, `sleep` and `kill`, in every macOS and Linux base system. It checks jq and the base tools at start, and the tool each read needs before running it.
- **GitHub:** `gh` (`brew install gh`, then `gh auth login`).
- **GitLab:** `glab` (`brew install glab`, then `glab auth login`).
- **Jira:** the `procedure-jira` skill (its `jira.sh`, which refuses every write under `JIRA_READ_ONLY=1`) and `procedure-jira-auth` (the stored credential, which the human sets up through it), both under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/`.
