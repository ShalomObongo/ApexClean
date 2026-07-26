# ApexClean

**Mac care, transparently.**

A free, open-source, native macOS care app. It finds reclaimable space, uninstalls
apps completely, runs bounded maintenance, maps your disk, and reports live system
health — and it shows you everything before it touches anything.

<br>

## What it does

| | |
|---|---|
| **Smart Care** | One scan across every category. Findings arrive grouped, each with its size, its evidence, and its risk. Nothing is removed until you approve the group. |
| **Cleanup** | ~430 rules covering user caches, logs, system temporary data, browser caches, developer build artifacts, package-manager caches, AI-tool caches, and installer remnants. Filter, inspect individual paths, reveal in Finder. |
| **Applications** | Every installed app with its real on-disk size. Complete uninstall with reviewable leftover detection. Startup and background-item control, including orphan detection. |
| **Maintenance** | 10 bounded macOS tasks — rebuild Spotlight, flush DNS, prune logs, verify the boot volume. Each states exactly what it runs and what it will not fix. |
| **Space Lens** | An interactive squarified treemap of your disk. Drill down, find large files, reveal, remove. |
| **Vitals** | Live CPU, memory, storage, network, battery, thermal, and process data, plus a weighted health score. Sampled at a rate you'd never notice. |
| **Menu bar HUD** | An opt-in status item with a health ring and expandable metric tiles. Quiet by design — no badges, no nags, no recommendations. |

<br>

## The safety model

This app deletes files, so it is built to be distrusted.

**Scan first, always.** There is no "clean now" button that acts before it looks. The
primary action on every screen is a scan; removal is a second, separate, explicit act.

**Every path goes through one gate.** `PathGuard.evaluate` is the sole choke point
before any removal, and it *fails closed* — it must find an affirmative reason to
allow a deletion, and refuses when anything is ambiguous. It rejects:

- immovable system paths and anything above a minimum depth floor
- mount points and volume roots
- paths containing protected fragments
- endpoint-security vendor paths under `/var/folders`
- anything outside an explicitly permitted root

**Validation happens at the syscall boundary.** Paths are re-resolved and re-checked
immediately before the removal call, not just at scan time. A symlink that changes
between scan and confirm cannot redirect a delete.

**Trash, not `unlink`.** Removals go to the Trash wherever macOS allows it, so
recovery is a drag away. Where Trash is impossible the UI says so before you confirm.

**Running apps block their own caches.** If an app is open, its data is excluded and
labelled — deleting a live app's cache is how cleaners corrupt state.

**Nothing is remembered that you can't see.** Every removal is written to a local
operation log, visible in History, with path, size, and outcome.

**Ambiguous uninstalls are refused.** Leftover matching requires bundle-identifier
evidence or a reverse-DNS boundary. Generic names (`com.apple.*`, `helper`, `updater`)
are on a refusal list rather than guessed at.

<br>

## Privacy

Local-first, and structurally so: **ApexClean contains no network client.** There is
no telemetry, no account, no update check, no crash reporter, no analytics SDK. It
links only Apple system frameworks. Nothing about your files or your machine can
leave the device, because there is no code capable of sending it.

It also goes out of its way *not* to ask for permissions. macOS gates Desktop,
Documents, Downloads, sandbox containers, and media libraries behind TCC consent —
and a gated path does not fail, it *blocks in the kernel*, which is how scanners hang
forever. ApexClean therefore excludes those paths from automatic scans entirely, so
no scan you didn't ask for will ever raise a permission dialog. Including the personal
folders is a deliberate, explained, one-tap opt-in.

<br>

## Build and run

Requires macOS 14+ and a Swift 5.9+ toolchain (Xcode 15 or later).

```sh
make app     # build release + assemble dist/ApexClean.app
make run     # build, assemble, and launch
make test    # run the test suite
make clean   # remove build products
```

`make app` produces a self-contained `dist/ApexClean.app`. There is no Xcode project —
the whole build is a SwiftPM package plus `Scripts/bundle.sh`, so a checkout builds
identically anywhere with no IDE state involved.

The bundled build is **ad-hoc signed**, which is enough to run locally. A distribution
build substitutes a Developer ID identity and runs `notarytool`; see the comment at
the bottom of `Scripts/bundle.sh`.

<br>

## Architecture

