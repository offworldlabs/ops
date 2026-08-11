#!/usr/bin/env bash
#
# Dead-code gate. Canonical copy: offworldlabs/ops, check-dead-code.sh.
#
# Consumed by other repos as a pre-commit hook, pinned by rev:
#
#   - repo: https://github.com/offworldlabs/ops
#     rev: <latest dead-code-v*.* tag — see the repo's tag list or README>
#     hooks:
#       - id: dead-code
#
# No version is named here on purpose. This file is frozen inside whatever tag
# a consumer pinned, so any version written here is guaranteed wrong for every
# release after it. The README on main is the current reference.
#
# Do not vendor this file. Change it here, publish a dead-code-v<MAJOR>.<MINOR>
# tag (the dot matters — pre-commit warns "mutable reference" without one), then
# bump rev in the consumers (`pre-commit autoupdate` does that for you).
#
#   check-dead-code.sh            # fail if anything unwhitelisted is dead
#   check-dead-code.sh --list     # print findings without failing
#   check-dead-code.sh backend    # scan a subdirectory
#
# Why this wraps vulture rather than calling it directly:
#
# Tests are SCANNED but not REPORTED. Excluding tests entirely — the obvious
# setup — makes anything used only by tests look dead, which is the largest
# single source of false positives. Scanning them fixes that, but then unused
# test helpers become findings in their own right. So we scan everything and
# drop findings whose location is a test file.
#
# Build artefacts are excluded because they contain a stale copy of the source,
# which doubles every finding.

set -euo pipefail

# Scan the current directory by default; pre-commit sets CWD to the consumer
# repo root. An optional positional argument scopes it (Tower-Finder passes
# "backend"). This replaces a cd relative to the script's own location, which
# is meaningless now the script lives in a pre-commit cache.
LIST_ONLY=0
TARGET="."
for arg in "$@"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        -*)     echo "check-dead-code: unknown option: $arg" >&2; exit 2 ;;
        *)      TARGET="$arg" ;;
    esac
done
cd "$TARGET"

# Fail closed (ops README convention 4: fail loudly). A missing tool is not a
# clean scan, and this gate used to report one as the other: the shell's
# "command not found" went to /dev/null and `|| true` discarded exit 127.
if ! command -v vulture >/dev/null 2>&1; then
    echo "check-dead-code: vulture is not installed or not on PATH" >&2
    echo "  install it with:  pip install vulture==2.14" >&2
    exit 127
fi

EXCLUDE=".venv,scripts,htmlcov,__pycache__,node_modules,build,dist,*.egg-info"
# Framework-dispatched handlers: Flask (@bp/@app) and FastAPI (@router/@app).
DECORATORS="@app.*,@bp.*,@router.*"
WHITELIST=""
[ -f vulture_whitelist.py ] && WHITELIST="vulture_whitelist.py"

stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

set +e
raw="$(vulture . $WHITELIST \
    --min-confidence 60 \
    --exclude "$EXCLUDE" \
    --ignore-decorators "$DECORATORS" \
    2>"$stderr_file")"
status=$?
set -e

# vulture 2.x exit codes (vulture.utils.ExitCode): 0 NoDeadCode, 1 InvalidInput,
# 2 InvalidCmdlineArguments, 3 DeadCode. Only 0 and 3 mean vulture ran fine —
# 1 and 2 are real failures and must propagate rather than read as "clean".
case "$status" in
    0|3) ;;
    *)   echo "check-dead-code: vulture exited $status" >&2
         cat "$stderr_file" >&2
         exit "$status" ;;
esac

# `|| true` is correct here and only here: grep exits 1 when it filters
# everything out, which is the clean case. The bug this script had was applying
# the same `|| true` to the whole pipeline, where it also swallowed exit 127.
findings="$(printf '%s\n' "$raw" | grep -vE '(^|/)tests?/|/test_|conftest\.py' || true)"

if [ -z "$findings" ]; then
    echo "no dead code found"
    exit 0
fi

echo "$findings"

if [ "$LIST_ONLY" = "1" ]; then
    exit 0
fi

echo >&2
echo "Dead code found. Delete it, or — only if it is referenced dynamically and" >&2
echo "vulture cannot see that — add it to vulture_whitelist.py with a reason." >&2
exit 1
