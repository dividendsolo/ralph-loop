# ralph-loop

Board-driven autonomous dev loop for the Docket project: a **worker** (Ralph)
that pulls one Linear ticket at a time and produces a PR, and a **reviewer** that
reviews those PRs. State lives in Linear, GitHub, and the repo — never in a
context window — so any machine with this installed can take the next step.

## Layout

```
bin/
  ralph-once     Work ONE AFK ticket end-to-end, then stop (worker, hermes -z, headless).
  ralph-once-tui Same run in the interactive TUI, so you can watch it work live.
  afk-ralph      Run the worker loop up to N times; stops when the board is clear.
  ralph-init     Readiness check (repo, git identity, hermes, gh, prompt present).
  review-board   One senior-reviewer pass over AFK "In Review" PRs (claude, headless).
prompts/
  ralph-board.md   The worker's procedure.
  review-board.md  The reviewer's procedure (SHADOW vs LIVE merge mode in here).
install.sh       Symlink bin/ onto PATH and prompts/ into ~/.claude.
crontab.example  Schedule the reviewer pass.
```

## Install on a machine

```bash
git clone git@github.com:dividendsolo/ralph-loop.git
cd ralph-loop
./install.sh        # symlinks bin -> ~/.local/bin, prompts -> ~/.claude
ralph-init          # verify the toolchain
```

Requires on PATH: `hermes` (worker), `claude` (reviewer), `gh` (authenticated),
`git`, and the Docket bun toolchain. Set `RALPH_REPO` if your Docket checkout is
not at `$HOME/code/docket`.

## Run

```bash
ralph-once          # advance one ticket (headless: only the final summary prints)
ralph-once-tui      # same, in the TUI, to watch it work live
afk-ralph 10        # advance up to 10 tickets
review-board        # one review pass (also runs from cron)
```

`ralph-once` runs `hermes -z` (oneshot), which prints ONLY the final summary —
the terminal stays blank until it finishes. To watch a headless run live, follow
the agent log in another terminal: `hermes logs -f`. Or use `ralph-once-tui`.

## Schedule the reviewer

See `crontab.example`. The reviewer runs in **SHADOW** mode by default (reviews
and posts verdicts, never merges). Flip `MERGE_MODE: LIVE` in
`prompts/review-board.md` to let it merge CI-green, accepted PRs.

## Notes

- The worker never merges and never pushes to `main` outside a PR; the reviewer
  is the only thing that merges (and only in LIVE mode).
- Prompts hardcode the Docket repo/board/org. To retarget, edit `prompts/*.md`.
