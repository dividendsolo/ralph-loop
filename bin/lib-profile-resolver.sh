#!/bin/bash
# bin/lib-profile-resolver.sh, resolve the per-repo Hermes command.
#
# Given a repo name (one of skills / rep-sheet / docket), return the
# per-profile wrapper `hermes-<repo>` if it exists on PATH, otherwise
# fall back to bare `hermes`. This is the single chokepoint the ralph
# legs consult so a box that has profiles set up routes each repo to
# its own isolated Hermes profile, while a box that does NOT have
# profiles yet keeps using the default profile unchanged.
#
# Source this file from a leg (engineer-ralph / review-ralph) and call
# `resolve_hermes_cmd <repo>`. The function logs the choice to stderr
# in Eastern time so a misrouted profile is visible in the loop logs.
#
# Why the fallback to bare `hermes`: this script merges BEFORE the box
# has any profiles, and the loop must keep running unchanged until the
# post-merge human half creates them. A hard "require a wrapper" gate
# would dead-lock the loop on day 1.
#
# ENG-133, Profiles: per-project isolated Hermes agents.

# Print the timestamp prefix in Eastern time, matching the loop's log style.
_profile_resolver_stamp() {
  TZ=America/New_York date +"%b %d %I:%M:%S %p %Z"
}

# resolve_hermes_cmd <repo>
#   <repo>  one of skills | rep-sheet | docket
#   stdout: the resolved command name (hermes-<repo> or hermes)
#   stderr: one log line describing the choice
#   exit:   0 always (fallback is always available); rejects bad repo names
resolve_hermes_cmd() {
  local repo="$1"

  # Reject empty / odd names. The wrapper filename is `hermes-<repo>`; a
  # name with a slash or whitespace would produce a non-existent command
  # that `command -v` would still happily evaluate, masking the bug.
  case "$repo" in
    ""|*/*|*' '*|*'	'*)
      echo "resolve_hermes_cmd: refusing odd repo name: '$repo'" >&2
      return 2
      ;;
  esac

  local wrapper="hermes-${repo}"
  local stamp
  stamp="$(_profile_resolver_stamp)"

  if command -v "$wrapper" >/dev/null 2>&1; then
    echo "[$stamp] profile-resolver: repo='$repo' -> '$wrapper' (per-profile wrapper on PATH)" >&2
    printf '%s\n' "$wrapper"
  else
    echo "[$stamp] profile-resolver: repo='$repo' -> 'hermes' (fallback; no '$wrapper' on PATH)" >&2
    printf '%s\n' "hermes"
  fi
}