//! Inertia.js page responses and redirects, inspired by inertia-roda.
//!
//! `Inertia(SharedProps)` is a registered instance. Routes choose the
//! component and pass typed props explicitly:
//!
//!     ctx.plugins.inertia.render(req, res, "Users/Show", .{ .user = user })
//!     ctx.plugins.inertia.redirect(req, res, "/users")
//!     ctx.plugins.inertia.location(req, res, "https://billing.example/")
//!
//! Implemented protocol subset:
//! - An ordinary visit gets the configured HTML layout with its single
//!   `@inertia` marker replaced by the page object
//!   `{component, props, url, version}` and an empty root element. The
//!   default `.script` form is the one Inertia v3 reads:
//!   `<script data-page="app" type="application/json">` with `<`, `>`, and
//!   `&` written as `\u003c`, `\u003e`, and `\u0026`, then `<div id="app">`.
//!   `.attribute` writes `<div id="app" data-page="...">` with the JSON
//!   HTML-attribute escaped, for v1 and v2 clients.
//! - `X-Inertia: true` gets the same page object as `application/json` with
//!   `X-Inertia: true`. Both forms add `Vary: X-Inertia`.
//! - An Inertia GET whose `X-Inertia-Version` differs from the configured
//!   version gets `409`. A missing field counts as the empty version, because
//!   clients omit it when the page version is empty. The conflict sets
//!   `X-Inertia-Location` to the request target. The check runs inside
//!   `render`, so only rendering routes perform it, and never for non-Inertia
//!   or non-GET requests.
//! - `props.errors` is always an object (`{}` unless a route or shared prop
//!   supplies it), and configured shared props are named in `sharedProps`.
//! - `redirect` sends a local path with 302 after GET/HEAD and 303 otherwise,
//!   or 409 and `X-Inertia-Redirect` for an Inertia request to a path with a
//!   fragment, which XHR would drop. `location` forces a full visit: 409 and
//!   `X-Inertia-Location` for an Inertia request, a plain 302/303 otherwise.
//!
//! - Partial reloads: when `X-Inertia-Partial-Component` equals the rendered
//!   component, `X-Inertia-Partial-Data` keeps only the listed props and
//!   `X-Inertia-Partial-Except` removes listed props, winning over `-Data`.
//!   Filtering is top-level: `a.b` in `-Data` keeps all of `a`, and `a.b` in
//!   `-Except` removes nothing. Shared props are filtered the same way;
//!   `errors` is always sent. `optional(context, resolve)` props are resolved
//!   only for a partial reload that asks for them; `always(value)` props
//!   ignore both lists.
//! - Deferred props: `deferred(context, resolve)` and
//!   `deferredGroup(group, context, resolve)` are left out of full visits
//!   without being resolved and listed in the page as
//!   `deferredProps: {group: [names]}`. The client then requests each group
//!   with a partial reload, which resolves them like `optional` props and
//!   sends no `deferredProps`.
//! - Merge props: `merge(prop)`, `prepend(prop)`, and `deepMerge(prop)` wrap
//!   a plain, `optional`, or `deferred` prop. When the prop is in `props`,
//!   its name is listed in `mergeProps`, `prependProps`, or `deepMergeProps`,
//!   and each `.matchOn(key)` adds `name.key` to `matchPropsOn`. The client
//!   merges them into its current props on a partial reload. Props named in
//!   `X-Inertia-Reset` on such a reload are sent without the listing, so the
//!   client replaces them.
//! - Scroll props: `scroll(prop, .{ .current = n, .next = ..., ... })` is a
//!   merge prop for `<InfiniteScroll>`. When it is in `props`, the page also
//!   carries `scrollProps: {name: {pageName, previousPage, nextPage,
//!   currentPage, reset}}`, and it is listed in `prependProps` when a partial
//!   reload sends `X-Inertia-Infinite-Scroll-Merge-Intent: prepend`, else in
//!   `mergeProps`. `reset` is true when `X-Inertia-Reset` names it. The route
//!   reads the page number from its own query parameter and pages its data
//!   itself.
//! - Once props: `once(context, resolve)` is resolved like a plain prop and
//!   listed in `onceProps: {key: {prop, expiresAt}}`, keyed by the prop name
//!   or `.as(key)`. `.expiresIn(ms)` sets `expiresAt` from the injected
//!   `now_milliseconds` clock. An Inertia visit whose
//!   `X-Inertia-Except-Once-Props` names the key keeps the entry but neither
//!   resolves nor sends the prop, since the client still holds it, unless a
//!   partial reload of the component lists it in `X-Inertia-Partial-Data`.
//!
//! - Flash: `renderWith(..., .{ .flash = .{ .plugin, .session } })` sends the
//!   messages this request received through `zoda.Flash` as the top-level
//!   `flash: {kind: text}`, a later message of a kind replacing an earlier
//!   one, and consumes them once the response is committed. Like the Laravel
//!   and Rails adapters it does so on every render, partial reloads
//!   included: the client cannot be told apart from a deferred-props reload,
//!   whose flash it ignores. A page with no messages has no `flash` field,
//!   which the client reads as `{}`.
//! - Validation errors: `redirectWithErrors(req, res, source, path, errors)`
//!   stores the typed `errors` in the session through `zoda.Flash`, under
//!   the reserved kind `errors_flash_kind`, and redirects to the
//!   route-supplied local `path` with 303. An Inertia request's
//!   `X-Inertia-Error-Bag: name` nests them as `{name: errors}`. The next
//!   `renderWith` with `.flash` sends them as `props.errors`, where route
//!   `errors` win over them and they win over shared `errors`, and consumes
//!   them with the flash messages.
//!
//! Not implemented: once deferred props, history encryption, precognition,
//! and server-side rendering.
//!
//! URL and origin policy: the page `url` and every `X-Inertia-Location` for
//! the current page are the raw origin-form request target, so path and
//! query are preserved byte for byte. No origin is derived from `Host` or
//! forwarded headers; the client resolves the relative URL against the page it
//! is already on. Targets beginning with `//` or containing `\` are refused.
//!
//! Ownership: the response owns every serialized byte. Shared values and the
//! version must outlive the instance; callback results must stay valid until
//! the call that requested them returns. Header-syntax, configuration, and
//! limit failures leave the response unchanged; allocation errors propagate.
const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const http_cache = @import("http_cache.zig");
const flash_mod = @import("flash.zig");
const sessions = @import("sessions.zig");

pub const layout_marker = "@inertia";
pub const html_content_type = "text/html; charset=utf-8";
pub const max_root_id_bytes = 64;
/// Most names one `X-Inertia-Partial-Data`, `-Except`, or `X-Inertia-Reset`
/// field may list.
pub const max_partial_props = 64;
/// Most bytes in one `X-Inertia-Partial-Data`, `-Except`, or
/// `X-Inertia-Reset` value.
pub const max_partial_bytes = 1024;
/// Largest `expiresAt`: the largest integer a JavaScript number holds
/// exactly.
pub const max_once_expires_at: i64 = (1 << 53) - 1;
/// Most bytes in an `X-Inertia-Error-Bag` value.
pub const max_error_bag_bytes = 64;
/// The `zoda.Flash` kind that holds the errors `redirectWithErrors` stores.
/// `renderWith` leaves it out of the page's `flash`; do not add messages of
/// this kind yourself.
pub const errors_flash_kind = "inertia-errors";

pub const HeaderError = error{ DuplicateInertiaHeader, MalformedInertiaHeader, DuplicateVersionHeader };
pub const PartialError = error{ DuplicatePartialHeader, MalformedPartialHeader, PartialHeaderTooLarge };
pub const ScrollError = error{InvalidScrollPageName};
pub const OnceError = error{ OnceClockNotConfigured, InvalidOnceTime };
pub const ConfigError = error{ InvalidLayout, InvalidRootId };
pub const TargetError = error{ MissingRequestTarget, UnsafeRequestTarget };
pub const ErrorBagError = error{ DuplicateErrorBagHeader, MalformedErrorBagHeader };
pub const RenderError = HeaderError || PartialError || ScrollError || OnceError || ConfigError || TargetError || response.HeaderError || error{
    BodyTooLarge,
    InvalidComponent,
};
pub const RedirectError = HeaderError || response.RedirectError || error{InvalidLocation};
pub const ErrorsRedirectError = RedirectError || ErrorBagError || flash_mod.Error;

/// Reports whether `req` is an Inertia visit. Exactly one `X-Inertia` field
/// with the value `true` qualifies; a repeated field or any other value is an
/// error rather than a silent fallback to HTML.
pub fn isInertia(req: *const router.Request) HeaderError!bool {
    const value = req.getHeaderOne("X-Inertia") catch return error.DuplicateInertiaHeader;
    const raw = value orelse return false;
    if (!std.mem.eql(u8, raw, "true")) return error.MalformedInertiaHeader;
    return true;
}

/// Returns the page URL: the raw origin-form target, including its query.
pub fn requestUrl(req: *const router.Request) TargetError![]const u8 {
    const target = req.target;
    if (target.len == 0) return error.MissingRequestTarget;
    if (target[0] != '/' or (target.len > 1 and target[1] == '/')) return error.UnsafeRequestTarget;
    for (target) |c| {
        if (c <= ' ' or c >= 0x7f or c == '\\') return error.UnsafeRequestTarget;
    }
    return target;
}

/// Returns the `X-Inertia-Error-Bag` value: 1 to `max_error_bag_bytes`
/// `[A-Za-z0-9_-]` bytes, or null without the field. A repeated field or
/// any other value is an error.
pub fn errorBag(req: *const router.Request) ErrorBagError!?[]const u8 {
    const value = req.getHeaderOne("X-Inertia-Error-Bag") catch return error.DuplicateErrorBagHeader;
    const bag = value orelse return null;
    if (bag.len == 0 or bag.len > max_error_bag_bytes) return error.MalformedErrorBagHeader;
    for (bag) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.MalformedErrorBagHeader;
    }
    return bag;
}

/// How a prop takes part in partial reloads.
pub const PropKind = enum {
    /// A plain value: sent on full visits and when a partial reload keeps it.
    eager,
    /// Resolved and sent only when a partial reload keeps it.
    optional,
    /// Sent on every visit, whatever the partial reload lists.
    always,
    /// Like `optional`, but full visits list it in `deferredProps` so the
    /// client requests it right after the page loads.
    deferred,
    /// Resolved and sent like `eager`, unless the client says it still
    /// holds the value; listed in `onceProps` either way.
    once,
};

/// The prop type `optional(context, resolve)` returns. `resolve` is
/// `fn (Context, std.mem.Allocator) T` or `... E!T`; `render` calls it at
/// most once, only when the prop is sent, and returns its error unchanged.
pub fn Optional(comptime Context: type, comptime resolve: anytype) type {
    return Lazy(.optional, "", Context, resolve);
}

/// The prop type `deferredGroup(group, context, resolve)` returns. `resolve`
/// follows the `Optional` rules. `group` is 1-64 `[A-Za-z0-9_-]` bytes.
pub fn Deferred(comptime group: []const u8, comptime Context: type, comptime resolve: anytype) type {
    comptime {
        if (group.len == 0 or group.len > 64) @compileError("deferred group names are 1-64 bytes");
        for (group) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) @compileError("deferred group names use [A-Za-z0-9_-]");
        }
    }
    return Lazy(.deferred, group, Context, resolve);
}

fn Lazy(comptime kind: PropKind, comptime group: []const u8, comptime Context: type, comptime resolve: anytype) type {
    const info = @typeInfo(@TypeOf(resolve));
    if (info != .@"fn" or info.@"fn".params.len != 2 or info.@"fn".return_type == null) {
        @compileError(@tagName(kind) ++ " props take fn (context, std.mem.Allocator) T or E!T");
    }
    const Return = info.@"fn".return_type.?;
    const Value, const ResolveError = switch (@typeInfo(Return)) {
        .error_union => |eu| .{ eu.payload, eu.error_set },
        else => .{ Return, error{} },
    };
    return struct {
        pub const inertia_prop: PropKind = kind;
        pub const inertia_group = group;
        pub const Error = ResolveError;
        pub const Resolved = Value;

        context: Context,

        fn resolveIn(self: @This(), allocator: std.mem.Allocator) Error!Value {
            return resolve(self.context, allocator);
        }
    };
}

/// A prop computed only when a partial reload requests it. `allocator` is
/// an arena that `render` frees once the page is serialized, so the result
/// may live there or borrow from `context`.
pub fn optional(context: anytype, comptime resolve: anytype) Optional(@TypeOf(context), resolve) {
    return .{ .context = context };
}

/// A prop left out of full visits and loaded by the client right after the
/// page renders, in the `"default"` group. `resolve` follows the `optional`
/// rules and runs only on the partial reload that requests the prop.
pub fn deferred(context: anytype, comptime resolve: anytype) Deferred("default", @TypeOf(context), resolve) {
    return .{ .context = context };
}

/// Like `deferred`, in the named group. The client requests each group with
/// its own partial reload, so slow props in different groups load in
/// parallel.
pub fn deferredGroup(
    comptime group: []const u8,
    context: anytype,
    comptime resolve: anytype,
) Deferred(group, @TypeOf(context), resolve) {
    return .{ .context = context };
}

/// The prop type `once(context, resolve)` returns, keyed by `key` in
/// `onceProps` and `X-Inertia-Except-Once-Props`, or by the prop's name when
/// `key` is null. `resolve` follows the `Optional` rules. A key is one or more
/// non-empty `.`-separated segments of `[A-Za-z0-9_$-]`.
pub fn Onceable(comptime key: ?[]const u8, comptime Context: type, comptime resolve: anytype) type {
    comptime if (key) |k| checkOnceKey(k);
    const Base = Lazy(.once, "", Context, resolve);
    return struct {
        pub const inertia_prop: PropKind = .once;
        pub const inertia_once_key = key;
        pub const Error = Base.Error;

        context: Context,
        /// How long the client may reuse the value, in milliseconds; null
        /// keeps it until the page is left.
        expires_in_ms: ?u64 = null,

        /// Keys the prop as `new_key`. Props on different pages with the same
        /// key share one value on the client.
        pub fn as(self: @This(), comptime new_key: []const u8) Onceable(new_key, Context, resolve) {
            return .{ .context = self.context, .expires_in_ms = self.expires_in_ms };
        }

        /// Sends `expiresAt` as the clock's time plus `ms`. Once it has
        /// passed, the client stops listing the key and gets a fresh value.
        pub fn expiresIn(self: @This(), ms: u64) @This() {
            return .{ .context = self.context, .expires_in_ms = ms };
        }

        fn resolveIn(self: @This(), allocator: std.mem.Allocator) Error!Base.Resolved {
            return resolve(self.context, allocator);
        }
    };
}

/// The prop type `once(context, resolve)` returns.
pub fn Once(comptime Context: type, comptime resolve: anytype) type {
    return Onceable(null, Context, resolve);
}

/// A prop the client keeps once it has it. `resolve` follows the `optional`
/// rules but runs on every visit that sends the prop, full visits included.
/// Later Inertia visits that list its key in `X-Inertia-Except-Once-Props`
/// skip `resolve` and only list the key in `onceProps`, and the client reuses
/// its value.
pub fn once(context: anytype, comptime resolve: anytype) Once(@TypeOf(context), resolve) {
    return .{ .context = context };
}

fn checkOnceKey(comptime key: []const u8) void {
    var segments = std.mem.splitScalar(u8, key, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0) @compileError("once keys are non-empty dot-separated names");
        for (segment) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$')) {
                @compileError("once key \"" ++ key ++ "\" must use [A-Za-z0-9_$-]");
            }
        }
    }
}

/// The prop type `always(value)` returns.
pub fn Always(comptime T: type) type {
    if (propKind(T) != .eager or mergeMode(T) != null) @compileError("always() takes a plain value, not another prop wrapper");
    return struct {
        pub const inertia_prop: PropKind = .always;

        value: T,
    };
}

/// A prop sent on every visit, even when a partial reload leaves it out.
pub fn always(value: anytype) Always(@TypeOf(value)) {
    return .{ .value = value };
}

/// How a merge prop combines with the client's current value on a partial
/// reload of the same component. Otherwise the client replaces the value.
pub const MergeMode = enum {
    /// `mergeProps`: arrays are appended, objects shallow-merged.
    append,
    /// `prependProps`: arrays are prepended, objects shallow-merged.
    prepend,
    /// `deepMergeProps`: objects are merged recursively, arrays appended.
    deep,
};

/// The prop type `merge`, `prepend`, and `deepMerge` return, wrapping the
/// prop `T` (a plain value, `Optional`, or `Deferred`). Each `match_on` key
/// is matched below the prop: one `[A-Za-z0-9_$-]` field name, or for
/// `.deep` a dot path to an array field such as `data.id`.
pub fn Mergeable(comptime mode: MergeMode, comptime T: type, comptime match_on: []const []const u8) type {
    comptime {
        if (mergeMode(T) != null) @compileError("merge props do not nest");
        if (propKind(T) == .always) @compileError("always props cannot be merged");
        if (propKind(T) == .once) @compileError("once props cannot be merged");
        checkMatchKeys(mode, match_on);
    }
    return struct {
        pub const inertia_merge: MergeMode = mode;
        pub const inertia_match_on = match_on;
        pub const Inner = T;

        inner: T,

        /// Merges array items whose `key` field is equal: the new item
        /// replaces the current one in place instead of being added again.
        pub fn matchOn(self: @This(), comptime key: []const u8) Mergeable(mode, T, match_on ++ .{key}) {
            return .{ .inner = self.inner };
        }
    };
}

fn checkMatchKeys(comptime mode: MergeMode, comptime match_on: []const []const u8) void {
    if (mode != .deep and match_on.len > 1) @compileError("merge, prepend, and scroll props match on one key");
    for (match_on, 0..) |key, i| {
        if (mode != .deep and std.mem.indexOfScalar(u8, key, '.') != null) {
            @compileError("only deepMerge match keys may be dot paths");
        }
        var segments = std.mem.splitScalar(u8, key, '.');
        while (segments.next()) |segment| {
            if (segment.len == 0) @compileError("match keys are non-empty dot-separated names");
            for (segment) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$')) {
                    @compileError("match key \"" ++ key ++ "\" must use [A-Za-z0-9_$-]");
                }
            }
        }
        for (match_on[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, key)) @compileError("match key \"" ++ key ++ "\" is repeated");
        }
    }
}

/// The prop type `merge(prop)` returns.
pub fn Merge(comptime T: type) type {
    return Mergeable(.append, T, &.{});
}

/// The prop type `prepend(prop)` returns.
pub fn Prepend(comptime T: type) type {
    return Mergeable(.prepend, T, &.{});
}

/// The prop type `deepMerge(prop)` returns.
pub fn DeepMerge(comptime T: type) type {
    return Mergeable(.deep, T, &.{});
}

/// A prop whose items a partial reload appends to the client's current
/// array (or whose fields it adds to the current object). `prop` is a plain
/// value, `optional(...)`, or `deferred(...)`.
pub fn merge(prop: anytype) Merge(@TypeOf(prop)) {
    return .{ .inner = prop };
}

/// Like `merge`, but new array items go before the current ones.
pub fn prepend(prop: anytype) Prepend(@TypeOf(prop)) {
    return .{ .inner = prop };
}

/// Like `merge`, but objects are merged recursively, so nested arrays are
/// appended and nested fields kept.
pub fn deepMerge(prop: anytype) DeepMerge(@TypeOf(prop)) {
    return .{ .inner = prop };
}

/// `X-Inertia-Infinite-Scroll-Merge-Intent`: where `<InfiniteScroll>` puts
/// the page it is loading.
pub const MergeIntent = enum {
    /// The next page, after the current items.
    append,
    /// The previous page, before them.
    prepend,
};

/// Pagination state of a `scroll` prop, sent as its `scrollProps` entry.
/// `<InfiniteScroll>` loads `previous` or `next` with a partial reload that
/// sets the query parameter `page_name` to that number; null means there is
/// no such page. `page_name` is 1-64 `[A-Za-z0-9_-]` bytes.
pub const ScrollPage = struct {
    page_name: []const u8 = "page",
    previous: ?u32 = null,
    next: ?u32 = null,
    current: u32,
};

