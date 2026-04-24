#!/usr/bin/env bash
set -euo pipefail

# Generates docker-compose.override.yml for the current worktree from its
# entry in the port registry (.worktree-ports). The registry is the single
# source of truth; this script just projects that truth into a per-worktree
# override file. Shared by `dev wt init` and `dev wt up`.
# Usage: dev wt port

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/templates/docker-compose.override.yml"
WORKTREE_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Error: Not inside a git worktree." >&2
  exit 1
}
WORKTREE_NAME="$(basename "$WORKTREE_DIR")"
PARENT_DIR="$(cd "$WORKTREE_DIR/.." && pwd)"
REPO_NAME="$(basename "$PARENT_DIR" | sed 's/\.git$//')"
REGISTRY="$PARENT_DIR/.worktree-ports"
OVERRIDE_FILE="$WORKTREE_DIR/docker-compose.override.yml"

# --- Registry check ---
if [ ! -f "$REGISTRY" ]; then
  echo "Error: Port registry not found at $REGISTRY. Run 'dev wt init' first." >&2
  exit 1
fi

# --- Look up this worktree's port ---
PORT="$(awk -F'\t' -v n="$WORKTREE_NAME" '$1 == n {print $2; exit}' "$REGISTRY")"
if [ -z "$PORT" ]; then
  echo "Error: No entry for '$WORKTREE_NAME' in $REGISTRY" >&2
  exit 1
fi

# --- Template check ---
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: Template not found at $TEMPLATE" >&2
  exit 1
fi

# --- Render template ---
CONTAINER_NAME="${REPO_NAME}-${WORKTREE_NAME}"
sed \
  -e "s|__CONTAINER_NAME__|${CONTAINER_NAME}|g" \
  -e "s|__PORT__|${PORT}|g" \
  "$TEMPLATE" > "$OVERRIDE_FILE"
echo "Generated docker-compose.override.yml (host port $PORT -> container 3000)"
