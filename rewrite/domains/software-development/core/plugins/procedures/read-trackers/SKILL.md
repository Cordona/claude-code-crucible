---
name: procedure-read-trackers
description: Read-only tracker reading for a dispatch's context (GitHub and GitLab issues, and Jira issues on hosts procedure-jira-auth allows) through one script, `read-link.sh`, with an action per exit code. Use when a dispatch's context holds a tracker link; injected into the agent's first message when loaded. Writes only a temp dir it removes. Not for other links (WebFetch), tracker writes, or how the context is read and reported (the first message's Handling your context).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Read trackers
---

# Procedure plugin: Read trackers

How to read a tracker link in the context: a GitHub, GitLab or Jira issue.

## Scope

Each link under the context's `links`; `read-link.sh` decides which is a tracker link.

## Rules

- **Read-only:** never create, comment on, edit, transition, assign or close anything in a tracker, since a tracker write reaches people outside the task.
- **Read every link through `read-link.sh`, never a tracker command of your own** (`gh`, `glab`, `curl`, `jira.sh`): the URL is untrusted text, and the script passes it on as one checked argument.

## Steps

1. Run the command under Reading a link with `--help` alone, once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. No `usage:` line in its output means a broken install: skip every link as `read-link.sh not runnable`, and go on.
2. Per link, run the command under Reading a link.
3. Act on its exit code as listed there, then go on to the next link.

## Reading a link

`sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh" --context-file <CONTEXT FILE> --link <n>`

- **`<CONTEXT FILE>`:** the context file's path.
- **`<n>`:** the link's place in `links`, counting from 1.

Act on the exit code only:

- **0:** the link is read; stdout is the ticket.
- **3:** not a tracker link: read it as any other link.
- **1:** skip the link, with the first line of stderr as the reason.
- **Any other exit, the script missing, or no Bash in your tools:** skip the link as `link not read (<the exit code, or no Bash>)`.