/// The prop type `scroll(prop, page)` returns, wrapping the prop `T` (a
/// plain value, `Optional`, or `Deferred`) that holds one page of items.
/// `match_on` follows the `merge` rules.
pub fn Scrollable(comptime T: type, comptime match_on: []const []const u8) type {
    comptime {
        if (mergeMode(T) != null) @compileError("scroll props do not wrap merge props");
        if (propKind(T) == .always) @compileError("always props cannot be scroll props");
        if (propKind(T) == .once) @compileError("once props cannot be scroll props");
        checkMatchKeys(.append, match_on);
    }
    return struct {
        /// The listing a full visit uses; partial reloads follow the merge
        /// intent instead.
        pub const inertia_merge: MergeMode = .append;
        pub const inertia_scroll = true;
        pub const inertia_match_on = match_on;
        pub const Inner = T;

        inner: T,
        page: ScrollPage,

        /// Like `Mergeable.matchOn`: a loaded item whose `key` field equals a
        /// current one replaces it in place.
        pub fn matchOn(self: @This(), comptime key: []const u8) Scrollable(T, match_on ++ .{key}) {
            return .{ .inner = self.inner, .page = self.page };
        }
    };
}

/// The prop type `scroll(prop, page)` returns.
pub fn Scroll(comptime T: type) type {
    return Scrollable(T, &.{});
}

/// One page of items for `<InfiniteScroll data="name">`, with its pagination
/// state. The client appends the next page and prepends the previous one.
pub fn scroll(prop: anytype, page: ScrollPage) Scroll(@TypeOf(prop)) {
    return .{ .inner = prop, .page = page };
}

pub fn mergeMode(comptime T: type) ?MergeMode {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "inertia_merge")) return T.inertia_merge;
    return null;
}

/// The prop a merge wrapper holds, or `T` itself.
fn Unmerged(comptime T: type) type {
    return if (mergeMode(T) != null) T.Inner else T;
}

/// The kind of `T`, or of the prop a merge wrapper holds.
pub fn propKind(comptime T: type) PropKind {
    const U = Unmerged(T);
    if (@typeInfo(U) == .@"struct" and @hasDecl(U, "inertia_prop")) return U.inertia_prop;
    return .eager;
}

/// The errors the `optional`, `deferred`, and `once` props of the struct
/// `P` can return.
pub fn PropsError(comptime P: type) type {
    comptime var E = error{};
    inline for (std.meta.fields(P)) |field| {
        switch (comptime propKind(field.type)) {
            .optional, .deferred, .once => E = E || Unmerged(field.type).Error,
            .eager, .always => {},
        }
    }
    return E;
}

/// The validated partial-reload lists for the component being rendered.
/// Each list is the raw comma-separated header value.
pub const Partial = struct {
    only: ?[]const u8 = null,
    except: ?[]const u8 = null,
    /// `X-Inertia-Reset`: merge props the client replaces this time.
    reset: ?[]const u8 = null,
    /// How scroll props merge on this reload.
    merge_intent: MergeIntent = .append,

    /// Reports whether the prop `name` belongs in the page. `partial` is null
    /// for a full visit.
    pub fn wants(partial: ?Partial, name: []const u8, kind: PropKind) bool {
        if (kind == .always) return true;
        const p = partial orelse return kind == .eager or kind == .once;
        // `a.b` keeps all of `a`; filtering never goes below the top level.
        if (p.only) |list| if (!listNames(list, name, .first_segment)) return false;
        // Only a whole top-level name removes a prop, so `a.b` keeps `a`.
        if (p.except) |list| if (listNames(list, name, .exact)) return false;
        return true;
    }

    /// Reports whether the merge prop `name` is sent without its merge
    /// listing. Only a whole top-level name resets a prop.
    pub fn resets(partial: ?Partial, name: []const u8) bool {
        const p = partial orelse return false;
        return listNames(p.reset orelse return false, name, .exact);
    }

    fn listNames(list: []const u8, name: []const u8, match: enum { exact, first_segment }) bool {
        var items = std.mem.splitScalar(u8, list, ',');
        while (items.next()) |item| {
            const key = switch (match) {
                .exact => item,
                .first_segment => item[0 .. std.mem.indexOfScalar(u8, item, '.') orelse item.len],
            };
            if (std.mem.eql(u8, key, name)) return true;
        }
        return false;
    }
};

/// Reads `X-Inertia-Except-Once-Props`: the once keys the client still
/// holds. It follows the partial-list rules and errors.
pub fn exceptOnceProps(req: *const router.Request) PartialError!?[]const u8 {
    return partialList(req, "X-Inertia-Except-Once-Props");
}

/// Reads the partial-reload headers of an Inertia request, including
/// `X-Inertia-Reset` and `X-Inertia-Infinite-Scroll-Merge-Intent`. All five
/// are validated whatever the component; the result is null unless
/// `X-Inertia-Partial-Component` equals `component`.
pub fn partialReload(req: *const router.Request, component: []const u8) PartialError!?Partial {
    const target = req.getHeaderOne("X-Inertia-Partial-Component") catch return error.DuplicatePartialHeader;
    const only = try partialList(req, "X-Inertia-Partial-Data");
    const except = try partialList(req, "X-Inertia-Partial-Except");
    const reset = try partialList(req, "X-Inertia-Reset");
    const intent = try mergeIntent(req);
    if (!std.mem.eql(u8, target orelse return null, component)) return null;
    return .{ .only = only, .except = except, .reset = reset, .merge_intent = intent };
}

/// Accepts exactly `append` or `prepend`; a missing field means `append`.
fn mergeIntent(req: *const router.Request) PartialError!MergeIntent {
    const value = (req.getHeaderOne("X-Inertia-Infinite-Scroll-Merge-Intent") catch return error.DuplicatePartialHeader) orelse return .append;
    return std.meta.stringToEnum(MergeIntent, value) orelse error.MalformedPartialHeader;
}

/// Accepts 1 to `max_partial_props` comma-separated names in at most
/// `max_partial_bytes`. A name is one or more dot-separated non-empty
/// segments of `[A-Za-z0-9_$-]`; spaces and empty items are malformed.
/// Accepts 1-64 `[A-Za-z0-9_-]` bytes: a query parameter name the route
/// can read back without decoding.
fn checkPageName(name: []const u8) ScrollError!void {
    if (name.len == 0 or name.len > 64) return error.InvalidScrollPageName;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.InvalidScrollPageName;
    }
}

fn partialList(req: *const router.Request, name: []const u8) PartialError!?[]const u8 {
    const value = (req.getHeaderOne(name) catch return error.DuplicatePartialHeader) orelse return null;
    if (value.len > max_partial_bytes) return error.PartialHeaderTooLarge;
    var count: usize = 0;
    var items = std.mem.splitScalar(u8, value, ',');
    while (items.next()) |item| {
        count += 1;
        if (count > max_partial_props) return error.PartialHeaderTooLarge;
        var segments = std.mem.splitScalar(u8, item, '.');
        while (segments.next()) |segment| {
            if (segment.len == 0) return error.MalformedPartialHeader;
            for (segment) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$')) return error.MalformedPartialHeader;
            }
        }
    }
    return value;
}

/// Where `renderWith` reads flash messages and stored validation errors, and
/// `redirectWithErrors` stores errors: the registered `zoda.Flash` and this
/// request's session state.
pub const FlashSource = struct {
    plugin: *const flash_mod.Flash,
    session: *sessions.Sessions.State,
};

/// Per-call additions to `render`.
pub const RenderOptions = struct {
    /// Sends the messages this request received as the page's top-level
    /// `flash`, and errors stored by `redirectWithErrors` as `props.errors`,
    /// and consumes them. Call `Sessions.save` after `renderWith` to persist
    /// the consumption.
    flash: ?FlashSource = null,
};

pub fn Inertia(comptime SharedProps: type) type {
    comptime if (@typeInfo(SharedProps) != .@"struct") @compileError("Inertia shared props must be a struct");
    return struct {
        const Self = @This();

        /// Props merged into every page. Route props with the same name win.
        pub const Shared = union(enum) {
            none,
            value: SharedProps,
            callback: *const fn (*const router.Request) SharedProps,
        };

        /// Asset version. `.none` sends `"version":null` and skips the check.
        pub const Version = union(enum) {
            none,
            value: []const u8,
            callback: *const fn (*const router.Request) []const u8,
        };

        /// Complete HTML document containing `@inertia` exactly once. It owns
        /// the page layout and asset tags and is copied verbatim.
        layout: []const u8,
        /// `id` of the generated root element: 1-64 `[A-Za-z0-9_-]` bytes.
        root_id: []const u8 = "app",
        /// Where the initial page object goes; match the client's version.
        initial_page: InitialPage = .script,
        version: Version = .none,
        shared: Shared = .none,
        /// UTC Unix milliseconds for once props' `expiresAt`. Supply a
        /// trusted wall clock; tests can inject one. Read at most once per
        /// `render`, and only when a listed once prop has an expiry.
        now_milliseconds: ?*const fn () i64 = null,

        /// Checks the layout and root id. `render` repeats the check, so
        /// calling this at startup only reports mistakes earlier.
        pub fn validate(self: *const Self) ConfigError!void {
            _ = try self.layoutParts();
            if (self.root_id.len == 0 or self.root_id.len > max_root_id_bytes) return error.InvalidRootId;
            for (self.root_id) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidRootId;
            }
        }

        /// The errors `render` can return for route props of type `Props`:
        /// its own, plus those of every `optional` or `deferred` route or
        /// shared prop.
        pub fn Error(comptime Props: type) type {
            return RenderError || PropsError(SharedProps) || PropsError(Props);
        }

        /// Renders `component` with the struct `props`, as HTML or as an
        /// Inertia JSON page depending on `X-Inertia`, with status 200. A
        /// stale asset version on an Inertia GET produces the 409 conflict
        /// instead. A partial reload for `component` sends only the props it
        /// asks for.
        pub fn render(
            self: *const Self,
            req: *const router.Request,
            res: *response.Response,
            component: []const u8,
            props: anytype,
        ) Error(@TypeOf(props))!void {
            return self.renderWith(req, res, component, props, .{});
        }

        /// `render` with per-call options. With `options.flash`, the page
        /// carries the received flash messages and stored validation errors,
        /// which are marked read once the response is committed; on an error
        /// or a version conflict they stay unread.
        pub fn renderWith(
            self: *const Self,
            req: *const router.Request,
            res: *response.Response,
            component: []const u8,
            props: anytype,
            options: RenderOptions,
        ) Error(@TypeOf(props))!void {
            comptime {
                const info = @typeInfo(@TypeOf(props));
                if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".fields.len != 0)) {
                    @compileError("Inertia props must be a struct with named fields");
                }
            }
            try self.validate();
            const inertia = try isInertia(req);
            // Partial headers only mean something on Inertia visits.
            const partial = if (inertia) try partialReload(req, component) else null;
            const once_visit: OnceVisit = .{
                .except = if (inertia) try exceptOnceProps(req) else null,
                .clock = self.now_milliseconds,
            };
            const url = try requestUrl(req);
            const version = self.currentVersion(req);
            if (inertia and req.method == .get) {
                if (version) |current| {
                    const sent = req.getHeaderOne("X-Inertia-Version") catch return error.DuplicateVersionHeader;
                    if (!std.mem.eql(u8, sent orelse "", current)) return conflict(res, url);
                }
            }
            if (component.len == 0) return error.InvalidComponent;

            // Partial reloads get flash too: other than deferred-props
            // reloads, which no header marks, the client fires flash events
            // for them. A deferred reload follows a full visit that has
            // already consumed the messages.
            const flash = options.flash;
            const messages = if (flash) |source| source.plugin.peek(source.session) else null;
            const page = try self.pageJson(res.allocator, req, partial, once_visit, component, props, url, version, messages);
            if (inertia) {
                var committed = false;
                defer if (!committed) res.allocator.free(page);
                if (page.len > res.limits.max_body_bytes) return error.BodyTooLarge;
                try reserveHeaders(res, 1, "X-Inertia".len + "true".len);
                try res.setHeader("X-Inertia", "true");
                try addInertiaVary(res);
                try commitBody(res, response.json_content_type, page);
                committed = true;
            } else {
                defer res.allocator.free(page);
                const body = try self.htmlBody(res, page);
                var committed = false;
                defer if (!committed) res.allocator.free(body);
                try reserveHeaders(res, 0, 0);
                try addInertiaVary(res);
                try commitBody(res, html_content_type, body);
                committed = true;
            }
            // Consume only what was sent: nothing above can fail any more.
            if (flash) |source| _ = source.plugin.read(source.session);
        }

        /// Redirects to a local path (the `Response.redirectPath` rules) with
        /// 302 after GET/HEAD and 303 after any other method, so the browser
        /// and the Inertia client follow with GET. XHR drops the fragment of
        /// a followed redirect, so an Inertia request for a path with `#`
        /// instead gets 409 and `X-Inertia-Redirect`, which v3 clients visit
        /// with GET while keeping the fragment.
        pub fn redirect(
            _: *const Self,
            req: *const router.Request,
            res: *response.Response,
            path: []const u8,
        ) RedirectError!void {
            return sendRedirect(req, res, followUpStatus(req), path);
        }

        /// Stores `errors`, a struct such as `.{ .text = "Required" }`, in the
        /// session for the next `renderWith` with `.flash`, then redirects to
        /// the local `path` with 303, or with 409 and `X-Inertia-Redirect`
        /// like `redirect` when it has a fragment. Pass the form's page, built
        /// by the route: `Referer` is never read. On an Inertia request,
        /// `X-Inertia-Error-Bag: name` nests them as `{name: errors}`. Null
        /// optional fields are left out. Call `Sessions.save` afterwards.
        /// Any failure, including `error.FlashTooLarge` for errors that do
        /// not fit the flash budget, leaves the response and session
        /// unchanged.
        pub fn redirectWithErrors(
            _: *const Self,
            req: *const router.Request,
            res: *response.Response,
            source: FlashSource,
            path: []const u8,
            errors: anytype,
        ) ErrorsRedirectError!void {
            comptime {
                const info = @typeInfo(@TypeOf(errors));
                if (info != .@"struct" or info.@"struct".is_tuple) @compileError("Inertia errors must be a struct with named fields");
            }
            const inertia = try isInertia(req);
            const bag = if (inertia) try errorBag(req) else null;
            var buffer: [flash_mod.max_bytes]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var json: std.json.Stringify = .{ .writer = &out, .options = .{ .emit_null_optional_fields = false } };
            encodeErrors(&json, bag, errors) catch return error.FlashTooLarge;
            try checkRedirect(inertia, res, path);
            try source.plugin.add(source.session, errors_flash_kind, out.buffered());
            return sendRedirect(req, res, .see_other, path);
        }

        fn encodeErrors(json: *std.json.Stringify, bag: ?[]const u8, errors: anytype) std.json.Stringify.Error!void {
            if (bag) |name| {
                try json.beginObject();
                try json.objectField(name);
            }
            try json.write(errors);
            if (bag != null) try json.endObject();
        }

        /// Forces a full page visit to a local path or an absolute `http(s)`
        /// URL without userinfo. Inertia requests get 409 and
        /// `X-Inertia-Location`; other requests get a 302/303 `Location`.
        pub fn location(
            _: *const Self,
            req: *const router.Request,
            res: *response.Response,
            destination: []const u8,
        ) RedirectError!void {
            try validateLocation(destination);
            const inertia = try isInertia(req);
            var existing = res.getAllHeaders(if (inertia) "X-Inertia-Location" else "Location");
            if (existing.next() != null) return error.LocationAlreadySet;
            if (!inertia) {
                try res.setHeader("Location", destination);
                emptyBody(res, @intFromEnum(followUpStatus(req)));
                return;
            }
            try reserveHeaders(res, 1, "X-Inertia-Location".len + destination.len);
            try res.setHeader("X-Inertia-Location", destination);
            try addInertiaVary(res);
            emptyBody(res, 409);
        }

        fn layoutParts(self: *const Self) ConfigError!struct { []const u8, []const u8 } {
            const at = std.mem.indexOf(u8, self.layout, layout_marker) orelse return error.InvalidLayout;
            const after = self.layout[at + layout_marker.len ..];
            if (std.mem.indexOf(u8, after, layout_marker) != null) return error.InvalidLayout;
            return .{ self.layout[0..at], after };
        }

        fn currentVersion(self: *const Self, req: *const router.Request) ?[]const u8 {
            return switch (self.version) {
                .none => null,
                .value => |value| value,
                .callback => |callback| callback(req),
            };
        }

        fn pageJson(
            self: *const Self,
            allocator: std.mem.Allocator,
            req: *const router.Request,
            partial: ?Partial,
            once_visit: OnceVisit,
            component: []const u8,
            props: anytype,
            url: []const u8,
            version: ?[]const u8,
            flash: ?flash_mod.Messages,
        ) (error{OutOfMemory} || ScrollError || OnceError || PropsError(SharedProps) || PropsError(@TypeOf(props)))![]u8 {
            const shared: ?SharedProps = switch (self.shared) {
                .none => null,
                .value => |value| value,
                .callback => |callback| callback(req),
            };
            // `optional`, `deferred`, and `once` results live here until
            // serialized.
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer };
            try writePage(&json, arena.allocator(), partial, once_visit, component, shared, props, url, version, flash);
            return out.toOwnedSlice();
        }

        /// Writes the page. The writer allocates, so its only failures are
        /// `OutOfMemory`, an invalid scroll page name, and a once expiry
        /// error; any other error came from an `optional`, `deferred`, or
        /// `once` prop.
        fn writePage(
            json: *std.json.Stringify,
            arena: std.mem.Allocator,
            partial: ?Partial,
            once_visit: OnceVisit,
            component: []const u8,
            shared: ?SharedProps,
            props: anytype,
            url: []const u8,
            version: ?[]const u8,
            flash: ?flash_mod.Messages,
        ) (error{OutOfMemory} || ScrollError || OnceError || PropsError(SharedProps) || PropsError(@TypeOf(props)))!void {
            const P = @TypeOf(props);
            // Route `errors` win over stored ones, which win over shared ones.
            const stored = if (comptime @hasField(P, "errors")) null else if (flash) |messages| try storedErrors(arena, messages) else null;
            json.beginObject() catch return error.OutOfMemory;
            try writeField(json, "component", component);
            json.objectField("props") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            if (shared) |value| {
                inline for (std.meta.fields(SharedProps)) |field| {
                    const replaced = comptime std.mem.eql(u8, field.name, "errors");
                    if (comptime !@hasField(P, field.name)) {
                        if (!replaced or stored == null) {
                            try writeProp(json, arena, partial, once_visit, field.name, @field(value, field.name));
                        }
                    }
                }
            }
            inline for (std.meta.fields(P)) |field| {
                try writeProp(json, arena, partial, once_visit, field.name, @field(props, field.name));
            }
            // Clients treat `errors` as always present, as Laravel sends it.
            const shared_errors = shared != null and @hasField(SharedProps, "errors");
            if (stored) |text| {
                json.objectField("errors") catch return error.OutOfMemory;
                json.print("{s}", .{text}) catch return error.OutOfMemory;
            } else if (comptime !@hasField(P, "errors")) {
                if (!shared_errors) try writeField(json, "errors", struct {}{});
            }
            json.endObject() catch return error.OutOfMemory;
            try writeField(json, "url", url);
            try writeField(json, "version", version);
            try writeMerge(json, partial, shared != null, comptime mergeProps(P));
            try writeScroll(json, partial, shared, props, comptime mergeProps(P));
            // Only full visits announce deferred props; a partial reload
            // either resolves them or leaves them to the client.
            if (partial == null) try writeDeferred(json, shared != null, comptime deferredProps(P));
            try writeOnce(json, partial, once_visit, shared, props, comptime onceProps(P));
            if (shared != null) {
                // v3 carries these props over to instant client-side visits.
                // The list names every shared prop, even on partial reloads.
                json.objectField("sharedProps") catch return error.OutOfMemory;
                json.beginArray() catch return error.OutOfMemory;
                inline for (std.meta.fields(SharedProps)) |field| {
                    json.write(field.name) catch return error.OutOfMemory;
                }
                json.endArray() catch return error.OutOfMemory;
            }
            if (flash) |messages| try writeFlash(json, messages);
            json.endObject() catch return error.OutOfMemory;
        }

        /// The errors `redirectWithErrors` stored, the last entry of
        /// `errors_flash_kind` winning. One that is not a JSON object, which
        /// only a hand-added message can be, is ignored.
        fn storedErrors(arena: std.mem.Allocator, messages: flash_mod.Messages) error{OutOfMemory}!?[]const u8 {
            var it = messages;
            var found: ?[]const u8 = null;
            while (it.next()) |message| {
                if (std.mem.eql(u8, message.kind, errors_flash_kind)) found = message.text;
            }
            const text = found orelse return null;
            if (text.len == 0 or text[0] != '{' or !try std.json.validate(arena, text)) return null;
            return text;
        }

        /// Writes `flash` as `{kind: text}` in the order each kind was last
        /// added, so a later message of a kind replaces an earlier one, as
        /// the client's `router.flash(key, value)` does. Leaves the field out
        /// when there are no messages other than stored errors.
        fn writeFlash(json: *std.json.Stringify, messages: flash_mod.Messages) error{OutOfMemory}!void {
            var shown = messages;
            while (shown.next()) |message| {
                if (!std.mem.eql(u8, message.kind, errors_flash_kind)) break;
            } else return;
            json.objectField("flash") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            var it = messages;
            while (it.next()) |message| {
                if (std.mem.eql(u8, message.kind, errors_flash_kind)) continue;
                var later = it;
                const replaced = while (later.next()) |next| {
                    if (std.mem.eql(u8, next.kind, message.kind)) break true;
                } else false;
                if (!replaced) try writeField(json, message.kind, message.text);
            }
            json.endObject() catch return error.OutOfMemory;
        }

        const DeferredProp = struct { group: []const u8, name: []const u8, shared: bool };

        /// The deferred props of a page with route props `P`, shared ones
        /// first, leaving out shared props that a route prop overrides.
        fn deferredProps(comptime P: type) []const DeferredProp {
            var found: []const DeferredProp = &.{};
            for (.{ SharedProps, P }, .{ true, false }) |T, is_shared| {
                for (std.meta.fields(T)) |field| {
                    if (propKind(field.type) != .deferred) continue;
                    if (is_shared and @hasField(P, field.name)) continue;
                    checkListedName("deferred", field.name);
                    found = found ++ .{DeferredProp{ .group = Unmerged(field.type).inertia_group, .name = field.name, .shared = is_shared }};
                }
            }
            return found;
        }

        /// Checks the name of a prop the page lists by name. The client sends
        /// it back in `X-Inertia-Partial-Data` and reads it as a dot path.
        fn checkListedName(comptime what: []const u8, comptime name: []const u8) void {
            if (std.mem.eql(u8, name, "errors")) @compileError("the errors prop cannot be " ++ what);
            if (name.len == 0) @compileError(what ++ " prop names cannot be empty");
            for (name) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$')) {
                    @compileError(what ++ " prop \"" ++ name ++ "\" must be named with [A-Za-z0-9_$-]");
                }
            }
        }

        const OnceProp = struct { name: []const u8, key: []const u8, shared: bool };

        /// The once props of a page with route props `P`, shared ones first,
        /// leaving out shared props that a route prop overrides. Keys are
        /// unique, since each is one `onceProps` field.
        fn onceProps(comptime P: type) []const OnceProp {
            var found: []const OnceProp = &.{};
            for (.{ SharedProps, P }, .{ true, false }) |T, is_shared| {
                for (std.meta.fields(T)) |field| {
                    if (propKind(field.type) != .once) continue;
                    if (is_shared and @hasField(P, field.name)) continue;
                    checkListedName("once", field.name);
                    const key = field.type.inertia_once_key orelse field.name;
                    for (found) |earlier| {
                        if (std.mem.eql(u8, earlier.key, key)) {
                            @compileError("once props \"" ++ earlier.name ++ "\" and \"" ++ field.name ++ "\" share the key \"" ++ key ++ "\"");
                        }
                    }
                    found = found ++ .{OnceProp{ .name = field.name, .key = key, .shared = is_shared }};
                }
            }
            return found;
        }

        /// Writes `onceProps` as `{key: {prop, expiresAt}}` for the once
        /// props this page would send, whether or not the client already
        /// holds them, in declaration order, and leaves it out when there
        /// are none. `expiresAt` is null without an expiry.
        fn writeOnce(
            json: *std.json.Stringify,
            partial: ?Partial,
            once_visit: OnceVisit,
            shared: ?SharedProps,
            props: anytype,
            comptime list: []const OnceProp,
        ) (error{OutOfMemory} || OnceError)!void {
            var now: ?i64 = null;
            var started = false;
            inline for (list) |prop| {
                if ((!prop.shared or shared != null) and Partial.wants(partial, prop.name, .once)) {
                    const value = if (prop.shared) @field(shared.?, prop.name) else @field(props, prop.name);
                    const expires_at: ?i64 = if (value.expires_in_ms) |ms| try once_visit.expiresAt(&now, ms) else null;
                    if (!started) {
                        json.objectField("onceProps") catch return error.OutOfMemory;
                        json.beginObject() catch return error.OutOfMemory;
                        started = true;
                    }
                    try writeField(json, prop.key, .{ .prop = prop.name, .expiresAt = expires_at });
                }
            }
            if (started) json.endObject() catch return error.OutOfMemory;
        }

        const MergeProp = struct {
            name: []const u8,
            mode: MergeMode,
            match_on: []const []const u8,
            kind: PropKind,
            shared: bool,
            /// A `scroll` prop, whose listing follows the merge intent.
            scroll: bool,
        };

        /// The merge props of a page with route props `P`, shared ones
        /// first, leaving out shared props that a route prop overrides.
        fn mergeProps(comptime P: type) []const MergeProp {
            var found: []const MergeProp = &.{};
            for (.{ SharedProps, P }, .{ true, false }) |T, is_shared| {
                for (std.meta.fields(T)) |field| {
                    const mode = mergeMode(field.type) orelse continue;
                    if (is_shared and @hasField(P, field.name)) continue;
                    checkListedName("merged", field.name);
                    found = found ++ .{MergeProp{
                        .name = field.name,
                        .mode = mode,
                        .match_on = field.type.inertia_match_on,
                        .kind = propKind(field.type),
                        .shared = is_shared,
                        .scroll = @hasDecl(field.type, "inertia_scroll"),
                    }};
                }
            }
            return found;
        }

        /// Whether the merge prop is in `props`.
        fn sendsProp(partial: ?Partial, has_shared: bool, comptime prop: MergeProp) bool {
            if (prop.shared and !has_shared) return false;
            return Partial.wants(partial, prop.name, prop.kind);
        }

        /// Whether the merge prop is in `props` and not reset.
        fn mergesProp(partial: ?Partial, has_shared: bool, comptime prop: MergeProp) bool {
            return sendsProp(partial, has_shared, prop) and !Partial.resets(partial, prop.name);
        }

        /// The listing of a merge prop: its own mode, or for a scroll prop
        /// the merge intent of a partial reload.
        fn listedMode(partial: ?Partial, comptime prop: MergeProp) MergeMode {
            if (!prop.scroll) return prop.mode;
            const p = partial orelse return prop.mode;
            return switch (p.merge_intent) {
                .append => .append,
                .prepend => .prepend,
            };
        }

        /// Writes `mergeProps`, `prependProps`, `deepMergeProps`, and
        /// `matchPropsOn` for the merge props this page sends, each as an
        /// array of names in declaration order and left out when empty.
        fn writeMerge(json: *std.json.Stringify, partial: ?Partial, has_shared: bool, comptime props: []const MergeProp) error{OutOfMemory}!void {
            const lists = .{
                .{ @as(?MergeMode, .append), "mergeProps" },
                .{ @as(?MergeMode, .prepend), "prependProps" },
                .{ @as(?MergeMode, .deep), "deepMergeProps" },
                .{ @as(?MergeMode, null), "matchPropsOn" },
            };
            inline for (lists) |list| {
                var started = false;
                inline for (props) |prop| {
                    // A scroll prop may land in either list; `listedMode` picks.
                    const names: []const []const u8 = comptime if (list[0]) |mode|
                        (if (prop.mode == mode or (prop.scroll and mode != .deep)) &.{prop.name} else &.{})
                    else names: {
                        var keys: []const []const u8 = &.{};
                        for (prop.match_on) |key| keys = keys ++ .{prop.name ++ "." ++ key};
                        break :names keys;
                    };
                    const listed = if (list[0]) |mode| listedMode(partial, prop) == mode else true;
                    if (names.len != 0 and listed and mergesProp(partial, has_shared, prop)) {
                        if (!started) {
                            json.objectField(list[1]) catch return error.OutOfMemory;
                            json.beginArray() catch return error.OutOfMemory;
                            started = true;
                        }
                        inline for (names) |name| json.write(name) catch return error.OutOfMemory;
                    }
                }
                if (started) json.endArray() catch return error.OutOfMemory;
            }
        }

        /// Writes `scrollProps` as `{name: ScrollProp}` for the scroll props
        /// this page sends, in declaration order, and leaves it out when
        /// there are none. Every scroll prop's page name is checked first,
        /// sent or not.
        fn writeScroll(
            json: *std.json.Stringify,
            partial: ?Partial,
            shared: ?SharedProps,
            props: anytype,
            comptime list: []const MergeProp,
        ) (error{OutOfMemory} || ScrollError)!void {
            inline for (list) |prop| {
                if (comptime !prop.scroll) continue;
                if (!prop.shared or shared != null) try checkPageName(scrollPage(shared, props, prop).page_name);
            }
            var started = false;
            inline for (list) |prop| {
                if (comptime !prop.scroll) continue;
                if (sendsProp(partial, shared != null, prop)) {
                    const page = scrollPage(shared, props, prop);
                    if (!started) {
                        json.objectField("scrollProps") catch return error.OutOfMemory;
                        json.beginObject() catch return error.OutOfMemory;
                        started = true;
                    }
                    // `ScrollProp` in @inertiajs/core 3.9.1.
                    try writeField(json, prop.name, .{
                        .pageName = page.page_name,
                        .previousPage = page.previous,
                        .nextPage = page.next,
                        .currentPage = page.current,
                        .reset = Partial.resets(partial, prop.name),
                    });
                }
            }
            if (started) json.endObject() catch return error.OutOfMemory;
        }

        fn scrollPage(shared: ?SharedProps, props: anytype, comptime prop: MergeProp) ScrollPage {
            return if (prop.shared) @field(shared.?, prop.name).page else @field(props, prop.name).page;
        }

        /// Writes `deferredProps` as `{group: [names]}` in first-seen group
        /// order, leaving out shared props when no shared values are set,
        /// and the whole field when no group has a prop.
        fn writeDeferred(json: *std.json.Stringify, has_shared: bool, comptime props: []const DeferredProp) error{OutOfMemory}!void {
            var started = false;
            inline for (props, 0..) |first, i| {
                const new_group = comptime for (props[0..i]) |earlier| {
                    if (std.mem.eql(u8, earlier.group, first.group)) break false;
                } else true;
                if (new_group) {
                    var opened = false;
                    inline for (props[i..]) |prop| {
                        if (comptime !std.mem.eql(u8, prop.group, first.group)) continue;
                        if (!prop.shared or has_shared) {
                            if (!started) {
                                json.objectField("deferredProps") catch return error.OutOfMemory;
                                json.beginObject() catch return error.OutOfMemory;
                                started = true;
                            }
                            if (!opened) {
                                json.objectField(first.group) catch return error.OutOfMemory;
                                json.beginArray() catch return error.OutOfMemory;
                                opened = true;
                            }
                            json.write(prop.name) catch return error.OutOfMemory;
                        }
                    }
                    if (opened) json.endArray() catch return error.OutOfMemory;
                }
            }
            if (started) json.endObject() catch return error.OutOfMemory;
        }

        fn writeProp(
            json: *std.json.Stringify,
            arena: std.mem.Allocator,
            partial: ?Partial,
            once_visit: OnceVisit,
            comptime name: []const u8,
            value: anytype,
        ) (error{OutOfMemory} || PropsError(struct { value: @TypeOf(value) }))!void {
            const kind = comptime propKind(@TypeOf(value));
            const is_errors = comptime std.mem.eql(u8, name, "errors");
            if (!is_errors and !Partial.wants(partial, name, kind)) return;
            const prop = if (comptime mergeMode(@TypeOf(value)) != null) value.inner else value;
            switch (kind) {
                .eager => try writeField(json, name, prop),
                .always => try writeField(json, name, prop.value),
                .optional, .deferred => try writeField(json, name, try prop.resolveIn(arena)),
                .once => {
                    const key = comptime @TypeOf(prop).inertia_once_key orelse name;
                    if (once_visit.holds(partial, name, key)) return;
                    try writeField(json, name, try prop.resolveIn(arena));
                },
            }
        }

        fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) error{OutOfMemory}!void {
            json.objectField(name) catch return error.OutOfMemory;
            json.write(value) catch return error.OutOfMemory;
        }

        fn htmlBody(self: *const Self, res: *const response.Response, page: []const u8) RenderError![]u8 {
            const before, const after = try self.layoutParts();
            const id = self.root_id;
            // The escaped JSON goes between `head` and `tail`.
            const head: [4][]const u8, const tail: [4][]const u8 = switch (self.initial_page) {
                .script => .{
                    .{ before, "<script data-page=\"", id, "\" type=\"application/json\">" },
                    .{ "</script><div id=\"", id, "\"></div>", after },
                },
                .attribute => .{
                    .{ before, "<div id=\"", id, "\" data-page=\"" },
                    .{ "\"></div>", after, "", "" },
                },
            };
            var len: usize = 0;
            for (head ++ tail) |part| len += part.len;
            for (page) |c| len += if (self.initial_page.escape(c)) |e| e.len else 1;
            if (len > res.limits.max_body_bytes) return error.BodyTooLarge;

            const body = try res.allocator.alloc(u8, len);
            var i: usize = 0;
            for (head) |part| {
                @memcpy(body[i..][0..part.len], part);
                i += part.len;
            }
            for (page) |c| {
                if (self.initial_page.escape(c)) |e| {
                    @memcpy(body[i..][0..e.len], e);
                    i += e.len;
                } else {
                    body[i] = c;
                    i += 1;
                }
            }
            for (tail) |part| {
                @memcpy(body[i..][0..part.len], part);
                i += part.len;
            }
            std.debug.assert(i == len);
            return body;
        }
    };
}

