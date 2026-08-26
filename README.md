# MacCleaner

A native macOS disk-cleanup utility, rewritten in Swift from an Electron predecessor.

## Build and run

```sh
xcodegen generate                 # regenerates MacCleaner.xcodeproj from project.yml
open MacCleaner.xcodeproj         # ⌘R to run
cd Core && swift test             # no Xcode needed
swift run maccleaner-cli scan     # exercise the engine headlessly
vale README.md AGENTS.md WRITING_STYLE.md  # check project writing
```

`project.yml` generates `MacCleaner.xcodeproj`, and Git ignores the generated
project. Change targets or build settings only in `project.yml`. XcodeGen includes
new source files from `App/` automatically.

## Layout

```
Core/                    Swift package — the scanning engine, testable without a UI
  Measure/               AllocatedSizeMeasurer, ByteFormatting
  System/                diskutil, snapshots, process running
  Scan/                  breakdown + category scanners + coordinator
  Act/                   cleanup, app uninstall, leftovers, trash, removal log
  Duplicates/            verified file duplicate matching and removal
  StorageExplorer/       one-level storage accounting and reviewed removal
  maccleaner-cli/        headless harness
App/                     SwiftUI app — a thin shell over Core
  DesignSystem/          tokens, type ramp, shared components
  MainWindow/            sidebar, toolbar, six primary views, sheets
  Photos/                PhotoKit access, thumbnails and deletion
  Preferences/           four panes + settings store
design/                  the design handoff — spec of record
```

Run `swift test` to prove engine correctness before you build the interface.
Regression tests cover each measurement bug below.

## Measurement rules

These are not style preferences. Each one is a bug the Electron version shipped.

**Do not use `du`.** It stops at the first unreadable directory. The old code's
`catch` converted this failure to `0`. One unreadable folder then zeroed an entire
category. `AllocatedSizeMeasurer` uses `FileManager.enumerator`. Its error handler
counts each failure and continues the scan.

**Report what you could not read.** Each result contains
`SizeMeasurement.unreadableCount`. The Dashboard puts unreadable data in its
`Unmeasured` segment. Callers must see the gap to trust this segment.

**Keep the name `Unmeasured`.** The predecessor used two incorrect names: "APFS
Snapshots & System Overhead" and "Other User Accounts". Both names presented
guesses as measurements. `Unmeasured` is the honest residual. A test checks this
label.

**Measure the Data volume at its own mount point.** The `/System` path through `/`
refers to the read-only System volume. The Data volume has a different `/System`
tree. This tree contains about 13 GB of Apple Intelligence assets.

**Categories must be disjoint.** `DisjointCategoriesTests` asserts that no two
scanners claim the same path. Adding a cache root to one scanner fails the build
until you update the overlapping scanner.

**Reported sizes are an upper bound.** APFS clones share blocks between distinct
files and no per-file API can see it, so removing two clones frees less than their
sum. The measurer counts hard links once. Do not change this estimate into a
promise.

## The boot snapshot

macOS boots from a sealed, read-only APFS snapshot named `com.apple.os.update-…`,
mounted at `/`. It looks like update leftovers and is not: it is the running
operating system. The predecessor rewrote its volume identifier (`disk3s1s1` →
`disk3s1`) specifically to make it a valid delete target. Only SIP prevented
disaster.

Here, deleting it is **unrepresentable**. `SnapshotService.delete` accepts only a
`DeletableSnapshot`. Its initializer is private to its source file. The code does
not create values for the boot snapshot or the System volume. A runtime check and
seven tests provide more protection.

## Deliberate limitations

**Put Back only restores what MacCleaner trashed.** macOS exposes no API for the
original location of a trashed item. Finder stores this location privately. Items
from Finder have a disabled button and an explanatory tooltip.

**"Last opened" often means last *modified*.** `kMDItemLastUsedDate` returns null
for almost every item on macOS 26. This includes apps that people use daily. Used
alone, it made every row show "Never opened". The design treats this label as the
strongest safe-to-delete signal. The app now falls back through modification dates.
It uses `nil` only when the date is unknown.

**File duplicate scans use selected folders.** MacCleaner narrows candidates by size,
sampled SHA-256, and full SHA-256. It then compares the bytes before it reports a
match. The app skips hard links, hidden files, package contents, exclusions, and
cloud-only files. MacCleaner does not select any file automatically. Each set keeps
one copy, and selected copies move to the Trash.

APFS clones can share storage. Therefore, the available space for duplicate files
is an upper bound. The volume free-space value is the final result.

The Photos tab uses PhotoKit metadata and Vision feature prints. It keeps one copy
in each group and requires a review before deletion.

**Storage Explorer measures one folder level at a time.** Each row includes all
allocated bytes below that item. Hard links count once across sibling rows.
MacCleaner protects system locations, applications, packages, volumes, exclusions,
and items with unreadable contents. Reviewed unlocked items move to the Trash.
MacCleaner checks each file identity again before removal.

**Automatic scanning is process-resident.** MacCleaner evaluates daily and weekly
schedules while it runs. This includes menu-bar-only login launches. No separate
launch daemon wakes the application after a full quit.

**Low-space notifications are process-resident too.** MacCleaner checks the live
volume total on launch, after its own storage operations, and every five minutes
while running. It warns on a transition below the threshold in General settings,
persists that state across launches, and limits repeated crossings to one per day.

**Complete uninstall requires an existing application bundle.** App Uninstaller
attributes related files from the selected app's verified identity.

**Application Leftovers uses strict ownership rules.** The Scanner finds exact
bundle-identifier paths and roots from curated app rules. It ignores loose name
matches and shared containers. It keeps exclusions, keychains, ambiguous paths,
and files for installed applications protected. Safe to Remove includes each
verified application group. MacCleaner checks the owner and the file identity
again before removal.

**The app does not include "Storage Report…".** The design specified only its
label and did not specify its function.

## Permissions

The app measures `~/Documents`, `~/Desktop` and `~/Downloads`, all TCC-gated. The
Debug target uses the stable Apple Development identity configured in `project.yml`,
so TCC grants survive rebuilds. Do not validate the app with
`CODE_SIGNING_ALLOWED=NO`: that replaces the Debug product with an ad-hoc identity
and macOS correctly asks for access again. The app target rejects unsigned builds.

MacCleaner stores the last breakdown at
`~/Library/Application Support/MacCleaner/breakdown-cache.json`. This data seeds the
initial layout. The Dashboard refreshes it at launch. A scan also refreshes it with
the category results.

## Design

`design/README.md` is the specification of record. Its pixel values describe the
appearance of standard native controls. The app uses these stock controls. The
platform supplies all three glass tiers. They use `.listStyle(.sidebar)`, the
unified toolbar, and `.bar` in a `safeAreaInset`. The app does not draw gradients.

Colours resolve to `NSColor` semantics so the app follows the user's accent choice
and Increase Contrast. Three literals survive, for shades AppKit has no name for.

## Writing

Use ADS-STE100 Simplified Technical English for documentation, interface text,
code comments, release notes, and support text. See [WRITING_STYLE.md](WRITING_STYLE.md)
for the project rules and the Vale command.
