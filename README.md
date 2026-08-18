# MacCleaner

A native macOS disk-cleanup utility, rewritten in Swift from an Electron predecessor.

## Build and run

```sh
xcodegen generate                 # regenerates MacCleaner.xcodeproj from project.yml
open MacCleaner.xcodeproj         # ⌘R to run
cd Core && swift test             # 57 tests, no Xcode needed
swift run maccleaner-cli scan     # exercise the engine headlessly
```

`MacCleaner.xcodeproj` is **generated and gitignored**. Change targets or build
settings in `project.yml`, never in Xcode's UI. Adding source files is fine —
XcodeGen globs `App/`.

## Layout

```
Core/                    Swift package — the scanning engine, testable without a UI
  Measure/               AllocatedSizeMeasurer, ByteFormatting
  System/                diskutil, snapshots, process running
  Scan/                  breakdown + seven category scanners + coordinator
  Act/                   cleanup, trash, removal log
  maccleaner-cli/        headless harness
App/                     SwiftUI app — a thin shell over Core
  DesignSystem/          tokens, type ramp, shared components
  MainWindow/            sidebar, toolbar, four views, sheets
  Preferences/           four panes + settings store
design/                  the design handoff — spec of record
```

The engine is a package so correctness can be proven with `swift test` before any
pixels exist. Every measurement bug listed below has a regression test.

## Measurement rules

These are not style preferences. Each one is a bug the Electron version shipped.

**Never shell out to `du`.** It exits non-zero on the first unreadable directory,
and the old code's `catch` turned that into `0` — one permission-denied folder
silently zeroed an entire category. `AllocatedSizeMeasurer` uses
`FileManager.enumerator` with an error handler that counts the failure and
continues, so one unreadable file costs one file.

**Report what you could not read.** `SizeMeasurement.unreadableCount` is part of
every result. Whatever cannot be reached lands in the Dashboard's `Unmeasured`
segment, which is only trustworthy if callers can see the gap.

**`Unmeasured` keeps its name.** It was mislabelled twice in the predecessor —
first as "APFS Snapshots & System Overhead", then as "Other User Accounts". Both
were guesses presented as measurements. It is the honest residual; a test asserts
the label.

**Measure the Data volume at its own mount point.** `/System` reached through `/`
is the read-only System volume, but the Data volume carries its *own* `/System`
tree — about 13 GB of on-device Apple Intelligence assets — invisible to any walk
of `/`.

**Categories must be disjoint.** `DisjointCategoriesTests` asserts that no two
scanners claim the same path. Adding a cache root to one scanner fails the build
until the overlapping one is updated.

**Reported sizes are an upper bound.** APFS clones share blocks between distinct
files and no per-file API can see it, so removing two clones frees less than their
sum. Hard links *are* deduplicated. Do not "fix" this into a promise.

## The boot snapshot

macOS boots from a sealed, read-only APFS snapshot named `com.apple.os.update-…`,
mounted at `/`. It looks like update leftovers and is not: it is the running
operating system. The predecessor rewrote its volume identifier (`disk3s1s1` →
`disk3s1`) specifically to make it a valid delete target. Only SIP prevented
disaster.

Here, deleting it is **unrepresentable**. `SnapshotService.delete` accepts only a
`DeletableSnapshot`, whose initializer is private to that file and is never minted
for the boot snapshot or for anything on the System volume. The runtime check
remains as well. Seven tests cover it.

## Deliberate limitations

**Put Back only restores what MacCleaner trashed.** macOS exposes no API for a
trashed item's original location; Finder keeps it privately. Items dragged in from
Finder get a disabled button with a tooltip saying why.

**"Last opened" is often last *modified*.** `kMDItemLastUsedDate` returns null for
almost everything on macOS 26, including apps in daily use. Read alone it made
every row claim "Never opened" — which the design renders as the strongest
safe-to-delete signal, and which flagged an actively-used project as disposable.
It now falls back through modification dates, with `nil` reserved for genuinely
unknown.

**Duplicates are same-size candidates**, grouped by identical allocated size, not
compared byte for byte. The UI says so.

**No scheduled scanning.** The setting persists but nothing acts on it: an
automatic scan would walk TCC-protected folders unprompted, which on an unsigned
build means a permission prompt storm. Worth adding once the app is signed.

**"Storage Report…" was dropped** — specified in the design as a label and nothing
else.

## Permissions

The app measures `~/Documents`, `~/Desktop` and `~/Downloads`, all TCC-gated.
Because a development build is ad-hoc signed, its signature changes on every
build and macOS re-asks each time.

Mitigated by **not measuring on launch**: the last breakdown is cached to
`~/Library/Application Support/MacCleaner/breakdown-cache.json` and shown
immediately, with measurement happening only on request or after a scan. Stale
figures are labelled.

The real fix is a stable signing identity. With an Apple Development certificate,
set `CODE_SIGN_IDENTITY` in `project.yml` and TCC grants will survive rebuilds.

## Design

`design/README.md` is the spec of record. Where it gives pixel values for standard
controls it is describing what the native control already does — it says so
directly, and the app uses stock controls throughout. All three "glass tiers" come
from the platform: `.listStyle(.sidebar)`, the unified toolbar, and `.bar` in a
`safeAreaInset`. No hand-drawn gradients.

Colours resolve to `NSColor` semantics so the app follows the user's accent choice
and Increase Contrast. Three literals survive, for shades AppKit has no name for.
