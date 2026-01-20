const std = @import("std");
const pubsub = @import("pubsub");
const datastar = @import("datastar.zig");
const Log = @import("log.zig");
const router_module = @import("router.zig");
const Router = router_module.Router;
const RouteHandler = router_module.RouteHandler;

const builtin = @import("builtin");
const posix = std.posix; // probably gonna get deprecated soon ?

const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    address: ?[]const u8 = null,
    port: u16, // must be provided
    log: Log = .{},
    io: ?Io = null,
    allocator: ?Allocator = null,
};

pub fn Server() type {
    return ServerCtx(void);
}

pub fn ServerCtx(comptime Context: type) type {
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        server: Io.net.Server = undefined,
        router: *Router(Context),
        ctx: ?Context = null,
        log: Log = undefined,

        /// for Server() without std.process.init
        fn initVoid(config: Config) !Self {
            std.debug.assert(config.io != null);
            std.debug.assert(config.allocator != null);

            // if address is not defined / null - then listen on all addresses
            const address = if (config.address) |addr|
                try Io.net.IpAddress.parseIp4(addr, config.port)
            else
                try Io.net.IpAddress.parseIp6("::", config.port);

            const io = config.io.?;
            const allocator = config.allocator.?;

            return .{
                .server = try address.listen(io, .{ .reuse_address = true }),
                .router = try Router(Context).init(allocator),
                .log = config.log,
                .io = io,
                .allocator = allocator,
            };
        }

        /// for Server(Context) without std.process.init
        fn initCtx(ctx: Context, config: Config) !Self {
            var server = try initVoid(config);
            server.ctx = ctx;
            return server;
        }

        /// for Server() with std.process.init
        fn fromVoid(process: std.process.Init, config: Config) !Self {
            const io = config.io orelse process.io;
            const allocator = config.allocator orelse process.gpa;

            // if address is not defined / null - then listen on all addresses
            const address = if (config.address) |addr|
                try Io.net.IpAddress.parseIp4(addr, config.port)
            else
                try Io.net.IpAddress.parseIp6("::", config.port);

            return .{
                .server = try address.listen(io, .{ .reuse_address = true }),
                .router = try Router(Context).init(allocator),
                .log = config.log,
                .io = io,
                .allocator = allocator,
            };
        }

        /// for Server(Context) with std.process.init
        fn fromCtx(process: std.process.Init, config: Config, ctx: Context) !Self {
            var server = try fromVoid(process, config);
            server.ctx = ctx;
            return server;
        }

        pub const init = if (Context == void) initVoid else initCtx;
        pub const from = if (Context == void) fromVoid else fromCtx;

        pub fn deinit(self: *Self) void {
            self.server.deinit(self.io);
        }

        pub fn run(self: *Self) !void {
            var group: std.Io.Group = .init;
            defer group.cancel(self.io);

            // create global app instance
            while (true) {
                const conn = try self.server.accept(self.io);
                group.concurrent(self.io, handleConnection, .{ self, conn }) catch |err| {
                    std.log.err("spawn handler error {}\n", .{err});
                    conn.close(self.io);
                    // group.cancel(self.io);
                    continue; // ah well failed - try another one, dont exit the loop
                };
            }
        }

        fn handleConnection(self: *Self, conn: Io.net.Stream) Io.Cancelable!void {
            defer conn.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;

            var reader = conn.reader(self.io, &read_buffer);
            var writer = conn.writer(self.io, &write_buffer);

            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();

            while (true) {
                defer _ = arena.reset(.retain_capacity);

                var server = std.http.Server.init(&reader.interface, &writer.interface);
                var request = server.receiveHead() catch break;

                var http = HTTPRequest{
                    .io = self.io,
                    .req = &request,
                    .arena = arena.allocator(),
                    .params = .{},
                    .path = arena.allocator().dupe(u8, request.head.target) catch return error.Canceled,
                    .method = request.head.method,
                    .timer = std.time.Timer.start() catch undefined, // live dangerously !
                    .log = self.log,
                };

                self.router.dispatch(self.ctx, &http) catch return;

                // Anything asking for a Sync SSE connection will detach the request from this inner loop
                // this is because any SSE created over this connection will be treated as the last action
                // in this connection. The trigger for the browser is text/event-stream + chunked encoding
                if (http.detach) break;
            }
        }

        pub fn rebooter(self: *Self, proc: std.process.Init) !void {
            _ = try self.io.concurrent(Self.watchLoop, .{ self, proc });
        }

        fn watchLoop(self: *Self, proc: std.process.Init) !void {
            const args = proc.minimal.args;
            const self_path = try std.process.executablePathAlloc(self.io, self.allocator);
            defer self.allocator.free(self_path);
            std.log.warn("♻️ Monitoring Executable File {s}", .{self_path});

            var initial_inode: u64 = 0;
            var initial_mtime: Io.Timestamp = .zero;

            // wait around till the inital inode is available
            while (true) {
                const stat = std.Io.Dir.cwd().statFile(self.io, self_path, .{}) catch |err| {
                    std.log.err("Path {s} cannot stat: {}", .{ self_path, err });
                    continue;
                };
                initial_inode = stat.inode;
                initial_mtime = stat.mtime;
                break;
            }

            while (true) {
                try self.io.sleep(.fromSeconds(2), .real);

                const stat = std.Io.Dir.cwd().statFile(self.io, self_path, .{}) catch |err| {
                    std.log.err("Path {s} cannot stat: {}", .{ self_path, err });
                    continue;
                };

                const inode_changed = (stat.inode != initial_inode);
                const mtime_changed = (stat.mtime.toMilliseconds() > initial_mtime.toMilliseconds());

                if (inode_changed or mtime_changed) {
                    std.log.warn("♻️ Binary Changed - Reboot", .{});

                    const argv = try self.allocator.alloc([]const u8, args.vector.len);
                    defer self.allocator.free(argv);
                    for (args.vector, 0..) |arg, i| {
                        argv[i] = std.mem.span(arg);
                    }

                    return std.process.replace(self.io, .{ .argv = argv });
                }
            }
        }

        pub fn maxFdLimits(_: *Self) !void {
            switch (builtin.os.tag) {
                .macos, .linux, .freebsd, .openbsd => {
                    // Get current limits
                    var limit = try posix.getrlimit(.NOFILE);
                    if (limit.cur == limit.max) {
                        std.log.warn("🚀 Process FD limit currently at MAX capacity {}", .{limit.max});
                    } else {
                        std.log.warn("🚀 Process FD limit Current={}, raise to {}", .{ limit.cur, limit.max });
                    }

                    // Set Soft Limit (cur) to the Hard Limit (max)
                    // On macOS, 'max' is typically 10,240 by default.
                    limit.cur = limit.max;

                    posix.setrlimit(.NOFILE, limit) catch |err| {
                        std.log.err("🚀 Failed to bump limits: {}", .{err});
                        return err;
                    };
                },
                else => return,
            }
        }
    };
}

