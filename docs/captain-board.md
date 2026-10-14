# Captain board — the captain-facing decision surface

When a firstmate-manager agent supervises several firstmate homes, the captain
(the human) needs one stable place to see what needs their decision and to
answer in writing. This page describes the convention; companion
implementations live in `bin/captain-board` (interactive web UI),
`bin/fleet-status`, and `bin/fleet-snapshot`.

## The board (primary surface)

`bin/captain-board` serves a kanban-style board over HTTP on the machine's
Tailscale IP and localhost, so the captain can review and answer decisions
from a phone browser on the tailnet:

- Columns: **Decisions needed · In execution · Waiting · Resolved**, plus a
  fleet log.
- Cards are clickable: the detail page shows the full description and a large
  multi-line answer box. Answers append to `data/captain-answers.jsonl` (the
  durable record the manager processes) and mirror onto the card immediately.
- State lives in `data/captain-board.json`. Writers contract: the server owns
  each item's `answer` field; the manager agent owns everything else and
  updates the file atomically between captain interactions. There is no
  double-writer conflict, unlike a shared Markdown file.
- Run it under `systemd-run --user` (or any supervisor) so it outlives the
  manager agent's session: `systemd-run --user --unit=captain-board
  bin/captain-board --port 8420`.

## The Markdown export (optional fallback)

The manager may additionally regenerate a `captain-report.md` at the fleet
root from the board state (useful for git history and offline reading). The
board is authoritative for answers; the captain never edits the export by
hand. If no export is wanted, skip it — the board alone is sufficient.

### Snapshot pipeline

`bin/fleet-snapshot` runs unattended on the manager host (detached loop or
timer, ~every 10 minutes) and appends per-home state to
`data/fleet-snapshots/YYYY-MM-DD.jsonl`: lifecycle status (an agent in `done`
status has an unread completion) plus the latest assistant message text parsed
from each home's pi session JSONL, with a screen-scrape fallback. The manager
summarizes snapshots into the report whenever it is active; the collector
itself is deterministic and never interprets.

`bin/fleet-status` is the read-only, on-demand view of the same fleet:
per-home status, latest captain-facing excerpt, and a heuristic
`<== NEEDS CAPTAIN` flag when the latest report asks for authorization,
approval, or a decision. The flag is a heuristic over the visible screen —
treat flags as provisional while an agent is `working`, because the excerpt
may be its previous message.

## Conventions that make it work

- The captain answers only in the file; the manager never edits a `captain:`
  line's content, only appends execution receipts beneath it.
- The fleet log keeps one line per sweep with real wall-clock times.
- When the captain's editor overwrites manager edits (stale buffer), the
  manager restores lost content from its own history rather than asking the
  captain to redo anything.
