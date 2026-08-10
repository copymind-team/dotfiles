# claude

The Claude Code setup: shared settings, the two exporter scripts the
[session monitor](../tmux/README.md#session-monitor) reads, and user-level
`skills/`. The [root README](../README.md#claude-code-config) has the short
version.

| File                | What it is                                                   |
| ------------------- | ------------------------------------------------------------ |
| `settings.json`     | Shared: `statusLine` + `hooks` only, nothing else            |
| `merge-settings.sh` | Merges the above into an existing config                     |
| `statusline.sh`     | Status line + context/cost export + spend ledger             |
| `monitor-hook.sh`   | Claude Code hooks → session state + subagent count           |
| `skills/`           | User-level skills, symlinked one by one                      |

## Settings are merged, not symlinked

The scripts and each skill are symlinked. Settings are **merged**, because Claude
writes to that file itself — `/model`, permission changes, enabled plugins — and
a symlink would drag every runtime toggle into git as a dirty working tree.

`claude/settings.json` holds **exactly two keys**: `statusLine` and `hooks`.
Those are what the session monitor reads, so they are the only things worth
sharing. Everything else in a Claude settings file belongs to whoever owns the
laptop and is never tracked:

| Shared, installed for everyone | Yours alone, never touched |
| --- | --- |
| `statusLine` | `editorMode`, `tui`, `model`, `enabledPlugins`, `extraKnownMarketplaces`, notifications |
| `hooks` | `env` and its tokens |
| | `permissions` — including `defaultMode` and the `skip*` prompts, which decide how much Claude does without asking |

The merge only touches the keys it is given, so `./install.sh` on a colleague's
machine gives them the monitor integration and changes nothing else. Their editor
mode, model and permission posture survive every `git pull && ./install.sh`.

The merge is `claude/merge-settings.sh`, runnable and testable on its own:

```bash
claude/merge-settings.sh <live.json> <shared.json>   # merged JSON on stdout
```

It refuses rather than damages — exit 1 on unreadable or invalid JSON, exit 2 if
the shared file has grown an `env` block — and `install.sh` writes through a temp
file, so a failure leaves the existing settings untouched.

The two shared keys are applied differently:

- **`statusLine` is replaced** — there is only one of it. If you already had a
  custom one, the install says so and leaves the previous file at
  `~/.claude/settings.json.bak`.
- **`hooks` are appended per event**, so a colleague's own `PostToolUse`
  formatter keeps running alongside ours. Entries pointing at our script are
  removed first, so re-running never stacks duplicates.

Paths inside are written as `~/.claude/…` rather than absolute, so the file is
portable between machines and between users. Both the status line and hooks run
their command through a shell, so the `~` expands.

## Backstops

`tests/unit/04-claude-settings-merge.test.sh` covers the merge. Its main
assertion is a property rather than a checklist: for every scalar leaf in the
original config, outside the two keys we own, the merged result must hold the
same value at the same path — which covers settings this repo has never heard of.
It runs over a config containing something of everything, over the empty and
near-empty cases, over this machine's real config if there is one, and three
times in a row to prove the result converges. The detector itself is tested
first, against a deliberately lossy pair, because "reports nothing lost" and
"is broken" look identical from the outside.

`tests/unit/03-no-secrets.test.sh` is the other backstop. It scans tracked and
new-but-unignored files for credential-shaped tokens and for secret-named JSON
keys with values, and it asserts the shared settings file contains nothing but
`statusLine` and `hooks` — an allowlist, so widening what this repo pushes onto
other laptops takes a deliberate edit to the test as well. The untracked half of
the scan matters most: a secret is at its most dangerous in the moment before it
is first committed.