/// What a visit says about once props: the keys the client still holds and
/// the clock for their expiry.
const OnceVisit = struct {
    /// The validated `X-Inertia-Except-Once-Props`; null on ordinary visits.
    except: ?[]const u8 = null,
    clock: ?*const fn () i64 = null,

    /// Whether the once prop `name` keyed `key` is left to the client's
    /// copy. A partial reload whose `-Data` names the prop asks for a fresh
    /// value, so it is sent anyway.
    fn holds(self: OnceVisit, partial: ?Partial, name: []const u8, key: []const u8) bool {
        const list = self.except orelse return false;
        if (!Partial.listNames(list, key, .exact)) return false;
        if (partial) |p| if (p.only) |only| if (Partial.listNames(only, name, .first_segment)) return false;
        return true;
    }

    /// The clock's time plus `ms`, reading the clock into `now` on first
    /// use so every entry of a page shares one time.
    fn expiresAt(self: OnceVisit, now: *?i64, ms: u64) OnceError!i64 {
        const current = now.* orelse current: {
            const read = (self.clock orelse return error.OnceClockNotConfigured)();
            if (read < 0) return error.InvalidOnceTime;
            now.* = read;
            break :current read;
        };
        const delta = std.math.cast(i64, ms) orelse return error.InvalidOnceTime;
        const at = std.math.add(i64, current, delta) catch return error.InvalidOnceTime;
        if (at > max_once_expires_at) return error.InvalidOnceTime;
        return at;
    }
};

pub const InitialPage = enum {
    /// `<script data-page="id" type="application/json">` plus `<div id="id">`
    /// (Inertia v3).
    script,
    /// `<div id="id" data-page="...">` (Inertia v1 and v2).
    attribute,

    /// The replacement for `c`, or null to copy it. In JSON these bytes occur
    /// only inside strings, where `\uXXXX` keeps the value unchanged.
    fn escape(self: InitialPage, c: u8) ?[]const u8 {
        return switch (self) {
            .script => switch (c) {
                '<' => "\\u003c",
                '>' => "\\u003e",
                '&' => "\\u0026",
                else => null,
            },
            .attribute => switch (c) {
                '&' => "&amp;",
                '"' => "&quot;",
                '\'' => "&#39;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => null,
            },
        };
    }
};

fn followUpStatus(req: *const router.Request) response.RedirectStatus {
    return switch (req.method) {
        .get, .head => .found,
        else => .see_other,
    };
}

/// Checks, without changing the response, that `sendRedirect` to `path`
/// cannot fail other than by running out of memory.
fn checkRedirect(inertia: bool, res: *const response.Response, path: []const u8) RedirectError!void {
    try response.validateRedirectPath(path);
    const fragment = inertia and std.mem.indexOfScalar(u8, path, '#') != null;
    const name = if (fragment) "X-Inertia-Redirect" else "Location";
    var existing = res.getAllHeaders(name);
    if (existing.next() != null) return error.LocationAlreadySet;
    if (fragment) return reserveHeaders(res, 1, name.len + path.len);
    if (res.header_count + 1 > res.limits.max_headers) return error.TooManyHeaders;
    if (res.header_bytes_used + name.len + path.len > res.limits.header_bytes) return error.HeaderBytesExceeded;
}

/// `redirect` with an explicit status for the plain `Location` form.
fn sendRedirect(req: *const router.Request, res: *response.Response, status: response.RedirectStatus, path: []const u8) RedirectError!void {
    const inertia = try isInertia(req);
    if (!inertia or std.mem.indexOfScalar(u8, path, '#') == null) {
        return res.redirectPath(status, path);
    }
    try response.validateRedirectPath(path);
    var existing = res.getAllHeaders("X-Inertia-Redirect");
    if (existing.next() != null) return error.LocationAlreadySet;
    try reserveHeaders(res, 1, "X-Inertia-Redirect".len + path.len);
    try res.setHeader("X-Inertia-Redirect", path);
    try addInertiaVary(res);
    emptyBody(res, 409);
}

/// Checks that `count` more fields plus `bytes`, and a possible `Vary:
/// X-Inertia`, fit the response header limits, so a limit failure never
/// leaves some Inertia headers behind.
fn reserveHeaders(res: *const response.Response, count: usize, bytes: usize) response.HeaderError!void {
    const vary: usize = if (listsInertiaVary(res)) 0 else 1;
    if (res.header_count + count + vary > res.limits.max_headers) return error.TooManyHeaders;
    const vary_bytes = vary * ("Vary".len + "X-Inertia".len);
    if (res.header_bytes_used + bytes + vary_bytes > res.limits.header_bytes) return error.HeaderBytesExceeded;
}

fn addInertiaVary(res: *response.Response) response.HeaderError!void {
    http_cache.addVary(res, "X-Inertia") catch |err| switch (err) {
        error.InvalidVary => unreachable,
        else => |e| return e,
    };
}

fn listsInertiaVary(res: *const response.Response) bool {
    var it = res.getAllHeaders("Vary");
    while (it.next()) |value| {
        var members = std.mem.splitScalar(u8, value, ',');
        while (members.next()) |member| {
            const name = std.mem.trim(u8, member, " \t");
            if (std.mem.eql(u8, name, "*") or std.ascii.eqlIgnoreCase(name, "X-Inertia")) return true;
        }
    }
    return false;
}

fn commitBody(res: *response.Response, content_type: []const u8, body: []u8) error{ OutOfMemory, BodyTooLarge }!void {
    res.replaceOwnedBody(200, content_type, body) catch |err| switch (err) {
        error.InvalidContentType => unreachable,
        else => |e| return e,
    };
}

fn conflict(res: *response.Response, url: []const u8) RenderError!void {
    try reserveHeaders(res, 1, "X-Inertia-Location".len + url.len);
    try res.setHeader("X-Inertia-Location", url);
    try addInertiaVary(res);
    emptyBody(res, 409);
}

/// Replaces the body and content type with nothing, like `redirectPath`.
fn emptyBody(res: *response.Response, status: u16) void {
    if (res.body.len != 0) res.allocator.free(res.body);
    if (res.content_type.len != 0) res.allocator.free(@constCast(res.content_type));
    res.body = &.{};
    res.content_type = &.{};
    res.status_code = status;
    res.handled = true;
    res.generated = false;
}

/// Accepts a local path under the `redirectPath` rules or an absolute
/// `http`/`https` URL with a non-empty host, no userinfo, and printable ASCII
/// without `\` and with well-formed percent escapes.
fn validateLocation(destination: []const u8) error{InvalidLocation}!void {
    if (destination.len != 0 and destination[0] == '/') {
        response.validateRedirectPath(destination) catch return error.InvalidLocation;
        return;
    }
    const rest = if (startsWithIgnoreCase(destination, "https://"))
        destination["https://".len..]
    else if (startsWithIgnoreCase(destination, "http://"))
        destination["http://".len..]
    else
        return error.InvalidLocation;
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..host_end];
    if (authority.len == 0) return error.InvalidLocation;
    for (authority) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':' or c == '[' or c == ']')) {
            return error.InvalidLocation;
        }
    }
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c <= ' ' or c >= 0x7f or c == '\\') return error.InvalidLocation;
        if (c == '%') {
            if (rest.len - i < 3 or !std.ascii.isHex(rest[i + 1]) or !std.ascii.isHex(rest[i + 2])) {
                return error.InvalidLocation;
            }
            i += 2;
        }
    }
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

const testing = std.testing;
const test_layout = "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>@inertia</body></html>";
const TestShared = struct { app_name: []const u8, user: ?[]const u8 = null };
const TestInertia = Inertia(TestShared);

