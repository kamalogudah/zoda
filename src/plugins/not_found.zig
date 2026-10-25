//! Configured plain-text fallback for routes that leave a response unhandled.
//!
//! Place `NotFound` in an app's plugin struct and pass the route through
//! `App.composeRoute`. Its wrapper runs after the inner route and before
//! dispatch's default 404, including when other inner wrappers leave a miss.
const router = @import("../router.zig");
const response = @import("../response.zig");

pub const NotFound = struct {
    /// Borrowed configuration; the response copies these bytes before return.
    body: []const u8,

    pub fn wrapRoute(comptime H: type, comptime inner: H.RouteFn) H.RouteFn {
        return struct {
            fn run(ctx: *H.Context, req: *router.Request, res: *response.Response) anyerror!void {
                try inner(ctx, req, res);
                if (!res.handled) try res.text(404, H.plugin(ctx).body);
            }
        }.run;
    }
};
