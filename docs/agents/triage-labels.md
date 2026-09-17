# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Repo notes

- `wontfix` is the only one that exists on `itlmkz/PingStatus` today. The other four are created on first use: `gh label create needs-triage`.
- **No priority scheme.** The repo is one small app with a short issue list, so triage roles are enough. Do not invent `P0` to `P4` labels without asking.
- **`ready-for-human` is the common case for behaviour bugs.** Verifying a networking or popover fix needs a real macOS menu bar session, which an agent does not have. Mark those `ready-for-human` rather than claiming a fix works.
