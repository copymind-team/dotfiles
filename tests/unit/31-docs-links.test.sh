#!/usr/bin/env bash
# The README is split across the folders it documents: the root one carries the
# interface, and each subfolder carries how its own feature works. That only
# stays useful if the links between them resolve, and a link into a section is
# exactly the kind of thing a rename breaks silently -- the heading moves, the
# link still looks like a link, and nothing complains until somebody clicks it.
#
# So every relative link in every doc is followed here: the file has to exist,
# and a `#fragment` has to name a heading in it. Anchors are slugified the way
# GitHub does -- lowercased, punctuation dropped, spaces to dashes -- which is
# what the rendered page will be linking against.
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: documentation links${RESET}\n"

DOCS=("README.md" "tmux/README.md")

# Every heading in a file, as the anchor GitHub will give it.
anchors_of() { # <file>
  sed -n 's/^#\{1,6\}[[:space:]]\{1,\}//p' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 _-]//g; s/[[:space:]]\{1,\}/-/g; s/^-//; s/-$//'
}

# Every relative link target in a file, one per line, http(s) dropped.
links_of() { # <file>
  grep -o '](\([^)]*\))' "$1" 2>/dev/null \
    | sed 's/^](//; s/)$//' \
    | grep -v '^https\{0,1\}://' || true
}

header "every doc the root README points at exists"
for doc in "${DOCS[@]}"; do
  assert_file_exists "$doc" "$DOTFILES_DIR/$doc"
done
assert_contains "the root README hands off to tmux/" \
  "(tmux/README.md" "$(cat "$DOTFILES_DIR/README.md")"

header "every relative link resolves, file and anchor"
broken=""
count=0
for doc in "${DOCS[@]}"; do
  dir="$(dirname "$DOTFILES_DIR/$doc")"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    count=$((count + 1))
    path="${target%%#*}"
    frag=""
    case $target in *#*) frag="${target#*#}" ;; esac

    if [ -n "$path" ]; then
      file="$dir/$path"
    else
      file="$DOTFILES_DIR/$doc"   # a bare #fragment points into its own file
    fi

    if [ ! -e "$file" ]; then
      broken="$broken\n  $doc -> $target (no such file)"
      continue
    fi
    if [ -n "$frag" ] && ! anchors_of "$file" | grep -qx -- "$frag"; then
      broken="$broken\n  $doc -> $target (no such heading)"
    fi
  done < <(links_of "$DOTFILES_DIR/$doc")
done
assert_eq "no broken links" "" "$(printf '%b' "$broken")"
# A guard against the loop silently reading nothing -- "no broken links" and
# "checked no links" print the same tick otherwise.
assert "and there were links to check" bash -c "[ '$count' -ge 5 ]"

# The split is only worth having if the root file stays the short one. This is a
# smell test, not a budget: if the root grows past the folder docs again, the
# implementation detail has crept back in.
header "the root README stays the short one"
root=$(grep -c . "$DOTFILES_DIR/README.md")
sub=$(grep -c . "$DOTFILES_DIR/tmux/README.md")
assert "the folder docs carry more prose than the root" bash -c "[ '$sub' -gt '$root' ]"

print_results
