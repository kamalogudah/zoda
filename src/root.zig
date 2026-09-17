//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Router core: allocation-free consuming matchers and cursor checkpoints
/// (ADR-0001 §3.1, §5.1).
pub const router = @import("router.zig");

comptime {
    // Collect the imported router's test declarations into the library test
    // suite; `zig build test` otherwise only analyzes decls it references.
    std.testing.refAllDecls(router);
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
