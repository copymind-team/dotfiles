# tmux

`.tmux.conf` plus three features built on top of it: a
[session picker](#session-picker), a [session monitor](#session-monitor) and
[session restore](#session-restore). The first two read what Claude Code exports
about itself, through the hooks and status line in `claude/`.

| File                 | What it is                                 |
| -------------------- | ------------------------------------------- |
| `.tmux.conf`         | Keybindings, appearance, plugins           |
| `session-select.sh`  | `prefix + S` — the picker                  |
| `monitor.sh`         | `prefix + M` — the monitor                 |
| `claude-save.sh`     | resurrect hook → pane → claude session map |
| `claude-restore.sh`  | resurrect process → `claude --resume`      |
| `claude-snapshot.sh` | claude session start/exit → resurrect save |

What follows is what using them will not tell you. Everything else — what the
keys do, what the columns say — the screens say themselves.

## Session picker

`prefix + S`, in place of tmux's own `choose-session`:

```
 SESSIONS  12

  1  admin                     1w
▸ 2 *dotfiles                  3w
  3 +infra                     2w
  M +monitor                   1w
  ...
  c  zz-other                  1w

  j/k move  h/l column  enter switch  esc cancel
  1-9/a-z/M jump directly   * here   + attached
```

- **Keys are stable between openings.** Sessions sort alphabetically, so a key
  only moves when a session is created or destroyed — worth relying on.
- **`M` is always the monitor**, wherever it sorts, and whether or not it is
  running. The key that reaches it here is the one that opens it from anywhere
  else. `m` is held for it too, so the sessions around it keep their keys.
- **`hjkl`, `x` and `m` are not jump keys** — they drive the cursor, kill, and
  belong to the monitor. That leaves 29; sessions past them are reachable with
  the cursor only.
- Tunables: `PICKER_FILTER` (regex; list only matching sessions),
  `PICKER_WIDTH` (popup width, default 56), `PICKER_COLW` (column width once
  there is more than one, default 30), `MONITOR_SESSION` (the session that gets
  `M`, default `monitor`).

## Session monitor

`prefix + M` opens the `monitor` session: one line per tmux session, showing what
its Claude window is doing right now.

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

  j/k move   enter jump   1-9/a-z jump directly   r refresh   q back
```

| State       | Means                                            |
| ----------- | ------------------------------------------------ |
| `working`   | Claude is generating                             |
| `NEEDS YOU` | waiting on a permission, plan or select prompt   |
| `draft`     | text typed into the prompt but not sent          |
| `idle`      | up with an empty prompt; detail is its last task |
| `shell`     | just a shell                                     |
| `other`     | something else running; detail names the command |
| `gone`      | session or pane disappeared                      |

Reading the rows:

- **Blank is not zero.** Context, cost and the account tag come from the status
  line, not the screen. A session with no exporter installed, or one that has not
  answered yet, leaves them empty — that is *unknown*.
- **`5a` says nothing about the state beside it.** A session that handed five
  background agents their work and went quiet reads `idle 5a`, and that is right:
  it will answer you now, its fleet is still busy.
- **The account tag only appears when more than one account is in play.** On a
  single-account screen every row would say the same word.
- **`sub ~$487.01` is not a bill.** It is what the subscription absorbed, priced
  at API rates — nobody charged it, hence the tilde. The window percentages are
  the real constraint. `api` has no tilde: that figure is money.
- **`extra` is a floor.** Spend attributed to a window that already read full,
  and only ever on `active`. See [usage windows](#usage-windows).
- `active` and `today` overlap on purpose — live sessions are part of the day
  they are running in. `7d` and `30d` are calendar days including today.

Worth knowing:

- **The context and cost columns need the exporters.** Sessions on a machine
  without `claude/` installed still get a state, from the screen, and nothing
  else.
- **The subagent count is never aged out**, unlike the state — expiring it would
  blank it on exactly the sessions it exists for. A pane with no Claude in it
  counts nothing, so a killed fleet stops being reported.
- **Only subagents are counted.** Background shells, MCP tasks and monitors are
  left out; Claude's own footer already counts those.
- **A parked job is followed.** Handed something long, Claude moves the work to a
  background session with no pane of its own; the row follows it, so the numbers
  are the working session's rather than the pane's frozen last reading. One that
  never reports finishing leaves files behind — `rm ~/.claude/monitor/sess-*`
  while nothing is parked is the whole cleanup story.
- Tunables: `MONITOR_INTERVAL` (seconds, default 2), `MONITOR_WINDOW` (preferred
  window name, default `claude`), `MONITOR_FILTER` (regex, e.g. `^web-`),
  `MONITOR_SESSION` (default `monitor`), `CLAUDE_MONITOR_DIR` (default
  `~/.claude/monitor`), `CLAUDE_SESSION_DIR` (default `~/.claude/sessions`),
  `MONITOR_STALE` (seconds an exported state stays trusted, default 90),
  `CLAUDE_OVERAGE_AT` (window percentage counted as exhausted, default 100).
- Claude Code's UI strings live in `monitor_classify()` and
  `monitor_busy_titles()` — the places to fix if a release reworks the footer.
- `prefix + M` replaces tmux's default "clear marked pane"; `prefix + m` still
  toggles a mark.

### Usage windows

The account lines carry the rolling five-hour window and the weekly one, each
with the time it clears. `FULL` is drawn in red at 100 or above — the figure is
not clamped, and `101` has turned up in live exports.

Two things stay off those lines. **API-billed sessions** have no rate limits at
all, so they are tagged `api` and get no line; counting them against whichever
address the config holds would charge them to a subscription they do not spend
from. **Sessions that have not answered** are tagged blank, and if nothing on
screen names an account, the monitor falls back to a single pair in the header.

Once extra usage is switched on, treat `extra` as a floor: the API can report the
weekly window as `seven_day_overage_included`, folding the overage headroom into
the denominator, so it may never read 100 while overage is being spent.
`CLAUDE_OVERAGE_AT` is the knob if the percentage behaves differently.

### What the account tag means

**The account that was signed in when those numbers came back.** Not the one the
session will use next. The distinction is the whole design, and getting it wrong
is visible.

Claude tells a status line nothing about who is signed in — not in the payload,
the transcript or the session registry. The only place it is written down is
Claude's own config, which with a single config dir is one global file that
`/login` rewrites for every session on the machine at once. Reading it at render
time would relabel the entire fleet to an account most of it never used, while
still showing the previous account's usage underneath. So the label is only
refreshed when the session has actually heard from the API since its last export.

Two consequences worth expecting:

- **A line can name an account you have already left.** That is correct — those
  numbers are that account's. It clears itself the moment the session answers.
- **After a switch, nothing says which account an idle session will bill next.**
  Nothing observable from outside the process distinguishes a session that has
  picked up new credentials from one that has not, so the monitor does not guess.

`/login` gives you one account at a time. To keep two signed in at once, give
each its own config directory — it carries the whole account store:

```sh
CLAUDE_CONFIG_DIR=~/.claude-work claude    # /login once, then it stays
```

The monitor needs nothing configured for that: those sessions export their own
address and pick up their own line.

### Spend over time

The `active` row only knows about sessions that are still up, so `statusline.sh`
also keeps a ledger in `~/.claude/monitor/spend`, which is what `today`, `7d`,
`30d` and `all` are read from.

- **It starts when it is installed.** There is no history before the first write.
- **It counts sessions outside tmux too**, being keyed by session id rather than
  by pane — and it is this machine only.
- **A session already running at install** had nothing to measure against, so its
  history up to that point landed on that one day.
- **Nothing is ever pruned.** `rm ~/.claude/monitor/spend/2025-*` is the whole
  cleanup story, at the cost of those days leaving `all`.

## Session restore

`tmux-resurrect` saves the layout and `tmux-continuum` replays it, every five
minutes and again on the next tmux server start. That brings back the windows,
the panes and each pane's directory — but not what was running in them: `claude`
is not on resurrect's default process list, so a claude window came back as a
bare shell.

Three scripts close that gap. Two hang off resurrect's hooks, one off Claude's:

| Script                    | Runs                                                | Does                                                |
| ------------------------- | --------------------------------------------------- | --------------------------------------------------- |
| `claude-save.sh`          | `@resurrect-hook-post-save-all`, i.e. on every save | Writes `~/.claude/resurrect-map`                    |
| `claude-restore.sh`       | `@resurrect-processes`, in each restored claude pane| `exec claude --resume <the session that was there>` |
| `claude-snapshot.sh`      | Claude's `SessionStart` and `SessionEnd` hooks      | Takes a resurrect save when the state changes       |

Claude already knows which conversation is in which pane —
`~/.claude/sessions/<pid>.json` carries the session id, the cwd and the tmux
pane — but those files do not outlive the process. `claude-save.sh` copies the
fields into one map keyed by the coordinates resurrect rebuilds from, with the
tmux socket alongside, since coordinates repeat between servers:

```
infra:1.1   /Users/you/repo.git/infra   0101c585-…   /private/tmp/tmux-501/default
web:1.1     /Users/you/repo.git/web     da7d9d42-…   /private/tmp/tmux-501/default
web:1.2     /Users/you/repo.git/web     9e49e366-…   /private/tmp/tmux-501/default
```

Two conversations in one directory get a line each, which is the case
`claude --continue` cannot express — it can only hand back the newest. On the way
back:

| Situation                                          | Result                 |
| -------------------------------------------------- | ---------------------- |
| A line for these coordinates, on this server       | `claude --resume <id>` |
| No line, nothing else claims the cwd, and the cwd has a conversation | `claude --continue` |
| No line, but another pane claims the cwd           | `claude` (fresh)       |
| Map missing, transcript deleted, id malformed, line from another tmux server | `claude` (fresh) |

### The directory comes from the map, not the pane

resurrect recreates a pane in whatever path its own save recorded, and that path
is a guess: read off the pane's process, falling back to the home directory when
the directory has since been deleted, and self-perpetuating once wrong, because
the next save records the wrong answer again.

So the cwd in the map is the answer rather than a check — it is where claude
itself said it was running, and `claude-restore.sh` moves there before exec'ing.
If that directory is gone, the pane stays where resurrect put it.

`--continue` is skipped where another pane claims the same directory, and where
the directory has no conversation at all: there it does not start fresh but
fails, taking the shell it was exec'd over with it.

### A session you quit stays quit

What a pane comes back as is decided by the last snapshot, so anything between
two saves is invisible — a session started since the last save came back as a
bare shell, and one quit with `/exit` reopened on the next boot.

`claude-snapshot.sh` saves when the state changes instead. On `SessionStart`,
straight away; on `SessionEnd`, once the process is actually gone, since the hook
fires while claude is still up. Only a deliberate exit counts:

| Reason              | Means                                      | Snapshot |
| ------------------- | ------------------------------------------ | -------- |
| `prompt_input_exit` | `/exit`, or `^D`                           | yes      |
| `logout`            | `/logout`                                  | yes      |
| `clear`             | `/clear` — the pane still has claude in it | no       |
| `other`             | signalled, e.g. by a reboot                | no       |

That last row is the one that matters: a machine going down signals claude like
anything else, and treating that as "you are done here" would save a screenful of
empty shells over the layout at the one moment it is most worth keeping.

Worth knowing:

- **Nothing snapshots during a restore, or for two minutes after.** A restore
  brings panes up one at a time, and a save taken mid-flight records half a
  layout. Starts are also debounced to one save per 30 seconds.
- **`claude-restore.sh` ends in `exec`, always.** resurrect works out what a pane
  was running by asking `ps` for the shell's child, so a wrapper left in between
  would be recorded instead of `claude`, stop matching, and the pane would
  restore exactly once.
- **Restoring a full fleet starts every claude at once.** Nothing is sent to the
  API until you type, but the transcripts are read from disk.
- Tunables: `CLAUDE_RESURRECT_MAP` (default `~/.claude/resurrect-map`),
  `CLAUDE_SESSION_DIR` (default `~/.claude/sessions`), `CLAUDE_PROJECTS_DIR`
  (default `~/.claude/projects`), `CLAUDE_SNAPSHOT_DEBOUNCE` (30s),
  `CLAUDE_SNAPSHOT_COOLDOWN` (120s), `CLAUDE_SNAPSHOT_WAIT` (30s).
- To turn it off, drop `@resurrect-processes` from `.tmux.conf`; panes still come
  back in the right directory, just without claude in them.
