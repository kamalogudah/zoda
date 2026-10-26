//! Router core: allocation-free consuming matchers and cursor checkpoints
//! (ADR-0001 §3.1, §5.1).
//!
//! A `Request` carries the complete buffered HTTP request plus decoded path
//! segments and a single mutable `cursor`. Matchers only
//! read `segments` and never allocate; consumed values are borrowed slices into
//! the request's own storage. There is deliberately no second capture array:
//! `onSegment` returns the borrowed segment directly.
//!
//! Conventions enforced by documentation and tests:
//! - A failed matcher leaves the cursor unchanged.
//! - Checkpoints (`mark`/`restore`) apply only to the same request and restore
//!   routing state only — never response writes or plugin side effects.
//! - Alternatives must be attempted before producing output or side effects.
//! - A successful prefix match commits the handler to that branch by
//!   convention: the handler must `return` when the branch finishes, even when
//!   no response was produced. Dispatch supplies the fallback 404. Because a
//!   consumed prefix can itself reach the root (`GET /users` becomes root after
//!   consuming `users`), omitting the branch return lets a request fall
//!   through to a later root handler; a handler delegating a whole branch must
//!   use `return child(ctx, req, res)`.
//! - Matching never returns from the caller: a matcher that succeeds only
//!   consumes segments, and the handler decides whether (and how) to return.
//! - Unsupported methods are unhandled and initially become 404; automatic
//!   405/Allow and HEAD-to-GET fallback are outside this slice.
//! - Match cost depends on attempted siblings and string comparisons; there is
//!   no unconditional O(depth) guarantee.
const std = @import("std");

/// HTTP request methods. Phase 0 supports method-only matching (`isGet`).
/// Automatic 405/Allow and HEAD-to-GET fallback are outside the first slice
/// (ADR §3.1); parsing method strings into this enum lands with the transport.
pub const Method = enum {
    get,
    post,
    put,
    delete,
    patch,
    head,
    options,
    trace,
    connect,
};

/// An ordered query pair. The Phase 0.5 request parser (`src/request.zig`)
/// populates an arena-owned slice of these from an origin-form target; order
/// and duplicates survive, and `getAll`/`getOne` read the slice
/// allocation-free (§3.4).
pub const QueryPair = struct {
    key: []const u8,
    value: []const u8,
};

/// A request header. Names retain their wire spelling; lookup is
/// case-insensitive and repeated fields remain separate and ordered.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Iterates every value for a query key, in request order, including
/// duplicates. Allocation-free; backed by the request's query pair slice.
pub const QueryValueIterator = struct {
    pairs: []const QueryPair,
    key: []const u8,
    index: usize = 0,

    pub fn next(self: *QueryValueIterator) ?[]const u8 {
        while (self.index < self.pairs.len) {
            const pair = self.pairs[self.index];
            self.index += 1;
            if (std.mem.eql(u8, pair.key, self.key)) return pair.value;
        }
        return null;
    }
};

