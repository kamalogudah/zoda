//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Router core: allocation-free consuming matchers and cursor checkpoints
/// (ADR-0001 §3.1, §5.1).
pub const router = @import("router.zig");

/// Owned request storage and strict origin-form target/query parsing
/// (ADR-0001 §3.4, §5.1).
pub const request = @import("request.zig");

/// Independently owned buffered responses and safe header handling
/// (ADR-0001 §3.4, §3.5).
pub const response = @import("response.zig");

/// Embedded HTML templates with typed text interpolation (ADR-0001 Phase 3.5).
pub const template = @import("template.zig");

/// Bounded buffering and protocol error mappings (ADR-0001 §3.4).
pub const buffering = @import("buffering.zig");

/// Bounded HTTP/1.x framing over the pinned `std.http.Server` API.
pub const transport = @import("transport.zig");

/// Bounded concurrent socket runtime with total operation deadlines.
pub const server = @import("server.zig");

/// Application dispatch, typed handler context, and route-wrapper
/// composition (ADR-0001 §3.2, §3.3, §5.2).
pub const app = @import("app.zig");

/// Injected application clock and response-timing middleware
/// (ADR-0001 §5.4).
pub const timing = @import("timing.zig");

/// Configured default response headers across the middleware chain.
pub const default_headers = @import("default_headers.zig");

/// Exact Host allowlist middleware for routes and static files.
pub const host_authorization = @import("host_authorization.zig");

/// Static-file middleware with kernel-enforced document-root confinement
/// (ADR-0001 §5.4).
pub const static = @import("static.zig");

/// Built-in plugins.
pub const plugins = struct {
    /// Stateless JSON response plugin (ADR-0001 §5.3).
    pub const json = @import("plugins/json.zig");
    /// Typed parsing of bounded JSON request bodies.
    pub const json_parser = @import("plugins/json_parser.zig");
    /// Configured route-miss fallback (ADR-0001 §3.3).
    pub const not_found = @import("plugins/not_found.zig");
    /// Authenticated cookie sessions with explicit persistence.
    pub const sessions = @import("plugins/sessions.zig");
    /// Session-bound synchronizer token helpers.
    pub const csrf = @import("plugins/csrf.zig");
    /// One-time flash messages stored in the cookie session.
    pub const flash = @import("plugins/flash.zig");
    /// Application-validated Authorization Bearer credentials.
    pub const bearer_token = @import("plugins/bearer_token.zig");
    /// Request IDs and access records across the dispatch chain.
    pub const request_trace = @import("plugins/request_trace.zig");
    /// Explicit Cache-Control, ETag, Vary, and conditional GET helpers.
    pub const http_cache = @import("plugins/http_cache.zig");
    /// Configured responses for selected empty or generated 4xx/5xx statuses.
    pub const status_handler = @import("plugins/status_handler.zig");
    /// Recovery middleware that clears partial responses before replacement.
    pub const error_handler = @import("plugins/error_handler.zig");
};

/// Re-export the JSON plugin instance type for convenience.
pub const Json = plugins.json.Json;
pub const JsonParser = plugins.json_parser.JsonParser;

/// Re-export the not-found wrapper instance type for convenience.
pub const NotFound = plugins.not_found.NotFound;
pub const Sessions = plugins.sessions.Sessions;
pub const Flash = plugins.flash.Flash;
pub const BearerToken = plugins.bearer_token.BearerToken;
pub const RequestTrace = plugins.request_trace.RequestTrace;

comptime {
    // Collect the imported modules' test declarations into the library test
    // suite; `zig build test` otherwise only analyzes decls it references.
    std.testing.refAllDecls(router);
    std.testing.refAllDecls(request);
    std.testing.refAllDecls(response);
    std.testing.refAllDecls(template);
    std.testing.refAllDecls(buffering);
    std.testing.refAllDecls(transport);
    std.testing.refAllDecls(server);
    std.testing.refAllDecls(app);
    std.testing.refAllDecls(timing);
    std.testing.refAllDecls(default_headers);
    std.testing.refAllDecls(host_authorization);
    std.testing.refAllDecls(static);
    std.testing.refAllDecls(plugins.json);
    std.testing.refAllDecls(plugins.json_parser);
    std.testing.refAllDecls(plugins.not_found);
    std.testing.refAllDecls(plugins.sessions);
    std.testing.refAllDecls(plugins.csrf);
    std.testing.refAllDecls(plugins.flash);
    std.testing.refAllDecls(plugins.bearer_token);
    std.testing.refAllDecls(plugins.request_trace);
    std.testing.refAllDecls(plugins.http_cache);
    std.testing.refAllDecls(plugins.status_handler);
    std.testing.refAllDecls(plugins.error_handler);
}

test {
    // Adversarial real-socket suite (Phase 2b); not part of the public API.
    _ = @import("hardening.zig");
    _ = @import("lifecycle.zig");
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
