#!/usr/bin/env bash
# Shared helpers for dev-supabase-*.sh scripts. Source this, don't execute.

# --- Require supabase CLI ---
if ! command -v supabase &>/dev/null; then
  echo "Error: supabase CLI not found. Install via: brew install supabase/tap/supabase" >&2
  exit 1
fi

require_bare_repo() {
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir)"
  if ! git -C "$git_common_dir" rev-parse --is-bare-repository 2>/dev/null | grep -q "true"; then
    echo "Error: You should clone the repo with --bare flag enabled to use the worktree setup script." >&2
    exit 1
  fi
}

supabase_is_running() {
  supabase status --output json >/dev/null 2>&1
}

resolve_supabase_wt() {
  local current_wt parent_dir
  current_wt="$(git rev-parse --show-toplevel)"
  parent_dir="$(cd "$current_wt/.." && pwd)"
  echo "$parent_dir/supabase"
}

ensure_fetch_refspec() {
  if ! git config --get remote.origin.fetch &>/dev/null; then
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  fi
}

# --- Colors ---
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# --- Migration helpers ---

find_supabase_wt() {
  local wt_path=""
  wt_path=$(git worktree list --porcelain | awk '/^worktree .*\/supabase$/ { print substr($0, 10) }')
  if [ -z "$wt_path" ]; then
    echo "Error: Supabase worktree not found. Run: dev sb up" >&2
    return 1
  fi
  echo "$wt_path"
}

find_new_migrations() {
  local wt_path="$1"
  local supabase_wt="$2"
  local dir basename_f
  for dir in app jobs; do
    local wt_dir="$wt_path/supabase/migrations/$dir"
    local sb_dir="$supabase_wt/supabase/migrations/$dir"
    [ -d "$wt_dir" ] || continue
    for f in "$wt_dir"/*.sql; do
      [ -f "$f" ] || continue
      basename_f="$(basename "$f")"
      if [ -f "$sb_dir/$basename_f" ] && [ ! -L "$sb_dir/$basename_f" ]; then
        continue
      fi
      if [ -L "$sb_dir/$basename_f" ]; then
        local target
        target="$(realpath "$sb_dir/$basename_f" 2>/dev/null || true)"
        if [ "$target" = "$(realpath "$f")" ]; then
          continue
        fi
      fi
      echo "supabase/migrations/$dir/$basename_f"
    done
  done
}

get_latest_origin_timestamp() {
  local supabase_wt="$1"
  find "$supabase_wt/supabase/migrations" -name "*.sql" ! -type l -print0 2>/dev/null \
    | xargs -0 -I{} basename {} \
    | sed 's/_.*//' \
    | sort -n \
    | tail -1
}

