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

/// Bounded buffering and protocol error mappings (ADR-0001 §3.4).
pub const buffering = @import("buffering.zig");

/// Application dispatch and typed handler context (ADR-0001 §3.2, §5.2).
pub const app = @import("app.zig");

/// Built-in plugins.
pub const plugins = struct {
    /// Stateless JSON response plugin (ADR-0001 §5.3).
    pub const json = @import("plugins/json.zig");
};

/// Re-export the JSON plugin instance type for convenience.
pub const Json = plugins.json.Json;

comptime {
    // Collect the imported modules' test declarations into the library test
    // suite; `zig build test` otherwise only analyzes decls it references.
    std.testing.refAllDecls(router);
    std.testing.refAllDecls(request);
    std.testing.refAllDecls(response);
    std.testing.refAllDecls(buffering);
    std.testing.refAllDecls(app);
    std.testing.refAllDecls(plugins.json);
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
