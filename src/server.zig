const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn Server(comptime Context: type) type {
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        server: std.Io.net.Server = undefined,
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
            defer {
                conn.close(self.io);
            }

            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;

            var reader = conn.reader(self.io, &read_buffer);
            var writer = conn.writer(self.io, &write_buffer);

            var server = std.http.Server.init(&reader.interface, &writer.interface);

            while (true) {
                var request = server.receiveHead() catch |err| {
                    // std.debug.print("Error reading header on stream {} IoWriter {*}:{}\n", .{ conn.socket.handle, &writer.interface, err });
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

                self.router.dispatch(self.ctx, &http) catch |err| {
                    std.debug.print("Routing error: {}\n", .{err});
                };
            }
        }
    };
}

pub fn RouteHandler(comptime Context: type) type {
    if (Context == void) {
        return *const fn (req: HTTPRequest) anyerror!void;
    } else {
        return *const fn (ctx: Context, req: HTTPRequest) anyerror!void;
    }
}

pub const HTTPRequest = struct {
    const Self = @This();

    req: *std.http.Server.Request,
    io: Io,
    arena: std.mem.Allocator,
    params: Params,

    // return the given data as text/html
    pub fn html(self: Self, data: []const u8) !void {
        try self.req.respond(data, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
        });
    }

    pub fn htmlFmt(self: Self, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [4096]u8 = undefined;

        var body_writer = try self.req.respondStreaming(&buffer, .{
            .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html" }},
            },
        });

        const w = body_writer.writer();
        try w.print(fmt, args);
        try body_writer.end();
    }

    pub fn json(self: Self, data: anytype) !void {
        var buffer: [4096]u8 = undefined;

        var body_writer = try self.req.respondStreaming(&buffer, .{
            .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            },
        });

        try std.json.Stringify.value(data, .{}, &body_writer.writer);
        try body_writer.end();
    }

    pub fn query(self: Self) ![]const u8 {
        const target = self.req.head.target;
        const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
        return target[query_idx + 1 ..];
    }

    pub fn readSignals(self: Self, comptime T: type) !T {
        const req = self.req;
        const arena = self.arena;

        switch (req.head.method) {
            .GET => {
                const target = req.head.target;
                const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
                const query_string = target[query_idx + 1 ..];

                var it = std.mem.tokenizeScalar(u8, query_string, '&');
                while (it.next()) |pair| {
                    if (std.mem.startsWith(u8, pair, "datastar=")) {
                        const encoded_val = pair["datastar=".len..];
                        const decoded = try urlDecode(arena, encoded_val);

                        return std.json.parseFromSliceLeaky(
                            T,
                            arena,
                            decoded,
                            .{ .ignore_unknown_fields = true },
                        );
                    }
                }
                return error.MissingDatastarKey;
            },
            else => {
                const length = req.head.content_length orelse return error.MissingContentLength;
                const body = try arena.alloc(u8, @intCast(length));

                var reader_buffer: [8192]u8 = undefined;
                const reader = req.readerExpectNone(&reader_buffer);

                try reader.readSliceAll(body);
                return std.json.parseFromSliceLeaky(
                    T,
                    arena,
                    body,
                    .{ .ignore_unknown_fields = true },
                );
            },
        }
    }

    fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out = try allocator.alloc(u8, input.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                out[j] = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch input[i];
                i += 3;
            } else if (input[i] == '+') {
                out[j] = ' ';
                i += 1;
            } else {
                out[j] = input[i];
                i += 1;
            }
            j += 1;
        }
        return out[0..j];
    }
};

pub const Params = struct {
    names: [8][]const u8 = undefined,
    values: [8][]const u8 = undefined,
    count: usize = 0,

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        }
        return null;
    }

    pub fn format(self: Params, writer: *std.Io.Writer) !void {
        try writer.writeAll("Params { ");
        for (0..self.count) |i| {
            if (i > 0) {
                try writer.writeAll(", ");
            }
            try writer.print("  {s}: \"{s}\"", .{ self.names[i], self.values[i] });
        }
        try writer.writeAll("}");
    }
};

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

            const method_idx = @intFromEnum(http.req.head.method);
            if (current.handlers[method_idx]) |h| {
                if (Context == void) {
                    return h(http.*);
                } else {
                    if (ctx) |c| {
                        return h(c, http.*);
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
