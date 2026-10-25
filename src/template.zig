//! Embedded HTML templates with text-node interpolation (ADR-0001 Phase 3.5).
//! Pass a source literal or `@embedFile` to `render`. Runtime file loading is
//! deliberately outside this API.
const std = @import("std");
const response = @import("response.zig");

/// Raw markup is accepted only through this explicit type. Construct it only
/// from reviewed static markup or HTML produced by a trusted sanitizer.
pub const TrustedHtml = struct {
    bytes: []const u8,

    pub fn fromTrusted(bytes: []const u8) TrustedHtml {
        return .{ .bytes = bytes };
    }
};

pub const RenderError = response.OwnedBodyError || error{
    MissingField,
    InvalidTemplate,
    UnsupportedContext,
    UntrustedRawHtml,
    UnsupportedFieldType,
};

/// Render an embedded template into a bounded, owned HTML response. `{{name}}`
/// escapes text. `{{{name}}}` inserts only a `TrustedHtml` value. Field names
/// refer to direct fields of a struct. Errors leave `res` unchanged.
pub fn render(res: *response.Response, status_code: u16, comptime source: []const u8, data: anytype) RenderError!void {
    const T = @TypeOf(data);
    comptime if (@typeInfo(T) != .@"struct") @compileError("template data must be a struct");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(res.allocator);
    var i: usize = 0;
    var raw: ?[]const u8 = null;
    while (i < source.len) {
        if (raw) |tag| {
            if (startsClosingTag(source[i..], tag)) {
                const end = try scanTag(source, i);
                try appendBounded(&out, res, source[i..end]);
                i = end;
                raw = null;
            } else {
                if (std.mem.startsWith(u8, source[i..], "{{")) return error.UnsupportedContext;
                try appendBounded(&out, res, source[i .. i + 1]);
                i += 1;
            }
        } else if (std.mem.startsWith(u8, source[i..], "<!--")) {
            const end_rel = std.mem.indexOf(u8, source[i + 4 ..], "-->") orelse return error.InvalidTemplate;
            const end = i + 4 + end_rel + 3;
            if (std.mem.indexOf(u8, source[i..end], "{{") != null) return error.UnsupportedContext;
            try appendBounded(&out, res, source[i..end]);
            i = end;
        } else if (source[i] == '<') {
            const end = try scanTag(source, i);
            const tag = source[i..end];
            try appendBounded(&out, res, tag);
            if (openingTag(tag, "script")) raw = "script";
            if (openingTag(tag, "style")) raw = "style";
            i = end;
        } else if (std.mem.startsWith(u8, source[i..], "{{")) {
            const trusted = std.mem.startsWith(u8, source[i..], "{{{");
            const start = i + (if (trusted) @as(usize, 3) else 2);
            const close = if (trusted) "}}}" else "}}";
            const offset = std.mem.indexOf(u8, source[start..], close) orelse return error.InvalidTemplate;
            const name = source[start .. start + offset];
            if (!validName(name)) return error.InvalidTemplate;
            try appendField(&out, res, name, data, trusted);
            i = start + offset + close.len;
        } else {
            try appendBounded(&out, res, source[i .. i + 1]);
            i += 1;
        }
    }
    if (raw != null) return error.InvalidTemplate;
    const body = try out.toOwnedSlice(res.allocator);
    errdefer res.allocator.free(body);
    try res.replaceOwnedBody(status_code, "text/html; charset=utf-8", body);
}

fn appendBounded(out: *std.ArrayList(u8), res: *response.Response, bytes: []const u8) RenderError!void {
    if (bytes.len > res.limits.max_body_bytes - out.items.len) return error.BodyTooLarge;
    try out.appendSlice(res.allocator, bytes);
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, j| {
        if (std.ascii.isAlphabetic(c) or c == '_' or (j != 0 and std.ascii.isDigit(c))) continue;
        return false;
    }
    return true;
}

fn scanTag(source: []const u8, start: usize) RenderError!usize {
    if (start + 1 >= source.len) return error.InvalidTemplate;
    const first = source[start + 1];
    if (!(std.ascii.isAlphabetic(first) or first == '/' or first == '!')) return error.InvalidTemplate;
    var quote: u8 = 0;
    var j = start + 1;
    while (j < source.len) : (j += 1) {
        const c = source[j];
        if (std.mem.startsWith(u8, source[j..], "{{")) return error.UnsupportedContext;
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return j + 1;
        } else if (c == '<') {
            return error.InvalidTemplate;
        }
    }
    return error.InvalidTemplate;
}