/// A complete buffered request carrying wire metadata, decoded path/query
/// data, and a consuming routing cursor.
///
/// The caller owns the request and its storage (an arena in later phases) and
/// keeps it alive while routing reads borrowed segments. Returned capture
/// slices must not outlive the request (§3.4).
pub const Request = struct {
    method: Method,
    segments: []const []const u8,
    cursor: usize = 0,
    /// Raw origin-form request target.
    target: []const u8 = &.{},
    query: []const QueryPair = &.{},
    headers: []const Header = &.{},
    body: []const u8 = &.{},

    /// Same-request checkpoint: returns the current cursor position. A saved
    /// checkpoint is meaningful only for the request it came from; it must not
    /// be used to rewind another request.
    pub fn mark(self: *const Request) usize {
        return self.cursor;
    }

    /// Restores routing state (`cursor`) only. It never rewinds response
    /// writes or plugin side effects; alternatives must be attempted before
    /// any output is produced.
    pub fn restore(self: *Request, saved: usize) void {
        self.cursor = saved;
    }

    /// Returns `true` when no path segments remain. Method-only: it never
    /// claims a path, so terminal routes combine it with `isGet` explicitly.
    pub fn isRoot(self: *const Request) bool {
        return self.cursor == self.segments.len;
    }

    /// Method-only check. Never consumes a segment and never claims a path.
    pub fn isGet(self: *const Request) bool {
        return self.method == .get;
    }

    /// Consumes one matching segment. A failed match leaves the cursor
    /// unchanged, so alternatives can be tried after a miss.
    pub fn onLiteral(self: *Request, literal: []const u8) bool {
        if (self.isRoot()) return false;
        if (!std.mem.eql(u8, self.segments[self.cursor], literal)) return false;
        self.cursor += 1;
        return true;
    }

    /// Consumes and returns the next segment as a borrowed slice into the
    /// request's own storage. No allocation occurs and no second capture array
    /// is maintained; the returned slice lives only as long as the request.
    /// Returns `null` when at the root.
    pub fn onSegment(self: *Request) ?[]const u8 {
        if (self.isRoot()) return null;
        const value = self.segments[self.cursor];
        self.cursor += 1;
        return value;
    }

    /// Parses the next segment as a base-10 integer of type `T`, then consumes
    /// it. Invalid text, overflow, or the end of the path returns `null` and
    /// leaves the cursor unchanged. `T` must be an integer type.
    pub fn onInt(self: *Request, comptime T: type) ?T {
        comptime if (@typeInfo(T) != .int) @compileError("onInt requires an integer type");
        if (self.isRoot()) return null;
        const value = std.fmt.parseInt(T, self.segments[self.cursor], 10) catch return null;
        self.cursor += 1;
        return value;
    }

    /// Terminal integer matcher: parses and consumes only when exactly one
    /// segment remains. Every failure leaves the cursor unchanged.
    pub fn isInt(self: *Request, comptime T: type) ?T {
        comptime if (@typeInfo(T) != .int) @compileError("isInt requires an integer type");
        if (self.segments.len - self.cursor != 1) return null;
        return self.onInt(T);
    }

    /// Terminal matcher: succeeds and consumes only when exactly one remaining
    /// segment equals `literal`. With two or more segments remaining it fails
    /// without consuming, and the caller must keep the branch open.
    pub fn isLiteral(self: *Request, literal: []const u8) bool {
        if (self.segments.len - self.cursor != 1) return false;
        if (!std.mem.eql(u8, self.segments[self.cursor], literal)) return false;
        self.cursor += 1;
        return true;
    }

    /// Returns every query value for `key` in request order, preserving
    /// duplicates, as an allocation-free iterator. Query keys compare exactly
    /// (they are case-sensitive per the origin-form grammar).
    pub fn getAll(self: *const Request, key: []const u8) QueryValueIterator {
        return .{ .pairs = self.query, .key = key };
    }

    /// Returns the single query value for `key`, `null` when the key is
    /// absent, and `error.DuplicateQueryValue` when the key appears more than
    /// once — never silently choosing between duplicate values (§3.4).
    pub fn getOne(self: *const Request, key: []const u8) error{DuplicateQueryValue}!?[]const u8 {
        var found: ?[]const u8 = null;
        var it = self.getAll(key);
        while (it.next()) |value| {
            if (found != null) return error.DuplicateQueryValue;
            found = value;
        }
        return found;
    }

    pub const HeaderIterator = struct {
        headers: []const Header,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *HeaderIterator) ?[]const u8 {
            while (self.index < self.headers.len) {
                const header = self.headers[self.index];
                self.index += 1;
                if (std.ascii.eqlIgnoreCase(header.name, self.name)) return header.value;
            }
            return null;
        }
    };

    /// Returns all values for a header name in wire order.
    pub fn getAllHeaders(self: *const Request, name: []const u8) HeaderIterator {
        return .{ .headers = self.headers, .name = name };
    }

    /// Returns one header value, reporting repeated fields explicitly.
    pub fn getHeaderOne(self: *const Request, name: []const u8) error{DuplicateHeaderValue}!?[]const u8 {
        var found: ?[]const u8 = null;
        var it = self.getAllHeaders(name);
        while (it.next()) |value| {
            if (found != null) return error.DuplicateHeaderValue;
            found = value;
        }
        return found;
    }
};

fn req(method: Method, segments: []const []const u8) Request {
    return .{ .method = method, .segments = segments };
}

test "method-only isGet does not consume a path" {
    var r = req(.get, &.{"users"});
    try std.testing.expect(r.isGet());
    try std.testing.expectEqual(@as(usize, 0), r.cursor);

    var other = req(.post, &.{"users"});
    try std.testing.expect(!other.isGet());
    try std.testing.expectEqual(@as(usize, 0), other.cursor);
}

test "isRoot checks that no segments remain" {
    var empty_path = req(.get, &.{});
    try std.testing.expect(empty_path.isRoot());

    var nonempty = req(.get, &.{"users"});
    try std.testing.expect(!nonempty.isRoot());
    _ = nonempty.onLiteral("users");
    try std.testing.expect(nonempty.isRoot());
}