fn testRequest(method: router.Method, target: []const u8, headers: []const router.Header) router.Request {
    return .{ .method = method, .segments = &.{}, .target = target, .headers = headers };
}

const inertia_headers = [_]router.Header{
    .{ .name = "X-Inertia", .value = "true" },
    .{ .name = "X-Inertia-Version", .value = "v1" },
};

test "ordinary visit embeds the page in a JSON script element for Inertia v3" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const req = testRequest(.get, "/users?q=a&b=%22x%22", &.{});
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Index", .{ .title = "</script><!-- & 'q'" });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings(html_content_type, res.content_type);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("X-Inertia"));
    const json = "{\"component\":\"Users/Index\",\"props\":{\"title\":\"\\u003c/script\\u003e\\u003c!-- \\u0026 'q'\",\"errors\":{}}," ++
        "\"url\":\"/users?q=a\\u0026b=%22x%22\",\"version\":\"v1\"}";
    try testing.expectEqualStrings(
        "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>" ++
            "<script data-page=\"app\" type=\"application/json\">" ++ json ++ "</script><div id=\"app\"></div>" ++
            "</body></html>",
        res.body,
    );

    // The escaped JSON still decodes to the original values.
    const start = std.mem.indexOf(u8, res.body, json).?;
    const Page = struct { props: struct { title: []const u8 }, url: []const u8 };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, res.body[start..][0..json.len], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("</script><!-- & 'q'", parsed.value.props.title);
    try testing.expectEqualStrings("/users?q=a&b=%22x%22", parsed.value.url);
}

test "attribute initial page escapes the JSON for v1 and v2 clients" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" }, .initial_page = .attribute };
    const req = testRequest(.get, "/users?q=a&b=%22x%22", &.{});
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Index", .{ .title = "<script>alert('x')</script> & \"q\"" });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings(html_content_type, res.content_type);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("X-Inertia"));
    try testing.expectEqualStrings(
        "<!doctype html><html><head><script src=\"/app.js\"></script></head><body>" ++
            "<div id=\"app\" data-page=\"{&quot;component&quot;:&quot;Users/Index&quot;," ++
            "&quot;props&quot;:{&quot;title&quot;:&quot;&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; \\&quot;q\\&quot;&quot;,&quot;errors&quot;:{}}," ++
            "&quot;url&quot;:&quot;/users?q=a&amp;b=%22x%22&quot;,&quot;version&quot;:&quot;v1&quot;}\"></div>" ++
            "</body></html>",
        res.body,
    );
}

test "Inertia visit returns the JSON page with shared props overridden by route props" {
    const plugin: TestInertia = .{
        .layout = test_layout,
        .version = .{ .value = "v1" },
        .shared = .{ .value = .{ .app_name = "zoda", .user = "shared" } },
    };
    const req = testRequest(.get, "/users/7?tab=posts&tab=likes", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Users/Show", .{ .user = "ada", .id = @as(u32, 7) });

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("application/json", res.content_type);
    try testing.expectEqualStrings("true", (try res.getHeaderOne("X-Inertia")).?);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqualStrings(
        "{\"component\":\"Users/Show\",\"props\":{\"app_name\":\"zoda\",\"user\":\"ada\",\"id\":7,\"errors\":{}}," ++
            "\"url\":\"/users/7?tab=posts&tab=likes\",\"version\":\"v1\",\"sharedProps\":[\"app_name\",\"user\"]}",
        res.body,
    );
}

test "shared props callback and version callback read the request" {
    const Callbacks = struct {
        fn shared(req: *const router.Request) TestShared {
            return .{ .app_name = "cb", .user = req.getHeaderOne("X-User") catch null };
        }
        fn version(_: *const router.Request) []const u8 {
            return "build-2";
        }
    };
    const plugin: TestInertia = .{
        .layout = test_layout,
        .version = .{ .callback = Callbacks.version },
        .shared = .{ .callback = Callbacks.shared },
    };
    const headers = [_]router.Header{
        .{ .name = "x-inertia", .value = "true" },
        .{ .name = "x-inertia-version", .value = "build-2" },
        .{ .name = "X-User", .value = "grace" },
    };
    const req = testRequest(.get, "/", &headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Home", .{});
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"app_name\":\"cb\",\"user\":\"grace\",\"errors\":{}},\"url\":\"/\",\"version\":\"build-2\",\"sharedProps\":[\"app_name\",\"user\"]}",
        res.body,
    );

    const none: Inertia(struct {}) = .{ .layout = "@inertia" };
    var plain = response.Response.init(testing.allocator);
    defer plain.deinit();
    try none.render(&req, &plain, "Home", .{});
    try testing.expectEqualStrings("{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null}", plain.body);
}

test "stale version on an Inertia GET returns 409 with the current URL" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v2" } };
    const stale = [_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "v1" } };
    const missing = [_]router.Header{.{ .name = "X-Inertia", .value = "true" }};
    inline for (.{ &stale, &missing }) |headers| {
        const req = testRequest(.get, "/search?q=zig+lang&page=2", headers);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(200, "partial");
        try plugin.render(&req, &res, "Search", .{});
        try testing.expectEqual(@as(u16, 409), res.status_code);
        try testing.expectEqualStrings("", res.body);
        try testing.expectEqualStrings("", res.content_type);
        try testing.expectEqualStrings("/search?q=zig+lang&page=2", (try res.getHeaderOne("X-Inertia-Location")).?);
        try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    }

    // Clients omit the header for an empty version, so that is no conflict.
    const empty: TestInertia = .{ .layout = test_layout, .version = .{ .value = "" } };
    const unversioned = testRequest(.get, "/", &missing);
    var current = response.Response.init(testing.allocator);
    defer current.deinit();
    try empty.render(&unversioned, &current, "Home", .{});
    try testing.expectEqual(@as(u16, 200), current.status_code);

    // Ordinary visits and non-GET Inertia requests never get the conflict.
    const ordinary = testRequest(.get, "/search", &.{});
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try plugin.render(&ordinary, &html, "Search", .{});
    try testing.expectEqual(@as(u16, 200), html.status_code);
    const post = testRequest(.post, "/search", &stale);
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try plugin.render(&post, &json, "Search", .{});
    try testing.expectEqual(@as(u16, 200), json.status_code);
    try testing.expectEqualStrings("true", (try json.getHeaderOne("X-Inertia")).?);
}

test "malformed and duplicate Inertia headers fail without changing the response" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const cases = .{
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "false" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "TRUE" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{.{ .name = "X-Inertia", .value = "" }}, error.MalformedInertiaHeader, true },
        .{ &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "x-inertia", .value = "true" } }, error.DuplicateInertiaHeader, true },
        // `location` does not read the version, so only `render` rejects this.
        .{ &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Version", .value = "v1" }, .{ .name = "X-Inertia-Version", .value = "v1" } }, error.DuplicateVersionHeader, false },
    };
    inline for (cases) |case| {
        const req = testRequest(.get, "/", case[0]);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(201, "keep");
        try testing.expectError(case[1], plugin.render(&req, &res, "Home", .{}));
        if (case[2]) try testing.expectError(case[1], plugin.location(&req, &res, "/elsewhere"));
        try testing.expectEqual(@as(u16, 201), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
}

test "unsafe targets, components, and configuration are rejected" {
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    const good: TestInertia = .{ .layout = test_layout };
    for ([_][]const u8{ "//evil.test/x", "relative", "/a\\b", "/a b", "/\x7f" }) |target| {
        const req = testRequest(.get, target, &.{});
        try testing.expectError(error.UnsafeRequestTarget, good.render(&req, &res, "Home", .{}));
    }
    const untargeted = testRequest(.get, "", &.{});
    try testing.expectError(error.MissingRequestTarget, good.render(&untargeted, &res, "Home", .{}));
    const req = testRequest(.get, "/", &.{});
    try testing.expectError(error.InvalidComponent, good.render(&req, &res, "", .{}));

    for ([_][]const u8{ "<body></body>", "@inertia @inertia" }) |layout| {
        const bad: TestInertia = .{ .layout = layout };
        try testing.expectError(error.InvalidLayout, bad.validate());
        try testing.expectError(error.InvalidLayout, bad.render(&req, &res, "Home", .{}));
    }
    for ([_][]const u8{ "", "a\"b", "a b", "x" ** 65 }) |root_id| {
        const bad: TestInertia = .{ .layout = test_layout, .root_id = root_id };
        try testing.expectError(error.InvalidRootId, bad.validate());
    }
    const custom: TestInertia = .{ .layout = "@inertia", .root_id = "root_1-x" };
    try custom.render(&req, &res, "Home", .{});
    try testing.expect(std.mem.startsWith(u8, res.body, "<script data-page=\"root_1-x\" type=\"application/json\">"));
    try testing.expect(std.mem.endsWith(u8, res.body, "</script><div id=\"root_1-x\"></div>"));
    const attribute: TestInertia = .{ .layout = "@inertia", .root_id = "root_1-x", .initial_page = .attribute };
    try attribute.render(&req, &res, "Home", .{});
    try testing.expect(std.mem.startsWith(u8, res.body, "<div id=\"root_1-x\" data-page=\""));
}

test "configured body and header limits are honored before changing the response" {
    const plugin: TestInertia = .{ .layout = test_layout, .version = .{ .value = "v1" } };
    const ordinary = testRequest(.get, "/", &.{});
    const inertia = testRequest(.get, "/", &inertia_headers);
    const stale_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "true" }};
    const stale = testRequest(.get, "/", &stale_headers);

    const cases = .{
        .{ ordinary, response.Limits{ .max_body_bytes = test_layout.len }, error.BodyTooLarge },
        .{ inertia, response.Limits{ .max_body_bytes = 20 }, error.BodyTooLarge },
        .{ ordinary, response.Limits{ .max_headers = 0 }, error.TooManyHeaders },
        .{ inertia, response.Limits{ .max_headers = 1 }, error.TooManyHeaders },
        .{ inertia, response.Limits{ .header_bytes = 20 }, error.HeaderBytesExceeded },
        .{ stale, response.Limits{ .max_headers = 1 }, error.TooManyHeaders },
    };
    inline for (cases) |case| {
        var res = response.Response.initWithLimits(testing.allocator, case[1]);
        defer res.deinit();
        try res.text(202, "keep");
        try testing.expectError(case[2], plugin.render(&case[0], &res, "Home", .{ .name = "ada" }));
        try testing.expectEqual(@as(u16, 202), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }

    // An existing `Vary: X-Inertia` is reused, so it needs no extra room.
    var reused = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer reused.deinit();
    try reused.setHeader("Vary", "Accept-Encoding, x-inertia");
    try plugin.render(&ordinary, &reused, "Home", .{});
    try testing.expectEqual(@as(usize, 1), reused.header_count);

    var tiny: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    var oom = response.Response.init(fba.allocator());
    defer oom.deinit();
    try testing.expectError(error.OutOfMemory, plugin.render(&inertia, &oom, "Home", .{}));
}

test "redirects use 302 after GET and 303 after other methods for local paths" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const methods = .{ .{ router.Method.get, @as(u16, 302) }, .{ router.Method.head, @as(u16, 302) }, .{ router.Method.post, @as(u16, 303) }, .{ router.Method.put, @as(u16, 303) }, .{ router.Method.patch, @as(u16, 303) }, .{ router.Method.delete, @as(u16, 303) } };
    inline for (methods) |case| {
        const req = testRequest(case[0], "/users", &inertia_headers);
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(200, "old");
        try plugin.redirect(&req, &res, "/users/7?saved=1");
        try testing.expectEqual(case[1], res.status_code);
        try testing.expectEqualStrings("/users/7?saved=1", (try res.getHeaderOne("Location")).?);
        try testing.expectEqualStrings("", res.body);
    }
    const req = testRequest(.post, "/users", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    for ([_][]const u8{ "https://evil.test/", "//evil.test/", "relative", "/\r\nX: y" }) |bad| {
        try testing.expectError(error.InvalidRedirectPath, plugin.redirect(&req, &res, bad));
    }
    try testing.expectEqual(@as(usize, 0), res.header_count);
}

test "errors is always an object and route errors win over shared errors" {
    const req = testRequest(.get, "/", &inertia_headers);
    const WithErrors = Inertia(struct { errors: struct { base: []const u8 } });
    const shared: WithErrors = .{ .layout = test_layout, .shared = .{ .value = .{ .errors = .{ .base = "shared" } } } };
    var from_shared = response.Response.init(testing.allocator);
    defer from_shared.deinit();
    try shared.render(&req, &from_shared, "Home", .{});
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"errors\":{\"base\":\"shared\"}},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"errors\"]}",
        from_shared.body,
    );
    var from_route = response.Response.init(testing.allocator);
    defer from_route.deinit();
    try shared.render(&req, &from_route, "Home", .{ .errors = .{ .text = "route" } });
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"errors\":{\"text\":\"route\"}},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"errors\"]}",
        from_route.body,
    );
    // Shared errors are declared but not configured, so the default applies.
    const unset: WithErrors = .{ .layout = test_layout };
    var defaulted = response.Response.init(testing.allocator);
    defer defaulted.deinit();
    try unset.render(&req, &defaulted, "Home", .{});
    try testing.expectEqualStrings("{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null}", defaulted.body);
}

test "fragment redirects use X-Inertia-Redirect for Inertia requests" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const inertia = testRequest(.post, "/todos", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(200, "old");
    try plugin.redirect(&inertia, &res, "/todos?filter=done#todo-3");
    try testing.expectEqual(@as(u16, 409), res.status_code);
    try testing.expectEqualStrings("", res.body);
    try testing.expectEqualStrings("/todos?filter=done#todo-3", (try res.getHeaderOne("X-Inertia-Redirect")).?);
    try testing.expectEqualStrings("X-Inertia", (try res.getHeaderOne("Vary")).?);
    try testing.expectEqual(@as(?[]const u8, null), try res.getHeaderOne("Location"));
    try testing.expectError(error.LocationAlreadySet, plugin.redirect(&inertia, &res, "/again#x"));

    // Browsers keep the fragment themselves on ordinary redirects.
    const ordinary = testRequest(.post, "/todos", &.{});
    var plain = response.Response.init(testing.allocator);
    defer plain.deinit();
    try plugin.redirect(&ordinary, &plain, "/todos#todo-3");
    try testing.expectEqual(@as(u16, 303), plain.status_code);
    try testing.expectEqualStrings("/todos#todo-3", (try plain.getHeaderOne("Location")).?);

    var rejected = response.Response.init(testing.allocator);
    defer rejected.deinit();
    for ([_][]const u8{ "//evil.test/#x", "https://evil.test/#x", "/a b#x", "/%2f#x" }) |bad| {
        try testing.expectError(error.InvalidRedirectPath, plugin.redirect(&inertia, &rejected, bad));
    }
    const malformed_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "1" }};
    const malformed = testRequest(.post, "/todos", &malformed_headers);
    try testing.expectError(error.MalformedInertiaHeader, plugin.redirect(&malformed, &rejected, "/todos"));
    try testing.expectEqual(@as(usize, 0), rejected.header_count);

    var limited = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer limited.deinit();
    try testing.expectError(error.TooManyHeaders, plugin.redirect(&inertia, &limited, "/todos#x"));
    try testing.expectEqual(@as(usize, 0), limited.header_count);
}

test "location forces full visits for Inertia requests and validates destinations" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const inertia = testRequest(.post, "/checkout", &inertia_headers);
    var conflict_res = response.Response.init(testing.allocator);
    defer conflict_res.deinit();
    try conflict_res.text(200, "old");
    try plugin.location(&inertia, &conflict_res, "https://billing.example:8443/pay?id=1%20a");
    try testing.expectEqual(@as(u16, 409), conflict_res.status_code);
    try testing.expectEqualStrings("", conflict_res.body);
    try testing.expectEqualStrings("https://billing.example:8443/pay?id=1%20a", (try conflict_res.getHeaderOne("X-Inertia-Location")).?);
    try testing.expectEqual(@as(?[]const u8, null), try conflict_res.getHeaderOne("Location"));
    try testing.expectEqualStrings("X-Inertia", (try conflict_res.getHeaderOne("Vary")).?);

    const ordinary_get = testRequest(.get, "/checkout", &.{});
    var get_res = response.Response.init(testing.allocator);
    defer get_res.deinit();
    try plugin.location(&ordinary_get, &get_res, "HTTP://billing.example");
    try testing.expectEqual(@as(u16, 302), get_res.status_code);
    try testing.expectEqualStrings("HTTP://billing.example", (try get_res.getHeaderOne("Location")).?);

    const ordinary_post = testRequest(.post, "/checkout", &.{});
    var post_res = response.Response.init(testing.allocator);
    defer post_res.deinit();
    try plugin.location(&ordinary_post, &post_res, "/legacy/page");
    try testing.expectEqual(@as(u16, 303), post_res.status_code);
    try testing.expectError(error.LocationAlreadySet, plugin.location(&ordinary_post, &post_res, "/again"));

    var rejected = response.Response.init(testing.allocator);
    defer rejected.deinit();
    for ([_][]const u8{
        "",                      "relative",                "javascript:alert(1)",     "ftp://files.example/",
        "https://",              "https:///path",           "https://user@evil.test/", "https://a.test\\@evil.test/",
        "https://a.test/ space", "https://a.test/\r\nX: y", "https://a.test/%zz",      "//evil.test/",
        "/%2f/evil",
        "https://a.test/é",
    }) |bad| {
        try testing.expectError(error.InvalidLocation, plugin.location(&inertia, &rejected, bad));
    }
    try testing.expectEqual(@as(usize, 0), rejected.header_count);

    var limited = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer limited.deinit();
    try testing.expectError(error.TooManyHeaders, plugin.location(&inertia, &limited, "/next"));
    try testing.expectEqual(@as(usize, 0), limited.header_count);
}

test "registered instance renders through app dispatch with errors propagating" {
    const app_mod = @import("../app.zig");
    const Plugins = struct { inertia: TestInertia };
    const App = app_mod.App(Plugins);
    const Routes = struct {
        fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
            if (req.onLiteral("users")) {
                if (req.isRoot() and req.isGet()) {
                    return ctx.plugins.inertia.render(req, res, "Users/Index", .{ .users = &[_][]const u8{ "ada", "grace" } });
                }
                if (req.isRoot() and req.method == .post) return ctx.plugins.inertia.redirect(req, res, "/users");
            }
        }
    };
    var app = try App.init(testing.allocator, .{
        .response_allocator = testing.allocator,
        .plugins = .{ .inertia = .{ .layout = test_layout, .version = .{ .value = "v1" }, .shared = .{ .value = .{ .app_name = "zoda" } } } },
        .route_fn = Routes.route,
    });
    defer app.deinit();

    var json_req: router.Request = .{ .method = .get, .segments = &.{"users"}, .target = "/users", .headers = &inertia_headers };
    var json_res = try app.dispatch(&json_req);
    defer json_res.deinit();
    try testing.expectEqualStrings(
        "{\"component\":\"Users/Index\",\"props\":{\"app_name\":\"zoda\",\"user\":null,\"users\":[\"ada\",\"grace\"],\"errors\":{}},\"url\":\"/users\",\"version\":\"v1\",\"sharedProps\":[\"app_name\",\"user\"]}",
        json_res.body,
    );

    var post_req: router.Request = .{ .method = .post, .segments = &.{"users"}, .target = "/users", .headers = &inertia_headers };
    var post_res = try app.dispatch(&post_req);
    defer post_res.deinit();
    try testing.expectEqual(@as(u16, 303), post_res.status_code);

    const bad_headers = [_]router.Header{.{ .name = "X-Inertia", .value = "yes" }};
    var bad_req: router.Request = .{ .method = .get, .segments = &.{"users"}, .target = "/users", .headers = &bad_headers };
    try testing.expectError(error.MalformedInertiaHeader, app.dispatch(&bad_req));

    var miss_req: router.Request = .{ .method = .get, .segments = &.{"missing"}, .target = "/missing", .headers = &inertia_headers };
    var miss_res = try app.dispatch(&miss_req);
    defer miss_res.deinit();
    try testing.expectEqual(@as(u16, 404), miss_res.status_code);
}

const PartialTest = struct {
    calls: usize = 0,

    fn stats(self: *PartialTest, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        self.calls += 1;
        return std.fmt.allocPrint(allocator, "computed {d}", .{self.calls});
    }

    fn fail(_: *PartialTest, _: std.mem.Allocator) error{StatsUnavailable}![]const u8 {
        return error.StatsUnavailable;
    }

    fn render(self: *PartialTest, plugin: *const TestInertia, headers: []const router.Header, res: *response.Response) !void {
        const req = testRequest(.get, "/todos", headers);
        try plugin.render(&req, res, "Todos/Index", .{
            .todos = &[_][]const u8{"milk"},
            .filter = "all",
            .stats = optional(self, stats),
            .flash = always("saved"),
        });
    }
};