middleware: ?*Middleware = null,

// Middleware functions take a HTTPRequest, and return
// - err if there is an error, no more processing
// - true = continue, hand over to the next middleware in the chain
// - false = do not continue .. response has been sent already, no more middleware
const MiddlewareFunc = *const fn (req: HTTPRequest) anyerror!bool;
const Middlewares = std.ArrayList(MiddlewareFunc);

const Middleware = struct {
    before: ?*Middlewares = null,
    after: ?*Middlewares = null,
    err: ?*Middlewares = null,
};

// Regiter onBefore middleware
pub fn onBefore(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.before == null) {
        self.middleware.before = try self.arena.create(Middlewares);
        self.middleware.before = .{};
    }
    std.debug.assert(self.middleware.before != null);
    try self.middleware.before.?.append(self.arena, func);
}

// Register onAfter middleware
pub fn onAfter(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.after == null) {
        self.middleware.after = try self.arena.create(Middlewares);
        self.middleware.after = .{};
    }
    std.debug.assert(self.middleware.after != null);
    try self.middleware.after.?.append(self.arena, func);
}

// Register onError middleware
pub fn onError(self: *HTTPRequest, func: MiddlewareFunc) !void {
    if (self.middleware == null) {
        self.middleware = try self.arena.create(Middleware);
        self.middleware.* = .{};
    }
    std.debug.assert(self.middleware != null);
    if (self.middleware.err == null) {
        self.middleware.err = try self.arena.create(Middlewares);
        self.middleware.err = .{};
    }
    std.debug.assert(self.middleware.err != null);
    try self.middleware.err.?.append(self.arena, func);
}

const TestApp = struct { data: i32 };

fn testAppHandler(app: *TestApp, _: *HTTPRequest) !void {
    std.debug.print("test *App handler data:{d}\n", .{app.data});
}

