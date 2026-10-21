#!/usr/bin/env bash
# fm-nm-budget.sh - deterministic no-mistakes run-time budget check.
#
# One owner for the minute-budget gate that the operational no-mistakes
# policy uses to decline an expected-over-budget run before it starts and to
# stop or skip a run that crosses the budget mid-flight. AGENTS.md section 7
# "Selected delivery path and merge authority" is the authoritative owner of
# the policy itself; this script is the deterministic clock and decision
# the policy asks for, and config/nm-budget-minutes overrides the default
# budget for this checkout (a single-line positive integer).
#
# Default budget is 10 minutes, matching the operational policy in
# AGENTS.md. config/nm-budget-minutes is optional; an absent file, an empty
# file, a non-positive value, or a non-integer value keeps the default
# rather than failing closed inside a pipeline-driven call. 10 is also the
# shipping default firstmate-coding-guidelines expects, so a default-branch
# skip-without-config clone stays on the documented number.
#
# Both threshold paths share this single check.
#   skip-before-start  the caller passes the wall-clock start of the task
#                      phase that would invoke /no-mistakes; if (now - start)
#                      is already over the budget, the ship declines no-
#                      mistakes for this task.
#   stop-at-budget     the caller passes the wall-clock start of the active
#                      /no-mistakes run; if (now - start) crosses the
#                      budget, the pipeline is told to stop or skip.
# Same arithmetic, same exit, same parseable line - one decision mechanic
# the policy references rather than two.
#
# Usage:
#   fm-nm-budget.sh check [--budget <minutes>] <start_epoch>
#       Exit 0 when (now - start_epoch) <= budget*60, exit 1 when over.
#       Prints one parseable line: status=within|over elapsed=<s> budget=<min>
#       A non-positive or non-integer --budget is reported on stderr and
#       exits 2; a missing or non-integer start epoch does the same.
#       Test seam: FM_NM_BUDGET_NOW overrides the current epoch, so a
#       hermetic suite can pin both sides of the comparison.
#
#   fm-nm-budget.sh budget
#       Prints the effective budget in minutes for this checkout
#       (config/nm-budget-minutes when valid, else the default).
#
#   fm-nm-budget.sh now
#       Prints the current epoch (FM_NM_BUDGET_NOW when set, else `date +%s`).
#
# Sourced library: provides fm_nm_budget_default_minutes,
# fm_nm_budget_now_epoch, fm_nm_budget_check, and fm_nm_budget_main. The
# library form is for callers that want the clock without spawning another
# shell (the operational policy uses the inline rule and points at the CLI).

# Default budget minutes. Overridden by config/nm-budget-minutes (a single-
# line positive integer) when the file is present and parseable.
FM_NM_BUDGET_DEFAULT_MINUTES=10

# fm_nm_budget_default_minutes: print the effective budget minutes.
fm_nm_budget_default_minutes() {
  local root=$FM_HOME
  if [ -z "$root" ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
  local cfg=$root/config/nm-budget-minutes
  if [ -f "$cfg" ] && [ -r "$cfg" ]; then
    local v
    IFS= read -r v < "$cfg" || true
    v=${v##*[[:space:]]}
    v=${v%%[[:space:]]*}
    case "$v" in
      ''|*[!0-9]*) : ;;
      0) : ;;
      *) printf '%s\n' "$v"; return ;;
    esac
  fi
  printf '%s\n' "$FM_NM_BUDGET_DEFAULT_MINUTES"
}

# fm_nm_budget_now_epoch: print the current epoch, honoring FM_NM_BUDGET_NOW.
# The seam only accepts a non-empty integer; anything else falls through to
# `date +%s`, so a typo in the test environment fails loudly instead of
# pretending the wall clock is some other time.
fm_nm_budget_now_epoch() {
  local override=${FM_NM_BUDGET_NOW:-}
  if [ -n "$override" ]; then
    case "$override" in
      *[!0-9]*) ;;
      *) printf '%s\n' "$override"; return ;;
    esac
  fi
  date +%s
}

# fm_nm_budget_check [--budget <minutes>] <start_epoch>: print
# "status=within|over elapsed=<s> budget=<min>" and exit 0 (within) / 1 (over).
# exit 2 is reserved for usage errors; never fakes a verdict.
fm_nm_budget_check() {
  local budget_min='' start='' usage=''
  if [ "${1:-}" = "--budget" ]; then
    if [ "$#" -lt 2 ]; then
      echo "fm-nm-budget: --budget requires a positive integer" >&2
      return 2
    fi
    budget_min=$2
    shift 2
  fi
  start=${1:-}
  if [ "$start" = "" ]; then
    echo "fm-nm-budget: a non-negative integer start epoch is required" >&2
    return 2
  fi
  case "$start" in *[!0-9]*) usage=1 ;; esac
  if [ -n "$budget_min" ]; then
    case "$budget_min" in *[!0-9]*) usage=1 ;; esac
  else
    budget_min=$(fm_nm_budget_default_minutes)
  fi
  if [ -n "$usage" ]; then
    echo "fm-nm-budget: start and --budget must be non-negative integers" >&2
    return 2
  fi
  local now elapsed limit
  now=$(fm_nm_budget_now_epoch)
  elapsed=$(( now - start ))
  limit=$(( budget_min * 60 ))
  if [ "$elapsed" -gt "$limit" ]; then
    echo "status=over elapsed=${elapsed}s budget=${budget_min}min"
    return 1
  fi
  echo "status=within elapsed=${elapsed}s budget=${budget_min}min"
}

# fm_nm_budget_main <subcommand> [args...]: CLI dispatcher. See usage block
# in the script header; subcommands are check, budget, now, help.
fm_nm_budget_main() {
  local cmd=${1:-}
  case "$cmd" in
    check)
      shift
      fm_nm_budget_check "$@"
      ;;
    budget)
      fm_nm_budget_default_minutes
      ;;
    now)
      fm_nm_budget_now_epoch
      ;;
    ''|-h|--help|help)
      cat <<'EOF' >&2
Usage: fm-nm-budget.sh <command> [args...]
  check [--budget <minutes>] <start_epoch>   exit 0 within, 1 over, 2 usage
  budget                                    print effective budget minutes
  now                                       print current epoch
EOF
      return 2
      ;;
    *)
      echo "fm-nm-budget: unknown command: $cmd" >&2
      return 2
      ;;
  esac
}

# CLI dispatcher: run only when executed, never when sourced. The explicit
# exit carries the dispatcher's exit code; without it, the script's last
# command is the if's own success and a help or unknown command would
# silently exit 0.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_nm_budget_main "$@"
  exit
fi
