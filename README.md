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

Events and identity calls are persisted before sending, sent in order, and retried after temporary network or server failures. The tracking key is a public write-only credential and may be included in an app binary.

The durable queue holds up to 1,000 items. When full, the SDK discards the oldest event first and preserves queued identity calls where possible.

Call `flush()` when your app enters the background to start sending queued work. iOS does not guarantee enough background execution time to finish. Unauthorized requests remain queued so a corrected key can retry them; payloads rejected as invalid by the server are discarded so they cannot block later events. A successful `track`, `identify`, or `reset` call means the change was validated and saved locally, not that the server has acknowledged it.

Keep one `GrowbaseClient` instance in your app. The SDK uses one durable queue and preserves it when the base URL or tracking key changes.

## Development

The source files are organized by responsibility:

- `GrowbaseClient.swift`: public API, validation, sending, and retry coordination. The actor owns all mutable client state.
- `ClientState.swift`: persisted identity, queued items, and queue capacity rules.
- `StateStore.swift`: state file location, loading, and atomic writes.
- `Payloads.swift`: event and identify request bodies and their JSON field mappings.
- `JSONValue.swift`: JSON values accepted as event properties.

State changes are saved before the client adopts them in memory. Keep this ordering when adding operations, and preserve compatibility with existing state files when changing the Codable types.

Run the test suite with:

```sh
swift test
```
