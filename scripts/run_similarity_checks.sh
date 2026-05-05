#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_MODULECACHE_PATH="/private/tmp/swift-module-cache"
CLANG_MODULE_CACHE_PATH="/private/tmp/clang-module-cache"

SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_unit_tests.swift"
SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_integration_tests.swift"
SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/catalog_workflow_tests.swift"
SWIFT_MODULECACHE_PATH="$SWIFT_MODULECACHE_PATH" CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" xcrun swift "$ROOT_DIR/scripts/similarity_benchmark.swift"
