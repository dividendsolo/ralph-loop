#!/bin/bash
# bin/refresh-profile-tokens.sh, iterate per-repo Hermes profiles and
# refresh each profile's Linear MCP access token, using the existing
# `refresh-linear-token.py` script.
#
# Today, refresh-linear-token.py refreshes only the default profile's
# token at ~/.hermes/mcp-tokens/linear.json. When the human post-merge
# half of ENG-133 creates the per-repo profiles on the box, each
# profile will own its own token file under a per-profile path. This
# wrapper is the single owner of "refresh every profile" and runs on a
# cron (replacing the single-profile refresh cron entry the brief calls
# out as the hard requirement behind ENG-159/ENG-171, silent dead
# per-profile tokens must NOT be possible).
#
# Behavior:
#   - Source the resolver. For each target repo, if the per-repo wrapper
#     `hermes-<repo>` exists on PATH, attempt to refresh that profile's
#     token. Per-profile refresh requires refresh-linear-token.py to
#     honor a per-profile token path; today the script ignores
#     LINEAR_TOKEN_PATH and rewrites its hardcoded default path. The
#     architect's brief (Task 2) is explicit: "If Hermes only supports
#     interactive login per profile (no headless refresh), do NOT fake
#     it: document that limitation clearly and make the per-profile
#     TRACKER_UNREACHABLE signal the safety net." So when only a
#     per-profile token exists (no default), the wrapper logs a loud
#     ERROR naming the manual-recovery command and counts as a
#     failure; the dead per-profile token surfaces as red in the cron
#     log instead of idling silently.
#   - If the wrapper is absent (no `hermes-<repo>` on PATH), log
#     "skipped" and continue -- this is the steady state before the
#     human post-merge half creates profiles.
#   - Loud failure: exit non-zero if any profile refresh fails or if a
#     per-profile token is found that the script cannot refresh, so the
#     cron job surfaces a red signal instead of idling.
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

for repo in "${TARGET_REPOS[@]}"; do
  wrapper="$(resolve_hermes_cmd "$repo")"
  if [ "$wrapper" = "hermes" ]; then
    log "repo='$repo' skipped (no '$repo' wrapper on PATH)"
    skipped=$((skipped + 1))
    continue
  fi

  # Per-profile token path (canonical Hermes location for a profile
  # named '$repo'). The default profile's token lives at
  # $TOKENS_DIR/linear.json; per-profile data lives under
  # $HOME/.hermes/profiles/<name>/.
  profile_token_path="$HOME/.hermes/profiles/$repo/mcp-tokens/linear.json"
  default_token_path="$TOKENS_DIR/linear.json"

  # Per-profile refresh path is wired through refresh-linear-token.py,
  # which today ignores LINEAR_TOKEN_PATH and rewrites its hardcoded
  # TOKENS_DIR/linear.json (the default token). Invoking it with
  # LINEAR_TOKEN_PATH=<per-profile> would silently refresh the default
  # while the cron log claims a per-profile refresh -- the silent
  # misinformation that ENG-159/ENG-171 are designed to surface as red.
  # Per the architect's brief (Task 2): "If Hermes only supports
  # interactive login per profile (no headless refresh), do NOT fake
  # it: document that limitation clearly and make the per-profile
  # TRACKER_UNREACHABLE signal the safety net." We take the brief at
  # its word: when a per-profile token exists but the python script
  # cannot honor it, log loudly and count as a failure, so a dead
  # profile token shows red instead of idling. A future refresh of
  # refresh-linear-token.py (to honor LINEAR_TOKEN_PATH, a 2-line
  # patch) flips this branch to refresh successfully; that lands in
  # its own skills-repo PR (LEARNINGS.md Scope: cross-repo slices ship
  # in their own PRs).
  if [ -f "$profile_token_path" ]; then
    log "ERROR repo='$repo' per-profile token at $profile_token_path; refresh-linear-token.py does not honor per-profile paths (it ignores LINEAR_TOKEN_PATH and rewrites the default). Run 'hermes mcp login linear' for profile='$repo' manually, or land the LINEAR_TOKEN_PATH patch in refresh-linear-token.py (skills repo)."
    failures=$((failures + 1))
    continue
  fi

  # No per-profile token; fall back to refreshing the default token
  # (single-profile steady state, the pre-ENG-133 behavior).
  if [ -f "$default_token_path" ]; then
    log "repo='$repo' refreshing default token at $default_token_path"
    if python3 "$REFRESH_SCRIPT" >>"${REFRESH_LOG:-/dev/null}" 2>&1; then
      log "repo='$repo' refreshed OK"
      refreshed=$((refreshed + 1))
    else
      rc=$?
      log "ERROR repo='$repo' refresh FAILED (rc=$rc); run 'hermes mcp login linear' for that profile"
      failures=$((failures + 1))
    fi
  else
    log "repo='$repo' skipped (no token file at $profile_token_path or $default_token_path)"
    skipped=$((skipped + 1))
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