check_timestamps() {
  local wt_name="$1"
  local new_files="$2"
  local latest_origin_ts="$3"
  local supabase_wt="$4"

  if [ -z "$latest_origin_ts" ]; then
    return 0
  fi

  local outdated=()
  local file ts basename_f
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    basename_f="$(basename "$file")"
    ts="${basename_f%%_*}"
    if [ "$ts" -le "$latest_origin_ts" ] 2>/dev/null; then
      outdated+=("$basename_f")
    fi
  done <<< "$new_files"

  if [ ${#outdated[@]} -eq 0 ]; then
    return 0
  fi

  local origin_migrations=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    origin_migrations+=("$f")
  done < <(find "$supabase_wt/supabase/migrations" -name "*.sql" ! -type l -exec basename {} \; 2>/dev/null | sort)

  local earliest_outdated_ts
  earliest_outdated_ts="${outdated[0]%%_*}"
  for o in "${outdated[@]}"; do
    local o_ts="${o%%_*}"
    if [ "$o_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      earliest_outdated_ts="$o_ts"
    fi
  done

  echo ""
  printf "${RED}\"$wt_name\" has migrations with outdated timestamps:${RESET}\n"
  echo ""

  local context_shown=0
  for m in "${origin_migrations[@]}"; do
    local m_ts="${m%%_*}"
    if [ "$m_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      context_shown=$((context_shown + 1))
    fi
  done

  local skip=$((context_shown - 2))
  if [ "$skip" -lt 0 ]; then skip=0; fi

  local shown=0
  local in_context=false
  for m in "${origin_migrations[@]}"; do
    local m_ts="${m%%_*}"
    if [ "$m_ts" -lt "$earliest_outdated_ts" ] 2>/dev/null; then
      shown=$((shown + 1))
      if [ "$shown" -le "$skip" ]; then
        if [ "$in_context" = false ]; then
          printf "  ${DIM}...${RESET}\n"
          in_context=true
        fi
        continue
      fi
      in_context=false
      printf "  ${DIM}- %s${RESET}\n" "$m"
    else
      printf "  ${GREEN}- %s  (origin/main)${RESET}\n" "$m"
    fi
  done

  for o in "${outdated[@]}"; do
    printf "  ${RED}- %s  (%s, outdated timestamp)${RESET}\n" "$o" "$wt_name"
  done

  echo ""
  echo "Fix: rebase $wt_name onto origin/main to update migration timestamps"
  echo ""
  return 1
}

symlink_migrations() {
  local wt_path="$1"
  local new_files="$2"
  local supabase_wt="$3"

  local file link_path target_path basename_f
  local count=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    basename_f="$(basename "$file")"
    target_path="$wt_path/$file"
    link_path="$supabase_wt/$file"

    if [ -L "$link_path" ]; then
      local existing_target
      existing_target="$(realpath "$link_path" 2>/dev/null || readlink "$link_path")"
      if [ "$existing_target" != "$target_path" ]; then
        echo "Error: $basename_f already symlinked from a different worktree:" >&2
        echo "  Existing: $existing_target" >&2
        echo "  New:      $target_path" >&2
        return 1
      fi
      continue
    fi

    ln -s "$target_path" "$link_path"
    count=$((count + 1))
  done <<< "$new_files"

  if [ "$count" -gt 0 ]; then
    echo "Symlinked $count migration(s) into the migration hub"
  fi
}

remove_wt_symlinks() {
  local wt_path="$1"
  local supabase_wt="$2"

  local count=0
  local f resolved
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -L "$f" ]; then
        resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
        if [[ "$resolved" == "$wt_path/"* ]]; then
          rm "$f"
          count=$((count + 1))
        fi
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count symlink(s) from the migration hub"
  fi
}

clean_stale_symlinks() {
  local wt_path="$1"
  local supabase_wt="$2"

  local count=0
  local f resolved
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
      if [[ "$resolved" == "$wt_path/"* ]] && [ ! -f "$resolved" ]; then
        rm "$f"
        count=$((count + 1))
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count stale symlink(s) from the migration hub"
  fi
}

clean_all_stale_symlinks() {
  local supabase_wt="$1"

  local count=0
  local f
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      if [ ! -f "$(realpath "$f" 2>/dev/null || readlink "$f")" ]; then
        rm "$f"
        count=$((count + 1))
      fi
    done
  done

  if [ "$count" -gt 0 ]; then
    echo "Removed $count stale symlink(s) from the migration hub"
  else
    echo "No stale symlinks found"
  fi
}

apply_migrations() {
  local supabase_wt="$1"
  echo "Applying migrations from supabase worktree..."
  if [ -x "$supabase_wt/scripts/db-migrate-local.sh" ]; then
    (cd "$supabase_wt" && ./scripts/db-migrate-local.sh)
  else
    (cd "$supabase_wt" && supabase migration up --local)
  fi
}

unlink_worktree_migrations() {
  local wt_path="$1"

  local supabase_wt
  supabase_wt="$(find_supabase_wt 2>/dev/null)" || {
    echo "Supabase worktree not found, skipping symlink cleanup."
    return 0
  }

  # Collect versions from this worktree's symlinks before removing them
  local versions=()
  local f resolved basename_f version
  for dir in "$supabase_wt/supabase/migrations/app" "$supabase_wt/supabase/migrations/jobs"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.sql; do
      [ -L "$f" ] || continue
      resolved="$(realpath "$f" 2>/dev/null || readlink "$f")"
      if [[ "$resolved" == "$wt_path/"* ]]; then
        basename_f="$(basename "$f")"
        version="${basename_f%%_*}"
        versions+=("$version")
      fi
    done
  done

  remove_wt_symlinks "$wt_path" "$supabase_wt"

  # Repair migration history
  if [ ${#versions[@]} -gt 0 ]; then
    local project_id
    project_id="$(sed -n 's/^project_id = "\(.*\)"/\1/p' "$supabase_wt/supabase/config.toml")"
    local db_container="supabase_db_${project_id}"

    local version_list
    version_list=$(printf "'%s'," "${versions[@]}")
    version_list="${version_list%,}"

    echo "Repairing migration history: ${versions[*]} => reverted"
    docker exec -e PGPASSWORD=postgres "$db_container" \
      psql -U supabase_admin -d postgres -c \
      "DELETE FROM supabase_migrations.schema_migrations WHERE version IN ($version_list);" \
      2>/dev/null || echo "  (warning: migration repair failed — continuing)"
  fi

  if supabase_is_running; then
    echo "Updating supabase worktree to origin/main..."
    git fetch origin
    (cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
    apply_migrations "$supabase_wt"
  fi
}
