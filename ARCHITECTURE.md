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
