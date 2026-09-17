# Agent instructions: PingStatus

A single-file macOS menu bar app that shows whether the network actually works: green when the target answers over HTTPS, red when it does not. Public repo, MIT licensed.

## Read these first

- `README.md`: how a check works, HTTPS versus ping mode, configuration, reliability details, and the "Design notes / deviations from a literal spec" section
- `Makefile`: the build. `make app`, `make run`, `make smoke`, `make clean`
- `PingStatusApp.swift`: the whole app
- `Info.plist`: `CFBundleShortVersionString` is the version of record

## Rules

- **Public repo.** Never commit secrets, tokens, personal hostnames, or internal machine names.
- **One file is the design.** Do not split `PingStatusApp.swift` into modules, or add a package manifest, without asking.
- **Do not "fix" deliberate behaviour** listed in the README's design notes without reading that section first.
- **Verify with `make smoke`.** Neither an agent nor CI can confirm menu bar behaviour; say so rather than claiming a fix works.

## Agent skills

Repo-level skills are vendored in `.agents/skills/`, mirrored into `.claude/skills/` as symlinks, and pinned in `skills-lock.json` alongside their upstream source. Refresh with `npx skills update` from the repo root; add one with `npx skills add <owner>/<repo> -s <skill>`.

- **Issue tracker**: GitHub Issues on `itlmkz/PingStatus` via the `gh` CLI. See `docs/agents/issue-tracker.md`.
- **Triage labels**: the default five-role vocabulary. See `docs/agents/triage-labels.md`.
- **Domain docs**: the README carries the behaviour and the reasoning; there is no decision log yet. See `docs/agents/domain.md`.

The vendored skills are MIT, Copyright (c) 2026 Matt Pocock. Their license sits at `.agents/skills/LICENSE-mattpocock-skills`.
