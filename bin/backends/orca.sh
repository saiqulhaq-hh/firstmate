#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

# fm_backend_orca_bin: the absolute path to the resolved Orca CLI. Every helper
# that talks to Orca reads this so the precedence rule (orca-ide > orca, with
# ORCA_CLI_BIN_DIR appended as a fallback) is owned once. The first call writes
# the cache; later calls return the cached value without re-running the probe.
# FM_BACKEND_ORCA_BIN takes precedence and lets tests pin a fake binary
# without touching PATH. The live host's ORCA_CLI_BIN_DIR
# (/home/chucky/.config/orca/linux-orca-cli-shim) holds an `orca` shim that
# exec's the AppImage; the Linux orca-cli-shim convention is to APPEND that
# dir to PATH so an explicit `orca-ide` (often on the user's PATH) wins.
fm_backend_orca_bin() {
  if [ -n "${FM_BACKEND_ORCA_BIN:-}" ]; then
    printf '%s\n' "$FM_BACKEND_ORCA_BIN"
    return 0
  fi
  local path_dir candidate status_out
  path_dir="$PATH"
  if [ -n "${ORCA_CLI_BIN_DIR:-}" ] && [ -d "$ORCA_CLI_BIN_DIR" ]; then
    path_dir="$path_dir:$ORCA_CLI_BIN_DIR"
  fi
  candidate=$(PATH="$path_dir" command -v orca-ide 2>/dev/null) || candidate=
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    FM_BACKEND_ORCA_BIN=$candidate
    export FM_BACKEND_ORCA_BIN
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(PATH="$path_dir" command -v orca 2>/dev/null) || candidate=
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    status_out=$("$candidate" status --json 2>/dev/null) || status_out=
    if [ -n "$status_out" ] && printf '%s' "$status_out" | grep -q '"runtime"'; then
      FM_BACKEND_ORCA_BIN=$candidate
      export FM_BACKEND_ORCA_BIN
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

# fm_backend_orca_feature: yes/no capability check against the resolved CLI's
# own --help. Cached per flag name for a process lifetime; FM_BACKEND_ORCA_FEATURES_FORCE
# overrides the verdict for tests (1=capable, 0=incapable) without probing
# the real binary. Older hosts that lack the flag fail closed to the legacy
# code path; this is the only place the runtime backend asks "is the feature
# here?" - every consumer calls this and branches on yes/no.
fm_backend_orca_feature() {  # <flag-name>
  local flag=$1 bin help_text
  case "${FM_BACKEND_ORCA_FEATURES_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  bin=$(fm_backend_orca_bin) || return 1
  help_text=$("$bin" --help 2>&1) || return 1
  printf '%s\n' "$help_text" | grep -Eq -- "[[:space:]]${flag}[[:space:]<]"
}

fm_backend_orca_tool_check() {
  local bin
  if ! bin=$(fm_backend_orca_bin); then
    echo "error: backend=orca selected but no Orca CLI is on PATH; install orca-ide or set ORCA_CLI_BIN_DIR to the linux-orca-cli-shim directory (a bare 'orca' resolving to the GNOME screen reader is rejected)" >&2
    return 1
  fi
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out bin
  bin=$(fm_backend_orca_bin)
  out=$("$bin" status --json 2>/dev/null) || {
    echo "error: backend=orca selected but '$bin status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

# fm_backend_orca_wait_tui_idle: capability-gated call to `orca terminal wait
# --for tui-idle`. Returns 0 on a settled TUI, 2 on timeout (live receipt), and
# a non-zero error for an unrecognized flag or runtime error. Older hosts that
# lack the primitive report capability=no and callers fall back to the
# read-and-classify path.
fm_backend_orca_wait_tui_idle() {  # <terminal-id> <timeout-ms>
  local terminal=$1 timeout_ms=${2:-30000} bin
  fm_backend_orca_tool_check || return 1
  if ! fm_backend_orca_feature --wait-submit >/dev/null 2>&1; then
    return 2
  fi
  bin=$(fm_backend_orca_bin)
  "$bin" terminal wait --terminal "$terminal" --for tui-idle --timeout-ms "$timeout_ms" --json
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal, a root terminal object with .handle, the live 1.4.221
  # startupTerminal.handle returned with --agent, and the legacy
  # agentTerminalHandle. Undocumented result.id and result.worktree.terminal
  # shapes are still rejected.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const startupTerm = r.startupTerminal || r.agentTerminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || startupTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm || startupTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  out=$("$bin" repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$("$bin" repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

# fm_backend_orca_agent_for_harness: maps a firstmate harness name to the
# matching Orca --agent id, or the empty string when the harness has no
# Orca-native TUI agent and the worktree must fall back to a plain shell
# terminal. Verified supported on the live Linux Orca 1.4.221 host: codex,
# opencode, claude, pi, kimi, grok, omp. Unsupported on firstmate: pi-signed,
# muse, rovo, cursor, agy, devin (refused by Orca with "Unknown TUI agent" or
# "Selected agent is disabled"). Firstmate's other harnesses (pi-signed,
# muse) intentionally keep the empty-string fallback so the existing shell +
# type-the-harness-into-the-shell behavior is preserved.
fm_backend_orca_agent_for_harness() {  # <harness>
  case "$1" in
    codex|opencode|claude|pi|kimi|grok|omp) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

fm_backend_orca_worktree_create() {  # <project-path> <name> [agent]
  local project=$1 name=$2 agent=${3:-} repo_id out wt_id wt_path terminal bin
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  bin=$(fm_backend_orca_bin)
  if [ -n "$agent" ]; then
    out=$("$bin" worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --agent "$agent" --json) || return 1
  else
    out=$("$bin" worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json) || return 1
  fi
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  out=$("$bin" terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

# fm_backend_orca_send_text_line_watch: returns the durable request id from a
# send (if the live runtime surfaced one) on stdout; empty on older hosts.
fm_backend_orca_send_text_line_watch() {  # <terminal-id> <text>
  local terminal=$1 text=$2 out bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  if fm_backend_orca_feature --wait-submit >/dev/null 2>&1; then
    out=$("$bin" terminal send --terminal "$terminal" --text "$text" --enter --wait-submit 1 --json) || return 1
  else
    out=$("$bin" terminal send --terminal "$terminal" --text "$text" --enter --json) || return 1
  fi
  fm_backend_orca_json_ok <<<"$out" || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.exit(0); }
const r = (data && data.result) || {};
const candidate = r.requestId || r.request_id || (r.send && (r.send.requestId || r.send.request_id)) || "";
if (typeof candidate === "string" || typeof candidate === "number") process.stdout.write(String(candidate));
'
}

# fm_backend_orca_send_retry: reissue an exact --retry-request <id> send. Used
# by fm_backend_orca_send_text_submit on the second send attempt when the
# runtime surfaced a request id and supports the flag. Falls back to a plain
# re-send on hosts that lack --retry-request (verified: 1.4.221 supports it).
fm_backend_orca_send_retry() {  # <terminal-id> <text> <request-id>
  local terminal=$1 text=$2 req_id=$3 bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  if [ -n "$req_id" ] && fm_backend_orca_feature --retry-request >/dev/null 2>&1; then
    "$bin" terminal send --terminal "$terminal" --text "$text" --enter --retry-request "$req_id" --json
  else
    "$bin" terminal send --terminal "$terminal" --text "$text" --enter --json
  fi
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json "$(fm_backend_orca_bin)" terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json "$(fm_backend_orca_bin)" terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json "$(fm_backend_orca_bin)" worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_bin) || return 1
  out=$("$out" worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_bin) || return 1
  out=$("$out" terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh. On hosts that expose
# `terminal wait --for tui-idle`, a settled TUI short-circuits the read into
# an `empty` verdict without polling; older hosts (and any wait error that
# does not look like a settled receipt) fall back to the read-and-classify
# path unchanged, so the safety contract on the existing `pending`/`unknown`
# verdicts is preserved.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  if [ "$verdict" = empty ] && [ -n "${FM_COMPOSER_TUI_IDLE_FASTPATH:-1}" ]; then
    if fm_backend_orca_wait_tui_idle "$1" 200 >/dev/null 2>&1; then
      printf 'empty'
      return 0
    fi
  fi
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2 bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json "$bin" terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json "$bin" terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: send <text> + Enter atomically with
# --wait-submit on hosts that support it (the receipt exposes a durable
# request id), and on hosts that accept --retry-request reissue the exact
# original prompt id instead of pressing Enter again. Hosts that lack either
# capability fall back to the legacy text-then-Enter pattern via the shared
# composer retry core, so the safety contract on the popup-fill Enter retry
# is preserved unchanged.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 req_id state i=0
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  if fm_backend_orca_feature --wait-submit >/dev/null 2>&1; then
    req_id=$(fm_backend_orca_send_text_line_watch "$terminal" "$text") || {
      printf 'send-failed'
      return 0
    }
    FM_BACKEND_ORCA_LAST_REQUEST_ID=$req_id
    export FM_BACKEND_ORCA_LAST_REQUEST_ID
    sleep "$settle"
    while [ "$i" -lt "$retries" ]; do
      state=$(fm_backend_orca_composer_state "$terminal")
      case "$state" in
        pending|pending-unproven)
          if [ -n "$req_id" ] && fm_backend_orca_feature --retry-request >/dev/null 2>&1; then
            fm_backend_orca_send_retry "$terminal" "$text" "$req_id" >/dev/null 2>&1 || true
          else
            fm_backend_orca_send_key "$terminal" Enter >/dev/null 2>&1 || true
          fi
          sleep "$sleep_s"
          i=$((i + 1))
          ;;
        *)
          printf '%s' "$state"
          return 0
          ;;
      esac
    done
    state=$(fm_backend_orca_composer_state "$terminal")
    printf '%s' "$state"
    return 0
  fi
  # Legacy hosts without --wait-submit: keep the text-then-Enter pattern.
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  local bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin)
  "$bin" terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
