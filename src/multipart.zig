//! Strict `multipart/form-data` (RFC 7578, framing per RFC 2046) parser for an
//! already buffered request body.
//!
//! Parsed parts are slices of `body`; nothing is copied or unescaped, so the
//! body must outlive the `Form`. Anything unexpected is an error rather than
//! being guessed at: a preamble, a boundary-like line that is not a clean
//! delimiter, folded or malformed part headers, unknown part headers, a
//! duplicate `name`/`filename`, `Content-Transfer-Encoding`, `filename*`, or
//! data after the closing delimiter. Duplicate field names are allowed (use
//! `Form.getAll`); filenames are untrusted client input and must be sanitized
//! by the application before touching a filesystem.
const std = @import("std");

pub const Limits = struct {
    /// Maximum number of parts in one form.
    max_parts: usize = 128,
    /// Maximum bytes in one part's header block (excluding the blank line).
    max_header_bytes: usize = 8 * 1024,
};

pub const ParseError = error{
    /// Content-Type is not `multipart/form-data`.
    UnsupportedContentType,
    /// Missing, duplicated, empty, over-long, or invalid boundary parameter,
    /// or an unknown/duplicate/malformed Content-Type parameter.
    InvalidBoundary,
    /// Body does not begin with the opening delimiter (preambles are refused).
    MissingOpeningDelimiter,
    /// A boundary line is not followed by `--` or optional blanks and CRLF.
    MalformedDelimiter,
    /// No closing delimiter was found.
    UnterminatedBody,
    /// Anything other than an optional CRLF after the closing delimiter.
    TrailingData,
    /// Part header block exceeds `Limits.max_header_bytes` or is unterminated.
    HeadersTooLarge,
    /// Malformed header line, folding, bare CR/LF, control bytes, or an
    /// unexpected header field.
    InvalidPartHeader,
    /// Missing or repeated Content-Disposition, or not `form-data` with `name`.
    InvalidContentDisposition,
    /// Repeated or empty part Content-Type.
    InvalidPartContentType,
    TooManyParts,
    OutOfMemory,
};

pub const Part = struct {
    /// Form field name, exactly as sent (not percent-decoded).
    name: []const u8,
    /// Client-supplied filename, exactly as sent; present for file parts.
    filename: ?[]const u8,
    /// Part Content-Type, if the part declared one.
    content_type: ?[]const u8,
    data: []const u8,
};

pub const Form = struct {
    parts: []const Part,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Form) void {
        self.allocator.free(self.parts);
        self.* = undefined;
    }

    /// First part named `name`, if any.
    pub fn get(self: *const Form, name: []const u8) ?Part {
        for (self.parts) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    /// Iterates every part named `name` in body order.
    pub fn getAll(self: *const Form, name: []const u8) GetAll {
        return .{ .parts = self.parts, .name = name };
    }

    pub const GetAll = struct {
        parts: []const Part,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *GetAll) ?Part {
            while (self.index < self.parts.len) {
                const p = self.parts[self.index];
                self.index += 1;
                if (std.mem.eql(u8, p.name, self.name)) return p;
            }
            return null;
        }
    };
};

/// Parses with default `Limits`.
pub fn parse(allocator: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError!Form {
    return parseWithLimits(allocator, content_type, body, .{});
}

pub fn parseWithLimits(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
    limits: Limits,
) ParseError!Form {
    const boundary = try boundaryFromContentType(content_type);

    // Opening delimiter is `--boundary`; later ones are `CRLF--boundary`.
    var open_buf: [72]u8 = undefined;
    open_buf[0] = '-';
    open_buf[1] = '-';
    @memcpy(open_buf[2..][0..boundary.len], boundary);
    const open = open_buf[0 .. 2 + boundary.len];
    var delim_buf: [74]u8 = undefined;
    delim_buf[0] = '\r';
    delim_buf[1] = '\n';
    @memcpy(delim_buf[2..][0..open.len], open);
    const delim = delim_buf[0 .. 2 + open.len];

    if (!std.mem.startsWith(u8, body, open)) return error.MissingOpeningDelimiter;

    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(allocator);

    var pos: usize = open.len;
    while (true) {
        // `pos` is just after a delimiter.
        if (std.mem.startsWith(u8, body[pos..], "--")) {
            const rest = body[pos + 2 ..];
            if (rest.len != 0 and !std.mem.eql(u8, rest, "\r\n")) return error.TrailingData;
            break;
        }
        while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) pos += 1;
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return error.MalformedDelimiter;
        const header_start = pos + 2;

        if (parts.items.len >= limits.max_parts) return error.TooManyParts;

        const window_end = @min(body.len, header_start +| (limits.max_header_bytes + 4));
        const header_end = std.mem.indexOf(u8, body[header_start..window_end], "\r\n\r\n") orelse
            return if (window_end < body.len) error.HeadersTooLarge else error.UnterminatedBody;
        if (header_end > limits.max_header_bytes) return error.HeadersTooLarge;
        const header_block = body[header_start..][0..header_end];
        const data_start = header_start + header_end + 4;

        const end = std.mem.indexOf(u8, body[data_start..], delim) orelse return error.UnterminatedBody;
        const part = try parsePartHeaders(header_block, body[data_start..][0..end]);
        try parts.append(allocator, part);
        pos = data_start + end + delim.len;
    }

    return .{ .parts = try parts.toOwnedSlice(allocator), .allocator = allocator };
}

