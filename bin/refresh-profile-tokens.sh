#!/bin/bash
# bin/refresh-profile-tokens.sh, iterate per-repo Hermes profiles and
# refresh each profile's Linear MCP access token, using the existing
# `refresh-linear-token.py` script.
#
# This wrapper is the single owner of "refresh every profile" and runs
# on a cron (replacing the single-profile refresh cron entry the brief
# calls out as the hard requirement behind ENG-159/ENG-171, silent dead
# per-profile tokens must NOT be possible).
#
# Behavior:
#   - Refresh the DEFAULT profile's token first (non-repo-scoped jobs
#     and the loop fallback still run on `default`); absent file is the
#     pre-login steady state, logged and skipped.
#   - Source the resolver. For each target repo, if the per-repo wrapper
#     `hermes-<repo>` exists on PATH, refresh that profile's token by
#     invoking refresh-linear-token.py with LINEAR_TOKEN_PATH pointing
#     at the per-profile linear.json (honored since the skills-repo
#     ENG-133 follow-up, commit 70fde79 there). Honesty guard: after
#     the refresh, verify the per-profile file actually changed; if the
#     script exited 0 but left it untouched (e.g. a regression back to
#     ignoring LINEAR_TOKEN_PATH and silently refreshing the default),
#     log a loud ERROR and count a failure.
#   - A wrapper WITHOUT a per-profile token is a blind profile the loop
#     will still dispatch to; that is a loud failure naming the manual
#     bootstrap (`hermes mcp login linear`), not a skip.
#   - If the wrapper is absent (no `hermes-<repo>` on PATH), log
#     "skipped" and continue -- this is the steady state before the
#     human post-merge half creates profiles.
#   - Loud failure: exit non-zero if any refresh fails, so the cron job
#     surfaces a red signal instead of idling.
#
# ENG-133, Profiles: per-project isolated Hermes agents.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-profile-resolver.sh
. "$REPO_ROOT/lib-profile-resolver.sh"

REFRESH_SCRIPT="${REFRESH_LINEAR_TOKEN_SCRIPT:-$HOME/code/skills/software-development/engineer/scripts/refresh-linear-token.py}"
TARGET_REPOS=(skills rep-sheet docket)
TOKENS_DIR="${HERMES_TOKENS_DIR:-$HOME/.hermes/mcp-tokens}"

log() {
  local stamp
  stamp="$(TZ=America/New_York date +"%b %d %I:%M:%S %p %Z")"
  printf '[%s] refresh-profile-tokens: %s\n' "$stamp" "$*" >&2
}

failures=0
refreshed=0
skipped=0

# DEFAULT profile first: non-repo-scoped jobs (watchdog, heartbeat) and
# the loop's bare-hermes fallback still run on it, so it must stay
# refreshed even once every repo has its own profile.
default_token_path="$TOKENS_DIR/linear.json"
if [ -f "$default_token_path" ]; then
  log "profile='default' refreshing token at $default_token_path"
  if python3 "$REFRESH_SCRIPT" >>"${REFRESH_LOG:-/dev/null}" 2>&1; then
    log "profile='default' refreshed OK"
    refreshed=$((refreshed + 1))
  else
    log "ERROR profile='default' refresh FAILED; run 'hermes mcp login linear'"
    failures=$((failures + 1))
  fi
else
  log "profile='default' skipped (no token file at $default_token_path)"
  skipped=$((skipped + 1))
fi

for repo in "${TARGET_REPOS[@]}"; do
  wrapper="$(resolve_hermes_cmd "$repo")"
  if [ "$wrapper" = "hermes" ]; then
    log "repo='$repo' skipped (no '$repo' wrapper on PATH)"
    skipped=$((skipped + 1))
    continue
  fi

  # Per-profile token path (canonical Hermes location for a profile
  # named '$repo').
  profile_token_path="$HOME/.hermes/profiles/$repo/mcp-tokens/linear.json"

  # A wrapper without a token is a blind profile the loop will still
  # dispatch to; refresh cannot help until the one-time interactive
  # bootstrap has run. Loud, per the brief.
  if [ ! -f "$profile_token_path" ]; then
    log "ERROR repo='$repo' wrapper exists but no token at $profile_token_path; run 'hermes-$repo mcp login linear' once to bootstrap"
    failures=$((failures + 1))
    continue
  fi

  # Refresh via LINEAR_TOKEN_PATH, then verify the file really changed.
  # A refresh rotates the access and refresh tokens, so an unchanged
  # file means the script did not actually honor the per-profile path
  # (the silent-default-refresh bug ENG-159/ENG-171 exist to surface).
  before="$(cksum < "$profile_token_path")"
  log "repo='$repo' refreshing per-profile token at $profile_token_path"
  if LINEAR_TOKEN_PATH="$profile_token_path" python3 "$REFRESH_SCRIPT" >>"${REFRESH_LOG:-/dev/null}" 2>&1 \
     && [ "$(cksum < "$profile_token_path")" != "$before" ]; then
    log "repo='$repo' refreshed OK"
    refreshed=$((refreshed + 1))
  else
    log "ERROR repo='$repo' per-profile refresh did not update $profile_token_path (script failed, or ignored LINEAR_TOKEN_PATH and touched the default token instead); run 'hermes-$repo mcp login linear' manually"
    failures=$((failures + 1))
  fi
done

log "summary: refreshed=$refreshed skipped=$skipped failed=$failures"

# Exit 0 with nothing-refreshed log so the steady state (no profiles
# yet) is visible-but-not-alarming; exit non-zero only on real refresh
# failures so the cron log surfaces red.
if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0