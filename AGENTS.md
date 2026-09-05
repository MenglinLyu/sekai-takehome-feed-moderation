
comments and docs should be in English.
use Xcode MCP to operate on projects.
use RocketSim skill & CLI to do smoke tests.
## Technology stack

- Platform: Swift, iOS 15+.
- Project: standard Xcode `.xcodeproj` with App and unit-test targets.
- Dependency injection: manual composition root and initializer injection; no third-party DI container.
- UI: SwiftUI with `ObservableObject` / `@Published`; UIKit `UICollectionView` and Diffable Data Source for the feed, embedded through `UIViewControllerRepresentable`.
- Web content: WebKit `WKWebView`.
- Concurrency: Swift Concurrency (`async`/`await`, `Task`, actors, `@MainActor`, and `Sendable`).
- Reactive state: Combine (`CurrentValueSubject`, `AnyPublisher`, and `combineLatest`).
- Callback bridging: checked continuations; `AsyncStream` for repeated callbacks when needed.
- Networking: `URLSession` and `Codable` DTOs.
- Persistence: JSON files with atomic replacement and serial file I/O.
- Performance measurement: Instruments with physical-device Release builds.

Follow `docs/technical-selection-and-architecture.md` for architecture, implementation rules, scope, and acceptance criteria.
