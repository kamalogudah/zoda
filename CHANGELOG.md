# Changelog

All notable changes to Zoda are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Response.streamBody(status, content_type, response.BodyStream)` and
  `BodyStream.fromReader`: a handler can attach a pull source (file, reader)
  that the transport writes to the socket in 64 KiB chunks instead of
  buffering the body. `Content-Length` when `length` is known, chunked (or
  close-delimited for HTTP/1.0) otherwise; HEAD, 1xx, 204 and 304 never read
  the source. `Response` owns the source and closes it exactly once on every
  path, including client disconnect. Failures after the head closes the
  connection; the write deadline is re-armed per chunk; streamed bodies are
  not bounded by `max_body_bytes`. `http_cache.setBodyETag` returns
  `error.StreamedBody`; `status_handler` and Inertia treat a stream as a body.
  `static.zig` is unchanged (no Range yet). New
  [ADR-0003](adr_0003_response_streaming.md) supersedes ADR-0001 §4.2.5 (#101).
- `server.Config.body_stream` (`transport.BodyStreamHook` / `BodySink`): the
  app can stream selected request bodies to a caller-provided sink (file,
  hasher, multipart parser) instead of buffering them in the request arena.
  `open` decides from the request head (and may allocate sink state in the
  request arena); `write` gets decoded bytes in order, `finish` runs after the
  full body and trailers are validated, `abort` on any incomplete body. The
  same size limit (`body_limit_rules`) and body-read deadline apply; an
  over-limit body aborts the sink and goes through `on_body_too_large`.
  `app.dispatch` runs after `finish` with an empty `req.body`,
  `req.body_streamed == true`, and `req.body_sink` set to the sink context,
  so middleware that reads `req.body` sees no body. `error.InvalidBody` from
  the sink maps to 400, other errors to 500 (#100). Sinks run on the
  connection thread and block it; the response is still buffered.
- `server.Config.on_body_too_large` (`transport.BodyTooLargeHook`): the app can
  render the response for an over-limit request body (JSON error, custom
  headers, ...). The hook gets the request head and the exceeded limit; its
  response is written and the connection closed. A failing hook or invalid
  status falls back to the bare 413 (#99).
- `zoda.s3`: optional S3-compatible storage (S3, R2, MinIO, SeaweedFS). `sign`
  is a pure AWS Signature V4 signer with injected time, verified against the
  published AWS S3 GET and PUT examples; `Store` offers buffered path-style
  `put`/`get`/`delete` over `std.http.Client` with `keep_alive = false` (works
  around the stdlib hang on keep-alive `204` DELETE responses). No streaming,
  multipart upload, listing, or presigned URLs (#98).
- `response_limits` on `App.Options` (and the `App` struct): configures
  `response.Limits` for every response the app builds, parallel to
  `server.Config.request_limits`. Raise `max_body_bytes` (default 1 MiB) to
  serve larger buffered bodies from the app (#97). The body is still held in
  memory; response streaming is not included.
- `server.Config.body_limit_rules` (`transport.BodyLimitRule`): per-path
  request body limits matched on decoded path-segment prefixes, longest prefix
  wins. The limit is chosen from the request head, so an over-limit
  `Content-Length` is refused with 413 before any body is buffered. Lets one
  upload route exceed the global `max_body_bytes` (#96). Streaming is not included.
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
