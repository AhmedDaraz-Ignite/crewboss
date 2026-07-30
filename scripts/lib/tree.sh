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

# Reuse an existing worktree for the branch, so a failed spawn can be retried.
cb_tree_create() {
  cb_tree_path "$1" 2>/dev/null && return 0
  wt switch --create "$1" --base "$(cb_base_ref)" --no-cd >&2 || return 1
  cb_tree_path "$1"
}

cb_tree_path() {
  wt list --format=json | jq -er --arg b "$1" '.[] | select(.branch == $b) | .path'
}

cb_tree_remove() {
  wt remove "$1" ${2:+-f}
}
