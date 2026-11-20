# Changelog

All notable changes to Zoda are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `server.Config.body_limit_rules` (`transport.BodyLimitRule`): per-path
  request body limits matched on decoded path-segment prefixes, longest prefix
  wins. The limit is chosen from the request head, so an over-limit
  `Content-Length` is refused with 413 before any body is buffered. Lets one
  upload route exceed the global `max_body_bytes` (#96). Streaming and
  app-rendered 413 responses are not included.
- `zoda.multipart.parse(allocator, content_type, body)`: strict
  `multipart/form-data` parsing (RFC 2046/7578 framing) into zero-copy parts
  with `name`, optional `filename` and `content_type`, and `data`; malformed
  framing and headers are errors, with limits on part count and header size
  (#95).

### Security

- Strengthened session key guidance (security analysis S5, #90). New
  `Sessions.Key.fromBase64` (exact 32-byte secret, fails closed) and
  `Key.generate` helpers; `Sessions` now also rejects two keys with the same
  secret. PLUGINS.md "Session keys" documents generation, runtime loading,
  rotation with overlapping verification keys and its invalidation effects,
  and compromise response, and states prominently that payloads are signed,
  not encrypted, and not revocable without a store. Hard-coded example and
  test keys are labelled TEST ONLY. Length checks are not entropy checks.

- Defined the handler execution contract (security analysis S4, #89). The
  framework does not bound or cancel `app.dispatch`; socket deadlines cover
  I/O only. `server.Stats` now reports `handlers_active`, `handlers_completed`,
  `handlers_over_budget`, and handler duration totals/max, and
  `Config.handler_budget` sets an observation-only threshold. README
  "Handler execution budgets" lists the required upstream rate limits,
  dependency timeouts, and bounded queues. A stalled-handler socket test
  checks slot occupancy, admission shedding, counters, shutdown, and leaks.

- Made authentication and CSRF coverage auditable (security analysis S3).
  New `zoda.route_table` declares routes as `.public` or `.protected` (no
  default), runs authentication, then CSRF proof on unsafe methods, then the
  handler, and exposes the route map for tests. `rt.gate` authenticates
  static and other responders. `examples/secure_notes.zig` shows the full
  middleware order with contract tests; see PLUGINS.md "Protected routes and
  middleware order".

- Chunked request trailers no longer merge into request headers (security
  analysis S1). They live in `Request.trailers` (type `Trailer`, accessors
  `getTrailerOne` / `getAllTrailers`). Only an integrity-digest allowlist is
  accepted; any other, duplicate, or malformed trailer gets `400` and closes the
  connection. New limits `request_limits.max_trailers` (8) and `trailer_bytes`
  (4 KiB). **Breaking:** clients sending other trailers are now rejected. See
  README "Chunked request trailers" for proxy requirements.

- Added revocable sessions (security analysis S2). `Sessions.store` takes a
  server-side `Store`; `login`, `logout`, and `revokeSubject` create, revoke,
  and mass-revoke sessions, and cookies use a new `v4` format carrying an opaque
  ID. `MemoryStore(capacity)` is a bounded reference store. Store outages fail
  closed (`initRequest` returns `SessionStoreUnavailable`). Stateless sessions
  remain the default and `clear()` is documented as browser-only deletion. See
  PLUGINS.md "Revocable sessions".

### Changed

- **Toolchain upgraded to Zig 0.17.1**, the latest stable release. This is
  now the exact pin and the `minimum_zig_version` floor. Zig 0.16.0 is no
  longer supported. Updated in `build.zig.zon`, CI, `PLATFORM.md`,
  `README.md`, `Getting_started_with_zoda.md`, and
  `examples/inertia/README.md`.
- `build.zig`: `zig build run -- …` and the `run-inertia` and `watch` steps now
  forward arguments with `Step.Run.addPassthruArgs()`, because `b.args` was
  removed. The `watch` step always passes `--`. With no arguments after it, the
  demo still defaults to `serve`.
- `build.zig`: the dev-loop test gets `repo_root` through
  `Options.addOptionPathUntracked`, because `b.pathFromRoot` was removed.
- Comptime reflection in `app.zig`, `template.zig`, and the Inertia plugin now
  iterates `@typeInfo(T).@"struct".field_names` and `field_types` directly,
  because `std.meta.fields` was removed and `Type.Struct.fields` was split
  into parallel slices. The remaining 0.17 reflection renames also apply:
  `StructField.Attributes` is now `Type.Struct.FieldAttributes`,
  `Fn.params` is now `Fn.param_types`, and `Pointer.is_const` is now
  `Pointer.attrs.@"const"`.
- Zig 0.17 removed the `**` array-repeat operator. Repeated strings in tests
  and examples now use `&comptime @as([N]u8, @splat(c))`, and the Inertia tests
  use a small comptime `repeatStr` helper for multi-character patterns.
- `zig fmt` migrations: `@intFromEnum` is now `@backingInt`, `@enumFromInt` is
  now `@fromBackingInt`, and `std.ascii.indexOfIgnoreCase` is now `findIgnoreCase`.

### Added

- `router.Method.query`: requests that use the HTTP `QUERY` method
  ([RFC 10008](https://datatracker.ietf.org/doc/html/rfc10008)) now reach
  routes. Zig 0.17's `std.http.Method` added this method. Like `POST`, a QUERY
  request carries a body, and Inertia redirects after one use `303 See Other`.
  Routes match it explicitly with `req.method == .query`. Zoda does not fall
  back to a GET route for QUERY requests.
  **Breaking:** an exhaustive `switch` on `router.Method` in application code
  needs a `.query` arm or an `else` arm.
