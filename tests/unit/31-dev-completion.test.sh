#!/usr/bin/env bash
# zsh/completions/_dev -- tab completion for the `dev` CLI.
#
# Three things can silently break it, so all three are pinned here:
#
#   1. The `dev` entry point being an alias again. zsh expands an alias before
#      it works out what to complete, so the command word turns into the script
#      path and `#compdef dev` never fires -- you get filenames instead of
#      branches, with nothing to say why. .zshrc must define a function.
#   2. The branch listers. They parse `git worktree list --porcelain` and have
#      to leave out the worktree you are standing in, which is the one
#      `dev wt down` refuses to remove.
#   3. Drift. The completion carries a second copy of every router's
#      subcommands; a new one added to a router but not here is invisible.
#
# The end-to-end case at the bottom runs a real interactive zsh in a pty
# (zsh/zpty) and presses TAB, because nothing short of that proves the wiring
# holds: fpath -> compinit -> #compdef -> the function.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: dev CLI zsh completion${RESET}\n"

COMPLETION="$DOTFILES_DIR/zsh/completions/_dev"
ZSHRC="$DOTFILES_DIR/zsh/.zshrc"

if ! command -v zsh >/dev/null 2>&1; then
  printf "  ${DIM}zsh not installed — skipping${RESET}\n"
  print_results
  exit 0
fi

# ── The file itself ──────────────────────────────────────────────────

header "the completion file loads"

assert "parses under zsh" zsh -n "$COMPLETION"
assert_contains "binds itself to dev" '#compdef dev' "$(head -1 "$COMPLETION")"
# Sourcing it must not try to complete anything (the $compstate guard), or
# every check below would fail on a stray compadd.
assert "sources outside a completion widget" zsh -c "source '$COMPLETION'"

# ── .zshrc wiring ────────────────────────────────────────────────────

header ".zshrc wires the completion up"

assert "dev is a function, not an alias" grep -qE '^dev\(\)' "$ZSHRC"
assert "no alias dev survives" bash -c "! grep -qE '^alias dev=' '$ZSHRC'"
assert "completions dir goes on fpath" grep -q 'zsh/completions" \$fpath' "$ZSHRC"

# fpath has to be set before oh-my-zsh.sh runs compinit, or compinit never
# sees the directory.
FPATH_LINE=$(grep -n 'zsh/completions" \$fpath' "$ZSHRC" | cut -d: -f1)
COMPINIT_LINE=$(grep -n 'source \$ZSH/oh-my-zsh.sh' "$ZSHRC" | cut -d: -f1)
assert "fpath precedes oh-my-zsh.sh" test "$FPATH_LINE" -lt "$COMPINIT_LINE"

# ── Fixture: a bare clone with the worktree shapes seen in the wild ───
#
#   main/      main                     ← the usual case
#   feat-x/    feat/x                   ← slash in the branch name
#   renamed/   moved                    ← directory no longer matches the branch
#   nested/agent-1/  agentbr            ← outside the worktree parent dir
#   stray/                              ← a directory where `up stray` would go
#
# The last three are what `dev wt down` cannot act on: it derives the directory
# from the branch name and looks for it beside the current worktree.

setup_tmpdir
FIX="$TEST_TMPDIR/fixture"
mkdir -p "$FIX"
(
  cd "$FIX"
  git init -q src
  cd src
  git config user.email test@test && git config user.name test
  echo hi > file.txt
  git add -A && git commit -qm init
  git branch -m main
  git branch feat/x
  git branch moved
  git branch agentbr
  git branch spare          # a branch with no worktree
  git branch stray          # a branch whose target directory is taken
  cd ..
  git clone -q --bare src repo.git
  cd repo.git
  git worktree add -q ../main main
  git worktree add -q ../feat-x feat/x
  git worktree add -q ../renamed moved
  git worktree add -q ../nested/agent-1 agentbr
  mkdir -p ../stray
) >/dev/null 2>&1

# Runs one of the completion file's branch listers in <dir>.
lister() {
  local dir="$1" fn="$2" arg="${3:-}"
  (cd "$dir" && zsh -c "source '$COMPLETION'; $fn $arg")
}

header "dev wt down offers the worktrees it can remove"

DOWN_FROM_MAIN=$(lister "$FIX/main" _dev_wt_worktree_branches for-down)
assert_eq "from main: only feat/x" "feat/x" "$DOWN_FROM_MAIN"

DOWN_FROM_FEAT=$(lister "$FIX/feat-x" _dev_wt_worktree_branches for-down)
assert_eq "from feat-x: only main" "main" "$DOWN_FROM_FEAT"

# Both would fail with "Directory does not exist" if offered.
assert_not_contains "a renamed directory is not offered" "moved" "$DOWN_FROM_MAIN"
assert_not_contains "a worktree outside the parent dir is not offered" \
  "agentbr" "$DOWN_FROM_MAIN"

ALL=$(lister "$FIX/main" _dev_wt_worktree_branches)
assert_contains "without for-down: main is listed" "main" "$ALL"
assert_contains "without for-down: the renamed one is listed" "moved" "$ALL"
assert_contains "without for-down: the nested one is listed" "agentbr" "$ALL"

header "dev wt up offers branches it can check out"