fn parsePartHeaders(block: []const u8, data: []const u8) ParseError!Part {
    var disposition: ?[]const u8 = null;
    var part_type: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return error.InvalidPartHeader;
        if (line[0] == ' ' or line[0] == '\t') return error.InvalidPartHeader; // obs-fold
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidPartHeader;
        const name = line[0..colon];
        if (name.len == 0 or !isToken(name)) return error.InvalidPartHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        for (value) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.InvalidPartHeader;

        if (std.ascii.eqlIgnoreCase(name, "content-disposition")) {
            if (disposition != null) return error.InvalidContentDisposition;
            disposition = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            if (part_type != null or value.len == 0) return error.InvalidPartContentType;
            part_type = value;
        } else return error.InvalidPartHeader;
    }

    const cd = disposition orelse return error.InvalidContentDisposition;
    var params = Params.init(cd);
    const media = params.media();
    if (!std.ascii.eqlIgnoreCase(media, "form-data")) return error.InvalidContentDisposition;
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    while (params.next() catch return error.InvalidContentDisposition) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, "name")) {
            if (name != null) return error.InvalidContentDisposition;
            name = p.value;
        } else if (std.ascii.eqlIgnoreCase(p.name, "filename")) {
            if (filename != null) return error.InvalidContentDisposition;
            filename = p.value;
        } else return error.InvalidContentDisposition;
    }
    return .{
        .name = name orelse return error.InvalidContentDisposition,
        .filename = filename,
        .content_type = part_type,
        .data = data,
    };
}

fn boundaryFromContentType(content_type: []const u8) ParseError![]const u8 {
    var params = Params.init(content_type);
    if (!std.ascii.eqlIgnoreCase(params.media(), "multipart/form-data")) return error.UnsupportedContentType;
    var boundary: ?[]const u8 = null;
    while (params.next() catch return error.InvalidBoundary) |p| {
        if (std.ascii.eqlIgnoreCase(p.name, "boundary")) {
            if (boundary != null) return error.InvalidBoundary;
            boundary = p.value;
        } else if (!std.ascii.eqlIgnoreCase(p.name, "charset")) return error.InvalidBoundary;
    }
    const b = boundary orelse return error.InvalidBoundary;
    if (b.len == 0 or b.len > 70 or b[b.len - 1] == ' ') return error.InvalidBoundary;
    for (b) |c| if (!isBoundaryChar(c)) return error.InvalidBoundary;
    return b;
}

fn isBoundaryChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "'()+_,-./:=? ", c) != null;
}

fn isToken(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null)) return false;
    }
    return s.len != 0;
}

