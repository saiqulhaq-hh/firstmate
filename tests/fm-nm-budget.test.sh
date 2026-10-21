#!/usr/bin/env bash
# Behavior tests for the no-mistakes 10-minute budget gate
# (bin/fm-nm-budget.sh). The script is the deterministic clock and decision
# the operational no-mistakes policy in AGENTS.md section 7 references; this
# suite pins both threshold paths end to end through the documented CLI
# surface, with FM_NM_BUDGET_NOW as the test seam so neither side of the
# comparison depends on the real wall clock.
#
# Coverage:
#   - elapsed <  budget  -> status=within, exit 0 (preserves <=10min behavior)
#   - elapsed == budget  -> status=within, exit 0 (the documented boundary)
#   - elapsed >  budget  -> status=over,  exit 1 (the new stop/skip verdict)
#   - a custom --budget moves both sides of the comparison
#   - the default budget reads config/nm-budget-minutes when present and valid
#   - usage errors exit non-zero and never emit a verdict
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM_BUDGET="$ROOT/bin/fm-nm-budget.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-budget)
TMP_HOME="$TMP_ROOT/home"
mkdir -p "$TMP_HOME/config"

# check_budget <expect_exit> <now_epoch> <expected_field> <args...>
# Runs the documented `check` subcommand with the test seam pinned and
# asserts its exit status and its single parseable status line. Results are
# returned through globals rather than command substitution because fail()
# inside a subshell would only exit that subshell and let the suite continue.
check_budget() {
  local expect_exit=$1 now_epoch=$2 expect_field=$3
  shift 3
  local out rc
  out=$(FM_NM_BUDGET_NOW=$now_epoch bash "$NM_BUDGET" check "$@" 2>&1)
  rc=$?
  if [ "$rc" != "$expect_exit" ]; then
    fail "check $* exit was $rc, expected $expect_exit. output: $out"
  fi
  case "$out" in
    "status=$expect_field"*) ;;
    *) fail "check $* reported '$out', expected status=$expect_field" ;;
  esac
  case "$out" in
    *"elapsed="*s" budget="*min*) ;;
    *) fail "check $* output lacks the elapsed/budget fields: $out" ;;
  esac
  BUDGET_OUT=$out
}

# expect_no_verdict <description> <args...>: a usage error must exit non-zero
# and print no status= token, so a caller can never read a verdict from a
# malformed invocation.
expect_no_verdict() {
  local desc=$1
  shift
  local out rc
  out=$(FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" check "$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$desc: usage error exited 0. output: $out"
  case "$out" in
    *status=*) fail "$desc: usage error emitted a verdict. output: $out" ;;
  esac
  [ -n "$out" ] || fail "$desc: usage error printed no diagnostic"
  pass "$desc reports a usage error without a verdict"
}

# --- at or below the budget: the preserved path ------------------------

check_budget 0 1000000 within 1000000  # 0s elapsed
case "$BUDGET_OUT" in
  *elapsed=0s*budget=10min*) pass "a zero elapsed run is within the default budget" ;;
  *) fail "zero elapsed should read elapsed=0s budget=10min, got: $BUDGET_OUT" ;;
esac

check_budget 0 1000000 within 999600  # 400s elapsed, under the 600s budget
case "$BUDGET_OUT" in
  *elapsed=400s*budget=10min*) pass "400s elapsed stays within the default 10-minute budget" ;;
  *) fail "expected within elapsed=400s budget=10min, got: $BUDGET_OUT" ;;
esac

check_budget 0 1000000 within 999400  # 600s elapsed, exactly the boundary
pass "elapsed exactly at the 10-minute budget stays within and exits 0"

# --- over the budget: the new stop/skip path --------------------------

check_budget 1 1000000 over 999399  # 601s elapsed, one second over
pass "elapsed one second over the 10-minute budget reports over and exits 1"

check_budget 1 1000000 over 940000  # 60000s elapsed, far over
case "$BUDGET_OUT" in
  *elapsed=60000s*budget=10min*) pass "a run far over the budget reports over with its elapsed span" ;;
  *) fail "expected over elapsed=60000s budget=10min, got: $BUDGET_OUT" ;;
esac

# --- a custom --budget moves both sides of the comparison --------------

