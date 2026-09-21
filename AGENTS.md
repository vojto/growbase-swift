# Growbase Swift SDK

Public Swift package for analytics events and customer identity. Shared product and cross-repository guidance is in `../AGENTS.md`.

## Requirements

- Support iOS 15+, macOS 12+, and Swift 6.
- Keep the public API small and source-compatible where possible.
- Preserve compatibility with existing persisted state when changing Codable types.
- Save state successfully before adopting it in memory.
- Keep one durable queue, ordered delivery, and the current retry semantics.
- Never log or expose tracking keys, customer data, or event properties unnecessarily.

## Structure

- `GrowbaseClient.swift`: public API, validation, delivery, and retry coordination. Its actor owns mutable client state.
- `ClientState.swift`: persisted identity, queued work, and capacity rules.
- `StateStore.swift`: state location, loading, and atomic writes.
- `Payloads.swift`: request bodies and JSON field mappings.
- `JSONValue.swift`: supported event-property values.
- Put generic helpers in focused files under `Sources/Growbase/Helpers/` when needed.

## Verification

- Add or update tests for behavior changes.
- Run `swift test` before finishing.
- Automatically commit each meaningful verified change with a focused message. Preserve unrelated edits. Start `git push` in the background and continue without waiting for it; treat the push optimistically rather than blocking task completion.