/// `value; name=token; name="quoted"` parameter reader. Quoted strings end at
/// the first `"`; no backslash unescaping is done (browsers do not escape).
const Params = struct {
    rest: []const u8,
    first: []const u8,

    const Param = struct { name: []const u8, value: []const u8 };

    fn init(s: []const u8) Params {
        const semi = std.mem.indexOfScalar(u8, s, ';');
        return .{
            .first = std.mem.trim(u8, if (semi) |i| s[0..i] else s, " \t"),
            .rest = if (semi) |i| s[i..] else "",
        };
    }

    fn media(self: *const Params) []const u8 {
        return self.first;
    }

    fn next(self: *Params) error{Invalid}!?Param {
        if (self.rest.len == 0) return null;
        std.debug.assert(self.rest[0] == ';');
        var s = std.mem.trimStart(u8, self.rest[1..], " \t");
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse return error.Invalid;
        const name = std.mem.trimEnd(u8, s[0..eq], " \t");
        if (!isToken(name)) return error.Invalid;
        s = std.mem.trimStart(u8, s[eq + 1 ..], " \t");
        var value: []const u8 = undefined;
        if (s.len > 0 and s[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse return error.Invalid;
            value = s[1..close];
            for (value) |c| if (c < 0x20 and c != '\t' or c == 0x7f) return error.Invalid;
            s = std.mem.trimStart(u8, s[close + 1 ..], " \t");
            if (s.len != 0 and s[0] != ';') return error.Invalid;
            self.rest = s;
        } else {
            const semi = std.mem.indexOfScalar(u8, s, ';') orelse s.len;
            value = std.mem.trimEnd(u8, s[0..semi], " \t");
            if (!isToken(value)) return error.Invalid;
            self.rest = s[semi..];
        }
        return .{ .name = name, .value = value };
    }
};

const ct = "multipart/form-data; boundary=b";

test "parses fields and files as slices of the body" {
    const real =
        "--b\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n" ++
        "--b\r\nContent-Disposition: Form-Data; NAME=\"file\"; filename=\"a b.txt\"\r\n" ++
        "content-type: text/plain\r\n\r\nline1\r\n--b\r\n" ++
        "Content-Disposition: form-data; name=title\r\n\r\n\r\n--b--\r\n";
    var form = try parse(std.testing.allocator, " Multipart/Form-Data ; boundary=b", real);
    defer form.deinit();
    try std.testing.expectEqual(@as(usize, 3), form.parts.len);
    try std.testing.expectEqualStrings("hello", form.get("title").?.data);
    const f = form.get("file").?;
    try std.testing.expectEqualStrings("a b.txt", f.filename.?);
    try std.testing.expectEqualStrings("text/plain", f.content_type.?);
    try std.testing.expectEqualStrings("line1", f.data);
    try std.testing.expect(@intFromPtr(f.data.ptr) >= @intFromPtr(real.ptr) and @intFromPtr(f.data.ptr) < @intFromPtr(real.ptr) + real.len);
    var all = form.getAll("title");
    try std.testing.expectEqualStrings("hello", all.next().?.data);
    try std.testing.expectEqualStrings("", all.next().?.data);
    try std.testing.expect(all.next() == null);
    try std.testing.expect(form.get("nope") == null);
}

test "binary data may contain CRLF and partial boundaries" {
    const real = "--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\n\x00\r\n\r\n--\r\n-b\r\n--\x01\r\n--b--";
    var form = try parse(std.testing.allocator, "multipart/form-data; boundary=\"b\"", real);
    defer form.deinit();
    try std.testing.expectEqualStrings("\x00\r\n\r\n--\r\n-b\r\n--\x01", form.parts[0].data);
}

test "quoted boundary with special characters and transport padding" {
    const ctype = "multipart/form-data; boundary=\"a:b=c ?\"; charset=utf-8";
    const real = "--a:b=c ?  \t\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--a:b=c ?--";
    var form = try parse(std.testing.allocator, ctype, real);
    defer form.deinit();
    try std.testing.expectEqualStrings("v", form.parts[0].data);
}

test "rejects bad content types and boundaries" {
    const x70: *const [70]u8 = &@as([70]u8, @splat('x'));
    const x71: *const [71]u8 = &@as([71]u8, @splat('x'));
    const a = std.testing.allocator;
    const body = "--b--";
    try std.testing.expectError(error.UnsupportedContentType, parse(a, "text/plain; boundary=b", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=a; boundary=b", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=b; x=y", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=\"b \"", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=\"b\r\"", body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=" ++ x71, body));
    try std.testing.expectError(error.InvalidBoundary, parse(a, "multipart/form-data; boundary=b;", body));
    var ok = try parse(a, "multipart/form-data; boundary=" ++ x70, "--" ++ x70 ++ "--");
    ok.deinit();
}

test "rejects malformed framing" {
    const a = std.testing.allocator;
    const hdr = "Content-Disposition: form-data; name=\"n\"\r\n\r\n";
    try std.testing.expectError(error.MissingOpeningDelimiter, parse(a, ct, "junk\r\n--b--"));
    try std.testing.expectError(error.MissingOpeningDelimiter, parse(a, ct, ""));
    try std.testing.expectError(error.MalformedDelimiter, parse(a, ct, "--b\n" ++ hdr ++ "v\r\n--b--"));
    try std.testing.expectError(error.MalformedDelimiter, parse(a, ct, "--bx\r\n" ++ hdr ++ "v\r\n--b--"));
    try std.testing.expectError(error.MalformedDelimiter, parse(a, ct, "--b\r\n" ++ hdr ++ "v\r\n--bx\r\n" ++ hdr ++ "v\r\n--b--"));
    try std.testing.expectError(error.UnterminatedBody, parse(a, ct, "--b\r\n" ++ hdr ++ "v"));
    try std.testing.expectError(error.MalformedDelimiter, parse(a, ct, "--b\r\n" ++ hdr ++ "v\r\n--b"));
    try std.testing.expectError(error.UnterminatedBody, parse(a, ct, "--b\r\nContent-Disposition: form-data; name=\"n\""));
    try std.testing.expectError(error.TrailingData, parse(a, ct, "--b--x"));
    try std.testing.expectError(error.TrailingData, parse(a, ct, "--b--\r\n--b\r\n" ++ hdr ++ "v\r\n--b--"));
    try std.testing.expectError(error.TrailingData, parse(a, ct, "--b--\r\n\r\n"));
    // Zero parts is a valid empty form.
    var empty = try parse(a, ct, "--b--");
    empty.deinit();
}

test "rejects malformed part headers" {
    const a = std.testing.allocator;
    const tail = "\r\n\r\nv\r\n--b--";
    const pre = "--b\r\n";
    const cd = "Content-Disposition: form-data; name=\"n\"";
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ "X-Other: 1" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\r\nX-Other: 1" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\r\n folded" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\r\nno colon" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\nContent-Type: a" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\r\nContent-Transfer-Encoding: base64" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ "Bad Name: x\r\n" ++ cd ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ "Content-Type: a/b" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ "\r\n" ++ cd ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ "Content-Disposition: attachment; name=\"n\"" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ "Content-Disposition: form-data" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ "; name=\"m\"" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ "; filename=\"a\"; filename=\"b\"" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ "; filename*=UTF-8''a" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ "Content-Disposition: form-data; name=\"n" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ "x" ++ tail));
    try std.testing.expectError(error.InvalidContentDisposition, parse(a, ct, pre ++ cd ++ ";" ++ tail));
    try std.testing.expectError(error.InvalidPartContentType, parse(a, ct, pre ++ cd ++ "\r\nContent-Type: a\r\nContent-Type: b" ++ tail));
    try std.testing.expectError(error.InvalidPartContentType, parse(a, ct, pre ++ cd ++ "\r\nContent-Type:" ++ tail));
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, pre ++ cd ++ "\r\nContent-Type: a\x00b" ++ tail));
    // Part with no headers at all.
    try std.testing.expectError(error.InvalidPartHeader, parse(a, ct, "--b\r\n\r\n\r\nv\r\n--b--"));
}

