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
try await growbase.identify("your-user-id")

// On logout:
try await growbase.reset()
```

The SDK creates and persists an anonymous ID. Call `identify` after account creation or sign-in; it queues the identity link before later events and attaches the user ID to them. Call `reset()` on logout to create a fresh anonymous identity. Reset before identifying a different signed-in user.

Events and identity calls are persisted before sending, sent in order, and retried after temporary network or server failures. The tracking key is a public write-only credential and may be included in an app binary.

Call `flush()` when your app enters the background to start sending queued work. iOS does not guarantee enough background execution time to finish. Unauthorized requests remain queued so a corrected key can retry them; payloads rejected as invalid by the server are discarded so they cannot block later events. A successful `track`, `identify`, or `reset` call means the change was validated and saved locally, not that the server has acknowledged it.

Keep one `GrowbaseClient` instance per base URL and tracking key. Instances with different keys use separate durable queues.