fn testVoidHandler(_: *HTTPRequest) !void {
    std.debug.print("test void handler\n", .{});
}

fn testGetHandler(app: *TestApp, _: *HTTPRequest) !void {
    std.debug.print("test get handler data:{d}\n", .{app.data});
}

fn testPostHandler(app: *TestApp, _: *HTTPRequest) !void {
    std.debug.print("test post handler data:{d}\n", .{app.data});
}

test "Params.get returns correct value" {
    var params = Params{};
    params.names[0] = "id";
    params.values[0] = "123";
    params.names[1] = "name";
    params.values[1] = "alice";
    params.count = 2;

    try std.testing.expectEqualStrings("123", params.get("id").?);
    try std.testing.expectEqualStrings("alice", params.get("name").?);
    try std.testing.expect(params.get("missing") == null);
}

test "RouteHandler signature for void context" {
    const Handler = RouteHandler(void);
    const info = @typeInfo(Handler);

    // Should be a function pointer with 1 parameter (just HTTPRequest)
    try std.testing.expect(info == .pointer);
    const fn_info = @typeInfo(info.pointer.child).@"fn";
    try std.testing.expectEqual(1, fn_info.params.len);
}

test "RouteHandler signature for App context" {
    const App = struct { count: usize };
    const Handler = RouteHandler(*App);
    const info = @typeInfo(Handler);

    // Should be a function pointer with 2 parameters (ctx and HTTPRequest)
    try std.testing.expect(info == .pointer);
    const fn_info = @typeInfo(info.pointer.child).@"fn";
    try std.testing.expectEqual(2, fn_info.params.len);
}

test "Router can add and store routes" {
    var router = try Router(*TestApp).init(std.testing.allocator);
    defer {
        router.root.deinit(std.testing.allocator);
        std.testing.allocator.destroy(router);
    }

    router.get("/test", testAppHandler);

    // Verify the route was added
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("test", router.root.children.items[0].segment);
}

test "Router handles parameterized routes" {
    var router = try Router(*TestApp).init(std.testing.allocator);
    defer {
        router.root.deinit(std.testing.allocator);
        std.testing.allocator.destroy(router);
    }

    router.get("/user/:id", testAppHandler);

    // Navigate to /user
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("user", router.root.children.items[0].segment);

    // Check :id parameter
    const user_node = router.root.children.items[0];
    try std.testing.expect(user_node.children.items.len == 1);
    try std.testing.expect(user_node.children.items[0].is_param);
    try std.testing.expectEqualStrings("id", user_node.children.items[0].param_name);
}

test "Router with void context" {
    var router = try Router(void).init(std.testing.allocator);
    defer {
        router.root.deinit(std.testing.allocator);
        std.testing.allocator.destroy(router);
    }

    router.get("/test", testVoidHandler);

    try std.testing.expect(router.root.children.items.len == 1);
}

test "Router deduplicates identical paths" {
    var router = try Router(*TestApp).init(std.testing.allocator);
    defer {
        router.root.deinit(std.testing.allocator);
        std.testing.allocator.destroy(router);
    }

    router.get("/test", testGetHandler);
    router.post("/test", testPostHandler);

    // Should only have one child node for "/test", with both GET and POST handlers
    try std.testing.expect(router.root.children.items.len == 1);
    try std.testing.expectEqualStrings("test", router.root.children.items[0].segment);

    const test_node = router.root.children.items[0];
    const get_idx = @intFromEnum(std.http.Method.GET);
    const post_idx = @intFromEnum(std.http.Method.POST);

    try std.testing.expect(test_node.handlers[get_idx] != null);
    try std.testing.expect(test_node.handlers[post_idx] != null);
}

test "urlDecode handles percent encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "hello%20world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles plus signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "hello+world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles mixed encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try datastar.urlDecode(arena.allocator(), "foo+bar%3Dbaz");
    try std.testing.expectEqualStrings("foo bar=baz", decoded);
}

test "Server type can be created with void context" {
    const ServerVoid = ServerCtx(void);
    const type_info = @typeInfo(ServerVoid);
    try std.testing.expect(type_info == .@"struct");

    const ServerNotSpecified = Server();
    const type_info_not_specified = @typeInfo(ServerNotSpecified);
    try std.testing.expect(type_info_not_specified == .@"struct");
}

test "Server type can be created with App context" {
    const ServerApp = ServerCtx(*TestApp);
    const type_info = @typeInfo(ServerApp);
    try std.testing.expect(type_info == .@"struct");
}
