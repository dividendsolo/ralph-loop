# Hermes profiles for the ralph loop

The ralph loop runs the same `engineer` / `reviewer` agent over multiple
repos. Each repo can run against its own isolated Hermes profile so memory
pollution, skill overload, and one-model-fits-all stay out of the loop.

This doc is the box-side runbook for ENG-133 ("Profiles: per-project
isolated Hermes agents") plus the design notes the agent PR ships with.

## What the agent PR adds

The agent half of ENG-133 lands in this repo (`ralph-loop`) and ships:

* `bin/lib-profile-resolver.sh` is the single chokepoint that picks
  the per-repo wrapper `hermes-<repo>` if it exists on PATH, otherwise
  falls back to bare `hermes`. Source it from anywhere that needs to
  dispatch a per-repo Hermes call.
* `bin/refresh-profile-tokens.sh` iterates `hermes-<repo>` wrappers
  on PATH and refreshes each profile's Linear MCP token. Replaces the
  single-profile refresh cron once the human setup below is done.
  Today this refreshes the **default** profile's token (single-profile
  steady state) and logs a loud ERROR for any per-profile token it
  finds that `refresh-linear-token.py` cannot actually refresh -- the
  python script ignores `LINEAR_TOKEN_PATH` and rewrites its hardcoded
  default path, so a naive call would silently refresh the default
  while the log claims a per-profile refresh. Loud failure keeps a
  dead per-profile token red in the cron log instead of idling.
* `bin/engineer-ralph` and `bin/review-ralph` now set `RALPH_REPO_NAME`
  before calling `ralph-dispatch`, which resolves the command through
  the library. A box that has no profiles yet keeps running unchanged
  (bare `hermes`).
* `bin/ralph-dispatch` sources the resolver and routes every Hermes
  invocation (primary, fallback, force-fallback) through it.
* `crontab.example` shows the new per-profile refresh entry alongside
  the existing reviewer/worker entries.

The agent PR does NOT:

* Create profiles on the box (human half).
* Run `hermes mcp login linear` for any profile (human half).
* Edit the user's crontab (the example file is a template).
* Patch `refresh-linear-token.py` in the skills repo to honor
  `LINEAR_TOKEN_PATH`. That is a deliberate cross-repo split: the
  ralph-loop side ships the wrapper + loud-error path; the skills-repo
  side (a 2-line patch to read `LINEAR_TOKEN_PATH` in place of the
  hard-coded `TOK` constant) is the natural follow-up card. Until that
  patch lands, the per-profile refresh path is loud-but-no-op: the cron
  log surfaces the dead per-profile token as ERROR, the operator runs
  `hermes mcp login linear` for the affected profile, and the next
  6-hour cycle re-checks.

## Box setup runbook (human half, post-merge)

Run these on the dev box (`div@dev`) as the operator. Each step names
the exact command and the expected outcome.

### 1. Create the three profiles

```bash
for name in skills rep-sheet docket; do
  hermes profile create "$name" --model MiniMax-M3 --provider minimax
done
hermes profile list
```

Expected: the table shows `default`, `skills`, `rep-sheet`, `docket`,
each with `Model: MiniMax-M3` and `Gateway: stopped` (the loop
starts them on demand).

### 2. Generate the per-profile wrappers

```bash
for name in skills rep-sheet docket; do
  hermes profile alias "$name"
done
which hermes-skills hermes-rep-sheet hermes-docket
```

Expected: each wrapper is on PATH (typically `~/.local/bin/hermes-<name>`).
After this step the loop legs start routing per-repo (see step 6).

### 3. Install skills into each profile

The `default` profile's skills live at `~/.hermes/skills/`. Per-profile
skills live at `~/.hermes/profiles/<name>/skills/`. The agent half does
not bundle skills (skills are in `~/code/skills`); re-install them per
profile so the resolver and engineer/reviewer are available everywhere:

```bash
cd ~/code/skills
./install.sh   # wires the default profile today; per-profile install is a
               # small follow-up to install.sh if not auto-applied.
```

Expected: `hermes profile show <name>` reports `Skills: <N>` for each
profile. If the install script only wires `default`, file a small
follow-up to add a `--profile <name>` flag to `install.sh`.

### 4. Per-profile Linear MCP login (one-time per profile)

Hermes currently has no headless OAuth refresh for non-default
profiles, so each profile needs an interactive login ONCE. The
refresh wrapper (`refresh-profile-tokens.sh`) refreshes each profile's
token going forward; the initial bootstrap is manual:

