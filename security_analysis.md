# Zoda security analysis

Date: 2026-10-31. Reviewed revision: `a59d0ff79cc39a9ff8e3ca1eaa24509dd12a7a3a`.

## Overall assessment

Zoda has a promising defensive foundation, but this review does **not establish that it is safe for unrestricted production exposure**. Request bounds, absolute socket deadlines, authenticated cookies, strict path parsing, and kernel-enforced static-file confinement address several important attack classes. The main concerns are trailer/header trust confusion, session revocation limitations, and application security that depends on explicit middleware composition.

Use behind a controlled HTTPS reverse proxy, with explicit authentication, CSRF enforcement, host authorization, resource budgets, and application-specific tests. For sensitive authenticated applications, resolve the trailer handling issue and define session revocation before launch. No critical exploit or remote code execution was demonstrated. Absence of such a demonstration is not evidence that none exists.

## Scope and evidence limits

This is a targeted source review of HTTP transport and request bounds, server admission and deadlines, session and CSRF implementation, bearer authentication, host authorization, static-file confinement, template restrictions, SSR networking, logging behavior, and CI configuration. Source references below identify the relevant functions or line locations. Application business logic, every example frontend, the entire Zig standard library, deployment configuration, and dependency CVEs were not exhaustively audited. No external penetration test or sustained fuzzing was performed. Findings distinguish implementation concerns from documented design limitations and integration risks; severity depends on the stated prerequisites.

## Findings and improvements

### S1 — Security-sensitive trailers become ordinary headers

**Priority: high when an upstream security decision depends on headers; otherwise medium. Confidence: high in the code behavior; deployment exploitability unverified.**

In `src/transport.zig:242`, `processRequest` parses chunk trailers, rejects only `Content-Length` and `Transfer-Encoding` by name, then appends remaining fields into the same list as initial headers (`src/transport.zig:296`). That merged list becomes `arena.headers` before dispatch. Authentication and CSRF helpers read this list without provenance: see `BearerToken.parse` in `src/plugins/bearer_token.zig` and `validHeader` in `src/plugins/csrf.zig`.

A trailer-only `Authorization`, `Cookie`, `X-CSRF-Token`, or custom identity header can therefore become visible as an ordinary field to the application. A proxy that evaluates, strips, or overwrites only initial headers may disagree with the application. This does not forge credentials or by itself bypass signature verification. The higher-risk scenario is an application trusting an identity header that its proxy supposedly controls, while that proxy forwards attacker-supplied trailers.

**Improve:** retain trailers separately and expose them through a distinct API. Reject fields involved in authentication, routing, request controls, or payload interpretation; prefer a small explicit trailer allowlist. Ensure upstream identity headers cannot be supplied in trailers.

**Regression test:** send a chunked request with an ordinary Host field and `0\r\nAuthorization: Bearer test\r\n\r\n` as its final chunk/trailer section. Assert that authorization is rejected or that ordinary header lookup cannot see the trailer. Repeat with Cookie, CSRF, Content-Type, and a custom proxy identity field. Test the actual proxy/backend chain. This review establishes the behavior through source inspection, not a completed exploit reproduction.

### S2 — Logout does not revoke previously issued session cookies

**Priority: medium; potentially high for privileged accounts. Confirmed design limitation.**

`Sessions.State.clear` and `Sessions.save` in `src/plugins/sessions.zig:70` and `:92` clear local state and issue a browser deletion cookie. `Sessions.verify` accepts any correctly signed, unexpired cookie under a configured key. There is no per-session revocation lookup. Someone who already copied a valid cookie can replay it after logout until expiry or key removal. The allowed lifetime reaches 30 days; this is a maximum, not a default lifetime.

**Improve:** use opaque server-side sessions, or include a session identifier/account generation checked against a revocation store. Invalidate sessions after logout, password reset, account disablement, and privilege changes. Short lifetimes reduce exposure but do not provide immediate revocation. Rotate CSRF state when changing authenticated identity.

**Regression test:** copy an issued cookie, log out, then replay the copy. Under a revocation-enabled design it must fail, including after password reset and account suspension.

### S3 — Registering a security plugin does not guarantee enforcement

**Priority: medium integration risk; high impact if protected routes are accidentally public.**

`BearerToken.guard_routes` defaults to false (`src/plugins/bearer_token.zig:47`), and its wrapper runs only through route composition. CSRF checks are explicit calls that must precede side effects. Host authorization is middleware and its documentation requires placement before static serving and other responders (`src/host_authorization.zig:89`). These are documented contracts, not demonstrated bypasses of correctly configured applications.

**Improve:** provide a production setup example that composes guards, enforces CSRF on unsafe methods, and orders host/authentication checks before protected responders. Consider a dedicated guarded-route constructor to make protection visible at registration. Test every private route and protected static path with missing, malformed, and duplicate credentials; test every state-changing endpoint without a CSRF token. Do not assume route wrappers protect earlier middleware responses.

### S4 — Connection limits do not bound application execution time

**Priority: medium availability risk.**

