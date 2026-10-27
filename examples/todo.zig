//! Run with `zig build run-todo`, then open http://localhost:8080.
//! Todos live in memory and disappear when the process stops.
const std = @import("std");
const zoda = @import("zoda");

const Todo = struct {
    id: u64,
    text: []const u8,
    done: bool = false,
};

const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Todo) = .empty,
    next_id: u64 = 1,

    fn deinit(self: *Store) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
    }

    fn list(self: *Store, res: *zoda.response.Response) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try res.replaceJson(200, []const Todo, self.items.items);
    }

    fn add(self: *Store, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.items.append(self.allocator, .{ .id = self.next_id, .text = owned });
        self.next_id += 1;
    }

    fn toggle(self: *Store, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items) |*item| {
            if (item.id == id) {
                item.done = !item.done;
                return true;
            }
        }
        return false;
    }

    fn delete(self: *Store, id: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.items.items, 0..) |item, i| {
            if (item.id == id) {
                self.allocator.free(item.text);
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

const Plugins = struct { store: struct { value: *Store } };
const App = zoda.app.App(Plugins);

fn route(ctx: *App.Context, req: *zoda.router.Request, res: *zoda.response.Response) !void {
    if (req.isRoot() and req.isGet()) {
        return zoda.template.render(res, 200, @embedFile("todo.html"), .{});
    }
    if (!req.onLiteral("api")) return;
    if (!req.onLiteral("todos")) return;

    const store = ctx.plugins.store.value;
    if (req.isRoot()) {
        if (req.isGet()) return store.list(res);
        if (req.method == .post) {
            const parsed = std.json.parseFromSlice(struct { text: []const u8 }, store.allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
                return res.text(400, "Expected JSON with a text field");
            };
            defer parsed.deinit();
            const value = std.mem.trim(u8, parsed.value.text, " \t\r\n");
            if (value.len == 0 or value.len > 200) return res.text(400, "Text must be 1–200 bytes");
            try store.add(value);
            return res.text(201, "Created");
        }
        return;
    }

    const id = req.onInt(u64) orelse return;
    if (req.isRoot() and req.method == .delete) {
        if (!store.delete(id)) return res.text(404, "Todo not found");
        return res.text(200, "Deleted");
    }
    if (req.isLiteral("toggle") and req.method == .post) {
        if (!store.toggle(id)) return res.text(404, "Todo not found");
        return res.text(200, "Updated");
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var store = Store{ .allocator = allocator, .io = init.io };
    defer store.deinit();
    const app: App = .{
        .response_allocator = allocator,
        .config = .{ .name = "todo" },
        .plugins = .{ .store = .{ .value = &store } },
        .route_fn = route,
    };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) };
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    try zoda.server.serve(App, allocator, init.io, &listener, &app, .{});
}

fn dispatch(app: *const App, method: zoda.router.Method, target: []const u8, body: []const u8) !zoda.response.Response {
    var arena = try zoda.request.parseOriginForm(std.testing.allocator, .default, target);
    defer arena.deinit();
    try arena.copyBody(body);
    var req = arena.requestView(method);
    return app.dispatch(&req);
}

test "todo API creates, lists, toggles, and deletes" {
    var store = Store{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer store.deinit();
    const app: App = .{
        .response_allocator = std.testing.allocator,
        .config = .{},
        .plugins = .{ .store = .{ .value = &store } },
        .route_fn = route,
    };

    var created = try dispatch(&app, .post, "/api/todos", "{\"text\":\"  Buy milk  \"}");
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 201), created.status_code);

    var listed = try dispatch(&app, .get, "/api/todos", "");
    defer listed.deinit();
    try std.testing.expectEqualStrings("[{\"id\":1,\"text\":\"Buy milk\",\"done\":false}]", listed.body);

    var toggled = try dispatch(&app, .post, "/api/todos/1/toggle", "");
    defer toggled.deinit();
    try std.testing.expectEqual(@as(u16, 200), toggled.status_code);
    try std.testing.expect(store.items.items[0].done);

    var deleted = try dispatch(&app, .delete, "/api/todos/1", "");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(u16, 200), deleted.status_code);
    try std.testing.expectEqual(@as(usize, 0), store.items.items.len);
}