test "isLiteral consumes only an exact single remaining segment" {
    // Exactly one remaining segment that equals the literal: succeeds.
    var r = req(.get, &.{"users"});
    try std.testing.expect(r.isLiteral("users"));
    try std.testing.expect(r.isRoot());

    // One remaining segment that differs: fails without consuming.
    var other = req(.get, &.{"users"});
    try std.testing.expect(!other.isLiteral("admin"));
    try std.testing.expectEqual(@as(usize, 0), other.cursor);

    // More than one remaining segment: fails even when the first matches.
    var open = req(.get, &.{ "users", "42" });
    try std.testing.expect(!open.isLiteral("users"));
    try std.testing.expectEqual(@as(usize, 0), open.cursor);

    // At the root: fails.
    var root = req(.get, &.{});
    try std.testing.expect(!root.isLiteral("users"));
}

test "failed onLiteral leaves the cursor unchanged" {
    var r = req(.get, &.{ "users", "42" });
    const saved = r.mark();
    try std.testing.expect(!r.onLiteral("admin"));
    try std.testing.expectEqual(saved, r.cursor);
    try std.testing.expect(r.onLiteral("users"));
    try std.testing.expect(!r.onLiteral("extra")); // mismatch at depth.

    var root = req(.get, &.{});
    try std.testing.expect(!root.onLiteral("users"));
    try std.testing.expectEqual(@as(usize, 0), root.cursor);
}

test "onSegment borrows segments without a capture array" {
    var r = req(.get, &.{ "users", "42" });
    const first = r.onSegment().?;
    try std.testing.expectEqualSlices(u8, "users", first);
    // The returned slice aliases request storage; there is no capture copy.
    try std.testing.expect(first.ptr == r.segments[0].ptr);

    const second = r.onSegment().?;
    try std.testing.expectEqualSlices(u8, "42", second);
    try std.testing.expect(second.ptr == r.segments[1].ptr);

    try std.testing.expect(r.isRoot());
}

test "onSegment returns null at the root" {
    var r = req(.get, &.{});
    try std.testing.expect(r.onSegment() == null);
}

test "typed integer prefix parses before consuming" {
    var r = req(.get, &.{ "users", "255", "-128", "0" });
    try std.testing.expect(r.onLiteral("users"));
    try std.testing.expectEqual(@as(?u8, 255), r.onInt(u8));
    try std.testing.expectEqual(@as(?i8, -128), r.onInt(i8));
    try std.testing.expectEqual(@as(?u8, 0), r.onInt(u8));
    const end = r.mark();
    try std.testing.expect(r.onInt(u8) == null);
    try std.testing.expectEqual(end, r.cursor);

    const failures = .{ "256", "-129", "-1", "abc", "12x", "", " 1" };
    inline for (failures) |value| {
        var bad = req(.get, &.{ "users", value });
        try std.testing.expect(bad.onLiteral("users"));
        const saved = bad.mark();
        try std.testing.expect(bad.onInt(if (std.mem.eql(u8, value, "-129")) i8 else u8) == null);
        try std.testing.expectEqual(saved, bad.cursor);
        const raw = bad.onSegment().?;
        try std.testing.expect(raw.ptr == bad.segments[1].ptr);
        try std.testing.expectEqualStrings(value, raw);
    }
}

test "terminal integer matcher and checkpoints preserve borrowed captures" {
    var r = req(.get, &.{ "users", "42", "extra" });
    const outer = r.mark();
    try std.testing.expect(r.onLiteral("users"));
    const inner = r.mark();
    try std.testing.expect(r.isInt(u16) == null); // More than one remains.
    try std.testing.expectEqual(inner, r.cursor);
    try std.testing.expectEqual(@as(?u16, 42), r.onInt(u16));
    const after_number = r.mark();
    try std.testing.expect(r.isInt(u16) == null); // Invalid final value.
    try std.testing.expectEqual(after_number, r.cursor);
    r.restore(inner);
    const borrowed = r.onSegment().?;
    try std.testing.expect(borrowed.ptr == r.segments[1].ptr);
    try std.testing.expectEqualStrings("42", borrowed);
    r.restore(outer);
    try std.testing.expect(r.onLiteral("users"));
    try std.testing.expectEqual(@as(?u16, 42), r.onInt(u16));

    var terminal = req(.get, &.{"65535"});
    try std.testing.expectEqual(@as(?u16, 65535), terminal.isInt(u16));
    try std.testing.expect(terminal.isRoot());
    const end = terminal.mark();
    try std.testing.expect(terminal.isInt(u16) == null);
    try std.testing.expectEqual(end, terminal.cursor);

    var overflow = req(.get, &.{"65536"});
    try std.testing.expect(overflow.isInt(u16) == null);
    try std.testing.expectEqual(@as(usize, 0), overflow.cursor);
}