```bash
for name in skills rep-sheet docket; do
  hermes-skills    mcp login linear
  hermes-rep-sheet mcp login linear
  hermes-docket    mcp login linear
done
```

Expected: each profile's `~/.hermes/profiles/<name>/mcp-tokens/linear.json`
exists and has a non-empty `access_token`.

### 5. Wire the per-profile refresh cron

Replace the existing single-profile refresh entry with the
per-profile wrapper:

```bash
crontab -e
# Replace this line:
#   0 */6 * * * /usr/bin/python3 ~/code/skills/software-development/engineer/scripts/refresh-linear-token.py >> ~/linear-refresh.log 2>&1
# With:
0 */6 * * * /home/div/.local/bin/refresh-profile-tokens.sh >> /home/div/linear-refresh.log 2>&1
```

Expected: after one 6-hour cycle, `tail ~/linear-refresh.log` shows
three `refreshed OK` lines (one per profile). If a profile is missing,
the log shows `skipped (no '<name>' wrapper on PATH)` for it and
exit code 0 overall (steady state, not a failure).

### 6. Observe one green pass per profile per leg

Run each leg manually with `RALPH_REPO` pointed at the matching repo
and confirm the dispatch log picks the per-profile wrapper:

```bash
for repo in skills rep-sheet docket; do
  RALPH_REPO="$HOME/code/$repo" RALPH_LOG=/tmp/$repo-engineer.log \
    bash -c '. ~/code/ralph-loop/bin/ralph-dispatch; _hermes_cmd' 2>&1
done
```

Expected: each invocation prints `profile-resolver: repo='<repo>' ->
'hermes-<repo>' (per-profile wrapper on PATH)`. Then run a real tick
(one iteration of `engineer-ralph` against each repo) and confirm the
log shows the wrapper chosen plus the per-profile dispatch output.

### 7. Memory-isolation spot check

Save a fact in one profile, then confirm it does not appear in the
others. This is the load-bearing test of "isolated":

```bash
hermes-skills -p "Remember: ENG-133 skills-profile canary = $(uuidgen)"
for name in rep-sheet docket; do
  if hermes-$name -p "What is the ENG-133 canary?" | grep -q 'canary'; then
    echo "FAIL: $name profile sees skills canary"
  else
    echo "OK: $name profile is isolated"
  fi
done
```

Expected: `rep-sheet` and `docket` profiles report `OK`. If either
reports `FAIL`, the per-profile isolation is broken (most likely cause:
the skill resolver still points at the default profile's skill dir).

## Done when

All four ENG-133 acceptance criteria pass:

1. Legs invoke the per-repo profile wrapper when it exists on PATH,
   fall back cleanly to bare `hermes` when it doesn't. **(Agent PR
   ships this.)**
2. Token-refresh cron refreshes every profile, not just `default`.
   **(Agent PR ships the ralph-loop half: the wrapper iterates each
   profile and surfaces a dead per-profile token as a loud ERROR. The
   skills-repo half -- a 2-line patch to `refresh-linear-token.py`
   honoring `LINEAR_TOKEN_PATH` -- is the cross-repo follow-up card
   tracked separately per LEARNINGS.md Scope. Until that lands, the
   per-profile refresh path is loud-but-no-op; the operator runs
   `hermes mcp login linear` for the affected profile when the cron
   log shows ERROR.)**
3. This doc exists (it does, you're reading it).
4. Three profiles live on the box with isolated memory and observed
   green loop passes.

When the human half closes, move the Linear card to `Done` (not
`Ready for Human`); `Ready for Human` is the intermediate state during
the human walkthrough itself.

## Troubleshooting

* **Resolver logs `fallback; no '<name>' wrapper on PATH`** on a box
  where you ran `hermes profile alias <name>`. The wrapper file
  `~/.local/bin/hermes-<name>` is missing or not executable. Re-run
  `hermes profile alias <name>` and check `ls -la ~/.local/bin/hermes-*`.
* **One profile's refresh logs ERROR but the others succeed**. That
  profile's `mcp-tokens/linear.json` exists but
  `refresh-linear-token.py` cannot honor the per-profile path (it
  rewrites its hardcoded default path instead). Two paths: run
  `hermes-<name> mcp login linear` for that profile (manual
  bootstrap), or land the `LINEAR_TOKEN_PATH` patch in
  `refresh-linear-token.py` (skills repo) so the wrapper can refresh
  per-profile tokens directly.
* **A profile sees memory from another profile**. The skill resolver
  is still resolving against the default profile. Check `hermes
  profile show <name>`; the `Skills` count should match the number
  installed into that profile, not the default's count.