# Amazon Photos Swift Port and PhotoSync Integration Plan

## Objective
Port the required parts of [`trevorhobenshield/amazon_photos`](https://github.com/trevorhobenshield/amazon_photos) from Python to Swift and integrate them into `PhotoSyncCompanion` so the app can ingest Amazon Photos metadata and run duplicate comparison against Apple Photos.

This plan is written as an execution handoff for another agent.

## Current State
- `amazon_photos` source is cloned at: `/Users/mhamrah/pdev/amazon_photos`.
- Upstream snapshot pinned for porting: `685c965b5a4ba1ac85d418820ad200e12c18a46d`.
- `photosync` app currently has:
  - Apple Photos authorization + local metadata indexing into Core Data (`LocalAsset`).
  - Placeholder UI for Comparison/Transfer/Settings.
  - No Amazon client, no remote index, no comparison engine yet.

## Scope
- In scope:
  - Swift HTTP client for Amazon Photos private web endpoints used for read/index operations.
  - Secure settings and credentials input for required cookies/region.
  - Amazon metadata indexing into Core Data.
  - Duplicate comparison pipeline for local vs Amazon assets.
- Out of scope (for this phase):
  - Upload/download/album/trash write operations.
  - Full parity with every Python method.
  - iOS target expansion (keep macOS app focus).

## Upstream Behavior To Port (Read-Only Core)
From `/Users/mhamrah/pdev/amazon_photos/amazon_photos/_api.py` and README:
- Auth/session model:
  - Cookies required: `session-id` + (`ubid_main`,`at_main`) for US, or `ubid-acbXX`,`at-acbXX` for CA/EU.
  - Header required: `x-amzn-sessionid: <session-id>`.
- Region derivation:
  - US if cookie key ends with `_main` => TLD `com`.
  - Else parse `at-acbxx` => TLD `xx`.
- Base URLs:
  - `https://www.amazon.<tld>/drive/v1`
  - Thumbnail endpoint exists but optional for duplicate check.
- Read endpoints needed now:
  - `GET /drive/v1/nodes` with `filters=isRoot:true` (root + ownerId).
  - `GET /drive/v1/search` with pagination (`limit`, `offset`, `filters`, `sort`, etc.).
- Request params frequently required:
  - `asset=ALL`, `tempLink=false`, `resourceVersion=V2`, `ContentType=JSON`.
- Retry model:
  - Exponential backoff on transient failures.
  - Detect expired cookies on `401`.

## Settings and Credential Requirements (Must Implement)
### Secrets (store in Keychain, not UserDefaults)
- `session-id`
- `ubid` cookie key + value:
  - Key examples: `ubid_main`, `ubid-acbca`, `ubid-acbit`
- `at` cookie key + value:
  - Key examples: `at_main`, `at-acbca`, `at-acbit`

### Non-secrets (store in UserDefaults or app settings store)
- `regionMode`: `auto | us | ca | eu` (start with `auto` default).
- `amazonTLD`: derived automatically, user override optional.
- `searchFilter`: default `type:(PHOTOS OR VIDEOS)`.
- `searchSort`: default `['createdDate DESC']`.
- `searchContext`: default `customer`.
- `lowResThumbnail`: default `true`.
- `pageLimit`: default `200`, max `200`.
- `maxPages` or `maxAssets`: safety cap to avoid runaway sync.
- `requestTimeoutSeconds`.
- `maxConcurrentRequests`.
- `lastSuccessfulSyncAt` and `lastSyncError` for diagnostics.

## Proposed Swift Architecture
Create new folder: `PhotoSyncCompanion/Services/AmazonPhotos/`

Files to add:
- `AmazonPhotosConfig.swift`
  - Codable config for non-secret settings.
- `AmazonPhotosCredentialStore.swift`
  - Keychain wrapper for cookies.
- `AmazonPhotosAuthState.swift`
  - Validation status, derived TLD, and “ready/not ready”.
- `AmazonPhotosClient.swift`
  - Actor-based `URLSession` client with retry/backoff.
- `AmazonPhotosModels.swift`
  - Codable response/request models for `/nodes` and `/search`.
- `AmazonPhotosIndexer.swift`
  - Sync orchestration, pagination, persistence writes.
- `AmazonPhotosMapper.swift`
  - Normalize API payload fields into Core Data schema.

UI/state files to add or update:
- `PhotoSyncCompanion/ViewModels/SettingsViewModel.swift` (new)
- Replace `SettingsPlaceholder` in `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/ContentView.swift` with real settings form.
- Register new environment object(s) in `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/PhotoSyncCompanionApp.swift`.

## Data Model Changes
### Add new Core Data entity: `AmazonAsset`
Recommended fields:
- `nodeId` (String, unique, indexed)
- `name` (String?)
- `md5` (String?, indexed)
- `sizeBytes` (Integer 64)
- `contentType` (String?)
- `extensionName` (String?)
- `createdDate` (Date?)
- `modifiedDate` (Date?)
- `contentDate` (Date?)
- `width` (Integer 32)
- `height` (Integer 32)
- `duration` (Double)
- `ownerId` (String?)
- `parentsRaw` (String?)  // serialized array for now
- `rawJSON` (Binary/Data?) // optional for debugging
- `indexedAt` (Date)

### Update `LocalAsset` (optional but recommended for better matching)
- Add `originalFilename` (String?)
- Add `fileSizeBytes` (Integer 64)
- Add `md5` (String?) if feasible to compute

If local MD5 is expensive, compute it lazily only for candidate matches.

## Duplicate Comparison Strategy
Implement a two-pass matcher:

1. Exact pass (high confidence)
- Match on `md5` if both sides have MD5.
- If `md5` missing, match on stable key:
  - `(pixelWidth, pixelHeight, duration bucket, creationDate within tolerance, filename normalized, file size tolerance)`.

2. Review pass (possible duplicates)
- Score-based matching using weighted metadata:
  - Date proximity, dimensions, duration, size, filename similarity.
- Mark as:
  - `exactDuplicate`
  - `likelyDuplicate`
  - `amazonOnly`
  - `localOnly`

Persist comparison results in-memory first; add Core Data entity later if needed.

## Execution Plan (Agent Checklist)
1. Vendor and reference upstream
- Copy upstream commit hash into a new doc section for traceability.
- Keep MIT license notice in repo under `docs/vendor/amazon_photos_LICENSE.md`.
- Add a short `docs/vendor/amazon_photos_porting_notes.md` mapping Python methods to Swift files.

2. Add settings + secure credential storage
- Implement Keychain-backed cookie storage.
- Implement non-secret settings persistence.
- Build a settings form to input:
  - Session ID
  - Ubid cookie key/value
  - At cookie key/value
  - Optional advanced query defaults
- Add “Validate Connection” button:
  - Calls `GET /drive/v1/nodes?filters=isRoot:true`.
  - Surfaces success/failure in UI.

3. Implement Amazon HTTP client
- Actor-based request execution.
- Add base params automatically.
- Add required header/cookies per request.
- Add retry/backoff and typed errors (`unauthorized`, `rateLimited`, `network`, `decoding`).

4. Implement Amazon indexer
- Fetch root node first.
- Paginate `search` endpoint until total count reached or safety cap hit.
- Normalize and persist into `AmazonAsset` in batches.
- Store sync diagnostics (counts, duration, last error).

5. Implement comparison service
- Read `LocalAsset` + `AmazonAsset`.
- Run two-pass duplicate matching.
- Expose summary counts for Comparison screen:
  - total local
  - total amazon
  - exact duplicates
  - likely duplicates
  - local-only
  - amazon-only

6. Wire UI
- Settings tab: real credential/config UI.
- Comparison tab: table/list with filters and confidence status.
- Dashboard: quick sync/health stats.

7. Tests
- Unit tests:
  - TLD derivation from cookie keys.
  - Request building (params/header/cookies).
  - Response decoding for sample payloads.
  - Duplicate scoring logic.
- Integration-style tests:
  - Fixture-based pagination + persistence pipeline.
- Manual verification:
  - Expired cookie handling (`401`).
  - Empty library response.
  - Large library pagination behavior.

## File-Level Change Plan in `photosync`
- Modify: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/ContentView.swift`
- Modify: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/PhotoSyncCompanionApp.swift`
- Modify: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/Model/PhotoSyncCompanionModel.xcdatamodeld/PhotoSyncCompanionModel.xcdatamodel/contents`
- Modify: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/Model/LocalAsset+CoreDataProperties.swift` (if adding local fields)
- Modify: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/Persistence/PersistenceController.swift` (migration/preview seeds)
- Add: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/Services/AmazonPhotos/*`
- Add: `/Users/mhamrah/pdev/photosync/PhotoSyncCompanion/ViewModels/SettingsViewModel.swift`
- Add: `/Users/mhamrah/pdev/photosync/docs/vendor/amazon_photos_porting_notes.md`
- Add: `/Users/mhamrah/pdev/photosync/docs/vendor/amazon_photos_LICENSE.md`

## Risks and Mitigations
- Private/undocumented API instability:
  - Isolate API surface in one client; add robust error mapping and logging.
- Cookie expiry and account security:
  - Keep cookies in Keychain; never log cookie values.
  - Show clear re-auth instructions in Settings.
- Metadata mismatches across ecosystems:
  - Use confidence scoring, not binary only.
  - Keep tolerant date/size thresholds configurable.
- Pagination limits and performance:
  - Use batch writes and bounded concurrency.
  - Add user-configurable sync caps.

## Definition of Done
- User can enter required Amazon cookie credentials in Settings and validate connection.
- App can index Amazon Photos metadata into Core Data with pagination and retries.
- Comparison view shows duplicate and mismatch categories using deterministic rules.
- Unit tests cover auth derivation, request building, and duplicate logic.
- Porting notes include exact upstream methods mapped to Swift equivalents.

## Initial Task Split for Another Agent
1. Build `AmazonPhotosCredentialStore` + settings UI + validation call.
2. Implement `AmazonPhotosClient` + `/nodes` and `/search` models.
3. Add `AmazonAsset` entity and indexing pipeline.
4. Implement duplicate comparison service and Comparison UI wiring.
5. Add tests and vendor/porting documentation.