test "checkpoints apply per request and restore routing state only" {
    var a = req(.get, &.{ "users", "42" });
    var b = req(.get, &.{ "users", "42" });

    _ = a.onLiteral("users");
    _ = b.onLiteral("users");
    const a_saved = a.mark();
    _ = a.onSegment();

    // Checkpoints are positional and do not leak across requests.
    try std.testing.expectEqual(@as(usize, 2), a.cursor);
    b.restore(a_saved);
    try std.testing.expectEqual(@as(usize, 1), b.cursor);
    a.restore(a_saved);
    try std.testing.expectEqual(@as(usize, 1), a.cursor);

    // restore rewinds routing state only; method and segments are untouched.
    try std.testing.expect(a.isGet());
    try std.testing.expectEqualSlices(u8, "42", a.segments[1]);
}

test "nested failed branch restores transparently" {
    var r = req(.get, &.{"users"});
    const saved = r.mark();

    // A nested match that succeeds, then a deeper failure: the miss leaves
    // the cursor at the nested checkpoint.
    try std.testing.expect(r.onLiteral("users"));
    const opened = r.mark();
    try std.testing.expect(!r.onLiteral("admin"));
    try std.testing.expectEqual(opened, r.cursor);

    // Rewinding to the outer checkpoint reopens the whole branch.
    r.restore(saved);
    try std.testing.expectEqual(@as(usize, 0), r.cursor);
    try std.testing.expect(!r.isRoot());
}

test "explicit branch returns commit the prefix" {
    const Outcome = enum { root, user, committed_404, unmatched };

    const route = struct {
        fn run(request: *Request) Outcome {
            if (request.isRoot() and request.isGet()) return .root;
            if (request.onLiteral("users")) {
                if (request.onSegment()) |_| {
                    if (request.isRoot() and request.isGet()) return .user;
                }
                // Commit this branch; dispatch supplies 404 if unhandled.
                return .committed_404;
            }
            return .unmatched;
        }
    }.run;

    // GET /
    var root = req(.get, &.{});
    try std.testing.expectEqual(Outcome.root, route(&root));

    // GET /users/42
    var user = req(.get, &.{ "users", "42" });
    try std.testing.expectEqual(Outcome.user, route(&user));

    // GET /users must not fall through to the root handler.
    var prefix = req(.get, &.{"users"});
    try std.testing.expectEqual(Outcome.committed_404, route(&prefix));

    // GET /users/42/extra
    var extra = req(.get, &.{ "users", "42", "extra" });
    try std.testing.expectEqual(Outcome.committed_404, route(&extra));

    // GET /users/42/
    var trailing = req(.get, &.{ "users", "42", "" });
    try std.testing.expectEqual(Outcome.committed_404, route(&trailing));

    // POST /users/42
    var post = req(.post, &.{ "users", "42" });
    try std.testing.expectEqual(Outcome.committed_404, route(&post));

    // GET /other
    var other = req(.get, &.{"other"});
    try std.testing.expectEqual(Outcome.unmatched, route(&other));
}

test "consumed prefix cannot fall through to the root route" {
    const Outcome = enum { root, user, committed_404, unmatched };

    // Correct: the users branch commits with an explicit return, so a
    // consumed `/users` never reaches the root handler below.
    const committed = struct {
        fn run(request: *Request) Outcome {
            if (request.onLiteral("users")) {
                if (request.onSegment()) |_| {
                    if (request.isRoot() and request.isGet()) return .user;
                }
                return .committed_404; // branch boundary
            }
            if (request.isRoot() and request.isGet()) return .root;
            return .unmatched;
        }
    }.run;

    var root_path = req(.get, &.{});
    try std.testing.expectEqual(Outcome.root, committed(&root_path));

    // GET /users consumes the prefix and commits; it does not hit the root.
    var users = req(.get, &.{"users"});
    try std.testing.expectEqual(Outcome.committed_404, committed(&users));
    try std.testing.expect(users.isRoot()); // consumed, yet committed

    var user = req(.get, &.{ "users", "42" });
    try std.testing.expectEqual(Outcome.user, committed(&user));

    // Broken for contrast: without the branch `return`, a consumed `/users`
    // is root by the time control reaches the root handler, so it is served
    // as the root route — the fall-through the convention forbids.
    const fallen_through = struct {
        fn run(request: *Request) Outcome {
            if (request.onLiteral("users")) {
                if (request.onSegment()) |_| {
                    if (request.isRoot() and request.isGet()) return .user;
                }
                // missing branch return
            }
            if (request.isRoot() and request.isGet()) return .root;
            return .unmatched;
        }
    }.run;

    var fallthrough = req(.get, &.{"users"});
    try std.testing.expectEqual(Outcome.root, fallen_through(&fallthrough));
}