fn partialHeaders(comptime component: []const u8, comptime extra: []const router.Header) []const router.Header {
    return &([_]router.Header{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Version", .value = "v1" },
        .{ .name = "X-Inertia-Partial-Component", .value = component },
    } ++ extra[0..extra.len].*);
}

const partial_plugin: TestInertia = .{
    .layout = test_layout,
    .version = .{ .value = "v1" },
    .shared = .{ .value = .{ .app_name = "zoda", .user = "ada" } },
};

fn expectProps(comptime props: []const u8, body: []const u8) !void {
    try testing.expectEqualStrings(
        "{\"component\":\"Todos/Index\",\"props\":{" ++ props ++ "},\"url\":\"/todos\",\"version\":\"v1\",\"sharedProps\":[\"app_name\",\"user\"]}",
        body,
    );
}

test "partial reload applies only to the rendered component" {
    var state: PartialTest = .{};
    var full = response.Response.init(testing.allocator);
    defer full.deinit();
    try state.render(&partial_plugin, &inertia_headers, &full);
    // A full visit skips optional props without calling them.
    try expectProps("\"app_name\":\"zoda\",\"user\":\"ada\",\"todos\":[\"milk\"],\"filter\":\"all\",\"flash\":\"saved\",\"errors\":{}", full.body);
    try testing.expectEqual(@as(usize, 0), state.calls);

    var other = response.Response.init(testing.allocator);
    defer other.deinit();
    try state.render(&partial_plugin, partialHeaders("Users/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "todos" }}), &other);
    try testing.expectEqualStrings(full.body, other.body);
    try testing.expectEqual(@as(usize, 0), state.calls);

    // Component without lists: everything, optional props included.
    var bare = response.Response.init(testing.allocator);
    defer bare.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{}), &bare);
    try expectProps("\"app_name\":\"zoda\",\"user\":\"ada\",\"todos\":[\"milk\"],\"filter\":\"all\",\"stats\":\"computed 1\",\"flash\":\"saved\",\"errors\":{}", bare.body);
    try testing.expectEqual(@as(usize, 1), state.calls);

    // Ordinary visits ignore the partial headers, even malformed ones.
    const html_headers = [_]router.Header{
        .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" },
        .{ .name = "X-Inertia-Partial-Data", .value = "todos,,x y" },
    };
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try state.render(&partial_plugin, &html_headers, &html);
    try testing.expectEqualStrings(html_content_type, html.content_type);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"todos\":[\"milk\"]") != null);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"stats\"") == null);
    try testing.expectEqual(@as(usize, 1), state.calls);
}

test "partial data keeps only listed props plus always and errors" {
    var state: PartialTest = .{};
    var only = response.Response.init(testing.allocator);
    defer only.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "todos" }}), &only);
    try expectProps("\"todos\":[\"milk\"],\"flash\":\"saved\",\"errors\":{}", only.body);
    try testing.expectEqual(@as(usize, 0), state.calls);

    var requested = response.Response.init(testing.allocator);
    defer requested.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "stats,user,missing,stats" }}), &requested);
    try expectProps("\"user\":\"ada\",\"stats\":\"computed 1\",\"flash\":\"saved\",\"errors\":{}", requested.body);
    try testing.expectEqual(@as(usize, 1), state.calls);

    // Filtering is top-level: a dot path keeps the whole prop.
    var dotted = response.Response.init(testing.allocator);
    defer dotted.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "todos.0,app_name" }}), &dotted);
    try expectProps("\"app_name\":\"zoda\",\"todos\":[\"milk\"],\"flash\":\"saved\",\"errors\":{}", dotted.body);
}

test "partial except removes props and wins over partial data" {
    var state: PartialTest = .{};
    var except = response.Response.init(testing.allocator);
    defer except.deinit();
    // Like Laravel, an except-only reload includes optional props.
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Except", .value = "todos,app_name,flash,errors" }}), &except);
    try expectProps("\"user\":\"ada\",\"filter\":\"all\",\"stats\":\"computed 1\",\"flash\":\"saved\",\"errors\":{}", except.body);
    try testing.expectEqual(@as(usize, 1), state.calls);

    var both = response.Response.init(testing.allocator);
    defer both.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "todos,stats,user" },
        .{ .name = "X-Inertia-Partial-Except", .value = "stats,user.name" },
    }), &both);
    // `user.name` is below the top level, so `user` stays.
    try expectProps("\"user\":\"ada\",\"todos\":[\"milk\"],\"flash\":\"saved\",\"errors\":{}", both.body);
    try testing.expectEqual(@as(usize, 1), state.calls);
}

test "shared optional, always, and errors props follow the same filtering" {
    const Shared = struct {
        locale: []const u8,
        auth: Always([]const u8),
        errors: struct { text: []const u8 },
        stats: Optional(*PartialTest, PartialTest.stats),
    };
    var state: PartialTest = .{};
    const plugin: Inertia(Shared) = .{ .layout = test_layout, .shared = .{ .value = .{
        .locale = "en",
        .auth = .{ .value = "ada" },
        .errors = .{ .text = "required" },
        .stats = optional(&state, PartialTest.stats),
    } } };
    const req = testRequest(.get, "/", partialHeaders("Home", &.{.{ .name = "X-Inertia-Partial-Data", .value = "title" }}));
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.render(&req, &res, "Home", .{ .title = "hi", .body = "skipped" });
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"auth\":\"ada\",\"errors\":{\"text\":\"required\"},\"title\":\"hi\"},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"locale\",\"auth\",\"errors\",\"stats\"]}",
        res.body,
    );
    try testing.expectEqual(@as(usize, 0), state.calls);

    const wanted = testRequest(.get, "/", partialHeaders("Home", &.{.{ .name = "X-Inertia-Partial-Data", .value = "stats" }}));
    var with_stats = response.Response.init(testing.allocator);
    defer with_stats.deinit();
    try plugin.render(&wanted, &with_stats, "Home", .{});
    try testing.expect(std.mem.indexOf(u8, with_stats.body, "\"props\":{\"auth\":\"ada\",\"errors\":{\"text\":\"required\"},\"stats\":\"computed 1\"}") != null);
}

test "optional callback errors propagate and leave the response unchanged" {
    var state: PartialTest = .{};
    const req = testRequest(.get, "/todos", partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "stats" }}));
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    try testing.expectError(error.StatsUnavailable, partial_plugin.render(&req, &res, "Todos/Index", .{ .stats = optional(&state, PartialTest.fail) }));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqualStrings("keep", res.body);
    try testing.expectEqual(@as(usize, 0), res.header_count);

    // Not requested, so the failing callback never runs.
    const skip = testRequest(.get, "/todos", &inertia_headers);
    try partial_plugin.render(&skip, &res, "Todos/Index", .{ .stats = optional(&state, PartialTest.fail) });
    try testing.expectEqual(@as(u16, 200), res.status_code);

    // A plain callback without an error set and a void context also work.
    const Plain = struct {
        fn answer(_: void, _: std.mem.Allocator) u32 {
            return 42;
        }
    };
    try partial_plugin.render(&req, &res, "Todos/Index", .{ .stats = optional({}, Plain.answer) });
    try expectProps("\"stats\":42,\"errors\":{}", res.body);
}

test "malformed, duplicate, and oversized partial headers fail without changing the response" {
    var state: PartialTest = .{};
    const too_many = "a," ** max_partial_props ++ "a";
    const too_long = "a" ** (max_partial_bytes + 1);
    const cases = .{
        .{ "X-Inertia-Partial-Data", "", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Data", "todos,", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Data", ",todos", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Data", "todos, filter", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Except", "a..b", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Except", ".a", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Except", "a\"b", error.MalformedPartialHeader },
        .{ "X-Inertia-Partial-Data", too_many, error.PartialHeaderTooLarge },
        .{ "X-Inertia-Partial-Except", too_long, error.PartialHeaderTooLarge },
        .{ "X-Inertia-Reset", "", error.MalformedPartialHeader },
        .{ "X-Inertia-Reset", "todos,", error.MalformedPartialHeader },
        .{ "X-Inertia-Reset", "todos filter", error.MalformedPartialHeader },
        .{ "X-Inertia-Reset", too_many, error.PartialHeaderTooLarge },
        .{ "X-Inertia-Reset", too_long, error.PartialHeaderTooLarge },
        .{ "X-Inertia-Infinite-Scroll-Merge-Intent", "", error.MalformedPartialHeader },
        .{ "X-Inertia-Infinite-Scroll-Merge-Intent", "Append", error.MalformedPartialHeader },
        .{ "X-Inertia-Infinite-Scroll-Merge-Intent", "prepend ", error.MalformedPartialHeader },
        .{ "X-Inertia-Infinite-Scroll-Merge-Intent", "append,prepend", error.MalformedPartialHeader },
        .{ "X-Inertia-Infinite-Scroll-Merge-Intent", "merge", error.MalformedPartialHeader },
    };
    inline for (cases) |case| {
        // Headers are validated even when another component is named.
        inline for (.{ "Todos/Index", "Other" }) |component| {
            var res = response.Response.init(testing.allocator);
            defer res.deinit();
            try res.text(201, "keep");
            try testing.expectError(case[2], state.render(&partial_plugin, partialHeaders(component, &.{.{ .name = case[0], .value = case[1] }}), &res));
            try testing.expectEqual(@as(u16, 201), res.status_code);
            try testing.expectEqualStrings("keep", res.body);
            try testing.expectEqual(@as(usize, 0), res.header_count);
        }
    }

    // The limits themselves are accepted.
    var at_limit = response.Response.init(testing.allocator);
    defer at_limit.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "a," ** (max_partial_props - 1) ++ "todos" }}), &at_limit);
    try expectProps("\"todos\":[\"milk\"],\"flash\":\"saved\",\"errors\":{}", at_limit.body);
    var long_name = response.Response.init(testing.allocator);
    defer long_name.deinit();
    try state.render(&partial_plugin, partialHeaders("Todos/Index", &.{.{ .name = "X-Inertia-Partial-Data", .value = "a" ** max_partial_bytes }}), &long_name);

    const duplicates = .{
        &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Partial-Component", .value = "Todos/Index" }, .{ .name = "x-inertia-partial-component", .value = "Todos/Index" } },
        partialHeaders("Todos/Index", &.{ .{ .name = "X-Inertia-Partial-Data", .value = "todos" }, .{ .name = "X-Inertia-Partial-Data", .value = "todos" } }),
        partialHeaders("Other", &.{ .{ .name = "X-Inertia-Partial-Except", .value = "a" }, .{ .name = "x-inertia-partial-except", .value = "b" } }),
        partialHeaders("Todos/Index", &.{ .{ .name = "X-Inertia-Reset", .value = "todos" }, .{ .name = "x-inertia-reset", .value = "todos" } }),
        partialHeaders("Other", &.{
            .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "append" },
            .{ .name = "x-inertia-infinite-scroll-merge-intent", .value = "append" },
        }),
    };
    inline for (duplicates) |headers| {
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try testing.expectError(error.DuplicatePartialHeader, state.render(&partial_plugin, headers, &res));
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
    try testing.expectEqual(@as(usize, 0), state.calls);
}

const DeferredTest = struct {
    stats_calls: usize = 0,
    feed_calls: usize = 0,

    fn stats(self: *DeferredTest, _: std.mem.Allocator) u32 {
        self.stats_calls += 1;
        return 42;
    }

    fn feed(self: *DeferredTest, _: std.mem.Allocator) error{FeedUnavailable}![]const []const u8 {
        self.feed_calls += 1;
        return &.{"post"};
    }

    fn fail(_: *DeferredTest, _: std.mem.Allocator) error{FeedUnavailable}![]const u8 {
        return error.FeedUnavailable;
    }

    fn render(self: *DeferredTest, headers: []const router.Header, res: *response.Response) !void {
        const req = testRequest(.get, "/dashboard", headers);
        try deferred_plugin.render(&req, res, "Dashboard", .{
            .title = "hi",
            .stats = deferred(self, stats),
            .feed = deferredGroup("social", self, feed),
            .totals = deferred(self, stats),
        });
    }
};

const DeferredShared = struct {
    app_name: []const u8,
    notifications: Deferred("social", *DeferredTest, DeferredTest.stats),
};

var deferred_shared_state: DeferredTest = .{};
const deferred_plugin: Inertia(DeferredShared) = .{
    .layout = test_layout,
    .shared = .{ .value = .{
        .app_name = "zoda",
        .notifications = deferredGroup("social", &deferred_shared_state, DeferredTest.stats),
    } },
};

fn expectDeferredPage(comptime props: []const u8, comptime deferred_props: []const u8, body: []const u8) !void {
    try testing.expectEqualStrings(
        "{\"component\":\"Dashboard\",\"props\":{" ++ props ++ "},\"url\":\"/dashboard\",\"version\":null," ++
            deferred_props ++ "\"sharedProps\":[\"app_name\",\"notifications\"]}",
        body,
    );
}

test "full visits omit deferred props and list them by group" {
    deferred_shared_state = .{};
    var state: DeferredTest = .{};
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try state.render(&inertia_headers, &json);
    try expectDeferredPage(
        "\"app_name\":\"zoda\",\"title\":\"hi\",\"errors\":{}",
        "\"deferredProps\":{\"social\":[\"notifications\",\"feed\"],\"default\":[\"stats\",\"totals\"]},",
        json.body,
    );
    try testing.expectEqual(@as(usize, 0), state.stats_calls + state.feed_calls + deferred_shared_state.stats_calls);

    // The shape matches `Page.deferredProps` in @inertiajs/core 3.9.1:
    // `Record<string, string[]>`.
    const Page = struct { deferredProps: std.json.ArrayHashMap([]const []const u8) };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, json.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.deferredProps.map.count());
    try testing.expectEqualStrings("totals", parsed.value.deferredProps.map.get("default").?[1]);

    // The HTML shell lists them the same way.
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try state.render(&.{}, &html);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"deferredProps\":{\"social\":[\"notifications\",\"feed\"],\"default\":[\"stats\",\"totals\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"stats\":") == null);

    // Another component's partial reload is a full visit for this one.
    var other = response.Response.init(testing.allocator);
    defer other.deinit();
    try state.render(partialHeaders("Other", &.{.{ .name = "X-Inertia-Partial-Data", .value = "stats" }}), &other);
    try testing.expectEqualStrings(json.body, other.body);
    try testing.expectEqual(@as(usize, 0), state.stats_calls + state.feed_calls + deferred_shared_state.stats_calls);
}

test "a partial reload for a group resolves only its props and lists no groups" {
    deferred_shared_state = .{};
    var state: DeferredTest = .{};
    // What the client sends for the "default" group: `only: ['stats', 'totals']`.
    var default_group = response.Response.init(testing.allocator);
    defer default_group.deinit();
    try state.render(partialHeaders("Dashboard", &.{.{ .name = "X-Inertia-Partial-Data", .value = "stats,totals" }}), &default_group);
    try expectDeferredPage("\"stats\":42,\"totals\":42,\"errors\":{}", "", default_group.body);
    try testing.expectEqual(@as(usize, 2), state.stats_calls);
    try testing.expectEqual(@as(usize, 0), state.feed_calls + deferred_shared_state.stats_calls);

    var social = response.Response.init(testing.allocator);
    defer social.deinit();
    try state.render(partialHeaders("Dashboard", &.{.{ .name = "X-Inertia-Partial-Data", .value = "notifications,feed" }}), &social);
    try expectDeferredPage("\"notifications\":42,\"feed\":[\"post\"],\"errors\":{}", "", social.body);
    try testing.expectEqual(@as(usize, 1), state.feed_calls);
    try testing.expectEqual(@as(usize, 1), deferred_shared_state.stats_calls);
    try testing.expectEqual(@as(usize, 2), state.stats_calls);

    // An unrelated partial reload neither resolves nor lists them.
    var unrelated = response.Response.init(testing.allocator);
    defer unrelated.deinit();
    try state.render(partialHeaders("Dashboard", &.{.{ .name = "X-Inertia-Partial-Data", .value = "title" }}), &unrelated);
    try expectDeferredPage("\"title\":\"hi\",\"errors\":{}", "", unrelated.body);
    try testing.expectEqual(@as(usize, 2), state.stats_calls);

    // Like `optional` props, an except-only reload resolves the rest.
    var except = response.Response.init(testing.allocator);
    defer except.deinit();
    try state.render(partialHeaders("Dashboard", &.{.{ .name = "X-Inertia-Partial-Except", .value = "app_name,title,feed,notifications" }}), &except);
    try expectDeferredPage("\"stats\":42,\"totals\":42,\"errors\":{}", "", except.body);
    try testing.expectEqual(@as(usize, 4), state.stats_calls);
    try testing.expectEqual(@as(usize, 1), state.feed_calls);
}

test "route props override deferred shared props and unset shared ones are not listed" {
    deferred_shared_state = .{};
    var state: DeferredTest = .{};
    const req = testRequest(.get, "/dashboard", &inertia_headers);
    var overridden = response.Response.init(testing.allocator);
    defer overridden.deinit();
    try deferred_plugin.render(&req, &overridden, "Dashboard", .{ .notifications = @as(u32, 3), .feed = deferredGroup("social", &state, DeferredTest.feed) });
    try expectDeferredPage("\"app_name\":\"zoda\",\"notifications\":3,\"errors\":{}", "\"deferredProps\":{\"social\":[\"feed\"]},", overridden.body);

    // Without shared values, only the route's deferred props are listed,
    // and with none at all the field is left out.
    const unset: Inertia(DeferredShared) = .{ .layout = test_layout };
    var route_only = response.Response.init(testing.allocator);
    defer route_only.deinit();
    try unset.render(&req, &route_only, "Dashboard", .{ .stats = deferred(&state, DeferredTest.stats) });
    try testing.expectEqualStrings(
        "{\"component\":\"Dashboard\",\"props\":{\"errors\":{}},\"url\":\"/dashboard\",\"version\":null,\"deferredProps\":{\"default\":[\"stats\"]}}",
        route_only.body,
    );
    var none = response.Response.init(testing.allocator);
    defer none.deinit();
    try unset.render(&req, &none, "Dashboard", .{});
    try testing.expectEqualStrings("{\"component\":\"Dashboard\",\"props\":{\"errors\":{}},\"url\":\"/dashboard\",\"version\":null}", none.body);
    try testing.expectEqual(@as(usize, 0), state.stats_calls + state.feed_calls + deferred_shared_state.stats_calls);
}

test "deferred callback errors propagate and leave the response unchanged" {
    var state: DeferredTest = .{};
    const plugin: TestInertia = .{ .layout = test_layout };
    const req = testRequest(.get, "/dashboard", partialHeaders("Dashboard", &.{.{ .name = "X-Inertia-Partial-Data", .value = "feed" }}));
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    try testing.expectError(error.FeedUnavailable, plugin.render(&req, &res, "Dashboard", .{ .feed = deferred(&state, DeferredTest.fail) }));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqualStrings("keep", res.body);
    try testing.expectEqual(@as(usize, 0), res.header_count);

    // A full visit never runs the failing callback.
    const full = testRequest(.get, "/dashboard", &inertia_headers);
    try plugin.render(&full, &res, "Dashboard", .{ .feed = deferred(&state, DeferredTest.fail) });
    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"deferredProps\":{\"default\":[\"feed\"]}") != null);
}

const MergeTest = struct {
    const Item = struct { id: u32, text: []const u8 };
    const Feed = struct { posts: []const Item, meta: struct { page: u32 } };

    feed_calls: usize = 0,

    fn feed(self: *MergeTest, _: std.mem.Allocator) Feed {
        self.feed_calls += 1;
        return .{ .posts = &.{.{ .id = 3, .text = "c" }}, .meta = .{ .page = 2 } };
    }

    fn fail(_: *MergeTest, _: std.mem.Allocator) error{FeedUnavailable}![]const Item {
        return error.FeedUnavailable;
    }

    fn render(self: *MergeTest, headers: []const router.Header, res: *response.Response) !void {
        const req = testRequest(.get, "/feed", headers);
        try merge_plugin.render(&req, res, "Feed", .{
            .title = "hi",
            .items = merge(@as([]const Item, &.{.{ .id = 1, .text = "a" }})).matchOn("id"),
            .alerts = prepend(@as([]const []const u8, &.{"new"})),
            .feed = deepMerge(deferred(self, MergeTest.feed)).matchOn("posts.id"),
            .tags = merge(@as([]const []const u8, &.{"zig"})),
        });
    }
};

const MergeShared = struct {
    app_name: []const u8,
    notices: Mergeable(.append, []const MergeTest.Item, &.{"id"}),
};