UP=$(lister "$FIX/main" _dev_wt_up_branches)
assert_contains "spare has no worktree, so it is offered" "spare" "$UP"
assert_not_contains "main already has a worktree" "^main$" "$UP"
assert_not_contains "feat/x already has a worktree" "feat/x" "$UP"
assert_not_contains "moved is checked out under another name" "moved" "$UP"
# `up` refuses when the directory it would create is already there.
assert_not_contains "stray's directory already exists" "stray" "$UP"
# origin/HEAD strips to a bare HEAD; it is a symref, not a branch.
assert_not_contains "HEAD is not a branch" "HEAD" "$UP"

header "outside a repo the listers stay quiet"

OUTSIDE=$(lister "$TEST_TMPDIR" _dev_wt_worktree_branches for-down)
assert_eq "no worktree branches" "" "$OUTSIDE"
OUTSIDE_UP=$(lister "$TEST_TMPDIR" _dev_wt_up_branches)
assert_eq "no up branches" "" "$OUTSIDE_UP"
assert "exit status is still 0" bash -c \
  "cd '$TEST_TMPDIR' && zsh -c \"source '$COMPLETION'; _dev_wt_up_branches\""

# ── Drift: completion lists vs the routers' case clauses ─────────────

# The `name:description` entries of one array inside one of the completion's
# functions. Scoped to the function so the several `subcommands=(...)` arrays
# stay apart, and to the array so the quoted strings elsewhere in the body
# (_values flags, _alternative specs) are not mistaken for command names.
completion_names() {
  local fn="$1" array="$2"
  awk -v fn="$fn" -v a="$array" '
      $0 ~ "^"fn"\\(\\) \\{" { infn = 1; next }
      /^}/                   { infn = 0 }
      infn && index($0, a "=(") { inarr = 1; next }
      inarr && /^[[:space:]]*\)/ { inarr = 0 }
      inarr { print }' "$COMPLETION" \
    | sed -E "s/^[[:space:]]*'([a-z][a-z-]*):.*/\1/" \
    | LC_ALL=C sort
}

# Every dispatched name (including aliases) from a router's case clauses.
router_names() {
  grep -E "^  ([a-zA-Z_-]+\|)*[a-zA-Z_-]+\)$" "$1" \
    | sed -E 's/^  //;s/\)$//' \
    | tr '|' '\n' \
    | LC_ALL=C sort
}

header "every router subcommand is completable"

for pair in \
  "dev.sh:_dev:commands" \
  "dev-worktree.sh:_dev_worktree:subcommands" \
  "dev-supabase.sh:_dev_supabase:subcommands" \
  "dev-env.sh:_dev_env:subcommands" \
  "dev-nanoclaw.sh:_dev_nanoclaw:subcommands"
do
  router="${pair%%:*}"; rest="${pair#*:}"
  fn="${rest%%:*}"; array="${rest##*:}"
  assert_eq "$router ↔ $fn" \
    "$(router_names "$SCRIPTS_DIR/$router" | tr '\n' ' ')" \
    "$(completion_names "$fn" "$array" | tr '\n' ' ')"
done

# ── End to end: press TAB in a real zsh ──────────────────────────────

# Boots an interactive zsh in a pty out of a fake $HOME whose .zshrc is a
# symlink to the repo's, exactly as install.sh links it, types <line> followed
# by TAB, and prints what came back. Oh My Zsh is borrowed from the real $HOME
# because .zshrc sources it; without it there is nothing to test.
#
# The driver below is single-quoted for bash and must stay free of single
# quotes itself, so the TAB byte is appended here and the carriage returns and
# escape sequences are stripped on the way out.
TAB=$'\t'
tab() {
  local dir="$1" line="$2"
  zsh -c '
    zmodload zsh/zpty
    dir=$1; keys=$2; rc=$3; omz=$4
    fake=$(mktemp -d)
    ln -s $rc $fake/.zshrc
    ln -s $omz $fake/.oh-my-zsh
    zpty zz "cd $dir && HOME=$fake zsh -i"
    # Wait for the prompt instead of sleeping blind (compinit on a cold dump is
    # the slow part): read until half a second passes with nothing arriving.
    buf=""; idle=0
    for i in {1..200}; do
      got=""
      while zpty -r -t zz chunk 2>/dev/null; do got+=$chunk; done
      buf+=$got
      if [[ -n $buf && -z $got ]]; then
        (( ++idle >= 5 )) && break
      else
        idle=0
      fi
      sleep 0.1
    done
    zpty -w -n zz "$keys"
    for i in {1..40}; do
      while zpty -r -t zz chunk 2>/dev/null; do buf+=$chunk; done
      sleep 0.1
    done
    zpty -d zz
    rm -rf $fake
    print -r -- $buf
  ' _ "$dir" "$line$TAB" "$ZSHRC" "$HOME/.oh-my-zsh" \
    | tr -d '\r' | sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'
}

if [ -d "$HOME/.oh-my-zsh" ]; then
  header "pressing TAB in a real shell"

  OUT=$(tab "$FIX/feat-x" "dev wt down ")
  assert_contains "dev wt down ⇥ lists main" "main" "$OUT"

  OUT=$(tab "$FIX/feat-x" "dev wt down m")
  assert_contains "dev wt down m⇥ completes to main" "dev wt down main" "$OUT"

  OUT=$(tab "$FIX/main" "dev wt ")
  assert_contains "dev wt ⇥ lists down" "down" "$OUT"
else
  printf "  ${DIM}Oh My Zsh not installed — skipping the pty case${RESET}\n"
fi

print_results
