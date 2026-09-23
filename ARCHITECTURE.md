# Application state

`AppModel` creates the feature models and connects their completion actions.
It owns navigation, shared busy checks, and refreshes that affect more than one feature.
Views read each feature model directly.

## Ownership

| Component | Responsibility |
| --- | --- |
| `CleanupModel` | Cleanup scan state, filters, selection, and result invalidation |
| `CleanupScanner` | Scan settings, application owners, and the core scan request |
| `CleanupRemovalModel` | Captured cleanup plans, optional confirmation, and removal |
| `FileDuplicatesModel` | File scans, size filtering, keeper selection, and removal |
| `PhotoDuplicatesModel` | Photo scans, grouping, selection, previews, and deletion |
| `ApplicationLibraryModel` | Installed applications, leftover files, sizes, and library selection |
| `UninstallerModel` | Application plans and single or batch uninstall operations |
| `StorageExplorerModel` | Folder measurements, navigation, selection, and cached results |
| `StorageExplorerCache` | Cached folder sizes and estimates after confirmed Trash moves |
| `StorageRemovalModel` | Storage Explorer removal review and progress |
| `DashboardModel` | Volume measurements, iCloud storage, snapshots, and storage history |
| `TrashModel` | Trash contents, selected items, removal, and restore |
| `HistoryModel` | Cleanup history loading |
| `OperationState` | Shared progress, notices, confirmation state, and removal completion |
| `ScanScheduler` | Periodic volume and scan schedule checks |
| `ApplicationRuntime` | Native application-owner and process lookups |

## Operation rules

- Route cleanup and duplicate scan starts through `AppModel`.
- Check shared busy state before starting a conflicting operation.
- Keep local task state in the feature that starts the task.
- Cancel the current task through its feature model.
- Reject callbacks and results from a replaced or cancelled scan.
- Capture cleanup selection and overrides before removal starts.
- Keep removal validation in `ScoloCore`.
- Publish completion before clearing progress state.
- Refresh affected lists before removing the progress surface when required.
- Check completion identity before an automatic dismissal.
- Use weak captures for callbacks that connect a feature to `AppModel`.

Cleanup results become invalid after successful removal.
The next cleanup visit starts a new scan.
File size filters use the existing duplicate results and do not start another scan.

Storage Explorer keeps cached folders visible after removal.
Location shortcuts reuse cached results. Measure Again starts a new scan.
One traversal retains up to 128 nested folder listings and 8,192 child measurements.
The navigation cache holds up to 160 folders and 50,000 rows, with space for one larger folder.
Partial results appear during measurement. The app blocks their removal and does not cache them as complete results.
Confirmed moves update source and Trash sizes without reducing a shared parent total.
Changed sizes remain estimates until a background measurement finishes.
Navigation cancels that measurement and rejects late results.
Removal still requires a fresh validation of the selected items.

Application Leftovers checks known Epic Games folders in `/Users/Shared`.
Each folder requires application-specific files that establish its owner.
Verified shared application leftovers appear under Safe to Remove when no installed or running owner remains.
Verified launcher update copies do not count as installed applications.
Registered game applications still protect their data.
Removal checks ownership, folder identity, and symbolic links again.
Other shared folders remain outside these rules.

## Shared storage

`SharedDataScanner` lists visible files and folders under `/Users/Shared`.
It splits ancestors of known application paths so leftover removal does not hide sibling rows.
Application Leftovers owns verified leftover paths during final overlap removal.
Known application data remains locked when the user disables the leftover category.
Embedded application bundles require an explicit user-data override before removal of their containing folders.
Their labels state that the folder contains an application, without claiming current use.
Running applications, media libraries, and incomplete measurements keep removal locked.
Explicit vendor rules also check installed, registered, and running application owners.
Owner names appear beside protected rows when available.
Unknown ownership never produces a Safe to Remove classification or automatic selection.
The scanner preserves exclusions and rejects symbolic links.
Incomplete ownership or size measurements keep removal locked.

## AI tool storage

`AIToolsScanner` measures known Codex, Claude, and Cursor storage.
It reads file metadata without reading conversation contents.
Desktop caches use the shared rules in `StorageRuleRegistry`.
Caches for running applications remain outside Safe to Remove.
AI Tools starts enabled unless a saved preference disables it.
Session, attachment, workspace, and worktree rows carry a `.userData` lock and a specific removal warning.
An exact `userDataRemovalOverrides` entry permits removal through the existing user-data flow.
These rows always move to the Trash.
Incomplete or protected contents keep their parent locked with `inventoryReason`.
Their measured sizes remain visible under Needs Review.
The coordinator removes overlapping generic rows before it publishes final results.
Hidden folder scanning never offers the complete `.codex` or `.claude` folder.

The scanner checks default storage paths.
It also checks two project levels under Documents, Developer, Code, Projects, repos, GitHub, src, and Work for Claude worktrees.
The scanner skips custom storage paths and deeper projects.
Worktree detection follows the [Claude worktree layout](https://code.claude.com/docs/en/worktrees).
The scanner does not infer that an old session or worktree is safe to remove.

## Checks

Generate the Xcode project before building new source files:

```sh
xcodegen generate
```

Run model checks without starting the application:

```sh
xcodebuild -scheme Scolo -configuration Debug test
```

`ScoloModelTests` compiles the production model files in a test bundle without an application host.
The checks use controlled services, temporary files, and separate preferences.
They do not delete user files or access the real photo library.

Run the core checks separately:

```sh
swift test --package-path Core
```

Keep signing enabled for application builds.
Check visible layout and native permission dialogs in the application.

## Storage rule registry

`Core/Sources/ScoloCore/StorageRules` contains the shared application storage catalog.
It covers application support layouts, Electron caches, sandbox caches, AI storage, downloaded runtimes, and curated system caches.
Specialized scanners still discover files and measure storage. Uninstall planners still validate installed owners and filesystem identity.

Each `StorageRule` records a stable ID, home-relative path, owner, category, data type, description, removal effect, and evidence.
Evidence distinguishes documentation, source review, local inspection, inherited rules, and unverified rules.
Inherited rules preserve previous behavior. They do not claim new compatibility testing with the application.
New application layouts default to unverified evidence. Unverified rules never qualify for automatic selection.

The resolver compares individual path components. A wildcard cannot cross a path separator.
More specific paths take priority. Literal paths take priority over wildcard paths at the same depth.
Equally specific conflicting rules lock the row for review. A parent cache cannot bypass a more specific protected rule.
Unknown paths receive no registry classification. Symbolic links cannot inherit a cache classification.

Each classified `FileEntry` retains its rule. Descriptions and safety badges use the resulting fields.
Removal checks use the recorded ownership rules with a fresh process snapshot before each move.
Rules do not store running state, access permissions, or measurement results.
Exclusions and protected-file checks remain in the scanners and removal services.

Photos library thumbnails and rendered images use the `managedLibrary` data type.
The scanner shows their size and Photos ownership without a Regenerable badge or a removal option.
Apple warns against changing library contents. Closing Photos does not make direct removal safe.
The rule records [Apple's library guidance](https://support.apple.com/guide/photos/pht12e7a8015/mac) as its evidence.

To add a known storage location:

1. Add its path, owner, data type, and removal effect to the applicable catalog file.
2. Record the evidence source. Use unverified evidence when support is incomplete.
3. Add fixtures for the intended folder and nearby user-data folders.
4. Test running owners, exclusions, conflicts, and path boundaries.
5. Run the core tests and signed application build.

Fixture tests verify classification and boundaries. They do not prove that an application recovers correctly after removal.
