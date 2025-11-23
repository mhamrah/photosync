# PhotoSync Companion

macOS companion app that bridges Apple Photos with Amazon Photos for catalog comparison, mismatch resolution, and selective transfer.

## Current Status

Stage 1 scaffolding is in place:

- Xcode project targeting macOS 13+ with SwiftUI lifecycle.
- Navigation shell using `NavigationSplitView` with placeholders for the Dashboard, Comparison, Transfer Queue, and Settings sections.
- Project assets and configuration files (Info.plist, asset catalogs) established.
- Repository housekeeping via `.gitignore`.

## Getting Started

1. Open the project in Xcode 15.3 or later:

   ```bash
   open PhotoSyncCompanion.xcodeproj
   ```

2. Select the **PhotoSyncCompanion** scheme and build/run on macOS.

## Roadmap Highlights

Upcoming implementation milestones will focus on:

1. **Apple Photos integration** – authorization, indexing, Core Data persistence.
2. **Amazon Photos integration** – OAuth 2.0 flow, metadata ingestion, delta updates.
3. **Comparison engine** – unified record model, deduplication heuristics, UI surfacing of mismatches.
4. **Transfer pipeline** – download management, import into Photos, progress and error handling.
5. **Background sync & resilience** – scheduling, state persistence, logging, and diagnostics.

Refer to the Architecture & Implementation Plan for full details.
