const std = @import("std");
const pubsub = @import("pubsub");
const datastar = @import("datastar.zig");

const builtin = @import("builtin");
const posix = std.posix; // probably gonna get deprecated soon ?

const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const LogLevel = enum {
    none,
    path,
    payload,
    signals,
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
        log_level: LogLevel = .path,

        fn initVoid(io: Io, allocator: Allocator, addr: []const u8, port: u16, log_level: LogLevel) !Self {
            const address = try Io.net.IpAddress.parseIp4(addr, port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator, log_level),
                .log_level = log_level,
            };
        }

        fn initCtx(io: Io, allocator: Allocator, addr: []const u8, port: u16, ctx: Context, log_level: LogLevel) !Self {
            const address = try Io.net.IpAddress.parseIp4(addr, port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator, log_level),
                .ctx = ctx,
                .log_level = log_level,
            };
        }

        pub const init = if (Context == void) initVoid else initCtx;

        fn initIp6Void(io: Io, allocator: Allocator, port: u16, log_level: LogLevel) !Self {
            const address = try Io.net.IpAddress.parseIp6("::", port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator, log_level),
                .log_level = log_level,
            };
        }

        fn initIp6Ctx(io: Io, allocator: Allocator, port: u16, ctx: Context, log_level: LogLevel) !Self {
            const address = try Io.net.IpAddress.parseIp6("::", port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator, log_level),
                .ctx = ctx,
                .log_level = log_level,
            };
        }

        pub const initIp6 = if (Context == void) initIp6Void else initIp6Ctx;

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

            var server = std.http.Server.init(&reader.interface, &writer.interface);

            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();

            while (true) {
                defer _ = arena.reset(.retain_capacity);

                var request = server.receiveHead() catch break;

                var http = HTTPRequest{
                    .io = self.io,
                    .req = &request,
                    .arena = arena.allocator(),
                    .params = .{},
                    .path = arena.allocator().dupe(u8, request.head.target) catch return error.Canceled,
                    .method = request.head.method,
                };

                self.router.dispatch(self.ctx, &http) catch return;

                // Anything asking for a Sync SSE connection will detach the request from this inner loop
                // this is because any SSE created over this connection will be treated as the last action
                // in this connection. The trigger for the browser is text/event-stream + chunked encoding
                if (http.detach) break;
            }
        }

        pub fn rebooter(self: *Self, args: std.process.Args) !void {
            _ = try self.io.concurrent(Self.watchLoop, .{ self, args });
        }

        fn watchLoop(self: *Self, args: std.process.Args) !void {
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
                    std.log.warn("🚀 Process FD limit Current={}, raise to {}", .{ limit.cur, limit.max });

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

pub fn RouteHandler(comptime Context: type) type {
    if (Context == void) {
        return *const fn (req: *HTTPRequest) anyerror!void;
    } else {
        return *const fn (ctx: Context, req: *HTTPRequest) anyerror!void;
    }
}

pub fn Router(comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        root: *Node,
        log_level: LogLevel = .path,

        const Node = struct {
            segment: []const u8 = "",
            is_param: bool = false,
            param_name: []const u8 = "",
            handlers: [std.enums.values(std.http.Method).len]?RouteHandler(Context) = [_]?RouteHandler(Context){null} ** std.enums.values(std.http.Method).len,
            children: std.ArrayListUnmanaged(*Node) = .{},

            fn deinit(self: *Node, alloc: std.mem.Allocator) void {
                for (self.children.items) |child| child.deinit(alloc);
                self.children.deinit(alloc);
                if (!self.is_param and self.segment.len > 0) alloc.free(self.segment);
                if (self.is_param and self.param_name.len > 0) alloc.free(self.param_name);
                alloc.destroy(self);
            }
        };

        pub fn init(allocator: std.mem.Allocator, log_level: LogLevel) !*Self {
            const self = try allocator.create(Self);
            const root = try allocator.create(Node);
            root.* = .{};
            self.* = .{ .allocator = allocator, .root = root, .log_level = log_level };
            return self;
        }

        // No Context parameter needed - it's already baked into the Router type!
        pub fn get(self: *Self, path: []const u8, handler: RouteHandler(Context)) void {
            self.add(.GET, path, handler) catch unreachable;
        }

        pub fn post(self: *Self, path: []const u8, handler: RouteHandler(Context)) void {
            self.add(.POST, path, handler) catch unreachable;
        }

        pub fn put(self: *Self, path: []const u8, handler: RouteHandler(Context)) void {
            self.add(.PUT, path, handler) catch unreachable;
        }

        pub fn patch(self: *Self, path: []const u8, handler: RouteHandler(Context)) void {
            self.add(.PATCH, path, handler) catch unreachable;
        }

        pub fn delete(self: *Self, path: []const u8, handler: RouteHandler(Context)) void {
            self.add(.DELETE, path, handler) catch unreachable;
        }

        pub fn add(self: *Self, method: std.http.Method, path: []const u8, handler: RouteHandler(Context)) !void {
            var current = self.root;
            var it = std.mem.tokenizeScalar(u8, path, '/');

            while (it.next()) |seg| {
                const is_param = std.mem.startsWith(u8, seg, ":");
                var found: ?*Node = null;

                for (current.children.items) |child| {
                    if (is_param and child.is_param) {
                        found = child;
                        break;
                    }
                    if (!is_param and std.mem.eql(u8, child.segment, seg)) {
                        found = child;
                        break;
                    }
                }

                if (found) |node| {
                    current = node;
                } else {
                    const node = self.allocator.create(Node) catch unreachable;
                    node.* = .{
                        .segment = if (is_param) "" else try self.allocator.dupe(u8, seg),
                        .is_param = is_param,
                        .param_name = if (is_param) try self.allocator.dupe(u8, seg[1..]) else "",
                    };
                    try current.children.append(self.allocator, node);
                    current = node;
                }
            }
            current.handlers[@intFromEnum(method)] = handler;
            switch (self.log_level) {
                .none => {},
                .path, .payload, .signals => std.log.debug("  > {t} {s}", .{ method, path }),
            }
        }

        fn statusColor(status: std.http.Status) []const u8 {
            const code = @intFromEnum(status);
            return switch (code) {
                200...299 => "\x1b[32m", // Green
                300...399 => "\x1b[36m", // Cyan
                400...499 => "\x1b[33m", // Yellow
                500...599 => "\x1b[31m", // Red
                else => "\x1b[0m", // Reset/White
            };
        }

        const resetColor = "\x1b[0m";

        pub fn dispatch(self: *Self, ctx: ?Context, http: *HTTPRequest) !void {
            var params = Params{};
            var current = self.root;

            const target = http.path;
            const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const path_only = target[0..query_index];
            const query_params = target[query_index..];

            var it = std.mem.tokenizeScalar(u8, path_only, '/');

            while (it.next()) |seg| {
                var match: ?*Node = null;
                for (current.children.items) |child| {
                    if (child.is_param) {
                        params.names[params.count] = child.param_name;
                        params.values[params.count] = seg;
                        params.count += 1;
                        match = child;
                        break;
                    } else if (std.mem.eql(u8, child.segment, seg)) {
                        match = child;
                        break;
                    }
                }
                if (match) |m| current = m else {
                    http.status = .not_found;
                    return http.req.respond("", .{ .status = http.status });
                }
            }

            http.params = params;
            var path = http.path;
            const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
            path = path[0..q];

            var t1 = try std.time.Timer.start();
            defer {
                switch (self.log_level) {
                    .none => {},
                    .path, .payload, .signals => {
                        std.log.info("{t:<6} {s:<60} {s}{}{s} {:>8} μs", .{
                            http.req.head.method,
                            path_only,
                            statusColor(http.status),
                            @intFromEnum(http.status),
                            resetColor,
                            t1.read() / std.time.ns_per_us,
                        });

                        switch (self.log_level) {
                            else => {},
                            .payload => {
                                if (http.req_payload) |payload| {
                                    std.log.debug(" > {s}", .{payload});
                                }
                            },
                            .signals => {
                                if (query_params.len > 0) {
                                    const buf: []u8 = "";
                                    var decode_params = http.arena.dupe(u8, query_params) catch buf;
                                    const start_index = if (std.mem.findScalar(u8, decode_params, '=')) |idx| idx + 1 else 0;
                                    decode_params = decode_params[start_index..];
                                    _ = std.mem.replaceScalar(u8, decode_params, '+', ' ');
                                    std.log.debug(" > Signals: {s}", .{
                                        std.Uri.percentDecodeInPlace(decode_params),
                                    });
                                }
                            },
                        }
                    },
                }
            }

            const method_idx = @intFromEnum(http.method);
            if (current.handlers[method_idx]) |h| {
                // TODO - in here, if we call any non-GET handler, we should
                // check that the handler actually sent a response
                // otherwise mock up a response for this
                if (Context == void) {
                    return h(http) catch |err| {
                        std.log.err("{} - {t} {s}", .{ err, http.req.head.method, http.req.head.target });
                        http.status = .internal_server_error;
                        return http.req.respond("Error", .{ .status = http.status });
                    };
                } else {
                    if (ctx) |c| {
                        return h(c, http) catch |err| {
                            std.log.err("{} - {t} {s}", .{ err, http.req.head.method, http.req.head.target });
                            http.status = .internal_server_error;
                            return http.req.respond("Error", .{ .status = http.status });
                        };
                    }
                    return error.NoContext;
                }
            }

            http.status = .method_not_allowed;
            return http.req.respond("Method Not Allowed", .{ .status = http.status });
        }
    };
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
    const ServerVoid = Server(void);
    const type_info = @typeInfo(ServerVoid);
    try std.testing.expect(type_info == .@"struct");
}

test "Server type can be created with App context" {
    const ServerApp = Server(*TestApp);
    const type_info = @typeInfo(ServerApp);
    try std.testing.expect(type_info == .@"struct");
}
