# Similarity Regression Fixtures

This directory tracks edge-case regression scenarios for duplicate and similarity pipelines.

## Fixture Manifest

Use `regression_cases.json` as the source of truth for expected behavior by case.

## Coverage Expectations

- `rotated_copy`: must remain in near-duplicate clusters even when orientation metadata changes.
- `edited_variant`: should not be exact duplicates but should remain near-duplicates and semantically similar.
- `burst_frame_neighbors`: should cluster as near-duplicates with strong semantic similarity.
- `low_resolution_copy`: should avoid exact duplicate classification but should be discoverable by near/semantic search.

## Validation Workflow

1. Index fixture library assets with the similarity indexer.
2. Verify exact duplicate groups by `contentHash`.
3. Verify near-duplicate clustering at default Hamming threshold (`<= 6`).
4. Verify semantic search rankings using representative seed assets.