check_budget 0 1000000 within --budget 5 999701  # 299s against a 300s budget
case "$BUDGET_OUT" in
  *elapsed=299s*budget=5min*) pass "299s is within an explicit 5-minute budget" ;;
  *) fail "expected within elapsed=299s budget=5min, got: $BUDGET_OUT" ;;
esac

check_budget 0 1000000 within --budget 5 999700  # 300s, exactly the 5-min budget
pass "a custom budget keeps its own boundary within"

check_budget 1 1000000 over --budget 5 999699  # 301s against a 300s budget
pass "a custom budget reports over past its own boundary"

# The same elapsed span flips its verdict with the budget width, which proves
# the budget is the decision input rather than a hardcoded constant.
check_budget 0 1000000 within --budget 20 999399  # 601s against a 1200s budget
check_budget 1 1000000 over --budget 5 999399   # 601s against a 300s budget
pass "one elapsed span is within a wide budget and over a narrow one"

# --- config/nm-budget-minutes supplies the default budget --------------

printf '7\n' > "$TMP_HOME/config/nm-budget-minutes"
out=$(FM_HOME="$TMP_HOME" FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" budget) || \
  fail "budget subcommand failed with a valid config"
[ "$out" = 7 ] || fail "valid config should yield budget 7, got: $out"
pass "a valid config/nm-budget-minutes supplies the default budget"

out=$(FM_HOME="$TMP_HOME" FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" check 995800 2>&1)
rc=$?
[ "$rc" = 1 ] || fail "4200s against a 7-minute config budget should be over (exit 1), got exit $rc"
case "$out" in
  *status=over*elapsed=4200s*budget=7min*) pass "a config budget makes 4200s over the 7-minute window" ;;
  *) fail "expected over elapsed=4200s budget=7min from config, got: $out" ;;
esac

out=$(FM_HOME="$TMP_HOME" FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" check 999600 2>&1)
rc=$?
[ "$rc" = 0 ] || fail "400s against a 7-minute config budget should be within, exit was $rc"
case "$out" in
  *status=within*elapsed=400s*budget=7min*) pass "a config budget keeps 400s within the 7-minute window" ;;
  *) fail "expected within elapsed=400s budget=7min from config, got: $out" ;;
esac

# A malformed or non-positive config falls back to the documented default
# rather than failing a pipeline-driven check.
for bad in 'not-a-number' '0' '-3' '4.5' ''; do
  printf '%s\n' "$bad" > "$TMP_HOME/config/nm-budget-minutes"
  out=$(FM_HOME="$TMP_HOME" FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" budget) || \
    fail "budget subcommand failed on config '$bad'"
  [ "$out" = 10 ] || fail "config '$bad' should fall back to the default 10, got: $out"
done
pass "a malformed or non-positive config falls back to the default 10-minute budget"

rm -f "$TMP_HOME/config/nm-budget-minutes"
out=$(FM_HOME="$TMP_HOME" FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" budget) || \
  fail "budget subcommand failed with no config"
[ "$out" = 10 ] || fail "an absent config should yield the default 10, got: $out"
pass "an absent config yields the default 10-minute budget"

# --- usage errors never emit a verdict ---------------------------------

expect_no_verdict 'a missing start epoch'
expect_no_verdict 'a non-integer start epoch' abc
expect_no_verdict 'a non-integer --budget' --budget foo 1000000
expect_no_verdict 'a --budget with no value' --budget
expect_no_verdict 'a negative start epoch' -- -5

# --- the budget and now subcommands ------------------------------------

out=$(FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" now) || fail "now subcommand failed"
[ "$out" = 1000000 ] || fail "now should honor FM_NM_BUDGET_NOW=1000000, got: $out"
out=$(FM_NM_BUDGET_NOW=1000000 bash "$NM_BUDGET" check 1000000 2>&1)
case "$out" in
  *status=within*) pass "check still reports a verdict when the seam is unset" ;;
  *) fail "check without the seam should still work, got: $out" ;;
esac
out=$(FM_NM_BUDGET_NOW=not-a-number bash "$NM_BUDGET" now) || fail "now subcommand failed"
case "$out" in
  ''|*[!0-9]*) fail "now should still print an integer epoch, got: $out" ;;
esac
[ "$out" -gt 1000000 ] || \
  fail "a malformed FM_NM_BUDGET_NOW should fall through to the real clock, got: $out"
pass "a malformed FM_NM_BUDGET_NOW falls through to the real clock"

pass "fm-nm-budget.sh covers both threshold paths"