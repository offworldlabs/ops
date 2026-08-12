# ops

Small operational scripts and scheduled chores for Offworld Labs.

> **Where this runs.** Everything in this repository currently runs on a VPS
> controlled by Jonny Spicer — it is not managed infrastructure, and there is no
> deployment pipeline. Scripts are checked out at `/opt/apps/ops` on that box and
> scheduled from root's crontab. If Jonny's VPS is unavailable, these jobs do not
> run and nothing will alert you. Treat anything here as best-effort convenience
> automation rather than something the team can rely on.

## Contents

| Script | What it does | Schedule |
| --- | --- | --- |
| [`standup-nudge/`](standup-nudge/) | Posts a fixed standup prompt to the "Offworld Labs" ClickUp chat channel | 09:00 Europe/London, Mon–Fri |
| [`check-dead-code.sh`](check-dead-code.sh) | Dead-code gate (vulture) consumed by the Python repos as a pre-commit hook | On every commit / CI run in consumer repos |
| [`ruff-shared.toml`](ruff-shared.toml) | Canonical ruff configuration, enforced in consumer repos by the `ruff-config` hook | On every commit / CI run in consumer repos |

## Shared pre-commit hooks

This repository is also a [pre-commit](https://pre-commit.com) hook repository.
Consumers reference it by pinned tag, so there is exactly one copy of each hook
and vendored drift cannot happen:

    repos:
      - repo: https://github.com/offworldlabs/ops
        rev: hooks-v1.0
        hooks:
          - id: dead-code      # requires vulture==2.14 on PATH
          - id: ruff-config

If a consumer's Python lives in a subdirectory, add `args: [<dir>]` to both
hooks — Tower-Finder, whose backend is not at repo root, needs exactly that.

| Hook | Script | Requires |
| --- | --- | --- |
| `dead-code` | [`check-dead-code.sh`](check-dead-code.sh) | `vulture==2.14` on `PATH` |
| `ruff-config` | [`check-ruff-config.py`](check-ruff-config.py) | Python 3.11+ (`tomllib`) |

Hook versions are published as repo-level tags named `hooks-v<MAJOR>.<MINOR>`.
**The dot is required, not cosmetic.** pre-commit warns "appears to be a mutable
reference" for any `rev` containing neither a `.` nor pure hex
(`clientlib.py`, `WarnMutableRev`), so `hooks-v1` would make every consumer
print a spurious warning on every run.

Tags are repo-level rather than per-hook because pre-commit pins the whole
repository at one `rev` — two hooks cannot be versioned independently from a
single repo. The older `dead-code-v1.0` and `dead-code-v1.1` tags remain valid
for consumers that have not moved.

To change a hook: edit it here, run both suites in `tests/`, merge, tag, then
bump `rev` in the consumers (`pre-commit autoupdate` does the bump for you).

The "Adding a script" conventions below are about scheduled chores on the VPS
and do not apply to hooks — a hook takes no env config and nothing schedules it.
Convention 4, fail loudly, very much does apply: the dead-code gate exits 127
when vulture is missing rather than reporting a scan that never happened.

## Conventions

This repository is **public**, so every script must follow these rules. They are
what make it safe to keep adding to.

1. **No site-specific values in committed files.** Workspace IDs, channel IDs,
   hostnames, paths, and messages live in a `*.env` config file that stays on the
   host. Commit a `*.env.example` with placeholders instead.
2. **Secrets are referenced by path, never embedded.** A script reads its
   credential from a file outside the repository (mode `600`), and that path is
   itself configuration. No token, key, or password is ever committed — not even
   in an example file.
3. **Runtime output stays out of the repository.** Logs, findings, caches, and
   scratch files are written outside the checkout (or to a gitignored directory).
   This is the rule most easily broken by accident, because once the checkout is
   the working directory it feels natural to write a log next to the script.
4. **Fail loudly.** Cron on the host has no MTA, so unredirected stderr is
   discarded. Scripts exit non-zero on failure and report to stderr, the system
   log (`logger`), and their own log file.
5. **Config files are not secrets either.** Keeping credentials in a separate
   file from the site config means an accidentally-shared config costs nothing.

A [secret-scanning workflow](.github/workflows/secret-scan.yml) runs on every
push and pull request to enforce rule 2 mechanically.

## Adding a script

```
your-script/
  your-script.sh        # reads config from an env file; no hardcoded values
  your-script.env.example
  README.md             # what it does, how to configure, how it is scheduled
```

Then add it to the table above and wire up the schedule on the host.