test "delegated branches use return child(...)" {
    const Outcome = enum { root, user, committed_404, unmatched };

    const child = struct {
        fn run(request: *Request) Outcome {
            if (request.isRoot() and request.isGet()) return .user;
            return .committed_404;
        }
    }.run;

    // A whole branch is delegated with `return child(request, id)`; the child
    // decides and returns to the caller.
    const parent = struct {
        fn run(request: *Request) Outcome {
            if (request.isRoot() and request.isGet()) return .root;
            if (request.onLiteral("users")) {
                if (request.onSegment()) |_| {
                    return child(request);
                }
                return .committed_404;
            }
            return .unmatched;
        }
    }.run;

    var root_path = req(.get, &.{});
    try std.testing.expectEqual(Outcome.root, parent(&root_path));

    var user = req(.get, &.{ "users", "42" });
    try std.testing.expectEqual(Outcome.user, parent(&user));

    var extra = req(.get, &.{ "users", "42", "extra" });
    try std.testing.expectEqual(Outcome.committed_404, parent(&extra));

    var users = req(.get, &.{"users"});
    try std.testing.expectEqual(Outcome.committed_404, parent(&users));

    // Broken for contrast: discarding the child's result loses the branch
    // decision; the parent continues past the delegated branch.
    const lost_child = struct {
        fn run(request: *Request) Outcome {
            if (request.onLiteral("users")) {
                if (request.onSegment()) |_| {
                    _ = child(request); // missing `return`
                }
                return .unmatched; // reached after the delegated branch
            }
            return .unmatched;
        }
    }.run;

    var user_lost = req(.get, &.{ "users", "42" });
    try std.testing.expectEqual(Outcome.unmatched, lost_child(&user_lost));
}

test "slash rules preserve trailing and repeated slash segments" {
    // `/users/` (["users", ""]) and `/users` (["users"]) stay distinct.
    var bare = req(.get, &.{"users"});
    try std.testing.expect(bare.onLiteral("users"));
    try std.testing.expect(bare.isRoot());

    var trailing = req(.get, &.{ "users", "" });
    try std.testing.expect(trailing.onLiteral("users"));
    try std.testing.expect(!trailing.isRoot());
    try std.testing.expect(trailing.onLiteral(""));
    try std.testing.expect(trailing.isRoot());

    // Repeated slashes produce empty leading segments: match them explicitly.
    var repeated = req(.get, &.{ "", "users" });
    try std.testing.expect(repeated.onLiteral(""));
    try std.testing.expectEqualSlices(u8, "users", repeated.onSegment().?);
    try std.testing.expect(repeated.isRoot());
}

test "query getAll preserves order, duplicates, and case sensitivity" {
    const pairs: []const QueryPair = &.{
        .{ .key = "tag", .value = "one" },
        .{ .key = "sort", .value = "asc" },
        .{ .key = "tag", .value = "two" },
        .{ .key = "TAG", .value = "case-matters" },
        .{ .key = "tag", .value = "three" },
    };
    var r = req(.get, &.{});
    r.query = pairs;

    // getAll returns every duplicate value in request order.
    var all = r.getAll("tag");
    try std.testing.expectEqualStrings("one", all.next().?);
    try std.testing.expectEqualStrings("two", all.next().?);
    try std.testing.expectEqualStrings("three", all.next().?);
    try std.testing.expect(all.next() == null);

    // Query key matching is exact: "TAG" is a distinct key.
    var other = r.getAll("TAG");
    try std.testing.expectEqualStrings("case-matters", other.next().?);
    try std.testing.expect(other.next() == null);

    // getOne reports duplicates instead of choosing a value.
    try std.testing.expectError(error.DuplicateQueryValue, r.getOne("tag"));
    try std.testing.expectEqualStrings("asc", (try r.getOne("sort")).?);
    try std.testing.expect((try r.getOne("absent")) == null);
}
