const std = @import("std");
const Server = @import("server.zig");
const HTTPRequest = @import("http_request.zig");
const Params = @import("params.zig");

/// Define a custom RouteHandler for this type
/// - will either take just the HTTPRequest param for Server() type servers
/// - will take Context,HTTPRequest for Server(Context) type servers
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
            // on bootup - just always print the routes in effect
            std.log.debug("  > {t} {s}", .{ method, path });
        }

        pub fn dispatch(self: *Self, ctx: ?Context, http: *HTTPRequest) !void {
            var params = Params{};
            const log = http.log;

            const target = http.path;
            const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const path_only = target[0..query_index];

            var it = std.mem.tokenizeScalar(u8, path_only, '/');
            var current = self.root;
            while (it.next()) |seg| {
                var match: ?*Node = null;
                for (current.children.items) |child| {
                    if (child.is_param) {
                        // fill in the local params var from the actual URL in the request
                        if (params.count < params.names.len) {
                            params.names[params.count] = child.param_name;
                            params.values[params.count] = seg;
                            params.count += 1;
                        }
                        match = child;
                        break;
                    } else if (std.mem.eql(u8, child.segment, seg)) {
                        match = child;
                        break;
                    }
                }
                if (match) |m| current = m else return http.respond("Not Found", .not_found);
            }

            http.params = params;
            var path = http.path;
            const q = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
            path = path[0..q];

            // TODO - apply the onBefore middlewares
            // TODO - errdefer the onError middlewares

            var processed: bool = false;

            const method_idx = @intFromEnum(http.method);
            if (current.handlers[method_idx]) |h| {
                // TODO - in here, if we call any non-GET handler, we should
                // check that the handler actually sent a response
                // otherwise mock up a response for this ??
                if (Context == void) {
                    h(http) catch |err| {
                        log.err(http, err, .internal_server_error);
                        try http.respond("Error", .internal_server_error);
                    };
                    processed = true;
                } else {
                    if (ctx) |c| {
                        h(c, http) catch |err| {
                            log.err(http, err, .internal_server_error);
                            try http.respond("Error", .internal_server_error);
                        };
                        processed = true;
                    } else {
                        log.err(http, error.NoContext, .internal_server_error);
                        return error.NoContext;
                    }
                }
            }

            if (processed) {
                // TODO - run middlewares onAfter
            }

            if (!http.replied) {
                std.log.warn("request {t} {s} didnt reply ??", .{ http.method, http.path });
                // this is probably a user error - handler didnt bother
                // replying.  So raise a log error and terminate the call anyway
                http.html("") catch {};
            }

            // TODO - remove this after its done in logging middleware instead
            switch (log.level) {
                .none => {},
                else => {
                    log.info(http);

                    switch (log.level) {
                        .payload => log.payload(http),
                        .signals => log.signals(http),
                        .all => {
                            log.signals(http);
                            log.payload(http);
                        },
                        else => {},
                    }
                },
            }
            if (!processed) {
                return http.respond("Method Not Allowed", .method_not_allowed);
            }
        }
    };
}
