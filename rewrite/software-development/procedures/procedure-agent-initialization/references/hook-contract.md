# Hook contract: registration and injected blocks

The `inject-plugins.sh` hook's settings entry, and the shape of what it adds to a dispatched agent's prompt. SKILL.md's Scripts section points here when step 1's checklist shows the hook not registered; its Scripts section, when a hook denial or a not-injected refusal needs the block's shape.

## Registering the hook

The owner adds this entry to the global `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`, merged into any existing `hooks.PreToolUse` list, never replacing another entry; the procedure never writes it. To disable the hook, remove the entry; step 1 then stops every dispatch.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent",
        "hooks": [
          {
            "type": "command",
            "command": "sh \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-agent-initialization/scripts/inject-plugins.sh\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

- **`timeout` 30 (seconds):** the owner's bound, so a stuck hook can't hold the dispatch.
- **An entry added this session:** Claude Code reads hooks at session start, so it takes effect only after `/hooks` review or a restart; until then the agent refuses as `PLUGIN: not injected`, and SKILL.md step 9 tells the user to run `/hooks` or restart.

## What the agent receives

The hook builds each block as Claude Code builds a skill preloaded through an agent's `skills:` field: the same header, base-directory line and body rule, user role, after the brief. Example for one plugin (illustrative path):

```
<the brief as the main thread wrote it>

<command-message>tech-shell</command-message>
<command-name>tech-shell</command-name>
<skill-format>true</skill-format>
Base directory for this skill: /home/u/.claude/skills/tech-shell

<SKILL.md after its frontmatter, the one blank line after the closing --- removed>

<development.md (developer) or review.md (reviewer, once `code-reviewer` exists, #64; when present), whole>
```

- **One block per plugin folder, in `PLUGIN` order;** the brief is followed by two newlines (`\n\n`), then the first block.
- **No blank line inside the header:** the header's last line is followed directly by the base-directory line, as Claude Code's preload delivers them.
- **Denied block shapes:** the hook denies a plugin whose first path on the `PLUGIN` line isn't its `SKILL.md`, and a plugin folder whose paths are split into two runs by another plugin's; `render-plugin-line.sh` never produces either.
- **One empty line between a block's files, and between blocks:** each file keeps its final newline, and one is added where it's missing, except after the last file of the last block, which keeps its own ending; one more newline follows each file but that last one.
- **Line endings:** a body keeps its CRs; only the frontmatter's `---` fence lines and the blank line after the frontmatter tolerate a CR.
- **Different from a preload:** the blocks sit inside the prompt message, not in separate messages, since a `PreToolUse` hook can only rewrite the prompt; and the role's reference file follows its plugin's `SKILL.md` body in the same block, since Claude Code preloads no reference file.
- **Templates, developer only:** a plugin's `<plugin>/references/*-template.md` files are on the developer's `PLUGIN` line too, so each arrives whole in its plugin's block, after `development.md`.
- **A plugin can't be preloaded at all:** Claude Code skips a `skills:` entry whose skill sets `disable-model-invocation: true`, which every plugin does. For a dispatched agent, the hook is the only way in; direct implementation is the main thread reading the files itself (step 10).
