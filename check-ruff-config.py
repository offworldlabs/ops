#!/usr/bin/env python3
"""Fail if a repo's shared ruff keys have drifted from the canonical set.

The canonical values live in ruff-shared.toml beside this script. pre-commit
clones this hook repo locally before running it, so that file is always a local
path at run time — which is what makes sharing possible at all: ruff's `extend`
accepts only local paths, and there is no rev:-style sharing for pyproject.toml.

Comparison is SEMANTIC, not textual. `select`, `ignore` and the values inside
`per-file-ignores` are compared as sets, so comment whitespace and ordering are
irrelevant. This matters concretely: retina-server's config is semantically
identical to the baseline but pads its comments differently, and a text diff
would report false drift.

`target-version` is never compared. It tracks each package's requires-python and
is legitimately per-repo.

Permissive by design: the canonical keys must be present and equal, but a repo
may add extra ignores or per-file-ignores entries. The accepted cost is that a
repo could ignore a rule from the shared select list without being flagged.

    check-ruff-config.py            # check ./pyproject.toml
    check-ruff-config.py backend    # check backend/pyproject.toml

Exit codes: 0 compliant, 1 drift, 2 usage error or missing pyproject.toml.
"""

import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
CANONICAL = HERE / "ruff-shared.toml"


def load(path: Path) -> dict:
    with open(path, "rb") as handle:
        return tomllib.load(handle)


def ruff_of(doc: dict) -> dict:
    return doc.get("tool", {}).get("ruff", {})


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(f"check-ruff-config: expected at most one target directory, got {len(argv) - 1}", file=sys.stderr)
        return 2

    target = Path(argv[1]) if len(argv) == 2 else Path(".")
    pyproject = target if target.is_file() else target / "pyproject.toml"

    if not pyproject.is_file():
        print(f"check-ruff-config: no pyproject.toml at {pyproject}", file=sys.stderr)
        return 2
    if not CANONICAL.is_file():
        print(f"check-ruff-config: canonical config missing at {CANONICAL}", file=sys.stderr)
        return 2

    canon = ruff_of(load(CANONICAL))
    repo = ruff_of(load(pyproject))

    problems: list[str] = []

    if not repo:
        problems.append("no [tool.ruff] section at all")

    if repo.get("line-length") != canon.get("line-length"):
        problems.append(
            f"line-length is {repo.get('line-length')!r}, canonical is {canon.get('line-length')!r}"
        )

    canon_lint = canon.get("lint", {})
    repo_lint = repo.get("lint", {})

    for key in ("select", "ignore"):
        missing = sorted(set(canon_lint.get(key, [])) - set(repo_lint.get(key, [])))
        if missing:
            problems.append(f"lint.{key} is missing {missing}")

    canon_pfi = canon_lint.get("per-file-ignores", {})
    repo_pfi = repo_lint.get("per-file-ignores", {})
    for pattern, rules in canon_pfi.items():
        if pattern not in repo_pfi:
            problems.append(f"lint.per-file-ignores is missing {pattern!r}")
        elif set(repo_pfi[pattern]) != set(rules):
            problems.append(
                f"lint.per-file-ignores[{pattern!r}] is {sorted(repo_pfi[pattern])}, "
                f"canonical is {sorted(rules)}"
            )

    if problems:
        print(f"check-ruff-config: {pyproject} has drifted from the shared ruff standard", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(file=sys.stderr)
        print("Copy the entries above into this repo's pyproject.toml to match the", file=sys.stderr)
        print("shared standard. If the standard itself should change instead, edit", file=sys.stderr)
        print("offworldlabs/ops:ruff-shared.toml and publish a new hooks-v*.* tag.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