test "enforces limits" {
    const a = std.testing.allocator;
    const body = "--b\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--b\r\nContent-Disposition: form-data; name=\"m\"\r\n\r\nw\r\n--b--";
    try std.testing.expectError(error.TooManyParts, parseWithLimits(a, ct, body, .{ .max_parts = 1 }));
    var ok = try parseWithLimits(a, ct, body, .{ .max_parts = 2 });
    ok.deinit();
    try std.testing.expectError(error.HeadersTooLarge, parseWithLimits(a, ct, body, .{ .max_header_bytes = 10 }));
    // Exactly at the header limit is accepted.
    const h = "Content-Disposition: form-data; name=\"n\"";
    var at = try parseWithLimits(a, ct, "--b\r\n" ++ h ++ "\r\n\r\nv\r\n--b--", .{ .max_header_bytes = h.len });
    at.deinit();
    try std.testing.expectError(error.HeadersTooLarge, parseWithLimits(a, ct, "--b\r\n" ++ h ++ "\r\n\r\nv\r\n--b--", .{ .max_header_bytes = h.len - 1 }));
}

test "no leaks on failure after parts were collected" {
    const body = "--b\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--b\r\nbad\r\n\r\nx\r\n--b--";
    try std.testing.expectError(error.InvalidPartHeader, parse(std.testing.allocator, ct, body));
}

test "allocation failure is reported" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parse(failing.allocator(), ct, "--b\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\nv\r\n--b--"));
}
