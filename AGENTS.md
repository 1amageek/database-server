# Database Server Package Instructions

## Ownership

This package owns two distinct layers. `DatabaseServerRuntime` owns canonical
DatabaseWire frame execution, operation dispatch, remote command composition,
durable server jobs, schema administration, admission, and typed remote errors.
`DatabaseServerHost` owns native listener configuration, TLS, authentication,
routing validation, stdio process framing, backend startup, signals, and
authoritative shutdown. Neither owns framework query/index/transaction
semantics, storage behavior, client UX, profiles, or client credentials.

## Required boundaries

- `DatabaseServerRuntime` consumes framework execution APIs through
  `DatabaseOperationApplication`; it must remain Foundation-independent.
- `DatabaseServerHost` composes `DatabaseServerRuntime` with a host-selected
  StorageEngine and native lifecycle dependencies.
- HTTP, WebSocket, and stdio adapters share one authenticated request executor.
- A valid DatabaseWire request always reaches `DatabaseOperationInstance`; adapters
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
standard contract is 308 logical tests. An isolated `MultipleBases` graph uses
`DATABASE_SERVER_EXPECTED_TEST_COUNT=331` and requires 331 tests. Both runs
require zero failures, skips, expected failures, runtime warnings, and internal
tool errors. Cover HTTP, HTTPS with a real TLS
handshake, WebSocket, and stdio through real transports, including truncated
frames, oversized payloads, authentication and routing rejection,
cancellation, concurrent principals, graceful shutdown, and negative
readiness.

Use `scripts/storage-test-harness` with exact version-matched `database`,
`database-server`, and `database-fdb` executables. It must open SQLite,
PostgreSQL, and FoundationDB through the production CLI/runtime path and prove
negative service readiness after teardown.

Build the distributable standalone executable with `scripts/release-build`.
The package default is the lightweight SQLite host; it is not the distribution
artifact. The release gate must select `AllRuntimeFeatures,AllStorageBackends`
and then pass the storage harness with all three backends.

Before release, replace every local package dependency with its URL and verify
that no `.package(path:)` remains.
