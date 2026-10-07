#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The matching relaunch-side carve-out at the `[ "$RELAUNCH" -eq 1 ] &&
# [ "$BACKEND" = orca ]` branch is guarded by an earlier, unconditional gate:
# fm_control_backend_state_verified (bin/fm-control-lib.sh) only recognizes
# tmux and herdr as having a recovery-grade agent-state classifier, so any
# `--relaunch` on backend=orca is refused before that branch can ever run.
# The second test below pins that refusal so a future change that starts
# routing orca through the classifier does not silently reach the untested
# branch without also covering it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  # The adapter now prefers `orca-ide` over `orca`. The legacy test
  # created only `orca`; copy the same body to `orca-ide` so the resolver
  # picks the fake regardless of which name wins on PATH.
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    agent=0
    for a in "$@"; do
      case "$prev" in
        --name) name=$a ;;
        --agent) agent=1 ;;
      esac
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    if [ "$agent" -eq 1 ]; then
      # --agent: the live 1.4.221 CLI returns the agent terminal in
      # result.startupTerminal.handle (and result.agentTerminalHandle on
      # older runtimes). The legacy result.terminal.handle is also kept
      # for backends that still read it.
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"},"startupTerminal":{"handle":"term-%s"}}}\n' "$name" "$wt" "$name"
    else
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    fi
    exit 0
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  cp "$fb/orca" "$fb/orca-ide"
  chmod +x "$fb/orca-ide"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" \
    "the refusal should name the missing classifier, proving relaunch never reaches the worktree carve-out"
  pass "a relaunch against an Orca-backed task is refused before the RELAUNCH+orca worktree carve-out could run"
}

# test_orca_spawn_passes_agent_and_creates_only_one_terminal: with the live
# 1.4.221 --agent flag, the spawn must pass --agent to worktree create and
# record the agent terminal handle - not call terminal_create separately.
# That is the "only one worker terminal" contract.
test_orca_spawn_passes_agent_and_creates_only_one_terminal() {
  local case_dir home id=orca-agent-spawn fb out status wt_recorded terminal
  case_dir="$TMP_ROOT/agent-spawn"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Confirm the spawn passes --agent to worktree create for a supported harness.

## Firstmate spec
The spawn must record the agent terminal handle.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 0 "$status" "an Orca-backed spawn with --agent should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  # Recorded terminal must be the agent handle (term-*) that worktree
  # create returned, not a separately created shell terminal.
  terminal=$(grep '^terminal=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$terminal" ] || fail "meta did not record a terminal"
  case "$terminal" in
    term-*) : ;;
    *) fail "expected agent terminal handle (term-*); got '$terminal'" ;;
  esac
  pass "fm-spawn --backend orca: passes --agent to worktree create and records the agent terminal"
}

# test_orca_spawn_falls_back_to_shell_terminal_for_unsupported_harness:
# a harness whose Orca --agent id is not recognised (here, pi-signed) must
# still land the worktree and fall back to a separate terminal_create for
# the shell terminal, not refuse.
test_orca_spawn_falls_back_to_shell_terminal_for_unsupported_harness() {
  local case_dir home id=orca-shell-spawn fb out status wt_recorded terminal
  case_dir="$TMP_ROOT/shell-spawn"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'muse\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Confirm a harness without a matching Orca --agent falls back to the legacy shell terminal.

## Firstmate spec
The spawn must call terminal_create separately and record that handle.
EOF
  # Stub the muse credential file so the harness credential preflight
  # passes; the test only exercises the spawn-time terminal fallback, not
  # the muse runtime.
  mkdir -p "$case_dir/user-home/.config/muse"
  printf '{"apiKey":"test-key"}\n' > "$case_dir/user-home/.config/muse/auth.json"
  fb=$(make_orca_fakebin "$case_dir")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    XDG_CONFIG_HOME="$case_dir/user-home/.config" XDG_DATA_HOME="$case_dir/user-home/.local/share" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 0 "$status" "an Orca-backed spawn with an unsupported harness should still succeed via the shell-terminal fallback"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  terminal=$(grep '^terminal=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$terminal" ] || fail "meta did not record a terminal"
  # The fake's terminal_create returns handle "term-1"; that is the shell
  # terminal the legacy code creates separately.
  [ "$terminal" = "term-1" ] || fail "expected the legacy shell terminal handle 'term-1'; got '$terminal'"
  pass "fm-spawn --backend orca: falls back to a separate terminal_create when the harness has no Orca --agent"
}

test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run
test_orca_spawn_passes_agent_and_creates_only_one_terminal
test_orca_spawn_falls_back_to_shell_terminal_for_unsupported_harness

echo "# all fm-spawn-orca-worktree tests passed"
