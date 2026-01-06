const std = @import("std");
const pubsub = @import("pubsub");
const datastar = @import("datastar.zig");

const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn Server(comptime Context: type) type {
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        server: Io.net.Server = undefined,
        router: *Router(Context),
        ctx: ?Context = null,

        pub fn init(io: Io, allocator: Allocator, addr: []const u8, port: u16) !Self {
            const address = try Io.net.IpAddress.parseIp4(addr, port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator),
                .ctx = null,
            };
        }

        pub fn initIp6(io: Io, allocator: Allocator, port: u16) !Self {
            const address = try Io.net.IpAddress.parseIp6("::", port);
            const server = try address.listen(io, .{ .reuse_address = true });
            return .{
                .io = io,
                .allocator = allocator,
                .server = server,
                .router = try Router(Context).init(allocator),
                .ctx = null,
            };
        }

        pub fn setContext(self: *Self, ctx: Context) void {
            self.ctx = ctx;
        }

        pub fn deinit(self: *Self) void {
            self.server.deinit(self.io);
        }

        pub fn run(self: *Self) !void {
            while (true) {
                const conn = try self.server.accept(self.io);
                _ = try self.io.concurrent(handleConnection, .{ self, conn });
            }
        }

        fn handleConnection(self: *Self, conn: Io.net.Stream) void {
            defer conn.close(self.io);

            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;

            var reader = conn.reader(self.io, &read_buffer);
            var writer = conn.writer(self.io, &write_buffer);

            var server = std.http.Server.init(&reader.interface, &writer.interface);

            while (true) {
                var request = server.receiveHead() catch |err| {
                    if (err == error.HttpConnectionClosing) break;
                    return;
                };

                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();

                var http = HTTPRequest{
                    .io = self.io,
                    .req = &request,
                    .arena = arena.allocator(),
                    .params = .{},
                };

                self.router.dispatch(self.ctx, &http) catch return;

                // Anything asking for a Sync SSE connection will detach the request from this inner loop
                // this is because any SSE created over this connection will be treated as the last action
                // in this connection. The trigger for the browser is text/event-stream + chunked encoding
                if (http.detach) break;
            }
        }

        pub fn rebooter(self: *Self) !void {
            _ = try self.io.concurrent(Self.watchLoop, .{self});
        }

        fn watchLoop(self: *Self) !void {
            const self_path = try std.process.executablePathAlloc(self.io, self.allocator);
            defer self.allocator.free(self_path);
            std.debug.print("exe path is {s}\n", .{self_path});

            var initial_inode: u64 = 0;
            var initial_mtime: Io.Timestamp = .zero;

            // wait around till the inital inode is available
            while (true) {
                const file = std.Io.Dir.cwd().openFile(self.io, self_path, .{}) catch {
                    try self.io.sleep(.fromSeconds(2), .real);
                    continue;
                };
                defer file.close(self.io);
                const stat = file.stat(self.io) catch {
                    try self.io.sleep(.fromSeconds(2), .real);
                    continue;
                };
                initial_inode = stat.inode;
                initial_mtime = stat.mtime;
                break;
            }

            while (true) {
                try self.io.sleep(.fromSeconds(2), .real);

                const file = std.Io.Dir.cwd().openFile(self.io, self_path, .{}) catch |err| {
                    std.debug.print("Path {s} cannot open: {}\n", .{ self_path, err });
                    continue;
                };
                const stat = file.stat(self.io) catch |err| {
                    std.debug.print("Path {s} failed to stat(): {}\n", .{ self_path, err });
                    continue;
                };

                const inode_changed = (stat.inode != initial_inode);
                const mtime_changed = (stat.mtime.toMilliseconds() > initial_mtime.toMilliseconds());

                if (inode_changed or mtime_changed) {
                    std.debug.print("Binary Changed - Reboot ♻️\n", .{});

                    const args = try std.process.argsAlloc(self.allocator);

                    var exec_args: std.ArrayList([]const u8) = .empty;
                    try exec_args.append(self.allocator, self_path);

                    for (args[1..]) |arg| {
                        try exec_args.append(self.allocator, arg);
                    }

                    return std.process.execv(self.allocator, exec_args.items);
                }
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

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            const root = try allocator.create(Node);
            root.* = .{};
            self.* = .{ .allocator = allocator, .root = root };
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
        }

        pub fn dispatch(self: *Self, ctx: ?Context, http: *HTTPRequest) !void {
            var params = Params{};
            var current = self.root;

            const target = http.req.head.target;
            const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const path_only = target[0..query_index];

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
                if (match) |m| current = m else return http.req.respond("", .{ .status = .not_found });
            }

            http.params = params;
            var path = http.req.head.target;
            const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
            path = path[0..q];
            // std.debug.print("{t} {s}\n", .{ http.req.head.method, path });

            const method_idx = @intFromEnum(http.req.head.method);
            if (current.handlers[method_idx]) |h| {
                // TODO - in here, if we call any non-GET handler, we should
                // check that the handler actually sent a response
                // otherwise mock up a response for this
                if (Context == void) {
                    return h(http) catch {
                        return http.req.respond("Error", .{ .status = .internal_server_error });
                    };
                } else {
                    if (ctx) |c| {
                        return h(c, http) catch {
                            return http.req.respond("Error", .{ .status = .internal_server_error });
                        };
                    }
                    return error.NoContext;
                }
            }

            return http.req.respond("Method Not Allowed", .{ .status = .method_not_allowed });
        }
    };
}

const TestApp = struct { data: i32 };

fn testAppHandler(app: *TestApp, _: HTTPRequest) !void {
    std.debug.print("test *App handler data:{d}\n", .{app.data});
}

fn testVoidHandler(_: HTTPRequest) !void {
    std.debug.print("test void handler\n", .{});
}

fn testGetHandler(app: *TestApp, _: HTTPRequest) !void {
    std.debug.print("test get handler data:{d}\n", .{app.data});
}

fn testPostHandler(app: *TestApp, _: HTTPRequest) !void {
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

    const decoded = try HTTPRequest.urlDecode(arena.allocator(), "hello%20world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles plus signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try HTTPRequest.urlDecode(arena.allocator(), "hello+world");
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "urlDecode handles mixed encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try HTTPRequest.urlDecode(arena.allocator(), "foo+bar%3Dbaz");
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
