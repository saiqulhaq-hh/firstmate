# Fleet coordination — blockers as data, and synchronous fan-out/fan-in

Two manager-scope tools that fix the two classic failure modes of a
multi-home fleet: blockers getting lost in prose, and multi-home coordination
drifting across async turns.

## `bin/fleet-blocker` — the blocker registry

Homes record blockers as structured data instead of only mentioning them in
captain-facing messages:

```bash
fleet-blocker add <task-id> --on captain|manager|<home>|external \
    --need "exactly what is needed" [--note "context"]
fleet-blocker list
fleet-blocker clear <task-id>
fleet-blocker scan <fleet-root>   # manager: aggregate across all homes
```

The store is `<home>/state/fleet-blockers.json`; one record per task, `since`
preserved across updates so dwell time is measurable. `scan` discovers homes
from `data/fleet-sessions.json` at the fleet root (falling back to directory
conventions) and prints every recorded blocker fleet-wide.

### The standing rule

When a home is blocked on the captain, the manager, another home, or an
external party, it must `fleet-blocker add` **before or while** reporting in
prose, and `clear` immediately when resolved. Reporting "all clear" while
holding a registered blocker is a protocol violation. The manager sweeps the
registry (`scan`) and turns `on=captain` blockers into decision cards on the
captain board (see `docs/captain-board.md`).

## `bin/fleet-coordinate` — synchronous multi-home rounds

```bash
fleet-coordinate --home qa-team --home cosmos-team --prompt "run state?" \
    [--timeout 600] [--json]
fleet-coordinate --prompts-file prompts.json   # {"home": "prompt", ...}
```

One invocation performs a full coordination round trip:

1. Homes that are hibernated are resumed first (fresh workspace pane +
   `pi --session <path>` per the hibernation runbook; the session map is
   `data/fleet-sessions.json` at the fleet root).
2. The prompt is submitted to every home (queued per herdr semantics).
3. Answers are collected from each home's pi session JSONL — the first new
   assistant text message after the prompt timestamp, once the agent returns
   to idle/done — until every home answers or the timeout hits.

Use it for any question that needs several homes at once (state audits,
restart windows, fleet-wide policy checks). Per-home prompts via
`--prompts-file` when the question differs per home.
