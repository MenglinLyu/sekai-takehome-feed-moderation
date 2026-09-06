# Implementation checklist

Follow `technical-selection-and-architecture.md`; keep the mock backend unchanged.

- [x] Create the standard iOS 15+ Xcode app and XCTest targets using Xcode MCP.
- [x] Specify models, protocols, class responsibilities, function contracts, isolation, and ownership in `interface-design.md`.
- [x] Implement DTO decoding, API validation, atomic hidden-state storage, and injectable retry clock.
- [x] Implement serialized moderation commits, restored state publication, deduplicated synchronization, and one delayed retry per cycle.
- [x] Implement Feed and Creator Profile repositories with Combine-derived visibility, deduplication, generation guards, cancellation, and bounded pagination.
- [x] Implement repository-injected view models, stable composition, startup restoration, navigation, and action feedback.
- [x] Implement the three-WebView pool, settled playback, stable-ID replacement, and memory-pressure behavior.
- [x] Implement the SwiftUI shell/profile and UIKit paged feed.
- [x] Add deterministic Repository and ViewModel unit tests, plus visibility/playback policy tests.
- [x] Build and run tests using Xcode MCP; resolve failures (32 tests passed).
- [x] Document run instructions, verified scope, limitations, and validation evidence.
- [x] Smoke-test initial playback, normal/reverse paging, feed block/report, and profile block with RocketSim.
- [x] Complete RocketSim playback/lifecycle, same-device restart, forced-failure retry, and injected memory-warning checks; preserve runtime evidence and reproducible checks in `validation.md` and `smoke-testing.md`.
- [ ] Perform physical-device Release Instruments measurements and capture a demo (requires a connected device and interactive validation).

Pending-operation persistence and automatic restoration of adjacent preloading are deliberately outside the core implementation.
