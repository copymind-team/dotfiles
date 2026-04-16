# Tests

## Structure

```
tests/
  helpers.sh              # Shared assert functions and test utilities
  run-unit.sh             # Unit test runner
  unit/                   # Unit tests (no Docker/Supabase required)
    dev.test.sh
    dev-session.test.sh
    dev-supabase.test.sh
    dev-worktree.test.sh
    dev-worktree-down.test.sh
    dev-worktree-env.test.sh
    dev-worktree-info.test.sh
    dev-worktree-migrate.test.sh
    dev-worktree-supabase.test.sh
    dev-worktree-up.test.sh
  e2e/                    # End-to-end tests (require Docker + Supabase)
    test-migration-hub.sh
```

## Running unit tests

```bash
./tests/run-unit.sh              # all unit tests
./tests/run-unit.sh env          # only *env* tests
./tests/run-unit.sh migrate      # only *migrate* tests
```

Prerequisites: `git` only. No Docker or Supabase needed.

## Running e2e tests

```bash
./tests/e2e/test-migration-hub.sh
```

Prerequisites: `git`, `supabase` CLI, `docker`, `jq`, Docker daemon running.

No need to stop your existing Supabase — the test uses its own project (`test-mh`) on separate ports (`54421`/`54422`) so both can run simultaneously.

### E2E: migration hub (12 tests)

Self-contained — creates a temporary bare git repo, starts Supabase, runs all 12 tests, and cleans up.

| #   | Test                       | Commands tested       | Key assertion                               |
| --- | -------------------------- | --------------------- | ------------------------------------------- |
| 1   | Supabase wt setup          | `dev wt sb`           | Hub created, migrations applied, idempotent |
| 2   | Create feature wt          | `dev wt up`           | Hub refreshed, no symlinks                  |
| 3   | Migrate — no new           | `dev sb migrate`      | "No new migrations"                         |
| 4   | Migrate — new migration    | `dev sb migrate`      | Symlinked + applied to DB                   |
| 5   | Migrate — idempotent       | `dev sb migrate`      | Skips already-symlinked                     |
| 6   | Migrate — second migration | `dev sb migrate`      | Only new file symlinked                     |
| 7   | Merged to main             | `dev sb migrate`      | Symlink replaced by real file from origin   |
| 8   | Multi-worktree coexistence | `dev wt up` + migrate | Both worktrees' symlinks coexist            |
| 9   | Timestamp conflict         | `dev sb migrate`      | Rejected with diagnostic, exit 1            |
| 10  | Teardown first wt          | `dev wt down`         | Only its symlinks removed, DB repaired      |
| 11  | Teardown second wt         | `dev wt down`         | All symlinks gone, DB clean                 |
| 12  | Post-cleanup sanity        | `dev sb migrate`      | Hub is clean, no-op                         |
