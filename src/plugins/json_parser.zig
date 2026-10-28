//! Typed parsing of an already buffered request body. The returned value owns
//! its strings and must be deinitialized by the caller.
const std = @import("std");
const router = @import("../router.zig");

pub const ParseError = error{
    MissingContentType,
    DuplicateContentType,
    UnsupportedContentType,
    EmptyBody,
    BodyTooLarge,
    InvalidJson,
    OutOfMemory,
};

pub const JsonParser = struct {
    /// Must be no greater than the request transport's configured body bound
    /// when the same bound is desired for both direct dispatch and sockets.
    max_body_bytes: usize = 1024 * 1024,

    /// `allocator` owns the returned `std.json.Parsed(T)` until `deinit()`.
    /// Strings are copied, so the parsed value can outlive `req`.
    pub fn parse(
        self: *const JsonParser,
        allocator: std.mem.Allocator,
        req: *const router.Request,
        comptime T: type,
    ) ParseError!std.json.Parsed(T) {
        const raw_type = req.getHeaderOne("Content-Type") catch return error.DuplicateContentType;
        const content_type = raw_type orelse return error.MissingContentType;
        if (!isJsonContentType(content_type)) return error.UnsupportedContentType;
        if (req.body.len > self.max_body_bytes) return error.BodyTooLarge;
        if (req.body.len == 0) return error.EmptyBody;

        return std.json.parseFromSlice(T, allocator, req.body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
    }
};

fn isJsonContentType(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t");
    const semi = std.mem.indexOfScalar(u8, value, ';');
    const media = std.mem.trim(u8, if (semi) |i| value[0..i] else value, " \t");
    if (!std.ascii.eqlIgnoreCase(media, "application/json")) return false;
    if (semi) |i| {
        const parameter = std.mem.trim(u8, value[i + 1 ..], " \t");
        const eq = std.mem.indexOfScalar(u8, parameter, '=') orelse return false;
        const name = std.mem.trim(u8, parameter[0..eq], " \t");
        const charset = std.mem.trim(u8, parameter[eq + 1 ..], " \t");
        return std.ascii.eqlIgnoreCase(name, "charset") and
            (std.ascii.eqlIgnoreCase(charset, "utf-8") or std.ascii.eqlIgnoreCase(charset, "\"utf-8\""));
    }
    return true;
}

test "typed JSON owns strings and rejects malformed and ambiguous requests" {
    const T = struct { id: u32, name: []const u8 };
    const parser: JsonParser = .{ .max_body_bytes = 32 };
    const headers = [_]router.Header{.{ .name = "cOnTeNt-TyPe", .value = " Application/JSON ; charset=UTF-8 " }};
    var body = "{\"id\":7,\"name\":\"ada\"}".*;
    var req: router.Request = .{ .method = .post, .segments = &.{}, .headers = &headers, .body = &body };
    var parsed = try parser.parse(std.testing.allocator, &req, T);
    defer parsed.deinit();
    @memset(&body, 'x');
    try std.testing.expectEqual(@as(u32, 7), parsed.value.id);
    try std.testing.expectEqualStrings("ada", parsed.value.name);

    req.body = "{\"id\":";
    try std.testing.expectError(error.InvalidJson, parser.parse(std.testing.allocator, &req, T));
    req.body = "{\"id\":1,\"id\":2,\"name\":\"x\"}";
    try std.testing.expectError(error.InvalidJson, parser.parse(std.testing.allocator, &req, T));
    req.body = "";
    try std.testing.expectError(error.EmptyBody, parser.parse(std.testing.allocator, &req, T));
    req.body = " " ** 33;
    try std.testing.expectError(error.BodyTooLarge, parser.parse(std.testing.allocator, &req, T));
    req.body = "{\"id\":7,\"name\":\"ada\"}";

    req.headers = &.{};
    try std.testing.expectError(error.MissingContentType, parser.parse(std.testing.allocator, &req, T));
    const wrong = [_]router.Header{.{ .name = "Content-Type", .value = "text/json" }};
    req.headers = &wrong;
    try std.testing.expectError(error.UnsupportedContentType, parser.parse(std.testing.allocator, &req, T));
    const combined = [_]router.Header{.{ .name = "Content-Type", .value = "application/json, text/plain" }};
    req.headers = &combined;
    try std.testing.expectError(error.UnsupportedContentType, parser.parse(std.testing.allocator, &req, T));
    const duplicate = [_]router.Header{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "content-type", .value = "application/json" } };
    req.headers = &duplicate;
    try std.testing.expectError(error.DuplicateContentType, parser.parse(std.testing.allocator, &req, T));

    req.headers = &headers;
    var tiny: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    try std.testing.expectError(error.OutOfMemory, parser.parse(fba.allocator(), &req, T));
}
