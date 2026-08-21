#!/usr/bin/env bash
#
# Tests for check-dead-code.sh. Plain bash asserts, matching the shell-test
# style in claude-shared/tests/setup-repo/.
#
#   bash tests/test-check-dead-code.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check-dead-code.sh"

passed=0
failed=0
ok()  { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failed=$((failed + 1)); }

# A PATH with no vulture on it, used to prove the gate fails closed rather
# than reporting a scan that never happened as a clean one.
NO_VULTURE_PATH="/usr/bin:/bin"

if PATH="$NO_VULTURE_PATH" command -v vulture >/dev/null 2>&1; then
    echo "SKIP: vulture resolves on $NO_VULTURE_PATH; cannot test the missing-tool path" >&2
    exit 2
fi

# --- fixtures ---------------------------------------------------------------

# Only function is called, so vulture finds nothing.
mkclean() {
    local dir; dir="$(mktemp -d)"
    printf 'def used():\n    return 1\n\n\nprint(used())\n' >"$dir/main.py"
    printf '%s' "$dir"
}

# One never-referenced function. vulture reports unused functions at 60%
# confidence, which is exactly the gate's threshold.
mkdirty() {
    local dir; dir="$(mktemp -d)"
    printf 'def used():\n    return 1\n\n\ndef orphan_function():\n    return 2\n\n\nprint(used())\n' >"$dir/main.py"
    printf '%s' "$dir"
}

# Dead code inside a test file: scanned, but must not be reported.
mkdirty_tests() {
    local dir; dir="$(mktemp -d)"
    printf 'def used():\n    return 1\n\n\nprint(used())\n' >"$dir/main.py"
    mkdir -p "$dir/tests"
    printf 'def orphan_helper():\n    return 2\n' >"$dir/tests/test_thing.py"
    printf '%s' "$dir"
}

# A syntax error, not dead code. vulture exits 1 (InvalidInput) on this, not
# 3 (DeadCode) — the gate must propagate that as a failure, not read it as a
# clean scan the way the pre-fix version misread exit 3 as a crash.
mkbroken() {
    local dir; dir="$(mktemp -d)"
    printf 'def broken(:\n    pass\n' >"$dir/bad.py"
    printf '%s' "$dir"
}

# A decorated, otherwise-unreferenced handler — the Flask/FastAPI dispatch
# pattern --ignore-decorators exists for (retina-server's backend is exactly
# this shape). vulture can't see the framework's dispatch wiring, so without
# the flag this reads as dead.
mkdirty_decorated() {
    local dir; dir="$(mktemp -d)"
    printf 'def used():\n    return 1\n\n\n@app.route("/foo")\ndef handler_endpoint():\n    return "hi"\n\n\nprint(used())\n' >"$dir/main.py"
    printf '%s' "$dir"
}

# --- tests that run whether or not vulture is installed ---------------------

t_missing_vulture_fails_closed() {
    local dir out rc
    dir="$(mkclean)"
    out="$(cd "$dir" && PATH="$NO_VULTURE_PATH" bash "$SCRIPT" 2>&1)"; rc=$?
    # Assert the exact code, not just non-zero: 127 is this gate's whole
    # fail-closed contract, and other paths (findings, bad usage) also exit
    # non-zero, so a loose check can't tell them apart.
    if [ "$rc" -eq 127 ]; then
        ok "missing vulture exits exactly 127"
    else
        bad "missing vulture exits exactly 127" \
            "exited $rc — reported a scan that never happened, or used the wrong code"
    fi
    case "$out" in
        *vulture*) ok "missing vulture names the tool" ;;
        *)         bad "missing vulture names the tool" "no mention of vulture in: $out" ;;
    esac
    rm -rf "$dir"
}

# cd failure must not be mistaken for "dead code found" (both exit 1 under a
# bare `cd`). A bad target is a usage error, so it gets exit 2 — the code
# this script already uses for other usage errors — and must name the target
# so a typo'd path in a consumer's pre-commit config is diagnosable from CI
# output alone.
t_bad_target_exits_2() {
    local target out rc
    target="$(mktemp -u)/does-not-exist"
    out="$(PATH="$NO_VULTURE_PATH" bash "$SCRIPT" "$target" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ] && [[ "$out" == *"$target"* ]]; then
        ok "nonexistent target exits 2 and names the target"
    else
        bad "nonexistent target exits 2 and names the target" "rc=$rc out=$out"
    fi
}

t_unknown_option_rejected() {
    local dir out rc
    dir="$(mkclean)"
    out="$(cd "$dir" && PATH="$NO_VULTURE_PATH" bash "$SCRIPT" --nope 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "unknown option exits 2"
    else
        bad "unknown option exits 2" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

# --- tests that need vulture ------------------------------------------------

t_clean_tree_reports_none() {
    local dir out rc
    dir="$(mkclean)"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"no dead code found"* ]]; then
        ok "clean tree exits 0 with 'no dead code found'"
    else
        bad "clean tree exits 0" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

t_dead_code_fails() {
    local dir out rc
    dir="$(mkdirty)"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"orphan_function"* ]]; then
        ok "dead code exits 1 and names the symbol"
    else
        bad "dead code exits 1" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

