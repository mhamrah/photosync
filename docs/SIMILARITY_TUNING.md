# Similarity Tuning and Rollout

## Feature Flag

- Key: `feature.similarity.enabled`
- Default: `true`
- Scope: controls similarity indexing trigger and comparison UI behavior.

## Core Knobs

- Near-duplicate threshold: Hamming distance (`maxDistance`, default `6`).
- Similarity top-K: default `24`.
- Semantic prefilter `minimumLongestEdge`: default `0` (disabled).
- Semantic prefilter `lastYearOnly`: default `false`.
- Indexer retry attempts: `5`.
- Retry backoff: exponential, starts at `15s`, capped at `3600s`.

## Benchmark Script

Run:

```bash
swift /Users/mhamrah/.codex/worktrees/b42c/photosync/scripts/similarity_benchmark.swift
```

The benchmark reports:

- pairwise Hamming comparison throughput
- score sort timing for ranked similarity results

Use this output to set scale guardrails and decide if ANN/vector indexing is needed.

## Rollout Plan

1. Enable by default for internal users only.
2. Monitor indexing failure rate and retry queue size.
3. Validate duplicate precision on known fixture libraries.
4. Expand rollout once query latency and false-positive rates are within targets.
