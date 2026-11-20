# ADR-0003: Response Streaming

**Status:** Accepted  
**Author:** Paul Oguda  
**Date:** 2026-11-20  
**Supersedes:** [ADR-0001](zoda_plan.md) §4.2.5 (buffered-only responses,
issue #18) and the "required separate ADR" gate in
[ADR-0002](adr_0002_unsupported_capabilities.md) §5.1  
**Relates to:** issue #101, #97 (configurable buffered limit), #100 (request
body streaming)

## 1. Context

A `Response` holds its whole body, bounded by `response.Limits.max_body_bytes`.
#97 made the bound configurable, but a large download (a PDF from local storage)
must still be fully buffered before byte one is sent. Raising the limit trades
one problem for another: memory per in-flight response grows with body size.
ADR-0002 §5.1 listed "downloads larger than a reasonable buffered limit" as a
reopening condition and #100 already added the request-side equivalent.

## 2. Decision

Add streamed response bodies. The buffered contract does not change; a
streamed body is an opt-in alternative on the same `Response`.

### 2.1 API: a pull source

```zig
try res.streamBody(200, "application/pdf", .{
    .context = file_state,
    .length = size,            // null when unknown
    .read = readFn,            // fn (ctx, buffer) !usize; 0 = end of body
    .close = closeFn,          // releases the file; called exactly once
});
// or, over a std.Io.Reader the caller owns:
try res.streamBody(200, "text/plain", .fromReader(&reader, null));
```

A pull source was chosen over a writer callback because the transport owns the
pump: it controls chunk size, re-arms the write deadline per chunk, and can
never be handed a producer that writes unbounded data in one call.
`streamBody` copies the content type, clears any previous body, and leaves
caller-set headers in place. It is not subject to `max_body_bytes`. A failure
leaves the response unchanged and the caller still owns the source.

### 2.2 Framing

The transport still owns framing; application `Content-Length` and
`Transfer-Encoding` headers are dropped as for buffered bodies.

| Case | Framing |
|---|---|
| `length` known | `Content-Length`; a source that yields fewer or more bytes closes the connection |
| `length == null`, HTTP/1.1 | `Transfer-Encoding: chunked` |
| `length == null`, HTTP/1.0 | no length; body delimited by closing the connection, no keep-alive |
| HEAD | head and framing headers only; the source is never read |
| 1xx, 204, 304 | bodyless head; the source is never read |

### 2.3 Ownership and lifetime

`Response` owns the `BodyStream` and calls `close` exactly once, from
`deinit`, `clear`, or whatever replaces or discards the body (`text`,
`replaceJson`, `replaceOwnedBody`, `notModified`, a second `streamBody`,
`dropStream`). The transport already releases every response with `defer
res.deinit()`, so the source is closed after a complete send, a failed send, a
client disconnect mid-body, a HEAD request, and a handler error after the
stream was attached. A `Response` cannot outlive its source's context: the
context must stay valid until `close` returns. Server shutdown cancels the
connection fiber, which unwinds through the same `defer`.

### 2.4 Errors after the head

The head is written before the source is read, so the dispatch-before-output
guarantee holds only for buffered responses. A source error, a length
mismatch, a write error, or a deadline after that point closes the connection.
Zoda never sends a second status line. Truncation is visible to the client
(short `Content-Length` body, or chunked stream without the terminating chunk).

### 2.5 Deadlines and limits

The source runs on the connection thread and blocks it, like request-body sinks
(#100). The write deadline is re-armed before each chunk of up to
`transport.stream_chunk_bytes` (64 KiB): a slow client must accept each chunk
within `write_timeout`, which sets a floor of about 6.5 KiB/s at the default
10 s. This deliberately differs from the single absolute deadline for
buffered writes, which would cap the total download time. No framework byte cap
applies to a streamed body: an unbounded source (SSE, long download) is the
use case, the length is the caller's decision, and a stalled client is bounded
by the per-chunk deadline. Memory per streamed response is one chunk.

### 2.6 Middleware

Code that reads or rewrites `res.body` must treat `res.stream != null` as "body
not available":

- `http_cache.setBodyETag` returns `error.StreamedBody`; routes derive a tag and
  use `setETag`. `notModified` drops the stream.
- `status_handler` does not replace a streamed response (it is not an empty or
  generated body).
- Inertia's `emptyBody` drops the stream.
- Any other plugin that reads `res.body` sees an empty slice and so skips or
  no-ops; compression, if added, must check `stream` first.

## 3. Not decided here

- **Range requests / `static.zig`.** `static.zig` stays buffered. Serving files
  with `Range`, `If-Range`, and 206/416 is a follow-up that can build on
  `streamBody` with a bounded `length`.
- **Backpressure beyond the deadline, trailers, compression of streamed
  bodies, and HTTP/2** remain unsupported.
- **A file helper.** A source over `std.Io.File` needs the app's `Io`; apps wrap
  it in `read`/`close` for now.

## 4. Consequences

- `SUPPORTED_API.md` lists streaming as supported with the limits above.
- `src/hardening.zig`'s slow-reader scenario should be extended to a streamed
  body; the per-chunk deadline is covered by transport unit tests only.
- ADR-0001 §4.2.5 and ADR-0002 §5.1 are superseded by this ADR.