fn openingTag(tag: []const u8, name: []const u8) bool {
    if (tag.len < name.len + 2 or !std.ascii.eqlIgnoreCase(tag[1 .. 1 + name.len], name)) return false;
    const next = tag[1 + name.len];
    return next == '>' or next == '/' or std.ascii.isWhitespace(next);
}

fn startsClosingTag(source: []const u8, name: []const u8) bool {
    if (source.len < name.len + 3 or !std.mem.startsWith(u8, source, "</")) return false;
    if (!std.ascii.eqlIgnoreCase(source[2 .. 2 + name.len], name)) return false;
    const next = source[2 + name.len];
    return next == '>' or std.ascii.isWhitespace(next);
}

fn appendField(out: *std.ArrayList(u8), res: *response.Response, name: []const u8, data: anytype, trusted: bool) RenderError!void {
    inline for (@typeInfo(@TypeOf(data)).@"struct".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const value = @field(data, field.name);
            if (@TypeOf(value) == TrustedHtml) {
                if (!trusted) return error.UnsupportedFieldType;
                return appendBounded(out, res, value.bytes);
            }
            if (trusted) return error.UntrustedRawHtml;
            const V = @TypeOf(value);
            switch (@typeInfo(V)) {
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) return appendEscaped(out, res, value);
                    if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                        return appendEscaped(out, res, value);
                },
                .array => |a| if (a.child == u8) return appendEscaped(out, res, &value),
                .int, .comptime_int, .float, .comptime_float, .bool => {
                    const printed = try std.fmt.allocPrint(res.allocator, "{any}", .{value});
                    defer res.allocator.free(printed);
                    return appendEscaped(out, res, printed);
                },
                else => {},
            }
            return error.UnsupportedFieldType;
        }
    }
    return error.MissingField;
}

fn appendEscaped(out: *std.ArrayList(u8), res: *response.Response, bytes: []const u8) RenderError!void {
    for (bytes) |c| {
        const replacement: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &.{c},
        };
        try appendBounded(out, res, replacement);
    }
}

test "embedded page escapes hostile text and permits explicit trusted markup" {
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try render(&res, 200, "<h1>{{title}}</h1><p>{{count}}</p><div>{{{content}}}</div>", .{
        .title = "<script>alert('x') & \"y\"</script>",
        .count = @as(u32, 3),
        .content = TrustedHtml.fromTrusted("<strong>safe</strong>"),
    });
    try std.testing.expectEqualStrings("<h1>&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;y&quot;&lt;/script&gt;</h1><p>3</p><div><strong>safe</strong></div>", res.body);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", res.content_type);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
}

test "template errors preserve previous response" {
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    try res.text(201, "previous");
    try std.testing.expectError(error.MissingField, render(&res, 200, "{{absent}}", .{ .name = "x" }));
    try std.testing.expectError(error.InvalidTemplate, render(&res, 200, "{{name", .{ .name = "x" }));
    try std.testing.expectError(error.UntrustedRawHtml, render(&res, 200, "{{{name}}}", .{ .name = "<b>x</b>" }));
    try std.testing.expectEqualStrings("previous", res.body);
    try std.testing.expectEqual(@as(u16, 201), res.status_code);
}

test "interpolation is rejected outside text nodes" {
    var res = response.Response.init(std.testing.allocator);
    defer res.deinit();
    const data = .{ .x = "evil" };
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<a href='{{x}}'>a</a>", data));
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<p data-x={{x}}>a</p>", data));
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<script>{{x}}</script>", data));
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<SCRIPT/x>{{x}}</SCRIPT>", data));
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<style>{{x}}</style>", data));
    try std.testing.expectError(error.UnsupportedContext, render(&res, 200, "<!-- {{x}} -->", data));
    try std.testing.expectError(error.InvalidTemplate, render(&res, 200, "<a href='broken>", data));
}

test "render stays within response body limit" {
    var res = response.Response.initWithLimits(std.testing.allocator, .{ .max_body_bytes = 3 });
    defer res.deinit();
    try std.testing.expectError(error.BodyTooLarge, render(&res, 200, "{{x}}", .{ .x = "<" }));
    try std.testing.expect(!res.handled);
}