```
Sources/
├── ApexCore/                  Engine. Zero UI, fully testable.
│   ├── Support/               Byte formatting, bounded shell, allocated-size measurement
│   ├── Safety/                PathGuard, PrivacyAccess, Remover
│   ├── Cleanup/               CleanupCatalog (~430 rules), CleanupScanner, Glob
│   ├── Apps/                  AppInventory, LeftoverFinder, StartupInventory
│   ├── Maintenance/           MaintenanceCatalog + runner
│   ├── Disk/                  SpaceScanner, LargeFileFinder, Treemap
│   ├── Vitals/                CPU/Memory/Storage/Network/Power/Process samplers, HealthScore
│   └── History/               OperationLog
└── ApexClean/                 SwiftUI app
    ├── Design/                Palette, Typography, Motion, components
    ├── Features/              One model + one view per screen
    ├── MenuBar/               HUD
    └── App/                   AppState, RootView, About
```

The engine never imports SwiftUI and the UI never touches the filesystem directly.
That split is what makes the destructive logic testable in isolation.

### Performance notes

Low resource use is a product requirement, not an aspiration — a maintenance utility
that costs you performance is self-defeating. Measured on an M-series Mac, as a share
of one core:

| State | CPU | Memory |
|---|---|---|
| Window hidden or fully covered | **~0.3%** | ~60 MB |
| Window open, static screen | **~0.7%** | ~63 MB |
| Window open on the live Vitals dashboard | **~5%** | ~71 MB |

Four things got it there:

**Ambient motion runs on Core Animation, not SwiftUI.** A continuously animating
SwiftUI view re-runs layout and render every display cycle, forever. The aurora
backdrop and the orbiting scan arc are `NSViewRepresentable` wrappers around
`CABasicAnimation` on pre-rendered `CALayer`s, so the work happens in the render
server and the app process stays idle. `AuroraBackdrop.swift` documents this at
length — it is not a candidate for "simplification" back to SwiftUI.

**Sampling stops when nobody can see it.** Live metrics run at two seconds while a
window is on screen and drop to ten as soon as the app is hidden, minimised, or fully
occluded — three separate macOS events, none of which implies the others, all merged
in `WindowVisibility.swift`. An app left open all day should cost approximately
nothing while it sits there.

**Charts draw; they do not lay out.** `Sparkline` is a single `Canvas`, not a
`GeometryReader` wrapping stacked shapes. Profiling the dashboard put SwiftUI's stack
layout at the top of the main thread — four charts rebuilding a view tree on every
sample was most of the cost of the whole screen.

**Blocking I/O never runs on the cooperative pool.** Scans run off the main thread and
progress updates are coalesced to ~20/s. Each cleanup rule runs under a watchdog with
a bounded time budget, and every directory listing goes through `GuardedDirectoryLister`,
which replaces its worker queue if a listing does not return — because a `read` blocked
on a TCC-gated path cannot be cancelled, and one wedged job at the head of a serial
queue would otherwise swallow every job behind it. A pathological path can cost a
folder; it can never freeze the app.

<br>

## Testing

```sh
swift test
```

82 tests covering `PathGuard` refusals, `PrivacyAccess` gating, traversal fences,
guarded directory listing, leftover-matching precision, catalog invariants, treemap
layout, health scoring, and byte formatting.

One caveat worth knowing: `xctest` inherits the terminal's TCC grants, so a scan that
would block on a consent dialog inside the app runs fine under test. Permission
behaviour must be verified in the bundled app, not in the suite.

<br>

## License and attribution

ApexClean is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE).

It is built on [**Mole**](https://github.com/tw93/mole) by [Tw93](https://github.com/tw93) —
an excellent GPL-3.0 macOS maintenance CLI. ApexClean's cleanup path catalog,
path-protection boundaries, leftover-matching rules, maintenance task set, and health
scoring were all studied from Mole's source and reimplemented in Swift. Mole did the
hard, unglamorous work of figuring out what is actually safe to delete on a Mac, and
this app would not exist without it. [NOTICE](NOTICE) records exactly what was adapted
and where it now lives.

ApexClean is an independent project. It is not affiliated with or endorsed by Mole,
and it is unrelated to the separate proprietary *Mole for Mac* application. No Mole
source, trademarks, or trade dress are redistributed here; the interface, visual
language, interaction model, and product identity are original work.
