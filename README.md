<div align="center">

<br>

<img src="docs/images/icon.png" width="112" alt="ApexClean Coastal Atlas icon">

<p><sub><b>COASTAL ATLAS FOR macOS</b></sub></p>

<h1>ApexClean</h1>

<h3>Storage, clearly mapped.</h3>

<p>
A free, native macOS care app that finds reclaimable space, uninstalls apps completely,<br>
runs bounded maintenance, maps your disk and reports live system health —<br>
then shows you <b>everything</b> before it touches <b>anything</b>.
</p>

<p>
<a href="https://github.com/ShalomObongo/ApexClean/actions/workflows/ci.yml"><img src="https://github.com/ShalomObongo/ApexClean/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/ShalomObongo/ApexClean/actions/workflows/codeql.yml"><img src="https://github.com/ShalomObongo/ApexClean/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
</p>

<p>
<img src="https://img.shields.io/badge/macOS-14%2B-4F7180?style=flat-square&logo=apple&logoColor=FFFFFF&labelColor=26384A" alt="macOS 14+">
<img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-426E5A?style=flat-square&labelColor=26384A" alt="Universal">
<img src="https://img.shields.io/badge/Swift-5.9%2B-81501E?style=flat-square&logo=swift&logoColor=FFFFFF&labelColor=26384A" alt="Swift 5.9+">
<img src="https://img.shields.io/badge/tests-172_passing-426E5A?style=flat-square&labelColor=26384A" alt="172 tests">
<img src="https://img.shields.io/badge/telemetry-none-6D5878?style=flat-square&labelColor=26384A" alt="No telemetry">
<img src="https://img.shields.io/badge/license-GPL--3.0-8F3832?style=flat-square&labelColor=26384A" alt="GPL-3.0">
</p>

<p>
<a href="https://shalomobongo.github.io/ApexClean/"><b>Website</b></a>
&nbsp;·&nbsp;
<a href="#what-it-does"><b>Features</b></a>
&nbsp;·&nbsp;
<a href="#the-safety-model"><b>Safety</b></a>
&nbsp;·&nbsp;
<a href="#privacy"><b>Privacy</b></a>
&nbsp;·&nbsp;
<a href="#coastal-atlas"><b>Design</b></a>
&nbsp;·&nbsp;
<a href="#install"><b>Install</b></a>
&nbsp;·&nbsp;
<a href="#architecture"><b>Architecture</b></a>
&nbsp;·&nbsp;
<a href="#license-and-attribution"><b>License</b></a>
</p>

<br>

<img src="docs/images/smartcare.webp" width="100%" alt="Coastal Atlas Smart Care showing a segmented storage map and reviewable findings">

<br><br>

</div>

---

<div align="center">

### Map first. Review everything. Act only when you approve.

</div>

<table>
<tr>
<td width="33%" valign="top">

#### 01 / Map

There is no button that deletes something you haven't seen. Every screen's primary
action is a **scan**. Removal is a second, separate, deliberate act — and it operates
only on the groups you ticked.

</td>
<td width="33%" valign="top">

#### 02 / Review

No red badges, no invented "problems", no inflated savings. If a group is 52 KB it
says 52 KB. If a size can't be measured it says **Size unknown** rather than guessing
zero. Maintenance tasks state what they *won't* fix.

</td>
<td width="33%" valign="top">

#### 03 / Act

`PathGuard` is the single choke point in front of every deletion, and it must find an
affirmative reason to allow one. Anything ambiguous is refused, not resolved. Removals
go to the **Trash**, so undo is a drag away.

</td>
</tr>
</table>

<br>

---

## Coastal Atlas

The interface treats storage as a map, not a warning. Warm paper, one charcoal
contour weight, restrained coastal colour and a single brick action keep every
screen readable without making routine cache files look dangerous.

| Principle | Visible consequence |
| :--- | :--- |
| **Flat, honest surfaces** | Opaque panels and real borders; no glass, glow or decorative depth |
| **Data before decoration** | The storage map, exact byte count and selected scope always lead |
| **One action colour** | Brick marks the next deliberate action; category colour only explains data |
| **Native, accessible type** | Humanist hierarchy, tabular metrics and contrast-safe semantic colours |

<br>

---

## What it does

### 01 / Smart Care — one scan, grouped findings

<div align="center">
<img src="docs/images/review.webp" width="100%" alt="Coastal Atlas removal confirmation showing grouped scope, recovery and the final action">
</div>

One pass across every category. Findings come back **grouped, sized and explained** —
application caches, logs and diagnostics, system junk, browser caches, developer
artifacts, AI tooling, installers, orphaned app data. Each group carries its evidence,
its risk and its recovery behaviour, and each is approved individually.

