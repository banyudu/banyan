#!/usr/bin/env bash
# Which checkout the app scripts build, launch, and hunt for instances in.
#
# Why this exists: these scripts used to anchor everything to their own location,
# so running one from a linked worktree built that worktree — and, worse, looked
# for running instances only underneath it. An app launched from the main
# checkout was invisible to a worktree's restart-app, so the quit step was
# skipped and a second instance launched on the same control port and the same
# state.sqlite. The usual intent is "build what is on merged main", so the main
# worktree is the default and building a worktree is opt-in.
#
# Precedence: --here (a script flag, resolved by the caller) > $BANYAN_ROOT >
# the main worktree > the script's own checkout when git cannot answer.

# Absolute path of the main worktree for the repo containing $1.
# Falls back to $1 for a non-git directory or a checkout with no working tree.
banyan_main_checkout() {
  local from="$1" common_dir main_root
  common_dir="$(git -C "$from" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    echo "$from"
    return 0
  fi
  # `--git-common-dir` is relative to the queried directory unless already absolute.
  # Resolving it by hand keeps this working on git older than --path-format.
  case "$common_dir" in
    /*) ;;
    *) common_dir="$from/$common_dir" ;;
  esac
  if [[ ! -d "$common_dir" ]]; then
    echo "$from"
    return 0
  fi
  main_root="$(cd -P "$common_dir/.." && pwd)"
  # A bare repo's common dir has no working tree above it to build from.
  if [[ ! -f "$main_root/Package.swift" ]]; then
    echo "$from"
    return 0
  fi
  echo "$main_root"
}

# Resolve the checkout to operate on.
#   $1 = the script's own checkout
#   $2 = 1 when the caller passed --here
banyan_resolve_root() {
  local script_root="$1" here="${2:-0}"
  if [[ "$here" == 1 ]]; then
    echo "$script_root"
    return 0
  fi
  if [[ -n "${BANYAN_ROOT:-}" ]]; then
    if [[ ! -d "$BANYAN_ROOT" ]]; then
      echo "BANYAN_ROOT is set to '$BANYAN_ROOT', which is not a directory." >&2
      return 1
    fi
    (cd -P "$BANYAN_ROOT" && pwd)
    return 0
  fi
  banyan_main_checkout "$script_root"
}

# "path (branch @ sha)" for logging, so it is never a mystery what got built.
banyan_describe_root() {
  local root="$1" branch sha dirty=""
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?')"
  git -C "$root" diff --quiet HEAD 2>/dev/null || dirty=" +local changes"
  echo "$root ($branch @ $sha$dirty)"
}

# Announce the resolved checkout, and how to override it when it is not the one
# the script itself lives in.
banyan_announce_root() {
  local root="$1" script_root="$2" label="$3"
  echo "$label $(banyan_describe_root "$root")"
  if [[ "$root" != "$script_root" ]]; then
    echo "  (this script lives in $script_root — pass --here to use that instead)"
  fi
}
