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
  afk-ralph-watch  afk-ralph with the live agent log streamed beside it, to watch.
  ralph-init     Readiness check (repo, git identity, hermes, gh, engineer skill).
  review-board   One senior-reviewer pass over AFK "In Review" PRs (claude, headless).
  engineer-board One autonomous worker pass, scoped to rep-sheet (claude, headless).
install.sh       Symlink bin/ onto PATH.
crontab.example  Schedule the reviewer and worker passes.
```

The agent procedure is NOT in this repo: each loop invokes the `engineer` /
`reviewer` skill (in `~/code/skills`) with a short inline prompt, and both resolve
the repo, board, and scope from `~/.claude/afk.json`. Nothing here is hardcoded to
a single project.

## Install on a machine

```bash
git clone git@github.com:dividendsolo/ralph-loop.git
cd ralph-loop
./install.sh        # symlinks bin -> ~/.local/bin
ralph-init          # verify the toolchain
```

Requires on PATH: `hermes` (worker), `claude` (reviewer), `gh` (authenticated),
`git`, and the Docket bun toolchain. Set `RALPH_REPO` if your Docket checkout is
not at `$HOME/code/docket`.

## Run

```bash
ralph-once          # advance one ticket (headless: only the final summary prints)
ralph-once-tui      # same, in the TUI, to watch it work live
afk-ralph 10        # advance up to 10 tickets (headless)
afk-ralph-watch 10  # same, with the live agent log streamed so you can watch
review-board        # one review pass (also runs from cron)
```

`ralph-once` / `afk-ralph` run `hermes -z` (oneshot), which prints ONLY the final
summary per ticket — the terminal stays blank while each ticket works. To watch
live: use `ralph-once-tui` (single ticket, TUI) or `afk-ralph-watch` (loop, with
the agent log streamed), or follow the log yourself in another terminal with
`hermes logs -f`. Each ticket always runs in its own fresh context; the watch
variants never collapse the loop into one shared session.

## Schedule the reviewer

See `crontab.example`. The reviewer runs in **SHADOW** mode by default (reviews
and posts verdicts, never merges). The SHADOW-vs-LIVE merge mode lives in the
`reviewer` skill (in `~/code/skills`), not in this repo; flip it to `LIVE` there
to let the reviewer merge CI-green, accepted PRs.

## Notes

- The worker never merges and never pushes to `main` outside a PR; the reviewer
  is the only thing that merges (and only in LIVE mode).
- Nothing here is hardcoded to one project: the loops resolve the repo, board, and
  scope from `~/.claude/afk.json`, and the procedure lives in the `engineer` /
  `reviewer` skills. To retarget, edit `afk.json`.
