# Database Server Package Instructions

## Ownership

This package owns native process hosting for the canonical database runtime:
listener configuration, TLS, authentication, routing validation, stdio framing,
signals, and authoritative shutdown. It does not own database semantics,
storage behavior, client UX, profiles, or credentials at rest on the client.

## Required boundaries

- `DatabaseServerHost` consumes `DatabaseServerApplication` and injects a
  host-selected `StorageEngine`.
- HTTP, WebSocket, and stdio adapters share one authenticated request executor.
- A valid DatabaseWire request always reaches `DatabaseServerRuntime`; adapters
  never reinterpret operation payloads.
- Network authentication and routing failures occur before runtime execution.
- Non-loopback listeners require TLS, an authenticator, and a complete routing
  identity before binding.
- Shutdown rejects new requests, drains admitted requests, stops scheduled
  work, and awaits `DBContainer.shutdown()`.
- Secrets are never accepted through command-line arguments or environment
  variables and are never logged.

## Verification

Use `scripts/xcode-test-harness` with the pinned Swift snapshot. Its reviewed
contract is 20 logical tests, zero failures, skips, expected failures, runtime
warnings, and internal tool errors. Cover HTTP, HTTPS with a real TLS
handshake, WebSocket, and stdio through real transports, including truncated
frames, oversized payloads, authentication and routing rejection,
cancellation, concurrent principals, graceful shutdown, and negative
readiness.

Before release, replace every local package dependency with its URL and verify
that no `.package(path:)` remains.