t_list_does_not_fail() {
    local dir out rc
    dir="$(mkdirty)"
    out="$(cd "$dir" && bash "$SCRIPT" --list 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"orphan_function"* ]]; then
        ok "--list prints findings and exits 0"
    else
        bad "--list exits 0" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

t_test_files_filtered() {
    local dir out rc
    dir="$(mkdirty_tests)"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" != *"orphan_helper"* ]]; then
        ok "findings inside tests/ are filtered out"
    else
        bad "tests/ findings filtered" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

t_vulture_failure_propagates() {
    local dir out rc
    dir="$(mkbroken)"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    # Assert on the "vulture exited" message, not just non-zero — findings
    # also exit non-zero, so rc alone can't distinguish a real vulture
    # failure from a normal findings report.
    if [ "$rc" -ne 0 ] && [[ "$out" == *"vulture exited"* ]]; then
        ok "vulture failure (exit 1) propagates, not read as clean"
    else
        bad "vulture failure propagates" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

# vulture_whitelist.py pickup (check-dead-code.sh:65) is what keeps every
# consumer repo green — all six have one. Both halves are required: checking
# only "whitelisted symbol passes" would also pass if the scan found nothing
# at all, so this first proves the fixture fails without a whitelist, then
# adds a whitelist for exactly that symbol and proves it now passes.
t_whitelist_suppresses_finding() {
    local dir out rc
    dir="$(mkdirty)"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"orphan_function"* ]]; then
        ok "whitelist test: unwhitelisted dead code fails first"
    else
        bad "whitelist test: unwhitelisted dead code fails first" "rc=$rc out=$out"
    fi

    printf 'from main import orphan_function\norphan_function\n' >"$dir/vulture_whitelist.py"
    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"no dead code found"* ]]; then
        ok "vulture_whitelist.py suppresses the whitelisted symbol"
    else
        bad "vulture_whitelist.py suppresses the whitelisted symbol" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

# --ignore-decorators (check-dead-code.sh:63) is what stops every Flask/
# FastAPI route handler reading as dead — retina-server's backend is exactly
# this shape and depends on it directly. The script has no flag to disable
# its own --ignore-decorators, so the first half calls vulture directly
# with the script's other options (same EXCLUDE, same --min-confidence, no
# --ignore-decorators) to establish the finding is real; the second half
# runs the actual script and proves the flag suppresses it. As with the
# whitelist test, both halves are required — the second half alone would
# also pass if the scan found nothing at all.
t_ignore_decorators_suppresses_handlers() {
    local dir out rc
    dir="$(mkdirty_decorated)"
    out="$(cd "$dir" && vulture . --min-confidence 60 \
        --exclude ".venv,scripts,htmlcov,__pycache__,node_modules,build,dist,*.egg-info" 2>&1)"; rc=$?
    if [ "$rc" -eq 3 ] && [[ "$out" == *"handler_endpoint"* ]]; then
        ok "decorators test: scan without --ignore-decorators finds the handler dead"
    else
        bad "decorators test: scan without --ignore-decorators finds the handler dead" "rc=$rc out=$out"
    fi

    out="$(cd "$dir" && bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"no dead code found"* ]]; then
        ok "--ignore-decorators suppresses the decorated handler"
    else
        bad "--ignore-decorators suppresses the decorated handler" "rc=$rc out=$out"
    fi
    rm -rf "$dir"
}

t_positional_target_scopes_scan() {
    local root out rc
    root="$(mktemp -d)"
    mkdir -p "$root/backend" "$root/libs"
    printf 'def used():\n    return 1\n\n\nprint(used())\n' >"$root/backend/main.py"
    printf 'def orphan_in_libs():\n    return 2\n' >"$root/libs/other.py"
    out="$(cd "$root" && bash "$SCRIPT" backend 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" != *"orphan_in_libs"* ]]; then
        ok "positional target scopes the scan"
    else
        bad "positional target scopes the scan" "rc=$rc out=$out"
    fi
    rm -rf "$root"
}

# --- run --------------------------------------------------------------------

echo "fail-closed:"
t_missing_vulture_fails_closed
t_unknown_option_rejected
t_bad_target_exits_2

echo "behaviour:"
if command -v vulture >/dev/null 2>&1; then
    t_clean_tree_reports_none
    t_dead_code_fails
    t_list_does_not_fail
    t_test_files_filtered
    t_positional_target_scopes_scan
    t_vulture_failure_propagates
    t_whitelist_suppresses_finding
    t_ignore_decorators_suppresses_handlers
elif [ "${REQUIRE_VULTURE:-}" = "1" ]; then
    # A skipped suite reporting success is the same class of bug as the gate
    # this repo hosts: silence read as a clean result. CI sets
    # REQUIRE_VULTURE=1 so a broken `pip install vulture` fails the job
    # instead of quietly skipping the five tests below and going green.
    echo "  FAIL  REQUIRE_VULTURE=1 but vulture is not resolvable on PATH" >&2
    echo "        install did not happen or PATH is wrong; refusing to skip" >&2
    exit 1
else
    echo "  note  vulture not installed locally; CI runs these"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
