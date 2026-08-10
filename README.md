# dotfiles

Team configuration files for local development.

## What's included

| Tool                                                         | What it does                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| [Ghostty](https://ghostty.org/)                              | GPU-accelerated terminal emulator                             |
| [Neovim](https://neovim.io/)                                 | Text editor, used as the primary IDE                          |
| [tmux](https://github.com/tmux/tmux)                         | Terminal multiplexer — split panes, persistent sessions       |
| [Zsh](https://www.zsh.org/) + [Oh My Zsh](https://ohmyz.sh/) | Shell with plugins, themes, and better defaults               |
| [Homebrew](https://brew.sh/)                                 | macOS package manager, installs everything above              |
| [ripgrep](https://github.com/BurntSushi/ripgrep)             | Fast recursive code search, used by Neovim's Telescope        |
| [TPM](https://github.com/tmux-plugins/tpm)                   | Tmux Plugin Manager, auto-installs tmux plugins               |
| [Supabase CLI](https://supabase.com/docs/guides/cli)         | Local Supabase stack, required by `dev sb`                    |
| [Node.js](https://nodejs.org/)                               | Runtime for `pgflow`                                          |
| [Corepack](https://github.com/nodejs/corepack)               | Provides pnpm/yarn shims pinned per-project (ships with Node) |
| [pgflow](https://pgflow.dev/)                                | Flow compiler, required by `dev sb flow`                      |

## Structure

```
dotfiles/
├── claude/
│   ├── README.md                  # How the settings merge works, and what it guarantees
│   ├── settings.json              # Shared: statusLine + hooks only, nothing else
│   ├── merge-settings.sh          # Merges the above into an existing config
│   ├── statusline.sh              # Status line + context/cost export + spend ledger
│   ├── monitor-hook.sh            # Claude Code hooks -> session state + subagent count
│   └── skills/                    # User-level skills, symlinked one by one
├── ghostty/.config/ghostty/
├── neovim/.config/nvim/
├── scripts/
│   ├── dev.sh                    # Entry point
│   ├── dev-session.sh            # Tmux sessions
│   ├── dev-worktree.sh           # Worktree dispatcher
│   ├── dev-worktree-init.sh
│   ├── dev-worktree-up.sh
│   ├── dev-worktree-down.sh
│   ├── dev-worktree-env.sh
│   ├── dev-worktree-port.sh
│   ├── dev-worktree-info.sh
│   ├── dev-supabase.sh           # Supabase dispatcher
│   ├── dev-supabase-up.sh
│   ├── dev-supabase-down.sh
│   ├── dev-supabase-status.sh
│   ├── dev-supabase-link.sh
│   ├── dev-supabase-unlink.sh
│   ├── dev-supabase-sync.sh
│   ├── dev-supabase-migrate.sh
│   ├── dev-supabase-seed.sh
│   ├── dev-supabase-reset.sh
│   ├── dev-supabase-flow.sh
│   ├── dev-supabase-anchor.sh
│   ├── dev-env.sh                # Env-vars dispatcher
│   ├── dev-env-add.sh
│   ├── dev-env-remove.sh
│   ├── dev-env-pull.sh
│   ├── dev-env-push.mjs
│   ├── dev-nanoclaw.sh           # NanoClaw dispatcher
│   ├── dev-nanoclaw-up.sh
│   ├── dev-nanoclaw-down.sh
│   ├── dev-update.sh             # Pull latest dotfiles changes
│   ├── *.helpers.{sh,mjs}        # Sourced libraries (not callable)
│   └── templates/                # File templates used by scripts above
├── tests/
│   ├── unit/                     # Pure function tests
│   ├── integration/              # Single-command tests
│   └── e2e/                      # Multi-command workflows
├── tmux/
│   ├── README.md                 # The picker, the monitor and session restore in full
│   ├── .tmux.conf
│   ├── monitor.sh                # prefix+M session monitor
│   ├── session-select.sh         # prefix+S session picker
│   ├── claude-save.sh            # resurrect hook -> pane -> claude session map
│   ├── claude-restore.sh         # resurrect process -> claude --resume
│   └── claude-snapshot.sh        # claude session start/exit -> resurrect save
├── zsh/.zshrc
├── test.sh                       # Test runner shortcut
└── install.sh
```

## `dev` CLI

Unified entry point for development tools.

| Command        | Alias    | Description                                          |
| -------------- | -------- | ---------------------------------------------------- |
| `dev session`  | `dev s`   | Tmux dev sessions                                    |
| `dev supabase` | `dev sb`  | Shared local Supabase instance                       |
| `dev worktree` | `dev wt`  | Git worktrees with Docker isolation                  |
| `dev env`      | `dev e`   | Env vars across `.env.example`, `.env.local`, Vercel |
| `dev nanoclaw` | `dev nc`  | Manage the NanoClaw host service via launchd        |
| `dev update`   | `dev upd` | Pull latest dotfiles changes                         |

### `dev s` — Session

| Command       | Description                                              |
| ------------- | -------------------------------------------------------- |
| `dev s [dir]` | Create a tmux dev session (claude, nvim, docker windows) |

### `dev sb` — Supabase

All commands operate on the shared supabase worktree regardless of which worktree you invoke them from.

| Command                 | Description                                                                                                                              |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `dev sb up`             | Create supabase worktree and start Supabase                                                                                              |
| `dev sb down [--force]` | Stop shared Supabase instance                                                                                                            |
| `dev sb status`         | Show Supabase status                                                                                                                     |
| `dev sb link`           | Symlink current worktree's migrations and apply                                                                                          |
| `dev sb unlink`         | Remove current worktree's migration symlinks                                                                                             |
| `dev sb sync [--reset]` | Fetch origin/main, update supabase worktree, clean stale symlinks                                                                        |
| `dev sb migrate`        | Apply pending migrations in the shared worktree                                                                                          |
| `dev sb seed`           | Apply pending seeds from `supabase/seeds/` (skips `users.sql`; tracked in `supabase_seeds.applied_seeds` — rename a seed to re-apply it) |
| `dev sb reset`          | Full local reset: `db reset` → apply migrations → seed `users.sql` → apply seeds → background `functions serve`                          |
| `dev sb flow [slug]`    | Compile pgflow flows from the invoking worktree and apply against the shared stack.                                                      |
| `dev sb anchor`         | Point edge runtime's `COPYMIND_API_HOST` at this worktree's port                                                                         |

### `dev wt` — Worktree

Must be run from inside a bare-cloned repo. Repo name and paths are detected automatically.

| Command                | Description                                                      |
| ---------------------- | ---------------------------------------------------------------- |
| `dev wt init`          | Bootstrap first worktree + port registry from a fresh bare clone |
| `dev wt up <branch>`   | Create a git worktree with Docker isolation                      |
| `dev wt down <branch>` | Tear down a git worktree and free the port                       |
| `dev wt env`           | Set up .env.local for current worktree                           |
| `dev wt port`          | Write docker-compose.override.yml from the port registry         |
| `dev wt info`          | Show info about the current worktree                             |

### `dev e` — Env vars

Manages env vars across three places at once: `.env.example` (committed inventory, flat alphabetical), `.env.local` (gitignored cache), and Vercel (canonical store, all entries written as Plain Text/non-sensitive). Must be run from inside a Vercel-linked worktree.

`--prod` targets `production` + `preview` on Vercel. `--dev` targets `development` only. Default (no flag) targets all three plus `.env.local`.

| Command                             | Description                                                                                                                |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `dev e add [--prod\|--dev] NAME`    | Insert into `.env.example`, prompt for value(s), push to selected Vercel envs as non-sensitive, mirror dev to `.env.local` |
| `dev e remove [--prod\|--dev] NAME` | Remove from selected Vercel envs and `.env.local`. Full remove (no flag) also drops the line from `.env.example`           |
| `dev e pull`                        | Replace `.env.local` with the development env from Vercel (flat alphabetical), backfill local-dev defaults, report drift   |
| `dev e push [--force]`              | Bulk-upload `.env.local` to Vercel `development`. Skips existing keys unless `--force`. `VERCEL_*` keys are always skipped |

`add` / `remove` / `pull` / `push` all talk to Vercel via the REST API, not the `vercel env` CLI — see `dev-env.helpers.mjs`. This bypasses Vercel CLI quirks like the un-skippable preview git-branch prompt (vercel/vercel#15763).

### `dev nc` — NanoClaw

| Command       | Description                                                      |
| ------------- | ---------------------------------------------------------------- |
| `dev nc up`   | Bootstrap NanoClaw via launchd (kickstarts a stale registration) |
| `dev nc down` | Bootout NanoClaw via launchd                                     |

## tmux

The prefix is `C-b`, splits are `v` and `s`, and panes are navigated with `hjkl`.
Beyond that, three features live in `tmux/` — [tmux/README.md](tmux/README.md)
covers the parts using them will not teach you.

| Binding      | Feature                                           | What it does                                                                   |
| ------------ | ------------------------------------------------- | -------------------------------------------------------------------------------- |
| `prefix + S` | [Session picker](tmux/README.md#session-picker)   | Every session in a popup, one keystroke to switch                              |
| `prefix + M` | [Session monitor](tmux/README.md#session-monitor) | One row per session: what its Claude is doing, what it has cost, what is left   |
| —            | [Session restore](tmux/README.md#session-restore) | The layout after a reboot, with each pane's Claude conversation still in it     |

The monitor is the one worth a sentence more: it reads what Claude Code exports
about itself — context, cost, usage windows, subagents in flight — from the
hooks and status line installed by [claude/](claude/README.md), so a machine
without those gets the states and nothing else.

## Claude Code config

`claude/` holds the Claude Code setup: the shared settings, the two exporter
scripts the session monitor reads, and user-level `skills/`. The scripts and each
skill are symlinked; **settings are merged**, because Claude writes to that file
itself and a symlink would drag every runtime toggle into git.

Only `statusLine` and `hooks` are shared. Your model, editor mode, plugins, `env`
block and permission posture are never tracked and never touched — see
[claude/README.md](claude/README.md).

## Testing

```bash
./test.sh                    # all tests
./test.sh --unit             # unit only (no Docker/Supabase needed)
./test.sh --integration      # integration only
./test.sh --e2e              # e2e only
./test.sh link               # pattern filter
```

Requires everything `install.sh` sets up (`supabase`, `jq`, `pgflow`, `node`, …) plus `psql`, `rsync`, `curl`, `docker`. Run `./install.sh` before the first test run.

## Installation

```bash
git clone https://github.com/copymind-ai/dotfiles.git
cd dotfiles
./install.sh
```

The install script will install all tools from the table above and symlink configs to their expected locations. Existing config files are backed up with a `.bak` suffix before symlinking.

## Adding a new config

1. Move the config file/folder into the dotfiles repo, mirroring the home directory structure
2. Add a `link` entry in `install.sh`
3. Run `./test.sh --unit` — it will refuse anything carrying a credential
4. Commit and push

Use `link` for step 2: it backs up whatever is already at the destination, and
replaces an existing directory rather than creating the symlink inside it.

## Keeping in sync

```bash
git pull && ./install.sh
```
