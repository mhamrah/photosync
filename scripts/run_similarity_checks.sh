#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/Users/mhamrah/.codex/worktrees/b42c/photosync"
SWIFT_MODULECACHE_PATH="/tmp/swift-module-cache"
CLANG_MODULE_CACHE_PATH="/tmp/clang-module-cache"

SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_unit_tests.swift"
SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_integration_tests.swift"
SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_benchmark.swift"
