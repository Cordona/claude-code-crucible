# Probe: SubagentHandback and the report repair loop (2026-11-28)

Claude Code v2.1.332, the sandbox config. A haiku stand-in agent appends a line to a file and reports. The hooks log every call and can deny the handback or block the stop. No framework. The kit was in `/Users/Shared/crucible-sandbox/handback-probe` (hooks, log).

| # | Question | Answer, as observed |
|---|---|---|
| 1 | Does PreToolUse fire for `SubagentHandback` inside a subagent, with `agent_id` and `agent_type`? | Yes, both present; PostToolUse fires too |
| 2 | Denied there, does the agent get the reason and keep working? | Yes: it did what the reason asked (REPAIRED-1), then handed back again, which passed, all in one run. Main saw only the delivered report |
| 3 | Does a SubagentStop block after a handback restart the agent? | No. The block fired after the handback and the agent didn't run again (no STOP-REPAIRED). `last_assistant_message` is empty there |
| 4 | Every handback denied: what then, and what does main see? | The agent tries again, then stops without handing back. SubagentStop fires then, with its last message. Claude Code tells main the agent "ended without sending its report"; main reported no result and resumed the agent itself, which tried again |
| 5 | Control: in the foreground (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`) in auto mode | Same as 3: it hands back, and a stop block doesn't restart it |
| 5b | Not auto mode (`bypassPermissions`), backgrounded | No handback. A SubagentStop block does restart the agent (STOP-REPAIRED-1): the stop hook's repair loop works |
| 6 | Is `SubagentHandback` documented? | Yes, thinly: the tools reference says it delivers a subagent's final report, "provided only in auto mode, to subagents that the Agent tool runs locally other than forks", v2.1.271 or later. The sub-agents page names it once |

**What follows:**
- **Two doors, both live.** In auto mode the agent hands back, and only a check at the handback can send it back. In every other mode, and for an agent that stops without handing back, the stop hook is the door.
- **build-agent's "8-recovered"** was a scripted stop hook, not a live auto-mode agent, so it never covered the handback.
- **Main isn't handed a refused report.** With the check at the handback, a refused report is never delivered. If the agent gives up, Claude Code itself tells main it ended without a report. Nothing earlier than main's stop is needed for task #85.
- **If Claude Code drops or renames the handback,** the PreToolUse matcher simply never fires, and the stop hook works as it does today. Nothing else depends on the name.