The confirmation sheet is the last thing between a scan and a deletion, so it is
deliberately unhurried: what is going, how much of it, where it lands, and how to get
it back. Emptying the Trash afterwards is available, opt-in, and honest about the fact
that macOS keeps the Trash private unless the app has Full Disk Access.

<br>

### 02 / Cleanup — 406 rules, every path inspectable

<div align="center">
<img src="docs/images/cleanup.webp" width="100%" alt="Coastal Atlas Cleanup with category filters, expanded evidence and a running selection total">
</div>

Filter by category, expand any row to the exact paths, reveal any of them in Finder
before deciding. The catalog is deliberately narrow — it targets the directories
vendors themselves treat as disposable (`Cache`, `GPUCache`, `Code Cache`, `logs`)
rather than whole application-support trees.

<div align="center">

| Category | Rules | | Category | Rules |
|---|---:|:---:|---|---:|
| Application caches | 147 | | AI tooling | 18 |
| Browser data | 136 | | System junk | 18 |
| Developer artifacts | 72 | | Logs · installers · leftovers · Trash | 15 |

</div>

> **Browser data** means shader, GPU and code caches. Not history. Not logins. Not sessions.
> If an app is running, its caches are excluded and labelled — deleting a live app's cache
> is how cleaners corrupt state.

<br>

### 03 / Applications — install, update, and actually uninstall

<div align="center">
<img src="docs/images/applications.webp" width="100%" alt="Coastal Atlas Applications inventory sorted by real on-disk size">
</div>

Every installed app with its **real on-disk size**, sortable, searchable, with the last
time you opened it. Three tabs: what's installed, what has an update, and what starts
itself at login.

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/images/updates.webp" width="100%" alt="The Coastal Atlas Updates tab showing exact application version transitions">
<p align="center"><b>Updates</b></p>
<p>Outdated apps with the exact version transition, one at a time or all at once,
with live progress. Backed by Homebrew casks when they're available, and clear about
it when they aren't.</p>
</td>
<td width="50%" valign="top">
<img src="docs/images/uninstall.webp" width="100%" alt="The Coastal Atlas uninstall review listing the bundle and sandbox containers with per-item evidence">
<p align="center"><b>Uninstall</b></p>
<p>Every leftover shown with the reason it was matched, individually checkable. Nothing
is claimed without evidence — a bundle identifier or a reverse-DNS boundary. Generic
names are refused rather than guessed.</p>
</td>
</tr>
</table>

<br>

### 04 / Maintenance — bounded tasks that admit their limits

<div align="center">
<img src="docs/images/maintenance.webp" width="100%" alt="Coastal Atlas Maintenance showing ten bounded tasks and their selected state">
</div>

Ten real macOS maintenance operations — flush DNS, rebuild the icon cache, verify the
Spotlight index, repair the "Open With" menu, clear stale window state, remove broken
startup items, verify the boot volume. Each states **what it runs**, roughly how long
it takes, and whether it needs admin rights.

None of them claim to make your Mac faster, because none of them do. They repair
specific broken states, and the app tells you which of those it actually found.

<br>

### 05 / Space Lens — a treemap you can navigate

<div align="center">
<img src="docs/images/spacelens.webp" width="100%" alt="Coastal Atlas Space Lens showing a safe demo folder as a navigable allocated-size treemap">
</div>

An interactive squarified treemap of any folder, measured by **allocated size** — the
space you actually get back, not the logical size. Click a tile to inspect it,
double-click to descend, breadcrumb back out. The side panel keeps a running contents
list and the largest individual files, each one revealable or removable in place.
The screenshot uses a synthetic demo folder so the documentation never publishes a
personal file tree.

<br>

### 06 / Vitals — live, local, and cheap

<div align="center">
<img src="docs/images/vitals.webp" width="100%" alt="Coastal Atlas Vitals with an itemised health score and live metric panels">
</div>

CPU, memory pressure, storage, network throughput, battery, thermal state, fans,
uptime and top processes, sampled straight from the kernel every two seconds. The
health score is **fully itemised** — every point deducted is listed with the reason
that deducted it, so the number is auditable instead of decorative.

<br>

### 07 / Menu bar — quiet by design

<div align="center">
<img src="docs/images/menubar.webp" width="380" alt="Coastal Atlas menu bar HUD with health, processor, memory, storage, network and battery">
</div>

