# Photo Similarity and Duplicate Detection Task List

This task list is the implementation plan for:
- exact duplicate detection
- near-duplicate detection
- semantic similarity search

## Phase 0: Scope, Metrics, and Guardrails

- [x] Define target library scale for v1 (example: 10k, 50k, 100k assets).
- [x] Define performance goals.
  - Duplicate grouping batch run target.
  - Similarity query latency target (P50 and P95).
- [x] Define quality goals.
  - Exact duplicates: no false negatives for byte-identical assets.
  - Near duplicates: target precision and recall on labeled set.
  - Semantic similarity: Precision@K target.
- [x] Create a small labeled evaluation set from real assets.
  - Duplicate pairs.
  - Near-duplicate pairs.
  - Similar and non-similar pairs.

Acceptance criteria:
- Written goals are checked in and agreed on.
- Labeled evaluation set exists and is versioned for repeatable scoring.

## Phase 1: Data Model and Persistence

- [x] Extend Core Data model for image analysis artifacts.
  - Option A: add fields to `LocalAsset`.
  - Option B: add `AssetAnalysis` entity linked 1:1 with `LocalAsset`.
- [x] Add fields for:
  - `contentHash` (hex string, exact duplicate grouping).
  - `perceptualHash` (fixed-width integer/hex, near-duplicate grouping).
  - `featureVector` (binary data for semantic embedding).
  - `featureVersion` (algorithm/version string).
  - `analysisUpdatedAt` (date).
  - `analysisStatus` (pending/success/failed).
- [x] Add indexes for query-critical fields.
  - `contentHash`
  - `perceptualHash`
  - `analysisStatus`
- [x] Update manual Core Data generated files after model change.

Acceptance criteria:
- App launches with migrated store.
- New fields are readable/writable in background contexts.

## Phase 2: Asset Data Access Pipeline

- [x] Add a service to fetch image data or thumbnails from PhotoKit safely.
  - Skip non-image media types for now.
  - Respect iCloud/offline assets and error states.
- [x] Add deterministic thumbnail preprocessing for pHash/embedding.
  - Fixed size.
  - Fixed color space.
  - Orientation normalized.
- [x] Add retry and backoff behavior for transient PhotoKit failures.

Acceptance criteria:
- Service can return normalized image input for at least 99% of local image assets in test libraries.

## Phase 3: Exact Duplicate Detection

- [x] Implement content hash computation (`SHA-256`) from canonical image bytes.
- [x] Persist `contentHash` in analysis pipeline.
- [x] Implement duplicate-group query by `contentHash`.
- [x] Expose summary counts:
  - number of duplicate groups
  - total assets participating in exact duplicate groups

Acceptance criteria:
- Known byte-identical test assets are grouped correctly.
- No singletons are returned as duplicate groups.

## Phase 4: Near-Duplicate Detection

- [x] Implement perceptual hash (`pHash` or `dHash`) on normalized thumbnails.
- [x] Store hash in persistence.
- [x] Implement Hamming distance function and threshold configuration.
- [x] Add candidate generation strategy for scale.
  - For v1, full scan within bounded set.
  - Add bucketing/prefix filter if needed.
- [x] Implement near-duplicate clustering with deterministic tie-breaking.

Acceptance criteria:
- Labeled near-duplicate set reaches target precision/recall.
- Runtime remains within Phase 0 limits for target library size.

## Phase 5: Semantic Similarity Search

- [x] Implement semantic feature extraction using Apple Vision feature prints.
- [x] Persist feature vector and version.
- [x] Implement vector distance scoring (cosine or Vision-native distance).
- [x] Implement `findSimilar(to:assetID, topK:)` API.
- [x] Add prefilters to reduce search set.
  - media type filter
  - optional date window
  - optional minimum resolution

Acceptance criteria:
- Similarity API returns stable top-K results.
- Labeled semantic set hits Precision@K target.

## Phase 6: Indexing Orchestration

- [x] Add `PhotoSimilarityIndexer` service.
  - Batch processing.
  - Progress reporting.
  - Cancellation support.
  - Resume behavior.
- [x] Run analysis only for changed/new assets.
  - Trigger on `localIdentifier` new entries.
  - Recompute on `modificationDate` or `featureVersion` changes.
- [x] Add failure tracking and retry queue.

Acceptance criteria:
- Full indexing completes without main-thread blocking.
- Incremental runs process only dirty assets.

## Phase 7: Query Layer and API Surface

- [x] Add `SimilaritySearchService` with APIs:
  - [x] `findExactDuplicateGroups()`
  - [x] `findNearDuplicateGroups(maxDistance:)`
  - [x] `findSimilarAssets(to:topK:)`
- [x] Add confidence/score metadata to response models.
- [x] Add sort and pagination options.

Acceptance criteria:
- APIs are unit-tested and return deterministic results for seeded fixtures.

## Phase 8: UI Integration

- [x] Replace Comparison placeholder with:
  - Exact duplicates view.
  - Near duplicates view.
  - Similar-to-selected view.
- [x] Add interaction affordances:
  - group expansion
  - quick preview
  - keep/best-candidate marker (non-destructive in v1)
- [x] Add indexing status panel for similarity pipeline.

Acceptance criteria:
- User can discover duplicates and run similar search without leaving app flow.

## Phase 9: Test Strategy

- [x] Add unit tests for:
  - hash calculators
  - Hamming distance
  - vector distance
  - grouping/clustering logic
- [x] Add integration tests for:
  - end-to-end indexing on seeded fixture library
  - query outputs for known expected clusters
- [x] Add regression fixtures for edge cases:
  - rotated images
  - edited variants
  - burst photos
  - low-resolution copies

Acceptance criteria:
- CI passes deterministic tests with stable output ordering.

## Phase 10: Performance and Rollout

- [x] Run benchmark pass on target library scales.
- [x] Profile hotspots and optimize.
  - image decoding
  - feature extraction
  - distance computation
- [x] Add feature flag for similarity UI and indexing.
- [x] Document tuning knobs:
  - near-duplicate threshold
  - top-K defaults
  - prefilter settings

Acceptance criteria:
- Meets target latency and indexing budgets.
- Feature can be safely enabled incrementally.

## Initial Execution Order (First Implementation Sprint)

1. Phase 1 data model changes.
2. Phase 2 asset preprocessing pipeline.
3. Phase 3 exact duplicate end-to-end path.
4. Phase 6 minimal indexer orchestration for exact duplicates.
5. Phase 7 API for exact duplicate groups.
6. Phase 8 basic duplicate UI slice.
7. Then Phase 4 and Phase 5 in parallel with evaluation feedback.
