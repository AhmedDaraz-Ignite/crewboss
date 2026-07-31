# tree: worktree lifecycle via worktrunk. wt owns the path template and post-switch hooks.
# The base ref defaults to the remote's default branch. Override with CB_BASE.

cb_base_ref() {
  if [ -n "${CB_BASE:-}" ]; then printf '%s' "$CB_BASE"; return; fi
  local head
  head=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -z "$head" ]; then
    head=origin/$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
  fi
  printf '%s' "${head:-origin/main}"
}

cb_tree_primary_path() {
  local worktrees
  worktrees=$(git worktree list --porcelain) || return 1
  printf '%s\n' "$worktrees" | sed -n 's/^worktree //p' | head -1
}

# Reuse an existing worktree for the branch, so a failed spawn can be retried.
cb_tree_create() {
  local existing primary
  if existing=$(cb_tree_path "$1" 2>/dev/null); then
    primary=$(cb_tree_primary_path) || return 1
    [ -n "$primary" ] || {
      echo "crewboss: could not identify the primary repo" >&2
      return 1
    }
    [ "$existing" != "$primary" ] || {
      echo "crewboss: '$1' is checked out in the primary repo, pick another branch" >&2
      return 1
    }
    printf '%s' "$existing"
    return 0
  fi
  wt switch --create "$1" --base "$(cb_base_ref)" --no-cd >&2 || return 1
  cb_tree_path "$1"
}

cb_tree_path() {
  wt list --format=json | jq -er --arg b "$1" '.[] | select(.branch == $b) | .path'
}

cb_tree_remove() {
  wt remove "$1" ${2:+-f}
}
