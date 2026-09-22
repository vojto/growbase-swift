# Growbase Swift SDK

The official Swift SDK for sending analytics events and customer identities to [Growbase](https://growbase.dev).

## Installation

In Xcode, choose **File → Add Package Dependencies…** and enter:

```text
https://github.com/vojto/growbase-swift.git
```

Select **Up to Next Major Version** starting from `1.0.0`, then add the `Growbase` library to your app target.

You can also add Growbase to another Swift package:

```swift
dependencies: [
    .package(url: "https://github.com/vojto/growbase-swift.git", from: "1.0.0")
]
```

Growbase supports iOS 15 or newer and macOS 12 or newer.

## Usage

```swift
import Foundation
import Growbase

let growbase = try GrowbaseClient(
    baseURL: URL(string: "https://growbase.dev")!,
    trackingKey: "your-public-tracking-key"
)

try await growbase.track("app_opened")
try await growbase.track("workout_completed", properties: ["duration": 600])
try await growbase.identify(user.id, email: user.email)

// On logout:
try await growbase.reset()
```

The SDK creates and persists an anonymous ID. Call `identify` after account creation or sign-in; email is optional, so `identify(user.id)` also works. Call `reset()` on logout before identifying a different user.

Events and identity calls are persisted before sending, sent in order, and retried after temporary network or server failures. The tracking key is a public app credential for sending tracking data and reading active experiment settings. It may be included in an app binary; never put secrets in experiment names or settings.

The durable queue holds up to 1,000 items. When full, the SDK discards the oldest event first and preserves queued identity calls where possible.

Call `flush()` when your app enters the background to start sending queued work. iOS does not guarantee enough background execution time to finish. Unauthorized requests remain queued so a corrected key can retry them; payloads rejected as invalid by the server are discarded so they cannot block later events. A successful `track`, `identify`, or `reset` call means the change was validated and saved locally, not that the server has acknowledged it.

Keep one `GrowbaseClient` instance in your app. The SDK uses one durable queue and preserves it when the base URL or tracking key changes.

## Experiments

Experiment APIs are currently on `main`, not the `1.0.0` tag. In Xcode, use the **Branch** dependency rule with `main`, or use `.package(url: "https://github.com/vojto/growbase-swift.git", branch: "main")` in your package manifest.

Create an experiment in Growbase under **Analytics → Experiments**. Give it a key, a goal event, and one or more alternatives to `control`. The dashboard provides code using your exact names. Add those versions to your app, then start the experiment in Growbase.

```swift
// At launch, before choosing a version, and when returning to the foreground:
await growbase.refreshExperiments()

// When the experimental screen or experience will actually appear:
let variant = try await growbase.variant(for: "first_memo_prompt")
switch variant {
case "short_prompt":
    // Show your short prompt.
    break
case "long_prompt":
    // Show your longer prompt.
    break
default:
    // Show your current experience: control, or nil when not participating.
    break
}

// When the goal really happens, for every version:
try await growbase.track("memo_created")
```

`variant(for:)` reads local settings without a network request. It also saves an exposure event in the existing durable queue, once per experiment per client lifetime (and again after `reset()`). Keep its result for the screen; don't call it from a SwiftUI view's body or use it to preview assignments before a person sees the experience. A storage error is thrown before returning a variant; handle it by showing your current experience.

Assignment is stable for an installation and does not change on login. Separate devices can receive different versions; Growbase excludes a merged account from results if it has seen conflicting versions. Reinstalling or calling `reset()` creates a new assignment.

Initialization starts a settings refresh. Explicitly awaiting `refreshExperiments()` at launch lets that request finish before the first evaluation. In SwiftUI, also call it from your scene-phase handler when `scenePhase == .active`; in UIKit, call it from `sceneDidBecomeActive` using a `Task`.

Settings are cached on disk for up to 24 hours, with ETag support. Failed refreshes retain the last saved settings. Unknown, stopped, excluded, or uncached experiments return `nil` and enqueue no exposure. Stopping an experiment takes effect at the next successful refresh, or when the cache expires on a later evaluation; it does not change an already displayed screen. The app chooses when to apply a newly evaluated version. Configuration caches are scoped to the base URL and tracking key, while the existing tracking queue keeps its original persistence behavior.

The first dashboard reports counts and goal rates, not statistical significance or a winning version.

## Development

The source files are organized by responsibility:

- `GrowbaseClient.swift`: public API, validation, sending, and retry coordination. The actor owns all mutable client state.
- `ClientState.swift`: persisted identity, queued items, and queue capacity rules.
- `StateStore.swift`: state file location, loading, and atomic writes.
- `Payloads.swift`: event and identify request bodies and their JSON field mappings.
- `JSONValue.swift`: JSON values accepted as event properties.
- `ExperimentConfiguration.swift`: experiment decoding, validation, and stable assignment.
- `ExperimentCache.swift`: persisted settings, server/app scoping, and expiry.

State changes are saved before the client adopts them in memory. Keep this ordering when adding operations, and preserve compatibility with existing state files when changing the Codable types.

Run the test suite with:

```sh
swift test
```
