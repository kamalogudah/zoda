//! Stateless JSON plugin (ADR-0001 §3.2, §5.3).
//!
//! `Json` is a plugin instance with no per-request state. It exposes `render`,
//! which serializes a value into the response body as `application/json` and
//! marks the response handled.
const std = @import("std");
const response = @import("../response.zig");
const router = @import("../router.zig");

pub const Json = struct {
    pub const State = struct {};

    pub fn initRequest(_: *const Json, _: *router.Request) !State {
        return .{};
    }

    pub fn deinitRequest(_: *const Json, _: *State) void {}

    /// Serializes `value` as JSON and replaces the response body, status, and
    /// content type. On success the response is marked handled.
    pub fn render(
        _: *const Json,
        res: *response.Response,
        comptime T: type,
        value: T,
    ) !void {
        try res.replaceJson(200, T, value);
    }
};

test "json render serializes value and sets metadata" {
    const User = struct { id: usize, name: []const u8 };
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();

    const json: Json = .{};
    try json.render(&res, User, .{ .id = 7, .name = "ada" });

    try std.testing.expect(res.handled);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expectEqualStrings("application/json", res.content_type);
    try std.testing.expectEqualStrings("{\"id\":7,\"name\":\"ada\"}", res.body);
}

test "json plugin state is empty" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Json.State));
}
