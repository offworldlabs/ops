#!/usr/bin/env bash
#
# Tests for check-ruff-config.py. Plain bash asserts, matching the style of
# tests/test-check-dead-code.sh.
#
#   bash tests/test-check-ruff-config.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check-ruff-config.py"
CANON="$HERE/../ruff-shared.toml"

passed=0
failed=0
ok()  { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; failed=$((failed + 1)); }

# A pyproject carrying exactly the canonical keys, plus a per-repo
# target-version, which is what a compliant consumer looks like.
mkgood() {
    local dir; dir="$(mktemp -d)"
    {
        printf '[project]\nname = "x"\nversion = "0.1.0"\n\n'
        # reuse the canonical file verbatim, then add target-version
        cat "$CANON"
        printf '\n'
    } >"$dir/pyproject.toml"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("[tool.ruff]\nline-length = 120",
              '[tool.ruff]\nline-length = 120\ntarget-version = "py310"')
p.write_text(s)
PY
    printf '%s' "$dir"
}

t_matching_config_passes() {
    local dir out rc
    dir="$(mkgood)"
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "canonical config passes"
    else bad "canonical config passes" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

t_missing_select_fails() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('    "SIM", # flake8-simplify\n', '')
p.write_text(s)
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"SIM"* ]]; then
        ok "a missing select entry fails and names it"
    else bad "missing select fails" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

t_missing_ignore_fails() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('    "B905",   # zip strict — not needed everywhere\n', '')
p.write_text(s)
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"B905"* ]]; then
        ok "a missing ignore entry fails and names it"
    else bad "missing ignore fails" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

# The negative control. A check that fires on legitimate variation gets
# disabled within a month, so this matters as much as detecting real drift.
t_target_version_is_ignored() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace('target-version = "py310"', 'target-version = "py312"'))
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "a differing target-version still passes"
    else bad "target-version ignored" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

# Permissive by design: extra local rules are additions, not drift.
t_extra_entries_permitted() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('    "UP028",  # yield from — explicit loop is clearer\n',
              '    "UP028",  # yield from — explicit loop is clearer\n    "C901",   # local addition\n')
s = s.replace('"scripts/*" = ["S", "E"]', '"scripts/*" = ["S", "E"]\n"simulation/*" = ["S"]')
p.write_text(s)
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "extra ignores and per-file-ignores are permitted"
    else bad "extra entries permitted" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

t_missing_per_file_ignore_fails() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace('"scripts/*" = ["S", "E"]\n', ''))
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"scripts/*"* ]]; then
        ok "a missing per-file-ignores entry fails and names it"
    else bad "missing per-file-ignores fails" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

# Whitespace and ordering must not matter — Tower-Finder is semantically
# identical to the baseline but formats its comments differently.
t_whitespace_and_order_ignored() {
    local dir out rc
    dir="$(mkgood)"
    python3 - "$dir/pyproject.toml" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = re.sub(r'",\s+#', '", #', s)          # collapse comment padding
s = s.replace('    "E",   # pycodestyle errors\n', '')
s = s.replace('select = [\n', 'select = [\n    "E", # moved to the end later\n')
p.write_text(s)
PY
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "comment whitespace and ordering are ignored"
    else bad "whitespace/order ignored" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

# Tower-Finder's shape: config lives in a subdirectory.
t_subdirectory_argument() {
    local root dir out rc
    root="$(mktemp -d)"; mkdir -p "$root/backend"
    dir="$(mkgood)"
    mv "$dir/pyproject.toml" "$root/backend/pyproject.toml"; rmdir "$dir"
    out="$(cd "$root" && python3 "$SCRIPT" backend 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "positional target dir finds backend/pyproject.toml"
    else bad "subdirectory argument" "rc=$rc out=$out"; fi
    rm -rf "$root"
}

t_missing_pyproject_exits_2() {
    local dir out rc
    dir="$(mktemp -d)"
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ]; then ok "no pyproject.toml exits 2"
    else bad "no pyproject exits 2" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

t_no_ruff_section_fails() {
    local dir out rc
    dir="$(mktemp -d)"
    printf '[project]\nname = "x"\nversion = "0.1.0"\n' >"$dir/pyproject.toml"
    out="$(python3 "$SCRIPT" "$dir" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ]; then ok "a pyproject with no [tool.ruff] fails"
    else bad "no ruff section fails" "rc=$rc out=$out"; fi
    rm -rf "$dir"
}

echo "checker:"
t_matching_config_passes
t_missing_select_fails
t_missing_ignore_fails
t_target_version_is_ignored
t_extra_entries_permitted
t_missing_per_file_ignore_fails
t_whitespace_and_order_ignored
t_subdirectory_argument
t_missing_pyproject_exits_2
t_no_ruff_section_fails

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