const merge_plugin: Inertia(MergeShared) = .{
    .layout = test_layout,
    .shared = .{ .value = .{
        .app_name = "zoda",
        .notices = merge(@as([]const MergeTest.Item, &.{.{ .id = 9, .text = "hello" }})).matchOn("id"),
    } },
};

fn expectMergePage(comptime props: []const u8, comptime fields: []const u8, body: []const u8) !void {
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{" ++ props ++ "},\"url\":\"/feed\",\"version\":null," ++
            fields ++ "\"sharedProps\":[\"app_name\",\"notices\"]}",
        body,
    );
}

test "merge, prepend, and deep merge props are listed with their match keys" {
    var state: MergeTest = .{};
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try state.render(&inertia_headers, &json);
    // `feed` is deferred, so a full visit neither sends nor lists it as merged.
    try expectMergePage(
        "\"app_name\":\"zoda\",\"notices\":[{\"id\":9,\"text\":\"hello\"}],\"title\":\"hi\",\"items\":[{\"id\":1,\"text\":\"a\"}]," ++
            "\"alerts\":[\"new\"],\"tags\":[\"zig\"],\"errors\":{}",
        "\"mergeProps\":[\"notices\",\"items\",\"tags\"],\"prependProps\":[\"alerts\"],\"matchPropsOn\":[\"notices.id\",\"items.id\"]," ++
            "\"deferredProps\":{\"default\":[\"feed\"]},",
        json.body,
    );
    try testing.expectEqual(@as(usize, 0), state.feed_calls);

    // The shapes match `Page` in @inertiajs/core 3.9.1: each field is `string[]`.
    const Page = struct {
        mergeProps: []const []const u8,
        prependProps: []const []const u8,
        matchPropsOn: []const []const u8,
        deepMergeProps: ?[]const []const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, json.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("items", parsed.value.mergeProps[1]);
    try testing.expectEqual(@as(?[]const []const u8, null), parsed.value.deepMergeProps);

    // The HTML shell lists them the same way.
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try state.render(&.{}, &html);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"mergeProps\":[\"notices\",\"items\",\"tags\"],\"prependProps\":[\"alerts\"]") != null);

    // The deferred reload resolves `feed` and lists it for a deep merge,
    // with the match key below the prop.
    var loaded = response.Response.init(testing.allocator);
    defer loaded.deinit();
    try state.render(partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "feed" }}), &loaded);
    try expectMergePage(
        "\"feed\":{\"posts\":[{\"id\":3,\"text\":\"c\"}],\"meta\":{\"page\":2}},\"errors\":{}",
        "\"deepMergeProps\":[\"feed\"],\"matchPropsOn\":[\"feed.posts.id\"],",
        loaded.body,
    );
    try testing.expectEqual(@as(usize, 1), state.feed_calls);
}

test "partial reloads list only the merge props they send" {
    var state: MergeTest = .{};
    var only = response.Response.init(testing.allocator);
    defer only.deinit();
    try state.render(partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "items,title" }}), &only);
    try expectMergePage(
        "\"title\":\"hi\",\"items\":[{\"id\":1,\"text\":\"a\"}],\"errors\":{}",
        "\"mergeProps\":[\"items\"],\"matchPropsOn\":[\"items.id\"],",
        only.body,
    );

    var except = response.Response.init(testing.allocator);
    defer except.deinit();
    try state.render(partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Except", .value = "app_name,notices,items,feed,tags" }}), &except);
    try expectMergePage("\"title\":\"hi\",\"alerts\":[\"new\"],\"errors\":{}", "\"prependProps\":[\"alerts\"],", except.body);

    // Nothing merged in the response, so no merge fields at all.
    var plain = response.Response.init(testing.allocator);
    defer plain.deinit();
    try state.render(partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "title" }}), &plain);
    try expectMergePage("\"title\":\"hi\",\"errors\":{}", "", plain.body);
    try testing.expectEqual(@as(usize, 0), state.feed_calls);
}

test "X-Inertia-Reset sends the listed props without merge metadata" {
    var state: MergeTest = .{};
    // What `router.reload({ reset: ['items', 'feed'] })` sends: the reset
    // names are also in `-Data`.
    var reset = response.Response.init(testing.allocator);
    defer reset.deinit();
    try state.render(partialHeaders("Feed", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "items,feed,notices" },
        .{ .name = "X-Inertia-Reset", .value = "items,feed,title,missing" },
    }), &reset);
    try expectMergePage(
        "\"notices\":[{\"id\":9,\"text\":\"hello\"}],\"items\":[{\"id\":1,\"text\":\"a\"}]," ++
            "\"feed\":{\"posts\":[{\"id\":3,\"text\":\"c\"}],\"meta\":{\"page\":2}},\"errors\":{}",
        "\"mergeProps\":[\"notices\"],\"matchPropsOn\":[\"notices.id\"],",
        reset.body,
    );
    try testing.expectEqual(@as(usize, 1), state.feed_calls);

    // Only whole top-level names reset a prop.
    var dotted = response.Response.init(testing.allocator);
    defer dotted.deinit();
    try state.render(partialHeaders("Feed", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "items" },
        .{ .name = "X-Inertia-Reset", .value = "items.id" },
    }), &dotted);
    try testing.expect(std.mem.indexOf(u8, dotted.body, "\"mergeProps\":[\"items\"]") != null);

    // The client merges only on a partial reload of the same component, so
    // a reset for another component, or with no component, changes nothing.
    var full = response.Response.init(testing.allocator);
    defer full.deinit();
    try state.render(&inertia_headers, &full);
    inline for (.{
        partialHeaders("Other", &.{.{ .name = "X-Inertia-Reset", .value = "items,tags,notices,alerts" }}),
        &[_]router.Header{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Reset", .value = "items" } },
    }) |headers| {
        var other = response.Response.init(testing.allocator);
        defer other.deinit();
        try state.render(headers, &other);
        try testing.expectEqualStrings(full.body, other.body);
    }
    // Ordinary HTML visits ignore it, even malformed.
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try state.render(&.{.{ .name = "X-Inertia-Reset", .value = ",," }}, &html);
    try testing.expectEqualStrings(html_content_type, html.content_type);
}

test "route props override shared merge props and unset shared ones are not listed" {
    const req = testRequest(.get, "/feed", &inertia_headers);
    var overridden = response.Response.init(testing.allocator);
    defer overridden.deinit();
    try merge_plugin.render(&req, &overridden, "Feed", .{ .notices = prepend(@as([]const u32, &.{1})) });
    try expectMergePage(
        "\"app_name\":\"zoda\",\"notices\":[1],\"errors\":{}",
        "\"prependProps\":[\"notices\"],",
        overridden.body,
    );

    const unset: Inertia(MergeShared) = .{ .layout = test_layout };
    var route_only = response.Response.init(testing.allocator);
    defer route_only.deinit();
    try unset.render(&req, &route_only, "Feed", .{ .more = deepMerge(.{ .a = @as(u32, 1) }) });
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{\"more\":{\"a\":1},\"errors\":{}},\"url\":\"/feed\",\"version\":null,\"deepMergeProps\":[\"more\"]}",
        route_only.body,
    );
}

test "optional merge props resolve only when sent and their errors propagate" {
    var state: MergeTest = .{};
    const Plain = struct {
        fn items(_: void, _: std.mem.Allocator) []const u32 {
            return &.{ 4, 5 };
        }
    };
    const plugin: TestInertia = .{ .layout = test_layout };
    const full = testRequest(.get, "/feed", &inertia_headers);
    var skipped = response.Response.init(testing.allocator);
    defer skipped.deinit();
    try plugin.render(&full, &skipped, "Feed", .{ .items = merge(optional({}, Plain.items)), .bad = merge(optional(&state, MergeTest.fail)) });
    try testing.expectEqualStrings("{\"component\":\"Feed\",\"props\":{\"errors\":{}},\"url\":\"/feed\",\"version\":null}", skipped.body);

    // What `router.reload({ only: ['items'] })` for the next page sends.
    const next = testRequest(.get, "/feed?page=2", partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "items" }}));
    var page = response.Response.init(testing.allocator);
    defer page.deinit();
    try plugin.render(&next, &page, "Feed", .{ .items = merge(optional({}, Plain.items)), .bad = merge(optional(&state, MergeTest.fail)) });
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{\"items\":[4,5],\"errors\":{}},\"url\":\"/feed?page=2\",\"version\":null,\"mergeProps\":[\"items\"]}",
        page.body,
    );

    const failing = testRequest(.get, "/feed", partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "bad" }}));
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    try testing.expectError(error.FeedUnavailable, plugin.render(&failing, &res, "Feed", .{ .bad = merge(optional(&state, MergeTest.fail)) }));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqualStrings("keep", res.body);
    try testing.expectEqual(@as(usize, 0), res.header_count);
}

const ScrollTest = struct {
    const Item = MergeTest.Item;
    const pages = [_][]const Item{
        &.{ .{ .id = 1, .text = "a" }, .{ .id = 2, .text = "b" } },
        &.{ .{ .id = 3, .text = "c" }, .{ .id = 4, .text = "d" } },
        &.{.{ .id = 5, .text = "e" }},
    };

    /// What a route does: read `?page=` itself and pass one page of items
    /// with its neighbours.
    fn render(plugin: anytype, target: []const u8, headers: []const router.Header, res: *response.Response) !void {
        var req = testRequest(.get, target, headers);
        // `testRequest` does not parse the query; these targets have at most `page`.
        const query = [_]router.QueryPair{.{ .key = "page", .value = if (std.mem.indexOf(u8, target, "?page=")) |at| target[at + 6 ..] else "" }};
        if (query[0].value.len != 0) req.query = &query;
        const raw = (req.getOne("page") catch null) orelse "1";
        const current = std.fmt.parseInt(u32, raw, 10) catch 1;
        const index = @min(@max(current, 1), pages.len) - 1;
        try plugin.render(&req, res, "Feed", .{
            .title = "hi",
            .items = scroll(pages[index], .{
                .previous = if (index > 0) @intCast(index) else null,
                .next = if (index + 1 < pages.len) @intCast(index + 2) else null,
                .current = @intCast(index + 1),
            }).matchOn("id"),
        });
    }
};

const scroll_plugin: TestInertia = .{ .layout = test_layout };

fn expectScrollPage(comptime url: []const u8, comptime props: []const u8, comptime fields: []const u8, body: []const u8) !void {
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{" ++ props ++ "},\"url\":\"" ++ url ++ "\",\"version\":null" ++ fields ++ "}",
        body,
    );
}

/// What `<InfiniteScroll data="items">` sends to load a page.
fn scrollHeaders(comptime intent: []const u8) []const router.Header {
    return partialHeaders("Feed", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "items" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = intent },
    });
}

test "the first page of a scroll prop is merged and lists its pagination" {
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed", &inertia_headers, &json);
    try expectScrollPage(
        "/feed",
        "\"title\":\"hi\",\"items\":[{\"id\":1,\"text\":\"a\"},{\"id\":2,\"text\":\"b\"}],\"errors\":{}",
        ",\"mergeProps\":[\"items\"],\"matchPropsOn\":[\"items.id\"]," ++
            "\"scrollProps\":{\"items\":{\"pageName\":\"page\",\"previousPage\":null,\"nextPage\":2,\"currentPage\":1,\"reset\":false}}",
        json.body,
    );

    // The entry matches `ScrollProp` in @inertiajs/core 3.9.1.
    const ScrollProp = struct { pageName: []const u8, previousPage: ?u32, nextPage: ?u32, currentPage: u32, reset: bool };
    const Page = struct { scrollProps: struct { items: ScrollProp }, mergeProps: []const []const u8 };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, json.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("page", parsed.value.scrollProps.items.pageName);
    try testing.expectEqual(@as(?u32, 2), parsed.value.scrollProps.items.nextPage);

    // The HTML shell carries the same entry, and an intent header without
    // a partial reload changes nothing.
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed", &.{.{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" }}, &html);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"mergeProps\":[\"items\"],\"matchPropsOn\":[\"items.id\"],\"scrollProps\":{\"items\":{") != null);
    var full = response.Response.init(testing.allocator);
    defer full.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed", &.{ .{ .name = "X-Inertia", .value = "true" }, .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" } }, &full);
    try testing.expectEqualStrings(json.body, full.body);
}

test "next and previous pages follow the merge intent" {
    var next = response.Response.init(testing.allocator);
    defer next.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed?page=2", scrollHeaders("append"), &next);
    try expectScrollPage(
        "/feed?page=2",
        "\"items\":[{\"id\":3,\"text\":\"c\"},{\"id\":4,\"text\":\"d\"}],\"errors\":{}",
        ",\"mergeProps\":[\"items\"],\"matchPropsOn\":[\"items.id\"]," ++
            "\"scrollProps\":{\"items\":{\"pageName\":\"page\",\"previousPage\":1,\"nextPage\":3,\"currentPage\":2,\"reset\":false}}",
        next.body,
    );

    // A reload without the header appends, as the client's own default.
    var unspecified = response.Response.init(testing.allocator);
    defer unspecified.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed?page=2", partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "items" }}), &unspecified);
    try testing.expectEqualStrings(next.body, unspecified.body);

    // Scrolling up from a page opened at ?page=3 loads page 2 before it.
    var previous = response.Response.init(testing.allocator);
    defer previous.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed?page=2", scrollHeaders("prepend"), &previous);
    try expectScrollPage(
        "/feed?page=2",
        "\"items\":[{\"id\":3,\"text\":\"c\"},{\"id\":4,\"text\":\"d\"}],\"errors\":{}",
        ",\"prependProps\":[\"items\"],\"matchPropsOn\":[\"items.id\"]," ++
            "\"scrollProps\":{\"items\":{\"pageName\":\"page\",\"previousPage\":1,\"nextPage\":3,\"currentPage\":2,\"reset\":false}}",
        previous.body,
    );

    var last = response.Response.init(testing.allocator);
    defer last.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed?page=3", scrollHeaders("append"), &last);
    try testing.expect(std.mem.indexOf(u8, last.body, "{\"pageName\":\"page\",\"previousPage\":2,\"nextPage\":null,\"currentPage\":3,\"reset\":false}") != null);

    // The intent of a reload for another component is checked but unused.
    var other = response.Response.init(testing.allocator);
    defer other.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed", partialHeaders("Other", &.{.{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" }}), &other);
    try testing.expect(std.mem.indexOf(u8, other.body, "\"title\":\"hi\"") != null);
    try testing.expect(std.mem.indexOf(u8, other.body, "\"mergeProps\":[\"items\"]") != null);
}

test "reset scroll props are replaced and marked reset, and filtered ones are not listed" {
    // What `router.reload({ only: ['items'], reset: ['items'] })` sends.
    var reset = response.Response.init(testing.allocator);
    defer reset.deinit();
    try ScrollTest.render(&scroll_plugin, "/feed", partialHeaders("Feed", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "items" },
        .{ .name = "X-Inertia-Reset", .value = "items" },
    }), &reset);
    try expectScrollPage(
        "/feed",
        "\"items\":[{\"id\":1,\"text\":\"a\"},{\"id\":2,\"text\":\"b\"}],\"errors\":{}",
        ",\"scrollProps\":{\"items\":{\"pageName\":\"page\",\"previousPage\":null,\"nextPage\":2,\"currentPage\":1,\"reset\":true}}",
        reset.body,
    );

    inline for (.{
        .{ "X-Inertia-Partial-Data", "title" },
        .{ "X-Inertia-Partial-Except", "items" },
    }) |list| {
        var filtered = response.Response.init(testing.allocator);
        defer filtered.deinit();
        try ScrollTest.render(&scroll_plugin, "/feed", partialHeaders("Feed", &.{
            .{ .name = list[0], .value = list[1] },
            .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" },
        }), &filtered);
        try expectScrollPage("/feed", "\"title\":\"hi\",\"errors\":{}", "", filtered.body);
    }
}

test "invalid scroll page names fail without changing the response" {
    const long = "p" ** 65;
    inline for (.{ "", "a b", "page&x=1", "users[page]", long }) |name| {
        // Checked even when the prop is not sent.
        inline for (.{ &inertia_headers, partialHeaders("Feed", &.{.{ .name = "X-Inertia-Partial-Data", .value = "title" }}) }) |headers| {
            const req = testRequest(.get, "/feed", headers);
            var res = response.Response.init(testing.allocator);
            defer res.deinit();
            try res.text(201, "keep");
            try testing.expectError(error.InvalidScrollPageName, scroll_plugin.render(&req, &res, "Feed", .{
                .title = "hi",
                .items = scroll(@as([]const u32, &.{1}), .{ .page_name = name, .current = 1 }),
            }));
            try testing.expectEqual(@as(u16, 201), res.status_code);
            try testing.expectEqualStrings("keep", res.body);
            try testing.expectEqual(@as(usize, 0), res.header_count);
        }
    }

    const req = testRequest(.get, "/feed", &inertia_headers);
    var ok = response.Response.init(testing.allocator);
    defer ok.deinit();
    try scroll_plugin.render(&req, &ok, "Feed", .{ .items = scroll(@as([]const u32, &.{1}), .{ .page_name = "p" ** 64, .current = 1 }) });
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"pageName\":\"" ++ "p" ** 64 ++ "\"") != null);
}

const ScrollShared = struct {
    app_name: []const u8,
    notices: Scroll([]const u32),
};

test "shared and optional scroll props are listed only when sent and their errors propagate" {
    var state: MergeTest = .{};
    const Later = struct {
        fn items(_: void, _: std.mem.Allocator) []const u32 {
            return &.{ 7, 8 };
        }
    };
    const shared: Inertia(ScrollShared) = .{
        .layout = test_layout,
        .shared = .{ .value = .{ .app_name = "zoda", .notices = scroll(@as([]const u32, &.{1}), .{ .page_name = "notices_page", .next = 2, .current = 1 }) } },
    };
    const full = testRequest(.get, "/feed", &inertia_headers);
    var page = response.Response.init(testing.allocator);
    defer page.deinit();
    try shared.render(&full, &page, "Feed", .{ .items = scroll(optional({}, Later.items), .{ .current = 1, .next = 2 }) });
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{\"app_name\":\"zoda\",\"notices\":[1],\"errors\":{}},\"url\":\"/feed\",\"version\":null," ++
            "\"mergeProps\":[\"notices\"],\"scrollProps\":{\"notices\":{\"pageName\":\"notices_page\",\"previousPage\":null,\"nextPage\":2,\"currentPage\":1,\"reset\":false}}," ++
            "\"sharedProps\":[\"app_name\",\"notices\"]}",
        page.body,
    );

    const prepend_items = testRequest(.get, "/feed", partialHeaders("Feed", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "items" },
        .{ .name = "X-Inertia-Infinite-Scroll-Merge-Intent", .value = "prepend" },
    }));
    var loaded = response.Response.init(testing.allocator);
    defer loaded.deinit();
    try shared.render(&prepend_items, &loaded, "Feed", .{ .items = scroll(optional({}, Later.items), .{ .current = 1, .next = 2 }) });
    try testing.expectEqualStrings(
        "{\"component\":\"Feed\",\"props\":{\"items\":[7,8],\"errors\":{}},\"url\":\"/feed\",\"version\":null," ++
            "\"prependProps\":[\"items\"],\"scrollProps\":{\"items\":{\"pageName\":\"page\",\"previousPage\":null,\"nextPage\":2,\"currentPage\":1,\"reset\":false}}," ++
            "\"sharedProps\":[\"app_name\",\"notices\"]}",
        loaded.body,
    );

    // Unset shared values list nothing.
    const unset: Inertia(ScrollShared) = .{ .layout = test_layout };
    var bare = response.Response.init(testing.allocator);
    defer bare.deinit();
    try unset.render(&full, &bare, "Feed", .{});
    try testing.expectEqualStrings("{\"component\":\"Feed\",\"props\":{\"errors\":{}},\"url\":\"/feed\",\"version\":null}", bare.body);

    const failing = testRequest(.get, "/feed", scrollHeaders("append"));
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    try testing.expectError(error.FeedUnavailable, scroll_plugin.render(&failing, &res, "Feed", .{ .items = scroll(optional(&state, MergeTest.fail), .{ .current = 1 }) }));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqualStrings("keep", res.body);
    try testing.expectEqual(@as(usize, 0), res.header_count);
}

const OnceTest = struct {
    plans_calls: usize = 0,
    rates_calls: usize = 0,

    fn plans(self: *OnceTest, _: std.mem.Allocator) []const []const u8 {
        self.plans_calls += 1;
        return &.{ "free", "pro" };
    }

    fn rates(self: *OnceTest, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        self.rates_calls += 1;
        return std.fmt.allocPrint(allocator, "rates {d}", .{self.rates_calls});
    }

    fn fail(_: *OnceTest, _: std.mem.Allocator) error{PlansUnavailable}![]const u8 {
        return error.PlansUnavailable;
    }

    fn render(self: *OnceTest, plugin: anytype, headers: []const router.Header, res: *response.Response) !void {
        const req = testRequest(.get, "/billing", headers);
        try plugin.render(&req, res, "Billing", .{
            .title = "hi",
            .plans = once(self, plans),
            .rates = once(self, rates).as("billing.rates").expiresIn(60_000),
        });
    }
};

