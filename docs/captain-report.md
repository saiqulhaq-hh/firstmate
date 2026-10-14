# Captain report — the captain-facing decision surface

When a firstmate-manager agent supervises several firstmate homes, the captain
(the human) needs one stable place to see what needs their decision and to
answer in writing. This page describes the convention; a companion
implementation lives in `bin/fleet-status` and `bin/fleet-snapshot`.

## The file

The manager keeps a `captain-report.md` at the fleet root and rewrites the
machine-generated parts on every sweep. The captain's own edits are never
overwritten: answers stay put, sections only gain content.

### Format rules

- **H1 for sections, H2 per item — never tables.** The captain manages this
  file by hand; headings survive edits better than table rows.
- Every decision item carries a `captain:` line. The captain answers by
  editing that line (`captain: merge it`) and telling the manager "replied".
  The manager acts on every filled line, records the execution receipt inline,
  and moves the item to `# Resolved` on the next sweep.
- Section order: `# Decisions needed` → `# In execution` → `# Waiting` →
  `# Fleet status` → `# Resolved` → `# Fleet log`.

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