An opt-in status item with a health ring and expandable metric rows. Expand one to see
what's actually responsible — top processes, memory composition, per-interface
throughput. **No badges, no nags, no recommendations, no red dots.** It sits there and
answers questions when you ask them.

<br>

---

## The safety model

This app deletes files, so it is built to be distrusted.

<table>
<tr>
<td width="50%" valign="top">

**Scan first, always.**
There is no "clean now" button that acts before it looks. The primary action on every
screen is a scan; removal is a second, separate, explicit act.

**Every path goes through one gate.**
`PathGuard.evaluate` is the sole choke point before any removal, and it *fails closed* —
it must find an affirmative reason to allow a deletion and refuses when anything is
ambiguous.

**Validation happens at the syscall boundary.**
Paths are re-resolved and re-checked immediately before the removal call, not just at
scan time. A symlink that changes between scan and confirm cannot redirect a delete.

</td>
<td width="50%" valign="top">

**Trash, not `unlink`.**
Removals go to the Trash wherever macOS allows it. Where Trash is impossible the UI
says so before you confirm.

**Running apps block their own caches.**
If an app is open, its data is excluded and labelled.

**Nothing is remembered that you can't see.**
Every removal is written to a local operation log, visible in History, with path, size
and outcome.

**Ambiguous uninstalls are refused.**
Leftover matching requires bundle-identifier evidence or a reverse-DNS boundary.
Generic names (`com.apple.*`, `helper`, `updater`) are on a refusal list rather than
guessed at.

</td>
</tr>
</table>

<details>
<summary><b>What <code>PathGuard</code> rejects</b></summary>

<br>

- Immovable system paths, and anything above a minimum depth floor
- Mount points and volume roots
- Any path containing a protected fragment
- Endpoint-security vendor paths under `/var/folders`
- Anything outside an explicitly permitted root
- Anything it cannot positively justify — the default answer is *no*

</details>

<br>

---

## Privacy

Local-first, and structurally so: **ApexClean contains no network client.** No
telemetry, no account, no update check, no crash reporter, no analytics SDK. It links
only Apple system frameworks. Nothing about your files or your machine can leave the
device, because there is no code capable of sending it.

It also goes out of its way *not* to ask for permissions.

**Permissions are settled once, in setup — not sprung on you mid-scan.** A four-step
assistant runs on first launch: what the app is, the three rules it will not break,
permissions, and a summary. Every row says what the permission enables and what
specifically stops working without it.

| Permission | What it unlocks | Without it |
| :--- | :--- | :--- |
| **Full Disk Access** | Measuring the Trash, sizing sandbox containers during an uninstall | Trash shows as unreadable, some folders report "Size unknown" |
| **Desktop, Documents, Downloads** | Finding installers and forgotten downloads; mapping these folders | They are skipped entirely — no scan ever reads them |
| **Finder automation** | Emptying the Trash on your behalf | You empty it yourself |
| **App Management** | Replacing an app in place when installing an update | An update may be blocked and you finish it manually |

Full Disk Access and App Management have **no request API at any privilege level**, so
those rows open the exact Settings pane and say so, rather than pretending to ask.
Nothing is probed until you have been asked about it — probing an undecided permission
is itself what raises the dialog this flow exists to prevent.

Your answers persist. Granting Full Disk Access makes macOS quit and reopen the app, so
setup remembers where you were and resumes there instead of starting over. Re-runnable
any time from **ApexClean › Set Up ApexClean…**

<details>
<summary><b>Why a cleaner that avoids permission prompts is a better cleaner</b></summary>

<br>

macOS gates Desktop, Documents, Downloads, sandbox containers and media libraries
behind TCC consent. A gated path does not fail cleanly — it **blocks in the kernel**,
with no prompt, no error and no way to cancel the thread. That is precisely how
scanners hang forever.

ApexClean excludes those paths from automatic scans entirely, so no scan you didn't ask
for will ever raise a permission dialog. Including your personal folders is a
deliberate, explained, one-tap opt-in — and everything that touches a gated path runs
under a bounded budget, so a pathological path can cost you a folder but never the app.

</details>

<br>

---

## Install