`server.Config` (`src/server.zig:45`) caps connections at 128 and sets header, body, write, and idle timeouts. Dispatch is a direct call in `src/transport.zig:314`; those socket deadlines do not impose a wall-clock or CPU budget on a handler. Slow database calls, expensive validation, or blocked application code can occupy admitted work. There is no per-client admission policy in the inspected server configuration, so a single source can compete for the global capacity.

**Improve:** add upstream per-client and endpoint rate controls, explicit outbound dependency timeouts, bounded expensive-work queues, and cooperative cancellation. Use process isolation for work that must be forcibly stopped. Track active connections, rejection rates, memory, and handler duration. Size memory budgets using measured peak allocations: bounded bodies do not imply one allocation or a process-wide memory cap.

**Validation:** test an intentionally stalled handler and sustained connection occupancy while checking that normal clients retain an agreed service budget. Existing socket timeout tests alone cannot prove this property.

### S5 — Session authenticity does not provide confidentiality

**Priority: low if the documented contract is followed; higher if applications store secrets.**

`src/plugins/sessions.zig` explicitly uses base64-encoded data authenticated with HMAC-SHA256, without encryption. A cookie holder can decode its payload. The minimum secret length check cannot determine whether a configured key actually has sufficient randomness.

**Improve:** store only minimal nonsensitive identifiers and enforce authorization against current server-side state. Generate keys using a secure random source, load them from protected configuration, and document rotation and emergency invalidation. Use server-side storage for confidential session data. Do not copy test keys into deployed configuration.

### S6 — SSR trusts a plaintext service to supply executable page markup

**Priority: medium if configured across an untrusted network; low on an isolated trusted loopback service.**

`src/plugins/inertia_ssr.zig:31` defaults to loopback, bounds response size, and uses an absolute deadline. Its `exchange` function sends plaintext HTTP and `Page.body` is documented as inserted verbatim. A compromised renderer or an attacker able to modify this traffic can influence page HTML, and page props travel to that service. The destination is configured as a literal IP; this review found no request-controlled destination in this interface.

**Improve:** keep SSR on loopback or an isolated trusted channel, restrict service access, and avoid sending unnecessary secrets in props. If remote SSR is needed, use authenticated encrypted transport. Treat renderer code and output as part of the application's trusted computing base.

### S7 — CI actions are referenced by mutable version tags

**Priority: low supply-chain hardening.**

`.github/workflows/ci.yml` references `actions/checkout@v5` and `mlugg/setup-zig@v2`. Tags are not immutable content identifiers. The displayed workflow also lacks an explicit token permissions restriction; effective permissions depend on repository/organization settings.

**Improve:** pin reviewed action commit hashes, set `permissions: contents: read` where sufficient, and maintain a deliberate update process. Preserve the exact Zig version check. The core `build.zig.zon` declares no active third-party Zig dependencies, but that does not cover frontend dependencies, build tooling, or the compiler itself.

## Existing protections to preserve

- `request.Limits` bounds target length, header bytes/count, path/query counts, and body size; defaults include a 1 MiB request body. Path parsing rejects dot segments, encoded separators, backslashes, and NUL.
- `transport.processRequest` rejects conflicting Content-Length/Transfer-Encoding framing, validates header syntax and decimal lengths, and closes on protocol rejection. Chunk decoding is implemented explicitly to avoid known parser ambiguities documented in the source.
- `static.openLinux` uses `openat2` with BENEATH, NO_SYMLINKS, and NO_MAGICLINKS resolution (`src/static.zig:344`). Tests cover traversal and symlink races. Keep the document root trusted: confinement does not make intentionally placed secrets or attacker-controlled HTML safe to publish.
- Sessions use HMAC-SHA256 with constant-time comparison and validate expiry. Cookies use `__Host-`, Secure, HttpOnly, and SameSite=Lax; duplicate session names fail closed.
- CSRF tokens use secure randomness and constant-time comparison, and reject missing/duplicate token headers when the checks are called.
- Template interpolation escapes HTML text and rejects unsupported contexts; raw HTML requires an explicit trusted wrapper (`src/template.zig`). Keep unsanitized user content out of that wrapper.
- Request tracing excludes query strings, headers, and bodies (`src/plugins/request_trace.zig:33`). Paths can still contain application secrets, so avoid placing credentials in URLs.

## Remediation order

1. Separate trailers from headers and add regression coverage, including tests through the deployment proxy.
2. Define revocation requirements and implement them for authenticated applications; verify guard/CSRF coverage before deployment.
3. Enforce HTTPS at the deployment boundary and restrict direct backend access. Native TLS is explicitly unsupported in `SUPPORTED_API.md`.
4. Add application work budgets, operational rate controls, and overload monitoring; keep SSR within a trusted boundary.
5. Pin CI actions, minimize CI permissions, and extend adversarial testing with parser fuzzing and proxy differential tests.

## Validation record

The working tree was clean at review start. Zig reports `0.16.0`.

| Command | Result |
| --- | --- |
| `zig build test -Doptimize=ReleaseSafe` | Passed, exit code 0 |
| `zig build test-hardening -Doptimize=ReleaseSafe` | Passed, exit code 0 |

The commands produced no failure output; no test count is claimed. They were run outside the sandbox after its setup failed with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`, with execution approval. No new exploit regression tests were added. The final working tree contains only the new report. No source fixes were applied, and no security guarantee follows from passing tests.
