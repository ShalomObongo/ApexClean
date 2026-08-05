# Mole parity audit

ApexClean was audited against Mole `main` at
[`d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b`](https://github.com/tw93/Mole/commit/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b).
The latest Mole release during the audit was
[`V1.49.2`](https://github.com/tw93/Mole/releases/tag/V1.49.2).

This is a behavioral comparison, not a promise that a native GUI and a shell
utility should expose identical features. Differences are acceptable when they
are narrower or more reviewable; silent safety regressions are not.

## Verified parity or stronger behavior

| Area | ApexClean result |
| :--- | :--- |
| Path boundary | One fail-closed `PathGuard` gates every ordinary removal and rechecks at disposal time. Canonical Data-volume aliases, sacred roots, endpoint security paths, mount descendants and target identity changes are refused. |
| Deletion model | Cleanup follows Mole's direct-delete model. ApexClean also applies permanent deletion to reviewed uninstalls, maintenance and Space Lens, always behind an explicit irreversible confirmation. |
| Review | ApexClean is stronger: findings and uninstall leftovers expose per-item paths, sizes, evidence and confidence before action. |
| Running apps | ApexClean blocks relevant cache removal rather than quitting apps. Xcode CLI/Simulator processes and uninstall targets are checked again at the final action boundary. |
| Duplicate storage | Recursive cleanup measurements and Space Lens deduplicate hard-linked inodes, and the catalog has no static parent/child rule collisions. |
| Filesystem traversal | Recursive scans avoid child symlinks, foreign volumes, privacy-gated roots and provider-managed containers. Launch plists are read through bounded, no-follow regular-file descriptors. |
| Timeout behavior | Shell commands run in dedicated process groups with PID-identity validation and TERM/KILL escalation; cleanup and directory-listing abandoned workers have circuit-breaker limits. |
| Operation history | Each feature commits its own entries under a cross-instance file lock into one atomic, bounded store with lifetime totals. Corrupt and future-version history is preserved rather than overwritten. |
| Homebrew apps | Generic removal is refused for Homebrew-managed apps, because cask hooks and staged payloads are outside the reviewed file list. |
| Protected vendors | Endpoint/security products are directed to their official uninstallers instead of receiving a generic partial uninstall. |

## Cleanup catalog decisions

ApexClean deliberately uses narrower static rules while Mole relies more heavily
on procedural sweeps and runtime discovery.

Changes made after the parity audit:

- removed the broad `~/Library/Logs/*` sweep so app state such as Codex and
  cleaner-owned logs cannot be absorbed by a default-selected parent rule;
- removed Dart Pub's whole `~/.pub-cache/*` sweep, which can contain global
  package metadata and command shims;
- removed Claude `pending-uploads`, because it is pending user state rather than
  demonstrated cache data;
- moved Zed cache cleanup to opt-in AI tooling with a quit requirement;
- removed static VS Code and Spotify overlaps that could discard stricter risk
  or running-app metadata;
- added age and final open-file checks for partial downloads;
- expanded Xcode and Simulator idle requirements to all related rules;
- capped timed-out rules and retained sticky cancellation before work starts.

Mole references:

- cleanup normalization and execution:
  [`bin/clean.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/bin/clean.sh)
- app cache guards:
  [`lib/clean/app_caches.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/clean/app_caches.sh)
- developer cleanup:
  [`lib/clean/dev.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/clean/dev.sh)
- bounded execution:
  [`lib/core/timeout.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/core/timeout.sh)

## Uninstall decisions

ApexClean keeps its evidence-led review but adopts Mole's conservative gates:

- app-controlled display names cannot contain path components and name-only
  matches are never preselected;
- bundle identifiers use strict reverse-DNS component grammar;
- live related-identifier siblings are counted before preview and again before execution;
- application identity and running state are rechecked immediately before work;
- user launch jobs must successfully boot out before their plists move;
- administrator paths are shown only when they exist and are identifier-bound;
- the UI never emits `sudo rm -rf` bypass instructions;
- Homebrew and protected enterprise/security software require their official
  uninstall path.
- the reviewed bundle and selected leftovers are deleted permanently; History
  records the exact paths but is not presented as recovery or undo.

Mole references:

- uninstall orchestration:
  [`lib/uninstall/batch.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/uninstall/batch.sh)
- Homebrew casks:
  [`lib/uninstall/brew.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/uninstall/brew.sh)
- protected applications:
  [`lib/core/app_protection.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/core/app_protection.sh)

## Maintenance decisions

The overlapping tasks now treat subprocess/removal status as authoritative.
Quick Look, icon cache, Launch Services, Spotlight, preferences, saved state,
orphan agents, Finder/Dock and disk verification can report partial/failure
instead of unconditional success. Orphan launch agents are no longer selected by
default and paths on an absent external volume are treated as uncertain.

Mole reference:

- maintenance and optimization tasks:
  [`lib/optimize/tasks.sh`](https://github.com/tw93/Mole/blob/d1ef3430ef78ad5dfff82b4e3fcc69302644ee4b/lib/optimize/tasks.sh)

## Intentional differences

- Mole's generic uninstall defaults to Trash unless `--permanent` is supplied.
  ApexClean intentionally uses the permanent mode requested by this product,
  with a dedicated irreversible confirmation rather than an undo promise.
- ApexClean never automatically kills a running application.
- ApexClean does not execute `sudo` or request administrator authorization.
- ApexClean reports allocated size rather than logical file size.
- ApexClean does not yet enumerate modern BTM/SMAppService login items or every
  embedded helper identifier; those omissions remain visible limitations rather
  than guessed removal targets.

## Regression gates

The repository now enforces:

- the complete Swift concurrency checker with warnings as errors;
- normal, release, AddressSanitizer and ThreadSanitizer test lanes;
- catalog uniqueness and documented rule count;
- malicious app-name, reverse-DNS, APFS alias, Trash-boundary, target-swap,
  startup-volume/special-file, subprocess-descendant, hardlink, operation-log
  corruption/concurrency, power-source and extreme-treemap regression tests;
- signed bundle and universal `arm64`/`x86_64` artifact verification.