/// The injected wall clock: reads return `once_now_ms`.
var once_now_ms: i64 = 1_700_000_000_000;
var once_clock_reads: usize = 0;

fn onceClock() i64 {
    once_clock_reads += 1;
    return once_now_ms;
}

const OnceShared = struct {
    app_name: []const u8,
    locale: Onceable("locale", *OnceTest, OnceTest.rates),
};

var once_shared_state: OnceTest = .{};
const once_plugin: Inertia(OnceShared) = .{
    .layout = test_layout,
    .now_milliseconds = onceClock,
    .shared = .{ .value = .{
        .app_name = "zoda",
        .locale = once(&once_shared_state, OnceTest.rates).as("locale"),
    } },
};

fn expectOncePage(comptime props: []const u8, comptime fields: []const u8, body: []const u8) !void {
    try testing.expectEqualStrings(
        "{\"component\":\"Billing\",\"props\":{" ++ props ++ "},\"url\":\"/billing\",\"version\":null," ++
            fields ++ "\"sharedProps\":[\"app_name\",\"locale\"]}",
        body,
    );
}

const once_entries = "\"onceProps\":{\"locale\":{\"prop\":\"locale\",\"expiresAt\":null}," ++
    "\"plans\":{\"prop\":\"plans\",\"expiresAt\":null}," ++
    "\"billing.rates\":{\"prop\":\"rates\",\"expiresAt\":1700000060000}},";

fn onceHeaders(comptime except: []const u8) []const router.Header {
    return &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = except },
    };
}

test "the first visit resolves once props and lists them in onceProps" {
    once_shared_state = .{};
    once_clock_reads = 0;
    var state: OnceTest = .{};
    var json = response.Response.init(testing.allocator);
    defer json.deinit();
    try state.render(&once_plugin, &inertia_headers, &json);
    try expectOncePage(
        "\"app_name\":\"zoda\",\"locale\":\"rates 1\",\"title\":\"hi\",\"plans\":[\"free\",\"pro\"],\"rates\":\"rates 1\",\"errors\":{}",
        once_entries,
        json.body,
    );
    try testing.expectEqual(@as(usize, 1), state.plans_calls);
    try testing.expectEqual(@as(usize, 1), state.rates_calls);
    // One clock read serves every entry of the page.
    try testing.expectEqual(@as(usize, 1), once_clock_reads);

    // The shape matches `Page.onceProps` in @inertiajs/core 3.9.1:
    // `Record<string, {prop, expiresAt?: number | null}>`.
    const OnceProp = struct { prop: []const u8, expiresAt: ?i64 = null };
    const Page = struct { onceProps: std.json.ArrayHashMap(OnceProp) };
    const parsed = try std.json.parseFromSlice(Page, testing.allocator, json.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("rates", parsed.value.onceProps.map.get("billing.rates").?.prop);
    try testing.expectEqual(@as(?i64, 1_700_000_060_000), parsed.value.onceProps.map.get("billing.rates").?.expiresAt);

    // The HTML shell does the same and ignores the header, even malformed:
    // a full page load has no client copy to reuse.
    var html = response.Response.init(testing.allocator);
    defer html.deinit();
    try state.render(&once_plugin, &.{.{ .name = "X-Inertia-Except-Once-Props", .value = ",," }}, &html);
    try testing.expectEqualStrings(html_content_type, html.content_type);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"plans\":[\"free\",\"pro\"]") != null);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"onceProps\":{\"locale\":") != null);
    try testing.expectEqual(@as(usize, 2), state.plans_calls);
}

test "later visits skip once props the client holds but keep their entries" {
    once_shared_state = .{};
    once_clock_reads = 0;
    var state: OnceTest = .{};
    // What the client sends after the first visit: every key it still
    // holds, unexpired.
    var later = response.Response.init(testing.allocator);
    defer later.deinit();
    try state.render(&once_plugin, onceHeaders("locale,plans,billing.rates"), &later);
    try expectOncePage("\"app_name\":\"zoda\",\"title\":\"hi\",\"errors\":{}", once_entries, later.body);
    try testing.expectEqual(@as(usize, 0), state.plans_calls + state.rates_calls + once_shared_state.rates_calls);

    // Keys, not prop names, are matched: `rates` is keyed `billing.rates`.
    // Unknown keys are ignored.
    var by_name = response.Response.init(testing.allocator);
    defer by_name.deinit();
    try state.render(&once_plugin, onceHeaders("rates,missing,plans.x"), &by_name);
    try expectOncePage(
        "\"app_name\":\"zoda\",\"locale\":\"rates 1\",\"title\":\"hi\",\"plans\":[\"free\",\"pro\"],\"rates\":\"rates 1\",\"errors\":{}",
        once_entries,
        by_name.body,
    );

    // A visit to another component is a full visit for this one, and the
    // keys still apply.
    var other = response.Response.init(testing.allocator);
    defer other.deinit();
    try state.render(&once_plugin, &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Partial-Component", .value = "Other" },
        .{ .name = "X-Inertia-Partial-Data", .value = "plans" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "plans" },
    }, &other);
    try testing.expect(std.mem.indexOf(u8, other.body, "\"plans\":[") == null);
    try testing.expectEqual(@as(usize, 1), state.plans_calls);
}

test "a partial reload that lists a once prop sends it fresh" {
    once_shared_state = .{};
    var state: OnceTest = .{};
    // `router.reload({ only: ['plans'] })` while the client holds `plans`.
    var only = response.Response.init(testing.allocator);
    defer only.deinit();
    try state.render(&once_plugin, partialHeaders("Billing", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "plans,rates.0" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "plans,billing.rates,locale" },
    }), &only);
    // Props the list leaves out get no entry; the client keeps its old one.
    try expectOncePage(
        "\"plans\":[\"free\",\"pro\"],\"rates\":\"rates 1\",\"errors\":{}",
        "\"onceProps\":{\"plans\":{\"prop\":\"plans\",\"expiresAt\":null},\"billing.rates\":{\"prop\":\"rates\",\"expiresAt\":1700000060000}},",
        only.body,
    );
    try testing.expectEqual(@as(usize, 1), state.plans_calls);
    try testing.expectEqual(@as(usize, 0), once_shared_state.rates_calls);

    // Only `-Data` asks explicitly: an except-only reload or a bare
    // component header still leaves held props to the client.
    inline for (.{
        &[_]router.Header{.{ .name = "X-Inertia-Partial-Except", .value = "title" }},
        &[_]router.Header{},
    }) |extra| {
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try state.render(&once_plugin, partialHeaders("Billing", extra ++ &[_]router.Header{
            .{ .name = "X-Inertia-Except-Once-Props", .value = "plans,billing.rates,locale" },
        }), &res);
        try testing.expect(std.mem.indexOf(u8, res.body, "\"plans\":[") == null);
        try testing.expect(std.mem.indexOf(u8, res.body, "\"plans\":{\"prop\":\"plans\"") != null);
    }
    try testing.expectEqual(@as(usize, 1), state.plans_calls);

    // `-Except` removes a once prop and its entry.
    var except = response.Response.init(testing.allocator);
    defer except.deinit();
    try state.render(&once_plugin, partialHeaders("Billing", &.{.{ .name = "X-Inertia-Partial-Except", .value = "plans,rates,locale" }}), &except);
    try expectOncePage("\"app_name\":\"zoda\",\"title\":\"hi\",\"errors\":{}", "", except.body);
}

test "once expiry uses the injected clock and is checked before the response changes" {
    once_shared_state = .{};
    var state: OnceTest = .{};
    once_now_ms = 5_000;
    defer once_now_ms = 1_700_000_000_000;
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try state.render(&once_plugin, &inertia_headers, &res);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"billing.rates\":{\"prop\":\"rates\",\"expiresAt\":65000}") != null);

    // The client reuses a held value with its own expiry, but the entry is
    // still recomputed from the clock.
    once_now_ms = 9_000;
    try state.render(&once_plugin, onceHeaders("billing.rates"), &res);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"billing.rates\":{\"prop\":\"rates\",\"expiresAt\":69000}") != null);

    // Without an expiry the clock is not needed, or read.
    once_clock_reads = 0;
    const clockless: TestInertia = .{ .layout = test_layout };
    const req = testRequest(.get, "/billing", &inertia_headers);
    try clockless.render(&req, &res, "Billing", .{ .plans = once(&state, OnceTest.plans) });
    try testing.expectEqualStrings(
        "{\"component\":\"Billing\",\"props\":{\"plans\":[\"free\",\"pro\"],\"errors\":{}},\"url\":\"/billing\",\"version\":null,\"onceProps\":{\"plans\":{\"prop\":\"plans\",\"expiresAt\":null}}}",
        res.body,
    );
    try testing.expectEqual(@as(usize, 0), once_clock_reads);

    const Bad = struct {
        fn negative() i64 {
            return -1;
        }
        fn late() i64 {
            return max_once_expires_at - 10;
        }
    };
    const cases = .{
        .{ TestInertia{ .layout = test_layout }, @as(u64, 1), error.OnceClockNotConfigured },
        .{ TestInertia{ .layout = test_layout, .now_milliseconds = Bad.negative }, @as(u64, 1), error.InvalidOnceTime },
        .{ TestInertia{ .layout = test_layout, .now_milliseconds = Bad.late }, @as(u64, 11), error.InvalidOnceTime },
        .{ TestInertia{ .layout = test_layout, .now_milliseconds = onceClock }, std.math.maxInt(u64), error.InvalidOnceTime },
    };
    inline for (cases) |case| {
        // Checked even when the client holds the value, and on HTML visits.
        inline for (.{ &inertia_headers, onceHeaders("plans"), &[_]router.Header{} }) |headers| {
            const failing = testRequest(.get, "/billing", headers);
            var kept = response.Response.init(testing.allocator);
            defer kept.deinit();
            try kept.text(201, "keep");
            const plugin: TestInertia = case[0];
            try testing.expectError(case[2], plugin.render(&failing, &kept, "Billing", .{ .plans = once(&state, OnceTest.plans).expiresIn(case[1]) }));
            try testing.expectEqual(@as(u16, 201), kept.status_code);
            try testing.expectEqualStrings("keep", kept.body);
            try testing.expectEqual(@as(usize, 0), kept.header_count);
        }
    }

    // The largest exact JavaScript integer is accepted.
    const edge: TestInertia = .{ .layout = test_layout, .now_milliseconds = Bad.late };
    try edge.render(&req, &res, "Billing", .{ .plans = once(&state, OnceTest.plans).expiresIn(10) });
    try testing.expect(std.mem.indexOf(u8, res.body, "\"expiresAt\":9007199254740991}") != null);
}

test "malformed, duplicate, and oversized once headers fail without changing the response" {
    var state: OnceTest = .{};
    const cases = .{
        .{ "", error.MalformedPartialHeader },
        .{ "plans,", error.MalformedPartialHeader },
        .{ "plans, rates", error.MalformedPartialHeader },
        .{ "a..b", error.MalformedPartialHeader },
        .{ "plans;x", error.MalformedPartialHeader },
        .{ "a," ** max_partial_props ++ "a", error.PartialHeaderTooLarge },
        .{ "a" ** (max_partial_bytes + 1), error.PartialHeaderTooLarge },
    };
    inline for (cases) |case| {
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try res.text(201, "keep");
        try testing.expectError(case[1], state.render(&once_plugin, onceHeaders(case[0]), &res));
        try testing.expectEqual(@as(u16, 201), res.status_code);
        try testing.expectEqualStrings("keep", res.body);
        try testing.expectEqual(@as(usize, 0), res.header_count);
    }
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try testing.expectError(error.DuplicatePartialHeader, state.render(&once_plugin, &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia-Except-Once-Props", .value = "plans" },
        .{ .name = "x-inertia-except-once-props", .value = "rates" },
    }, &res));
    try testing.expectEqual(@as(usize, 0), res.header_count);
    try testing.expectEqual(@as(usize, 0), state.plans_calls + state.rates_calls);
}

test "once callback errors propagate and route props override shared once props" {
    var state: OnceTest = .{};
    const plugin: TestInertia = .{ .layout = test_layout };
    const req = testRequest(.get, "/billing", &inertia_headers);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try res.text(201, "keep");
    try testing.expectError(error.PlansUnavailable, plugin.render(&req, &res, "Billing", .{ .plans = once(&state, OnceTest.fail) }));
    try testing.expectEqual(@as(u16, 201), res.status_code);
    try testing.expectEqualStrings("keep", res.body);
    try testing.expectEqual(@as(usize, 0), res.header_count);

    // A held value never runs the failing callback.
    const held = testRequest(.get, "/billing", onceHeaders("plans"));
    try plugin.render(&held, &res, "Billing", .{ .plans = once(&state, OnceTest.fail) });
    try testing.expectEqualStrings(
        "{\"component\":\"Billing\",\"props\":{\"errors\":{}},\"url\":\"/billing\",\"version\":null,\"onceProps\":{\"plans\":{\"prop\":\"plans\",\"expiresAt\":null}}}",
        res.body,
    );

    // A plain route prop replaces the shared once prop and its entry, and
    // unset shared values list nothing.
    once_shared_state = .{};
    var overridden = response.Response.init(testing.allocator);
    defer overridden.deinit();
    try once_plugin.render(&req, &overridden, "Billing", .{ .locale = "fr" });
    try expectOncePage("\"app_name\":\"zoda\",\"locale\":\"fr\",\"errors\":{}", "", overridden.body);
    try testing.expectEqual(@as(usize, 0), once_shared_state.rates_calls);
    const unset: Inertia(OnceShared) = .{ .layout = test_layout };
    var bare = response.Response.init(testing.allocator);
    defer bare.deinit();
    try unset.render(&req, &bare, "Billing", .{});
    try testing.expectEqualStrings("{\"component\":\"Billing\",\"props\":{\"errors\":{}},\"url\":\"/billing\",\"version\":null}", bare.body);
}

const flash_test_secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn flashTestTime() i64 {
    return 1000;
}

const flash_test_sessions: sessions.Sessions = .{
    .keys = &.{.{ .id = 1, .secret = flash_test_secret }},
    .lifetime_seconds = 300,
    .now_seconds = flashTestTime,
};

const FlashTest = struct {
    const App = @import("../app.zig").App(struct {
        sessions: sessions.Sessions,
        flash: flash_mod.Flash = .{},
        inertia: TestInertia,
    });

    fn stats(_: void, _: std.mem.Allocator) u32 {
        return 3;
    }

    fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
        const session = &ctx.state.sessions;
        const inertia = &ctx.plugins.inertia;
        if (!req.onLiteral("todos") or !req.isRoot()) return;
        if (req.method == .post) {
            try ctx.plugins.flash.add(session, "notice", "Todo added");
            try ctx.plugins.sessions.save(session, res);
            return inertia.redirect(req, res, "/todos");
        }
        try inertia.renderWith(req, res, "Todos/Index", .{ .stats = deferred({}, stats) }, .{
            .flash = .{ .plugin = &ctx.plugins.flash, .session = session },
        });
        return ctx.plugins.sessions.save(session, res);
    }

    /// `/denied` short-circuits before the route, so nothing is rendered.
    fn middleware(_: *const anyopaque, ctx: *App.Context, req: *router.Request, res: *response.Response, next: App.Next) !void {
        if (req.segments.len == 1 and std.mem.eql(u8, req.segments[0], "denied")) return res.text(403, "denied");
        return next.call(ctx, req, res);
    }

    fn app() !App {
        return App.init(testing.allocator, .{
            .response_allocator = testing.allocator,
            .plugins = .{ .sessions = flash_test_sessions, .inertia = .{ .layout = test_layout, .version = .{ .value = "v1" } } },
            .route_fn = route,
            .middleware = &.{.{ .config = &.{}, .invoke = middleware }},
        });
    }

    const Outcome = struct { status: u16, body: []const u8, cookie: ?[]const u8 };

    /// Dispatches `target` with the cookie and extra headers, copying the
    /// body and any new session cookie into `out`.
    fn visit(
        a: *const App,
        method: router.Method,
        comptime target: []const u8,
        cookie: ?[]const u8,
        extra: []const router.Header,
        out: *[2][8192]u8,
    ) !Outcome {
        var headers: [8]router.Header = undefined;
        var n: usize = 0;
        if (cookie) |value| {
            headers[0] = .{ .name = "Cookie", .value = value };
            n = 1;
        }
        @memcpy(headers[n..][0..extra.len], extra);
        n += extra.len;
        var req: router.Request = .{ .method = method, .segments = &.{target[1..]}, .target = target, .headers = headers[0..n] };
        var res = try a.dispatch(&req);
        defer res.deinit();
        @memcpy(out[0][0..res.body.len], res.body);
        var outcome: Outcome = .{ .status = res.status_code, .body = out[0][0..res.body.len], .cookie = null };
        if (try res.getHeaderOne("Set-Cookie")) |set_cookie| {
            const value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?];
            @memcpy(out[1][0..value.len], value);
            outcome.cookie = out[1][0..value.len];
        }
        return outcome;
    }

    const page_head = "{\"component\":\"Todos/Index\",\"props\":{\"errors\":{}},\"url\":\"/todos\",\"version\":\"v1\"," ++
        "\"deferredProps\":{\"default\":[\"stats\"]}";
};

test "flash set before a redirect is sent once on the next full visit" {
    var app = try FlashTest.app();
    defer app.deinit();
    var a: [2][8192]u8 = undefined;
    var b: [2][8192]u8 = undefined;
    var c: [2][8192]u8 = undefined;

    const added = try FlashTest.visit(&app, .post, "/todos", null, &inertia_headers, &a);
    try testing.expectEqual(@as(u16, 303), added.status);

    // The followed GET carries the message and consumes it.
    const shown = try FlashTest.visit(&app, .get, "/todos", added.cookie, &inertia_headers, &b);
    try testing.expectEqualStrings(FlashTest.page_head ++ ",\"flash\":{\"notice\":\"Todo added\"}}", shown.body);
    try testing.expect(shown.cookie != null);

    // Afterwards there is no flash field, and nothing to save.
    const after = try FlashTest.visit(&app, .get, "/todos", shown.cookie, &inertia_headers, &c);
    try testing.expectEqualStrings(FlashTest.page_head ++ "}", after.body);
    try testing.expect(after.cookie == null);

    // The HTML shell carries it too, escaped like the rest of the page.
    const html = try FlashTest.visit(&app, .get, "/todos", added.cookie, &.{}, &c);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"deferredProps\":{\"default\":[\"stats\"]},\"flash\":{\"notice\":\"Todo added\"}}</script>") != null);
    try testing.expect(html.cookie != null);
}

test "partial reloads send flash; short circuits, conflicts, and header errors leave it unread" {
    var app = try FlashTest.app();
    defer app.deinit();
    var a: [2][8192]u8 = undefined;
    var b: [2][8192]u8 = undefined;
    var c: [2][8192]u8 = undefined;

    const added = try FlashTest.visit(&app, .post, "/todos", null, &inertia_headers, &a);
    const pending = added.cookie.?;

    // A form posted with `only` is followed by a partial reload, whose
    // flash the client shows, so it is sent and consumed there.
    const reload = try FlashTest.visit(&app, .get, "/todos", pending, partialHeaders("Todos/Index", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "stats" },
    }), &b);
    try testing.expectEqualStrings(
        "{\"component\":\"Todos/Index\",\"props\":{\"stats\":3,\"errors\":{}},\"url\":\"/todos\",\"version\":\"v1\",\"flash\":{\"notice\":\"Todo added\"}}",
        reload.body,
    );
    try testing.expect(reload.cookie != null);

    // The deferred `stats` reload that follows a full visit finds nothing
    // left to send.
    const deferred_reload = try FlashTest.visit(&app, .get, "/todos", reload.cookie, partialHeaders("Todos/Index", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "stats" },
    }), &c);
    try testing.expect(std.mem.indexOf(u8, deferred_reload.body, "\"flash\"") == null);
    try testing.expect(deferred_reload.cookie == null);

    const denied = try FlashTest.visit(&app, .get, "/denied", pending, &.{}, &b);
    try testing.expectEqual(@as(u16, 403), denied.status);
    try testing.expect(denied.cookie == null);

    const stale = try FlashTest.visit(&app, .get, "/todos", pending, &.{.{ .name = "X-Inertia", .value = "true" }}, &b);
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expect(stale.cookie == null);

    // Header errors propagate before anything is read.
    try testing.expectError(error.DuplicateInertiaHeader, FlashTest.visit(&app, .get, "/todos", pending, &.{
        .{ .name = "X-Inertia", .value = "true" },
        .{ .name = "X-Inertia", .value = "true" },
    }, &b));
    try testing.expectError(error.MalformedPartialHeader, FlashTest.visit(&app, .get, "/todos", pending, partialHeaders("Todos/Index", &.{
        .{ .name = "X-Inertia-Partial-Data", .value = "stats,," },
    }), &b));

    // The message is still there for the next full visit.
    const shown = try FlashTest.visit(&app, .get, "/todos", pending, &inertia_headers, &b);
    try testing.expect(std.mem.endsWith(u8, shown.body, ",\"flash\":{\"notice\":\"Todo added\"}}"));
}

