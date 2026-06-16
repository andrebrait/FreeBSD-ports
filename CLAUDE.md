# CLAUDE.md — pfBlockerNG/FreeBSD-ports

**This file lives on the orphan `claude-meta` ref ON PURPOSE — never on the
ports branches.** `pfBlockerNG/FreeBSD-ports` is a fork of
`pfsense/FreeBSD-ports`; our port is bumped on the `pfblockerng/use-github`
build-input branch (ADR-17). Agent/meta files must never land on a ports branch
(`use-github` / `devel` / upstream-tracking) — they could be accidentally
upstreamed. Keep this CLAUDE.md only on `claude-meta`.

As a `pfBlockerNG`-org repo, this **inherits `pfBlockerNG/pfBlockerNG`'s
`CLAUDE.md` + project/user `.claude/settings.json` as the org default** (see its
"Scope" section): communication (caveman + exceptions), the working principles
(don't-guess / investigate / confirm ambiguity), worktrees + rebase-only
landing, branch naming, the test-coverage mandate, linting discipline,
GitHub-issue handling + labels, and commit style. The org-wide `SessionStart`
hook carries this into sessions working the ports branches (where this file is
absent by design). The pfBlockerNG-package mechanics and language/runtime
specifics do **not** apply. **Any rule below overrides the inherited default for
this repo.**
