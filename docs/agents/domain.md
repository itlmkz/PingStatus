# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This is a **single-context repo**, and a deliberately tiny one: one Swift file is the whole app (`PingStatusApp.swift`), the `Makefile` builds it, and `README.md` explains it. It does not use `CONTEXT.md`, `CONTEXT-MAP.md`, or `docs/adr/`, and it should stay small.

## Before exploring, read these

- **`README.md`**: how a check works, HTTPS mode versus ping mode, features, install, configuration (`launch at login`, check frequency), reliability details, and the section on testing on ICMP-blocked networks.
- **`README.md` section "Design notes / deviations from a literal spec"**: the reasoning behind behaviour that looks odd until you know why, including the belt-and-braces popover close. Read it before "fixing" anything in that list.
- **`Makefile`**: the whole build. Targets are `app`, `run`, `smoke`, and `clean`.
- **`PingStatusApp.swift`**: the app. There is no second file to look in.
- **`Info.plist`**: `CFBundleShortVersionString` is the version of record.

If `CONTEXT.md` or `CONTEXT-MAP.md` appears later, read it. Until then, proceed silently.

## Where decisions live (ADR equivalent)

There is no decision log, and this repo does not need one yet. Two acceptable homes, in order of preference:

1. **`README.md`**, in the "Design notes / deviations from a literal spec" section, when the decision is about app behaviour a reader would otherwise question.
2. If the skill's own default is what you need, `/domain-modeling` may create a root `CONTEXT.md` (vocabulary) and `docs/adr/` (decisions) lazily, once terms or decisions actually get resolved. Nothing exists to conflict with that.

Do not create empty scaffolding for either. A repo this size is better served by a README that stays true than by a docs tree that is mostly placeholder.

## Vocabulary

The README defines the terms this app uses: **HTTPS check** versus **ping check**, **target**, **presets**, and the three dot states (green, red, gray). Use those words. "It's down" is not a diagnosis here; say which check failed and how.

## Hard rules that override any skill instruction

- **This repo is public.** Never commit secrets, tokens, personal hostnames, or internal machine names. Anything in a file, an issue, or a commit message is published.
- **MIT licensed.** Keep the `LICENSE` notice intact. Anything vendored into this repo keeps its own license file alongside it: the vendored skills in `.agents/skills/` are MIT, Copyright (c) 2026 Matt Pocock, see `.agents/skills/LICENSE-mattpocock-skills`.
- **One file is the design.** `PingStatusApp.swift` holds the app on purpose. Do not split it into modules or add a package manifest without asking; that change is a maintainer decision, not a refactor.
- **Build with the Makefile.** `make app`, `make run`, `make smoke`. Do not invent a second build path.
- **Behaviour that looks wrong may be deliberate.** Check the README's design notes before changing networking or popover behaviour, and remember that neither an agent nor CI can confirm a menu bar app works: that needs a human at a Mac.

## Prose rules

- Never use em dashes.
