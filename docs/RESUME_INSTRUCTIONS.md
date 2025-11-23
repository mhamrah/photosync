# Resume Instructions

## Current State (Commit `0a8701e`)
- Core Data stack is in place with manual `LocalAsset` subclasses.
- PhotoKit authorization flow and UI overlay are live.
- `PhotoLibraryIndexer` enumerates PHAsset metadata into Core Data with batching and progress reporting.
- macOS sandbox entitlements and `Info.plist` photo usage description configured.

## How to Resume
1. Pull the latest `main` branch:
   ```bash
   git pull origin main
   ```
2. Open the workspace in Xcode:
   ```bash
   open PhotoSyncCompanion.xcodeproj
   ```
3. Build & run the `PhotoSyncCompanion` scheme (Debug, code signing disabled via build settings).

## Immediate Next Steps
- Implement Amazon Photos OAuth authentication service, storing tokens securely in the keychain.
- Add Amazon catalog indexer mirroring `PhotoLibraryIndexer` structure.
- Build comparison engine to detect mismatched assets across local and Amazon catalogs.
- Implement selective download workflow to import Amazon-only assets into Apple Photos.

## Helpful References
- `PhotoSyncCompanion/Services/PhotoLibraryAuthorizationController.swift`
- `PhotoSyncCompanion/Services/PhotoLibraryIndexer.swift`
- `PhotoSyncCompanion/Persistence/PersistenceController.swift`

## Notes
- Maintain manual Core Data code generation for consistency.
- Keep build/test scripts running with `CODE_SIGNING_ALLOWED=NO` for CI.