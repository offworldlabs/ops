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

# --- tests that run whether or not vulture is installed ---------------------

t_missing_vulture_fails_closed() {
    local dir out rc
    dir="$(mkclean)"
    out="$(cd "$dir" && PATH="$NO_VULTURE_PATH" bash "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "missing vulture exits non-zero" \
            "exited 0 — reported a scan that never happened"
    else
        ok "missing vulture exits non-zero (got $rc)"
    fi
    case "$out" in
        *vulture*) ok "missing vulture names the tool" ;;
        *)         bad "missing vulture names the tool" "no mention of vulture in: $out" ;;
    esac
    rm -rf "$dir"
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

echo "behaviour:"
if command -v vulture >/dev/null 2>&1; then
    t_clean_tree_reports_none
    t_dead_code_fails
    t_list_does_not_fail
    t_test_files_filtered
    t_positional_target_scopes_scan
else
    echo "  note  vulture not installed locally; CI runs these"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
