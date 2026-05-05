# PhotoSync Project Progress

## Current Verification Loop

- Build the macOS app:
  `xcodebuild -project PhotoSyncCompanion.xcodeproj -scheme PhotoSyncCompanion -configuration Debug -derivedDataPath /private/tmp/photosync-derived build CODE_SIGNING_ALLOWED=NO`
- Run similarity checks:
  `scripts/run_similarity_checks.sh`
- Launch the built app:
  `open /private/tmp/photosync-derived/Build/Products/Debug/PhotoSyncCompanion.app`

## Milestones

### Completed

- Restore app shell and current macOS build compatibility.
- Retarget app to latest macOS for personal-use development.
- Add unified catalog schema for both libraries.
- Mirror Apple Photos and Amazon Photos metadata into the catalog.
- Add catalog search service and snapshot model.
- Add persistent cross-library match, duplicate cluster, and sync plan entities.
- Add persistent catalog match engine.
- Add first unified catalog grid/search tab with detail preview.
- Add comparison detail tabs for matches, duplicate clusters, and missing assets.
- Add transfer queue view backed by generated sync plan items.
- Add adjustable thumbnail size, expandable preview panes, and hover text for truncated labels.
- Add approval controls and execution flow for proposed sync work.
- Add approval-based sync execution for upload/import/delete operations.
- Add duplicate review workflows with keeper selection and cleanup-plan generation.
- Add first Apple Vision enrichment pass for labels, OCR text, face observations, and catalog search/detail display.
- Add AI-aware catalog search tokens for faces, OCR, and Vision labels.
- Add structured face observation and person cluster catalog tables with Faces/People review tabs.
- Add person cluster merge/reassignment workflow and richer face thumbnails.
- Add persistent thumbnail cache and faster large-library browsing.
- Expand Amazon metadata ingestion and catalog detail display.
- Add robust sync state reconciliation for recomputed transfer queue items.
- Add focused workflow tests for catalog matching, search predicates, and sync plan reconciliation.
- Add a clean final UI pass over project progress and transfer queue status rows.
- Complete the public-API Apple Vision people workflow with face detection, face thumbnails, manual/assisted clusters, rename, and merge.

### In Progress

### Remaining

- None.

### Public API Boundary

- Fully automated Photos-style person identity clustering is not exposed by public macOS Photos/Vision APIs in this SDK. The completed implementation uses public Vision analysis plus a manual/assisted person clustering workflow so the app stays shippable and honest.
