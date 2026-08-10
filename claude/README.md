# claude

The Claude Code setup: shared settings, the two exporter scripts the
[session monitor](../tmux/README.md#session-monitor) reads, and user-level
`skills/`.

| File                | What it is                                         |
| ------------------- | --------------------------------------------------- |
| `settings.json`     | Shared: `statusLine` + `hooks` only, nothing else   |
| `merge-settings.sh` | Merges the above into an existing config            |
| `statusline.sh`     | Status line + context/cost export + spend ledger    |
| `monitor-hook.sh`   | Claude Code hooks → session state + subagent count  |
| `skills/`           | User-level skills, symlinked one by one             |

## Settings are merged, not symlinked

The scripts and each skill are symlinked. Settings are **merged**, because Claude
writes to that file itself — `/model`, permission changes, enabled plugins — and
a symlink would drag every runtime toggle into git as a dirty working tree.

`settings.json` holds **exactly two keys**, `statusLine` and `hooks`, because
those are what the monitor reads. Everything else belongs to whoever owns the
laptop and is never tracked — editor mode, model, plugins, the `env` block with
its tokens, and `permissions`, which decides how much Claude does without asking.
The merge cannot touch a key it was not given, so `git pull && ./install.sh`
leaves all of it alone.

What that means in practice:

- **`statusLine` is replaced** — there is only one of it. If you had a custom
  one, the install says so and leaves the previous file at
  `~/.claude/settings.json.bak`.
- **`hooks` are appended per event**, so your own `PostToolUse` formatter keeps
  running alongside these. Entries pointing at our scripts are dropped first, so
  re-running converges instead of stacking duplicates.
- **It refuses rather than damages** — exit 1 on invalid JSON, exit 2 if the
  shared file has grown an `env` block — and `install.sh` writes through a temp
  file, so a failure leaves your settings untouched.
- Paths are written as `~/.claude/…` rather than absolute, so the file is
  portable between machines and users.

Runnable on its own:

```bash
claude/merge-settings.sh <live.json> <shared.json>   # merged JSON on stdout
```

Two tests hold the line. `04-claude-settings-merge.test.sh` asserts a property
rather than a checklist — every scalar leaf outside the two keys we own survives
at the same path, which covers settings this repo has never heard of.
`03-no-secrets.test.sh` scans tracked *and untracked* files for credentials, a
secret being at its most dangerous in the moment before it is first committed.
