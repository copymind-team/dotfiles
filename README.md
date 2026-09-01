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
│   ├── .tmux.conf
│   ├── monitor.sh                # leader+M session monitor
│   ├── session-select.sh         # leader+S session picker
│   ├── claude-save.sh            # resurrect hook -> pane -> claude session map
│   ├── claude-restore.sh         # resurrect process -> claude --resume
│   ├── claude-snapshot.sh        # claude session start/exit -> resurrect save
│   └── resurrect-guard.sh        # one save at a time, one per second
├── zsh/
│   ├── .zshrc
│   └── completions/_dev          # Tab completion for the dev CLI
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

`leader + S` — jump to a session:

```
┌──────────────────────────────────────────────────────┐
│ SESSIONS  12                                         │
│                                                      │
│  1  admin                                          1w│
│▸ 2 *dotfiles                                       3w│
│  3 +infra                                          2w│
│  ...                                                 │
│  c  zz-other                                       1w│
│                                                      │
│  j/k move  h/l column  enter switch  x kill          │
│  1-9/a-z/M jump   esc cancel   * here   + attached   │
└──────────────────────────────────────────────────────┘
```

`leader + M` — what every session's Claude is doing:

```
 MONITOR  15 sessions  11 claude  1 working  1 need you  refresh 2s

  you@example.com      11 sess  5h  17% to 5:20PM        7d  28% to Tue 11PM
  work@example.com      2 sess  5h 100% FULL to 6:02PM   7d  91% to Fri 9AM

  1  admin                   shell
  2  api                     draft           12%    $4.10  you       let's draft §3 now
▸ 3  billing                 NEEDS YOU       61%   $22.65  work      Do you want to make this edit to auth.ts?
  4  dotfiles                working         40%   $40.90  you       Cooking…
  5  infra                   idle        5a  14%   $41.61  you       Fix the failing CI job on main
  6  web                     idle            35%   $39.75  work      Check the nightly import status
  ...
  f  zz-other                other                  sleep
                               total active  $499.01  sub ~$487.01   api $12.00     extra ~$4.25
                                      today  $541.20  sub ~$521.20   api $20.00
                                         7d $1180.05  sub ~$1140.05  api $40.00
                                        30d $2620.11  sub ~$2540.11  api $80.00
                                        all $8841.66  sub ~$8601.66  api $240.00

  $1200 ┤                                                  ▃
        │▅ █         ▁                                     █
   $600 ┤█ █ ▁     ▁ █   ▄       ▄ ▁ █ ▃       ▄ ▄   ▁   ▅ █
        │█ █ █   ▂ █ █ ▄ █   ▃ ▁ █ █ █ █ ▂ ▂ ▄ █ █ ▆ █ ▁ █ █
     $0 └──┴─────┴─────┴─────┴─────┴─────┴─────┴───────────┴─
         07/08 10/08 13/08 16/08 19/08 22/08 25/08      31/08

  j/k move   enter jump   1-9/a-z jump directly   u usage   r refresh   q back
```

Under the totals, the last month of spending: dollars up the side, a day per
column. It appears when the terminal has rows to spare for it, and gives them
back to the sessions when it does not.

`u` — the same chart with the whole screen, and the whole history:

```
 USAGE  26 days  total $9370.33  avg $360.39/day  peak $1033.06 Mon 31 Aug

$1250 ┤
      │                                                                     ▂
$1000 ┤                     ▁                                               █
      │                   ▂ █                                               █
 $750 ┤                   █ █         ▃                                     █
      │                   █ █         █               █                     █
 $500 ┤                   █ █         █   ▅       ▆   █ ▂       ▇ ▅       █ █
      │                   █ █ ▆     ▇ █   █       █ ▆ █ █       █ █   ▇   █ █
 $250 ┤                   █ █ █     █ █ ▃ █       █ █ █ █     ▃ █ █ ▆ █   █ █
      │                   █ █ █   ▅ █ █ █ █   █ ▄ █ █ █ █ ▅ ▆ █ █ █ █ █ ▁ █ █
   $0 └─────────────────────┴─────┴─────┴─────┴─────┴─────┴─────┴───────────┴─
                          07/08 10/08 13/08 16/08 19/08 22/08 25/08      31/08

  h/l older/newer   j/k by week   u sessions   r refresh   q back
```

Days nothing ran are the gaps they were, today is bold — it is still being
written — and a column carries the subscription and API-billed parts of its day
in different colors, with a line under the chart naming them when a history has
both. The axis is scaled to the days on screen and labelled in round money; a
day too small for a row still gets an eighth of one. Wider terminals fit more
days, `h`/`l` walk a day and `j`/`k` a week, and `q` goes back to the sessions
rather than out — the small chart downstairs stays on today whatever this one is
scrolled to.

Both need the [Claude Code config](#claude-code-config) installed for the context
and cost columns; without it the states still work.

After a reboot, `tmux-resurrect` brings the layout back with each pane's Claude
conversation still in it, in the directory it was running in — unless you quit
that one with `/exit`, which stays quit.

## Claude Code config

Under every Claude Code session:

```
Opus 5 (1M context) · ctx 24% · $19.71 · 5h 7% · 7d 77%
```

Model, context used, session cost, and how much of the rolling five-hour and
weekly usage windows is gone.

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
