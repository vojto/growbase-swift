# Growbase iOS SDK

Add this directory as a local package in Xcode with **File → Add Package Dependencies… → Add Local…**, then import `Growbase`.

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
