# Moppo

A native macOS disk-cleanup utility, rewritten in Swift from an Electron predecessor.

## Build and run

```sh
xcodegen generate                 # regenerates Moppo.xcodeproj from project.yml
open Moppo.xcodeproj              # ⌘R to run
cd Core && swift test             # no Xcode needed
swift run moppo-cli scan          # exercise the engine headlessly
vale README.md AGENTS.md WRITING_STYLE.md  # check project writing
```

`project.yml` generates `Moppo.xcodeproj`, and Git ignores the generated
project. Change targets or build settings only in `project.yml`. XcodeGen includes
new source files from `App/` automatically.

Moppo imports preferences from the previous app identity once. Existing Moppo
preferences take priority. When a Moppo data folder does not exist, Moppo moves
the previous folder to the new name. This preserves caches, measurement history,
and cleanup records for Put Back. If both folders exist, Moppo keeps them and uses
the Moppo folder. macOS can request permissions again because the app identifier
has changed.

`App/Resources/AppIcon.icon` contains the Icon Composer source. It includes light
and dark appearances with neutral background gradients. The menu bar uses a
vector template image that follows the system appearance.

Select the `Moppo Onboarding` scheme to show the welcome guide on every Debug run.
This scheme passes `--show-onboarding`. It keeps saved settings and system permissions.
The `Moppo` scheme shows the guide until you complete it.
If access is missing on a later launch, Moppo shows the access step again.
Select **Enable** to open System Settings, or select **Continue with Limited Access** to enter the app.
Automatic scans wait for Full Disk Access. With limited access, select **Scan** or **Refresh Overview** to start a scan.
macOS can request folder access during a manual scan. Moppo requests Photos access when you open
Duplicates > Photos. Returning from System Settings refreshes the permission state.
The photo scan starts only when you select Find Duplicates.
Use **Moppo > Show Welcome Guide** to read the guide again.

## Layout

