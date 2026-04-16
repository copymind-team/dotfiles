# Tests

Unified test suite: bare repo + real Supabase container, ordered from pure logic through per-command integration to full migration lifecycle.

## Prerequisites

- `git`, `supabase` CLI, `docker`, `jq`
- Docker daemon running

## Running

```bash
./tests/run.sh              # all tests
./tests/run.sh migrate      # only *migrate* tests
./tests/run.sh unit          # only *unit* tests
```

Uses test project `test-int` on ports 54421/54422, so it can run alongside a real Supabase instance (54321/54322).

## Test sequence

| #   | File                             | What it tests                                         |
| --- | -------------------------------- | ----------------------------------------------------- |
| 01  | `01-unit-logic.test.sh`          | Pure functions: sanitization, port alloc, upsert_env, classify_var, discover_vars, migrate helpers |
| 02  | `02-routers.test.sh`             | Command dispatch, usage output, non-bare repo checks  |
| 03  | `03-worktree-supabase.test.sh`   | `dev wt sb` — creates migration hub, idempotent       |
| 04  | `04-worktree-up.test.sh`         | `dev wt up` — worktree, port, .env, override, supabase integration |
| 05  | `05-worktree-env.test.sh`        | `dev wt env` — real Supabase var injection             |
| 06  | `06-worktree-info.test.sh`       | `dev wt info` — registry, worktree listing             |
| 07  | `07-worktree-up-second.test.sh`  | `dev wt up` — port increment, multi-worktree           |
| 08  | `08-migrate.test.sh`             | Full migration lifecycle: link, idempotent, multi-wt, timestamp conflict, merge-to-main |
| 09  | `09-worktree-down.test.sh`       | `dev wt down` — teardown, registry cleanup, DB repair  |
| 10  | `10-post-cleanup.test.sh`        | Post-cleanup sanity: hub clean, DB consistent          |