Download the latest **[`.dmg`](https://github.com/ShalomObongo/ApexClean/releases/latest)**,
open it, and drag ApexClean to Applications. Universal — Apple Silicon and Intel,
macOS 14 or later.

> **First launch takes one extra step.** ApexClean is not notarised, because
> notarisation requires a paid Apple Developer Program membership and this is
> free software. macOS will block it once:
>
> 1. Double-click ApexClean. macOS says it cannot verify the developer — click **Done**.
> 2. Open **System Settings → Privacy & Security**.
> 3. Scroll to **Security**, and next to "ApexClean was blocked" click **Open Anyway**.
>
> Once only. On macOS 15 and later the old right-click → Open bypass no longer
> works, so most instructions you'll find elsewhere are out of date. From the
> terminal, `xattr -dr com.apple.quarantine /Applications/ApexClean.app` does the
> same thing. Building from source avoids it entirely — nothing you compile
> yourself is quarantined.

The app *is* ad-hoc signed, so its contents remain tamper-evident, and every
release ships a `SHA256SUMS.txt` you can check with `shasum -a 256 -c`.

<br>

---

## Build and run

Requires macOS 14+ and a Swift 5.9+ toolchain (Xcode 15 or later).

```sh
git clone https://github.com/ShalomObongo/ApexClean.git
cd ApexClean
make run
```

| Command | What it does |
|---|---|
| `make app` | Build release and assemble `dist/ApexClean.app` |
| `make universal` | Build a universal bundle for Apple Silicon and Intel |
| `make run` | Build, assemble and launch |
| `make test` | Run the test suite |
| `make coverage` | Run tests and report engine coverage |
| `make lint` | Check formatting |
| `make format` | Apply the project formatting style |
| `make ci` | Run everything CI runs, locally |
| `make clean` | Remove build products |

`make app` produces a self-contained **7.2 MB** `dist/ApexClean.app`. There is no Xcode
project — the whole build is a SwiftPM package plus `Scripts/bundle.sh`, so a checkout
builds identically anywhere with no IDE state involved.

The bundled build is **ad-hoc signed**, which is enough to run locally. A distribution
build substitutes a Developer ID identity and runs `notarytool`; see the comment at the
bottom of `Scripts/bundle.sh`.

> **Optional permissions.** ApexClean works without granting it anything. Two things
> improve if you do grant **Full Disk Access**: the Trash becomes measurable (macOS
> hides its size otherwise), and sandbox containers can be sized during an uninstall
> review instead of being reported as *Size unknown*. Updating apps installed as
> Homebrew casks may additionally prompt for **App Management**.

<br>

---

## Architecture

```
Sources/
├── ApexCore/                  Engine. Zero UI, fully testable.
│   ├── Support/               Byte formatting, bounded shell, Guarded, allocated size
│   ├── Safety/                PathGuard, PrivacyAccess, Remover
│   ├── Cleanup/               CleanupCatalog (406 rules), CleanupScanner, Glob
│   ├── Apps/                  AppInventory, LeftoverFinder, StartupInventory
│   ├── Maintenance/           MaintenanceCatalog + runner
│   ├── Disk/                  SpaceScanner, LargeFileFinder, Treemap
│   ├── Vitals/                CPU/Memory/Storage/Network/Power/Process, HealthScore
│   └── History/               OperationLog
└── ApexClean/                 SwiftUI app
    ├── Design/                Palette, Typography, Motion, components
    ├── Resources/             Coastal Atlas app icon and onboarding artwork
    ├── Features/              One model + one view per screen
    ├── MenuBar/               HUD
    └── App/                   AppState, RootView, About
```

The engine never imports SwiftUI and the UI never touches the filesystem directly. That
split is what makes the destructive logic testable in isolation.

### Performance

Low resource use is a product requirement, not an aspiration — a maintenance utility
that costs you performance is self-defeating. Measured on an M-series Mac, as a share
of one core:

| State | CPU | Memory |
|---|:---:|:---:|
| Window hidden or fully covered | **~0.3%** | ~60 MB |
| Window open, static screen | **~0.7%** | ~63 MB |
| Window open on the live Vitals dashboard | **~5%** | ~71 MB |

<details>
<summary><b>The four things that got it there</b></summary>

<br>

**The ambient surface is static.**
The Coastal Atlas background is one `Canvas` pass plus a cached paper-grain tile. It has
no timer, display link or perpetual animation, so an open static screen does not keep
invalidating SwiftUI. `AtlasBackdrop.swift` owns that rendering, while scan progress only
animates when its measured value changes.

**Sampling stops when nobody can see it.**
Live metrics run at two seconds while a window is on screen and drop to ten as soon as
the app is hidden, minimised or fully occluded — three separate macOS events, none of
which implies the others, all merged in `WindowVisibility.swift`. An app left open all
day should cost approximately nothing while it sits there.

**Charts draw; they do not lay out.**
`Sparkline` is a single `Canvas`, not a `GeometryReader` wrapping stacked shapes.
Profiling put SwiftUI's stack layout at the top of the main thread — four charts
rebuilding a view tree on every sample was most of the cost of the whole screen.

**Blocking I/O never runs on the cooperative pool.**
Scans run off the main thread and progress updates are coalesced to ~20/s. Every
cleanup rule runs under a watchdog with a bounded budget; every directory listing goes
through `GuardedDirectoryLister`, which replaces its worker queue if a listing does not
return. A `read` blocked on a TCC-gated path cannot be cancelled, and one wedged job at
the head of a serial queue would otherwise swallow every job behind it.

</details>

<br>

---

## Testing

```sh
swift test
```

**172 tests** covering `PathGuard` refusals, `PrivacyAccess` gating, traversal fences,
bounded execution, guarded directory listing, leftover-matching precision, uninstall
plan invariants, catalog invariants, treemap layout, health scoring and byte formatting.

> One caveat worth knowing: `xctest` inherits the terminal's TCC grants, so a scan that
> would block on a consent dialog inside the app runs fine under test. Permission
> behaviour must be verified in the bundled app, not in the suite.

<br>

---

## Continuous integration

Every push and pull request runs the full gate. `make ci` runs the same checks
locally, so a red build is reproducible without guessing at the runner.

| Job | Runner | What it enforces |
|---|---|---|
| **Static analysis** | Linux | `actionlint` on the workflows, `shellcheck` on the build scripts |
| **Formatting** | macOS 15 | `swift format lint --strict` against the checked-in `.swift-format` |
| **Test** | macOS 14 + 15 | Debug and release build and test — four combinations |
| **Coverage** | macOS | Engine coverage reported to the job summary, with a floor that fails the build |
| **Bundle** | macOS 15 | Assembles the real `.app` and asserts what it claims to be |
| **License compliance** | Linux | GPL-3.0 text, Mole attribution and the corresponding-source link |

The bundle job is the one that earns its keep. Compiling proves very little about
a shipped application, so it asserts the properties this README promises:
`lipo` must report **both `arm64` and `x86_64`**, `LSMinimumSystemVersion` must
still be `14.0`, every TCC usage-description key must be present — macOS kills a
process that touches a gated resource without one, rather than prompting — the
signature must verify, the Apple Events entitlement must survive, and the GPL
`LICENSE` and `NOTICE` must be inside the bundle.

Anything that does not need a Mac toolchain runs on Linux, because macOS runners
cost ten times the Actions minutes.

<details>
<summary><b>Releasing</b></summary>

<br>

Pushing a `v*` tag builds a universal bundle, signs it, and publishes a GitHub
Release with a drag-to-Applications `.dmg`, a `.zip` and `SHA256SUMS.txt`. The
disk image is mounted and inspected before publication — an image that will not
mount is worse than no release.

Signing is conditional rather than required. With no credentials configured the
workflow still produces a working ad-hoc build and ships first-launch
instructions inside the disk image, because notarisation needs a paid Apple
Developer Program membership that a free project may not have. Manual
`workflow_dispatch` runs always stay drafts, so the pipeline can be exercised
without publishing anything.

To sign and notarise properly, set these repository secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application certificate, `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID` | Apple ID used for notarisation |
| `NOTARY_PASSWORD` | App-specific password for that Apple ID |
| `NOTARY_TEAM_ID` | Your 10-character team ID |

The certificate is imported into an ephemeral keychain that is deleted even if
the run fails, and archives are built with `ditto` rather than `zip`, which
preserves the symlinks and signature that a `.app` needs to survive the trip.

</details>

<br>

---

## License and attribution

ApexClean is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE).

It is built on [**Mole**](https://github.com/tw93/mole) by [Tw93](https://github.com/tw93) —
an excellent GPL-3.0 macOS maintenance CLI. ApexClean's cleanup path catalog,
path-protection boundaries, leftover-matching rules, maintenance task set and health
scoring were all studied from Mole's source and reimplemented in Swift. Mole did the
hard, unglamorous work of figuring out what is actually safe to delete on a Mac, and
this app would not exist without it. [NOTICE](NOTICE) records exactly what was adapted
and where it now lives. The pinned behavioral comparison is documented in
[the Mole parity audit](docs/MOLE_PARITY.md).

ApexClean is an independent project. It is not affiliated with or endorsed by Mole, and
it is unrelated to the separate proprietary *Mole for Mac* application. No Mole source,
trademarks or trade dress are redistributed here; the interface, visual language,
interaction model and product identity are original work.

<br>

<div align="center">

<img src="docs/images/icon.png" width="56" alt="">

<p><b>ApexClean</b> · Storage, clearly mapped.<br>
<sub>Free software. No telemetry. Trash-first. Fails closed.</sub></p>

</div>