```
Core/                         Swift package
  Sources/MoppoCore/          Scanning engine and cleanup services
    Measure/                 AllocatedSizeMeasurer, ByteFormatting
    System/                  Disk information, snapshots, process execution
    Scan/                    Category scanners and scan coordination
    Act/                     Cleanup, app uninstall, Trash, history
    Duplicates/              File duplicate detection and removal
    StorageExplorer/         Folder measurement and reviewed removal
  Sources/moppo-cli/         Command-line tools
  Tests/MoppoCoreTests/      Engine tests
App/                          SwiftUI app
  DesignSystem/              Shared controls, colors, and text styles
  MainWindow/                Main views, sidebar, and sheets
  Photos/                    PhotoKit access and thumbnails
  Preferences/               Four panes and the settings store
design/                       Archived design handoff, kept locally
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

**Compare only measurements that use the same rules.** Moppo stores each
finished measurement together with the rules that produced it. The Dashboard then
subtracts two stored measurements and reports what grew, and where. A change to the
rules makes the two figures different kinds of measurement. The report states "not
comparable" and shows no numbers. Moppo keeps this history in
`~/Library/Application Support/Moppo/storage-history/`. Preferences › Advanced
clears it.

## Scanner rows and Git worktrees

The Scanner groups cleanup items. It does not show a complete folder tree.
Projects can expand to show dependencies and Git worktrees. Applications can
expand to show associated files. Ordinary folders stay as single rows.

Child rows have a 22-point indent. Size and action columns stay aligned.
The Safe to Remove filter can show a child as a separate row without its parent.
These separate rows use the normal alignment.

Documents & Files includes the usual user folders, `~/Developer`, and `~/Projects`.
The Scanner detects linked Git worktrees inside project folders and hidden
folders, including `.codex` and `.claude`. Discovery searches up to eight folder
levels and skips dependency stores and Git metadata. Worktree rows include their
contents once in the parent total.

Worktree badges report the state at scan time:

- **Uncommitted changes:** staged changes, unstaged changes, or untracked files.
- **Unpushed commits:** commits absent from the compared remote-tracking branches.
- **No unpushed commits:** both checks pass. This badge has muted green text and an outline.
- **Status unavailable** or **Push status unknown:** Moppo could not complete the corresponding check.

Branches use their upstream branch for comparison. Detached worktrees use all
local remote-tracking branches. Branches without an upstream have unknown push
status. Incomplete Git history also gives unknown push status.

Checks make no network requests. Local remote data can be out of date.
The uncommitted check excludes ignored files, which can include local settings
or databases. Every worktree stays in Needs Review, including worktrees with
no uncommitted changes or unpushed commits. A green outline does not mean
Safe to Remove.

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

**Put Back only restores what Moppo trashed.** macOS exposes no API for the
original location of a trashed item. Finder stores this location privately. Items
from Finder have a disabled button and an explanatory tooltip.

**Cleanup History uses saved removal receipts.** The History view lists successful
removals, permanent removals, and failed attempts. Use the Trash view to put back
items whose saved identity still matches an item in the Trash.

**"Last opened" often means last *modified*.** `kMDItemLastUsedDate` returns null
for almost every item on macOS 26. This includes apps that people use daily. Used
alone, it made every row show "Never opened". The design treats this label as the
strongest safe-to-delete signal. The app now falls back through modification dates.
It uses `nil` only when the date is unknown.

**File duplicate scans use selected folders.** Moppo narrows candidates by size,
sampled SHA-256, and full SHA-256. It then compares the bytes before it reports a
match. The app skips hard links, hidden files, exclusions, and cloud-only files. It
does not compare documents that macOS saves as packages, such as Pages and Keynote
files. Moppo does not select any file automatically. Each set keeps
one copy, and selected copies move to the Trash.

APFS clones can share storage. Therefore, the available space for duplicate files
is an upper bound. The volume free-space value is the final result.

The Photos tab uses PhotoKit metadata and Vision feature prints. It keeps one copy
in each group and requires a review before deletion.

**Storage Explorer measures one folder level at a time.** Each row includes all
allocated bytes below that item. Hard links count once across sibling rows.
Moppo protects system locations, applications, managed media libraries, volumes,
exclusions, cloud-only files, and items with unreadable contents. Alias targets do
not count towards a row. A mounted volume is separate from its parent. Reviewed
unlocked items move to the Trash. Moppo refreshes each selected size and checks
each file identity before it shows the removal confirmation. Use List for exact
rows. Use Map to compare direct-child sizes visually.

**Automatic scanning is process-resident.** Moppo evaluates daily and weekly
schedules while it runs. This includes menu-bar-only login launches. No separate
launch daemon wakes the application after a full quit.

**Low-space notifications are process-resident too.** Moppo checks the live
volume total on launch, after its own storage operations, and every five minutes
while running. It warns on a transition below the threshold in General settings,
persists that state across launches, and limits repeated crossings to one per day.

**Complete uninstall requires an existing application bundle.** App Uninstaller
attributes related files from the selected app's verified identity.

**Finder only starts an uninstall review.** Select one application in Finder. Then
choose Services › Review Uninstall with Moppo. Moppo opens the existing
App Uninstaller review. The Finder action never removes files.

**Application Leftovers uses strict ownership rules.** The Scanner finds exact
bundle-identifier paths and roots from curated app rules. It ignores loose name
matches and shared containers. It keeps exclusions, keychains, ambiguous paths,
and files for installed applications protected. Safe to Remove includes each
verified application group. Moppo checks the owner and the file identity
again before removal.

**The app does not include "Storage Report…".** The design specified only its
label and did not specify its function.

## Permissions

The app measures `~/Documents`, `~/Desktop` and `~/Downloads`, all TCC-gated. The
Debug target uses the stable Apple Development identity configured in `project.yml`,
so TCC grants survive rebuilds. Do not validate the app with
`CODE_SIGNING_ALLOWED=NO`: that replaces the Debug product with an ad-hoc identity
and macOS correctly asks for access again. The app target rejects unsigned builds.

Moppo stores the last breakdown at
`~/Library/Application Support/Moppo/breakdown-cache.json`. This data seeds the
initial layout. The Dashboard refreshes it at launch. A scan also refreshes it with
the category results.

## Design

`design/README.md` contains the archived design handoff. It stays outside the repository.
Its pixel values describe the appearance of standard native controls. The app uses these stock controls. The
platform supplies all three glass tiers. They use `.listStyle(.sidebar)`, the
unified toolbar, and `.bar` in a `safeAreaInset`. The app does not draw gradients.

Colours resolve to `NSColor` semantics so the app follows the user's accent choice
and Increase Contrast. Three literals survive, for shades AppKit has no name for.

## Writing

Use ADS-STE100 Simplified Technical English for documentation, interface text,
code comments, release notes, and support text. See [WRITING_STYLE.md](WRITING_STYLE.md)
for the project rules and the Vale command.