/// Session state that received `messages`, as loaded from a saved cookie.
fn receivedFlash(messages: []const [2][]const u8) !sessions.Sessions.State {
    const plugin: flash_mod.Flash = .{};
    var empty: router.Request = .{ .method = .get, .segments = &.{} };
    var state = try flash_test_sessions.initRequest(&empty);
    for (messages) |message| try plugin.add(&state, message[0], message[1]);
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try flash_test_sessions.save(&state, &res);
    const set_cookie = res.headers[0].value;
    const headers = [_]router.Header{.{ .name = "Cookie", .value = set_cookie[0..std.mem.indexOfScalar(u8, set_cookie, ';').?] }};
    var req: router.Request = .{ .method = .get, .segments = &.{}, .headers = &headers };
    return flash_test_sessions.initRequest(&req);
}

test "flash keeps the last message of each kind and its failures leave it unread" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const flash: flash_mod.Flash = .{};
    const req = testRequest(.get, "/", &inertia_headers);
    var state = try receivedFlash(&.{ .{ "notice", "first" }, .{ "alert", "a \"quoted\" <b>" }, .{ "notice", "second" } });
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    try plugin.renderWith(&req, &res, "Home", .{}, .{ .flash = .{ .plugin = &flash, .session = &state } });
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null,\"flash\":{\"alert\":\"a \\\"quoted\\\" <b>\",\"notice\":\"second\"}}",
        res.body,
    );
    try testing.expect(state.dirty and state.flash.consumed);

    // A prop callback error propagates before the messages are read.
    const Failing = struct {
        fn load(_: void, _: std.mem.Allocator) error{Unavailable}!u32 {
            return error.Unavailable;
        }
    };
    var failed = try receivedFlash(&.{.{ "notice", "kept" }});
    try testing.expectError(error.Unavailable, plugin.renderWith(&req, &res, "Home", .{ .n = once({}, Failing.load) }, .{
        .flash = .{ .plugin = &flash, .session = &failed },
    }));
    try testing.expect(!failed.dirty and !failed.flash.consumed);
}

test "flash counts toward the body limit and a failure leaves it unread" {
    const plugin: TestInertia = .{ .layout = "@inertia" };
    const flash: flash_mod.Flash = .{};
    const ordinary = testRequest(.get, "/", &.{});
    // The largest flash: one message of every remaining byte, each of which
    // the script element escapes to six.
    const text = "<" ** (flash_mod.max_bytes - 4);
    const prefix = "<script data-page=\"app\" type=\"application/json\">{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null,\"flash\":{\"n\":\"";
    const suffix = "\"}}</script><div id=\"app\"></div>";
    const size = prefix.len + text.len * "\\u003c".len + suffix.len;

    var too_small = response.Response.initWithLimits(testing.allocator, .{ .max_body_bytes = size - 1 });
    defer too_small.deinit();
    var state = try receivedFlash(&.{.{ "n", text }});
    try testing.expectError(error.BodyTooLarge, plugin.renderWith(&ordinary, &too_small, "Home", .{}, .{
        .flash = .{ .plugin = &flash, .session = &state },
    }));
    try testing.expectEqual(@as(usize, 0), too_small.body.len);
    try testing.expect(!state.dirty and !state.flash.consumed);

    var exact = response.Response.initWithLimits(testing.allocator, .{ .max_body_bytes = size });
    defer exact.deinit();
    try plugin.renderWith(&ordinary, &exact, "Home", .{}, .{ .flash = .{ .plugin = &flash, .session = &state } });
    try testing.expectEqual(size, exact.body.len);
    try testing.expect(std.mem.startsWith(u8, exact.body, prefix ++ "\\u003c"));
    try testing.expect(state.dirty and state.flash.consumed);

    // The JSON form, which leaves `<` as is, is limited the same way.
    const inertia = testRequest(.get, "/", &inertia_headers);
    const json_size = "{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null,\"flash\":{\"n\":\"".len + text.len + "\"}}".len;
    var json = response.Response.initWithLimits(testing.allocator, .{ .max_body_bytes = json_size - 1 });
    defer json.deinit();
    var big = try receivedFlash(&.{.{ "n", text }});
    try testing.expectError(error.BodyTooLarge, plugin.renderWith(&inertia, &json, "Home", .{}, .{
        .flash = .{ .plugin = &flash, .session = &big },
    }));
    try testing.expect(!big.dirty and !big.flash.consumed);
    try testing.expectEqual(@as(usize, 0), json.header_count);
}

/// A request's session state with nothing stored.
fn emptySession() !sessions.Sessions.State {
    var req: router.Request = .{ .method = .get, .segments = &.{} };
    return flash_test_sessions.initRequest(&req);
}

const ErrorsTest = struct {
    const App = FlashTest.App;

    const TodoErrors = struct { text: []const u8, due: ?[]const u8 = null };

    fn route(ctx: *App.Context, req: *router.Request, res: *response.Response) !void {
        const session = &ctx.state.sessions;
        const inertia = &ctx.plugins.inertia;
        const source: FlashSource = .{ .plugin = &ctx.plugins.flash, .session = session };
        if (!req.onLiteral("todos") or !req.isRoot()) return;
        if (req.method == .post) {
            try ctx.plugins.flash.add(session, "alert", "Check the form");
            try inertia.redirectWithErrors(req, res, source, "/todos", TodoErrors{ .text = "Write something first." });
            return ctx.plugins.sessions.save(session, res);
        }
        try inertia.renderWith(req, res, "Todos/Index", .{}, .{ .flash = source });
        return ctx.plugins.sessions.save(session, res);
    }

    fn app() !App {
        return App.init(testing.allocator, .{
            .response_allocator = testing.allocator,
            .plugins = .{ .sessions = flash_test_sessions, .inertia = .{ .layout = test_layout, .version = .{ .value = "v1" } } },
            .route_fn = route,
        });
    }

    fn page(comptime errors: []const u8, comptime rest: []const u8) []const u8 {
        return "{\"component\":\"Todos/Index\",\"props\":{\"errors\":" ++ errors ++ "},\"url\":\"/todos\",\"version\":\"v1\"" ++ rest ++ "}";
    }

    fn withBag(comptime bag: []const u8) []const router.Header {
        return &(inertia_headers ++ [_]router.Header{.{ .name = "X-Inertia-Error-Bag", .value = bag }});
    }
};

test "errors stored before a redirect are sent once as props.errors" {
    var app = try ErrorsTest.app();
    defer app.deinit();
    var a: [2][8192]u8 = undefined;
    var b: [2][8192]u8 = undefined;
    var c: [2][8192]u8 = undefined;

    const failed = try FlashTest.visit(&app, .post, "/todos", null, &inertia_headers, &a);
    try testing.expectEqual(@as(u16, 303), failed.status);
    try testing.expectEqualStrings("", failed.body);

    // The followed GET carries the errors, without the null `due`, and the
    // alert as `flash`, which leaves the errors entry out.
    const shown = try FlashTest.visit(&app, .get, "/todos", failed.cookie, &inertia_headers, &b);
    try testing.expectEqualStrings(
        ErrorsTest.page("{\"text\":\"Write something first.\"}", ",\"flash\":{\"alert\":\"Check the form\"}"),
        shown.body,
    );

    // Displayed once: the saved cookie no longer holds them.
    const after = try FlashTest.visit(&app, .get, "/todos", shown.cookie, &inertia_headers, &c);
    try testing.expectEqualStrings(ErrorsTest.page("{}", ""), after.body);
    try testing.expect(after.cookie == null);

    // A partial reload, which always sends `errors`, consumes them too.
    const reload = try FlashTest.visit(&app, .get, "/todos", failed.cookie, partialHeaders("Todos/Index", &.{
        .{ .name = "X-Inertia-Partial-Except", .value = "errors" },
    }), &c);
    try testing.expect(std.mem.indexOf(u8, reload.body, "\"errors\":{\"text\":\"Write something first.\"}") != null);
    try testing.expect(reload.cookie != null);

    // So does the HTML shell, where they are escaped like the rest.
    const html = try FlashTest.visit(&app, .get, "/todos", failed.cookie, &.{}, &c);
    try testing.expect(std.mem.indexOf(u8, html.body, "\"props\":{\"errors\":{\"text\":\"Write something first.\"}}") != null);

    // A version conflict leaves them unread.
    const stale = try FlashTest.visit(&app, .get, "/todos", failed.cookie, &.{.{ .name = "X-Inertia", .value = "true" }}, &c);
    try testing.expectEqual(@as(u16, 409), stale.status);
    try testing.expect(stale.cookie == null);

    // An ordinary form post redirects the same way and ignores the bag.
    const plain = try FlashTest.visit(&app, .post, "/todos", null, &.{.{ .name = "X-Inertia-Error-Bag", .value = "bad bag" }}, &a);
    try testing.expectEqual(@as(u16, 303), plain.status);
    const plain_shown = try FlashTest.visit(&app, .get, "/todos", plain.cookie, &inertia_headers, &b);
    try testing.expect(std.mem.indexOf(u8, plain_shown.body, "\"errors\":{\"text\":\"Write something first.\"}") != null);
}

test "X-Inertia-Error-Bag nests errors under the bag and bad bags change nothing" {
    var app = try ErrorsTest.app();
    defer app.deinit();
    var a: [2][8192]u8 = undefined;
    var b: [2][8192]u8 = undefined;

    const failed = try FlashTest.visit(&app, .post, "/todos", null, ErrorsTest.withBag("create_todo-2"), &a);
    try testing.expectEqual(@as(u16, 303), failed.status);
    // The bag was applied when storing, so the GET needs no header.
    const shown = try FlashTest.visit(&app, .get, "/todos", failed.cookie, &inertia_headers, &b);
    try testing.expectEqualStrings(
        ErrorsTest.page("{\"create_todo-2\":{\"text\":\"Write something first.\"}}", ",\"flash\":{\"alert\":\"Check the form\"}"),
        shown.body,
    );

    const longest = "b" ** max_error_bag_bytes;
    const at_limit = try FlashTest.visit(&app, .post, "/todos", null, ErrorsTest.withBag(longest), &a);
    try testing.expectEqual(@as(u16, 303), at_limit.status);

    for ([_][]const u8{ "", "has space", "dot.ted", "b" ** (max_error_bag_bytes + 1), "caf\xc3\xa9" }) |bag| {
        const headers = inertia_headers ++ [_]router.Header{.{ .name = "X-Inertia-Error-Bag", .value = bag }};
        try testing.expectError(error.MalformedErrorBagHeader, FlashTest.visit(&app, .post, "/todos", null, &headers, &a));
    }
    try testing.expectError(error.DuplicateErrorBagHeader, FlashTest.visit(&app, .post, "/todos", null, &(inertia_headers ++ [_]router.Header{
        .{ .name = "X-Inertia-Error-Bag", .value = "one" },
        .{ .name = "x-inertia-error-bag", .value = "two" },
    }), &a));

    // Direct calls: a header error leaves the response and session as they were.
    const plugin: TestInertia = .{ .layout = test_layout };
    const flash: flash_mod.Flash = .{};
    var state = try emptySession();
    var res = response.Response.init(testing.allocator);
    defer res.deinit();
    const req = testRequest(.post, "/todos", &(inertia_headers ++ [_]router.Header{.{ .name = "X-Inertia-Error-Bag", .value = "a,b" }}));
    try testing.expectError(error.MalformedErrorBagHeader, plugin.redirectWithErrors(&req, &res, .{ .plugin = &flash, .session = &state }, "/todos", .{ .text = "x" }));
    try testing.expectEqual(@as(usize, 0), res.header_count);
    try testing.expect(!state.dirty and state.flash.queued_count == 0);
    try testing.expectEqual(@as(?[]const u8, null), try errorBag(&testRequest(.get, "/", &.{})));
}

test "redirectWithErrors validates the path, fragments, limits, and size first" {
    const plugin: TestInertia = .{ .layout = test_layout };
    const flash: flash_mod.Flash = .{};
    const inertia_post = testRequest(.post, "/todos", &inertia_headers);
    const plain_post = testRequest(.post, "/todos", &.{});

    // An Inertia request to a path with a fragment gets X-Inertia-Redirect.
    var state = try emptySession();
    var fragment = response.Response.init(testing.allocator);
    defer fragment.deinit();
    try plugin.redirectWithErrors(&inertia_post, &fragment, .{ .plugin = &flash, .session = &state }, "/todos#new", .{ .text = "x" });
    try testing.expectEqual(@as(u16, 409), fragment.status_code);
    try testing.expectEqualStrings("/todos#new", (try fragment.getHeaderOne("X-Inertia-Redirect")).?);
    try testing.expect(state.dirty and state.flash.queued_count == 1);

    // A GET still gets 303, and a plain request keeps the fragment in Location.
    var get_state = try emptySession();
    var after_get = response.Response.init(testing.allocator);
    defer after_get.deinit();
    try plugin.redirectWithErrors(&testRequest(.get, "/todos", &.{}), &after_get, .{ .plugin = &flash, .session = &get_state }, "/todos#new", .{ .text = "x" });
    try testing.expectEqual(@as(u16, 303), after_get.status_code);
    try testing.expectEqualStrings("/todos#new", (try after_get.getHeaderOne("Location")).?);

    const Failure = struct { path: []const u8, limits: response.Limits = .{}, expected: ErrorsRedirectError };
    const failures = [_]Failure{
        .{ .path = "https://evil.example/", .expected = error.InvalidRedirectPath },
        .{ .path = "//evil.example/", .expected = error.InvalidRedirectPath },
        .{ .path = "/a\\b", .expected = error.InvalidRedirectPath },
        .{ .path = "", .expected = error.InvalidRedirectPath },
        .{ .path = "/todos", .limits = .{ .max_headers = 0 }, .expected = error.TooManyHeaders },
        .{ .path = "/todos", .limits = .{ .header_bytes = "Location".len + "/todos".len - 1 }, .expected = error.HeaderBytesExceeded },
    };
    for (failures) |failure| {
        var unchanged = try emptySession();
        var res = response.Response.initWithLimits(testing.allocator, failure.limits);
        defer res.deinit();
        try testing.expectError(failure.expected, plugin.redirectWithErrors(&plain_post, &res, .{ .plugin = &flash, .session = &unchanged }, failure.path, .{ .text = "x" }));
        try testing.expectEqual(@as(usize, 0), res.header_count);
        try testing.expect(!res.handled and !unchanged.dirty and unchanged.flash.queued_count == 0);
    }

    // A fragment redirect also reserves room for `Vary`.
    var tight_state = try emptySession();
    var tight = response.Response.initWithLimits(testing.allocator, .{ .max_headers = 1 });
    defer tight.deinit();
    try testing.expectError(error.TooManyHeaders, plugin.redirectWithErrors(&inertia_post, &tight, .{ .plugin = &flash, .session = &tight_state }, "/todos#new", .{ .text = "x" }));
    try testing.expect(!tight_state.dirty);

    // A Location already set is not replaced.
    var set_state = try emptySession();
    var set = response.Response.init(testing.allocator);
    defer set.deinit();
    try set.setHeader("Location", "/elsewhere");
    try testing.expectError(error.LocationAlreadySet, plugin.redirectWithErrors(&plain_post, &set, .{ .plugin = &flash, .session = &set_state }, "/todos", .{ .text = "x" }));
    try testing.expect(!set_state.dirty);

    // Errors share the flash budget with unread messages.
    const big = "x" ** (flash_mod.max_bytes - 3 - errors_flash_kind.len - "{\"text\":\"\"}".len);
    var fits_state = try emptySession();
    var fits = response.Response.init(testing.allocator);
    defer fits.deinit();
    try plugin.redirectWithErrors(&plain_post, &fits, .{ .plugin = &flash, .session = &fits_state }, "/todos", .{ .text = big });
    var full_state = try receivedFlash(&.{.{ "notice", "unread" }});
    var full = response.Response.init(testing.allocator);
    defer full.deinit();
    try testing.expectError(error.FlashTooLarge, plugin.redirectWithErrors(&plain_post, &full, .{ .plugin = &flash, .session = &full_state }, "/todos", .{ .text = big }));
    try testing.expectError(error.FlashTooLarge, plugin.redirectWithErrors(&plain_post, &full, .{ .plugin = &flash, .session = &full_state }, "/todos", .{ .text = "x" ** flash_mod.max_bytes }));
    try testing.expectEqual(@as(usize, 0), full.header_count);
    try testing.expect(!full_state.dirty);
}

test "route errors win over stored errors, which win over shared errors" {
    const flash: flash_mod.Flash = .{};
    const req = testRequest(.get, "/", &inertia_headers);
    const stored = "{\"text\":\"stored\"}";

    const WithErrors = Inertia(struct { app: []const u8, errors: struct { base: []const u8 } });
    const shared: WithErrors = .{ .layout = test_layout, .shared = .{ .value = .{ .app = "zoda", .errors = .{ .base = "shared" } } } };
    const plain: TestInertia = .{ .layout = test_layout };

    var over_shared = try receivedFlash(&.{.{ errors_flash_kind, stored }});
    var a = response.Response.init(testing.allocator);
    defer a.deinit();
    try shared.renderWith(&req, &a, "Home", .{}, .{ .flash = .{ .plugin = &flash, .session = &over_shared } });
    try testing.expectEqualStrings(
        "{\"component\":\"Home\",\"props\":{\"app\":\"zoda\",\"errors\":{\"text\":\"stored\"}},\"url\":\"/\",\"version\":null,\"sharedProps\":[\"app\",\"errors\"]}",
        a.body,
    );
    try testing.expect(over_shared.flash.consumed);

    // Route errors win, and the stored ones are consumed with the flash.
    var under_route = try receivedFlash(&.{.{ errors_flash_kind, stored }});
    var b = response.Response.init(testing.allocator);
    defer b.deinit();
    try shared.renderWith(&req, &b, "Home", .{ .errors = .{ .text = "route" } }, .{ .flash = .{ .plugin = &flash, .session = &under_route } });
    try testing.expect(std.mem.indexOf(u8, b.body, "\"props\":{\"app\":\"zoda\",\"errors\":{\"text\":\"route\"}}") != null);
    try testing.expect(under_route.flash.consumed);

    // Without the option, stored errors are neither sent nor read.
    const unused = try receivedFlash(&.{.{ errors_flash_kind, stored }});
    var c = response.Response.init(testing.allocator);
    defer c.deinit();
    try plain.render(&req, &c, "Home", .{});
    try testing.expectEqualStrings("{\"component\":\"Home\",\"props\":{\"errors\":{}},\"url\":\"/\",\"version\":null}", c.body);
    try testing.expect(!unused.flash.consumed);

    // The last entry wins; one that is not a JSON object is ignored, so the
    // default applies, and an errors-only flash sends no `flash` field.
    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"text\":\"later\"}", "{\"text\":\"later\"}" },
        .{ "[1]", "{}" },
        .{ "{\"text\":", "{}" },
        .{ "{} {}", "{}" },
    }) |case| {
        var state = try receivedFlash(&.{ .{ errors_flash_kind, stored }, .{ errors_flash_kind, case[0] } });
        var res = response.Response.init(testing.allocator);
        defer res.deinit();
        try plain.renderWith(&req, &res, "Home", .{}, .{ .flash = .{ .plugin = &flash, .session = &state } });
        var expected: [256]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "{{\"component\":\"Home\",\"props\":{{\"errors\":{s}}},\"url\":\"/\",\"version\":null}}", .{case[1]}),
            res.body,
        );
    }

    // A prop callback error leaves them unread.
    const Failing = struct {
        fn load(_: void, _: std.mem.Allocator) error{Unavailable}!u32 {
            return error.Unavailable;
        }
    };
    var failed = try receivedFlash(&.{.{ errors_flash_kind, stored }});
    var d = response.Response.init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Unavailable, plain.renderWith(&req, &d, "Home", .{ .n = once({}, Failing.load) }, .{
        .flash = .{ .plugin = &flash, .session = &failed },
    }));
    try testing.expect(!failed.dirty and !failed.flash.consumed);
}
