const std = @import("std");
const datastar = @import("datastar.zig");
const Params = @import("params.zig");

const SSE = datastar.SSE;
const SSEOptions = datastar.SSEOptions;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const HTTPRequest = @This();

req: *std.http.Server.Request,
io: Io,
arena: std.mem.Allocator,
params: Params,
extra_headers: ?[]const std.http.Header = null,
detach: bool = false, // detached is set if there is any SSE acting on this request - which stops it looping looking for more requests on the same connection
req_payload: ?[]const u8 = null,

/// Return a new SSE object for a simple 1 shot response
pub fn NewSSE(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{});
}

/// Return a new SSE object setup for a series of synchronous responses or persistent connection
pub fn NewSSESync(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{ .sync = true });
}

/// Return a new SSE object with custom options
pub fn NewSSEOpt(http: *HTTPRequest, opt: SSEOptions) !SSE {
    const buf_size = if (opt.buffer_size != 0) opt.buffer_size else datastar.DEFAULT_BUFFER_SIZE;
    const buf = try http.arena.alloc(u8, buf_size);

    // IF we are text/event-stream AND we have no content-length (chunked encoding)
    // THEN detach the request from the connection - because the browser will never queue
    // another request over this same connection
    if (opt.sync) {
        http.detach = true;
    }

    // need to create a BodyWriter on the heap, because we use it after this
    // because this is on the arena owned by the handleConnection->request ...
    // that means the handler needs to stay alive for as long we expect to keep
    // using this bodyWriter. This has implications for pub/sub
    const res = try http.arena.create(std.http.BodyWriter);
    var headers: []const std.http.Header = try http.mergeHeaders(&.{
        .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
        .{ .name = "cache-control", .value = "no-cache" },
    });
    if (opt.extra_headers) |extras| {
        headers = try http.mergeHeaders(extras);
    }

    res.* = try http.req.respondStreaming(
        buf,
        .{ .respond_options = .{ .extra_headers = headers } },
    );
    const allocating_writer = blk: {
        if (opt.buffer_size == 0) break :blk Io.Writer.Allocating.init(http.arena);
        break :blk Io.Writer.Allocating.initCapacity(http.arena, opt.buffer_size) catch Io.Writer.Allocating.init(http.arena);
    };
    if (opt.sync) {
        try res.flush();
    }

    return .{
        .stream = res,
        .output_buffer = allocating_writer,
        .buffer_size = opt.buffer_size,
        .sync = opt.sync,
        .io = http.io,
        .start_time = try Io.Clock.real.now(http.io),
    };
}

/// use this to construct extra_headers when creating any response
/// it will pull in self.extra_headers, and merge them with the new set
/// to provide a complete set for the actual request
/// See http.setCookie() for an example where this is needed
pub fn mergeHeaders(self: *HTTPRequest, extra: []const std.http.Header) ![]const std.http.Header {
    const defaults = &[_]std.http.Header{
        .{ .name = "connection", .value = "keep-alive" },
        .{ .name = "x-powered-by", .value = "datastar.zig" },
    };

    const stored_extras = if (self.extra_headers) |h| h else &[_]std.http.Header{};
    const total_len = defaults.len + stored_extras.len + extra.len;
    const combined = try self.arena.alloc(std.http.Header, total_len);

    var cursor: usize = 0;

    @memcpy(combined[cursor..][0..defaults.len], defaults);
    cursor += defaults.len;

    if (stored_extras.len > 0) {
        @memcpy(combined[cursor..][0..stored_extras.len], stored_extras);
        cursor += stored_extras.len;
    }

    if (extra.len > 0) {
        @memcpy(combined[cursor..][0..extra.len], extra);
    }

    return combined;
}

/// send a response of type text/html with the given data
pub fn html(self: *HTTPRequest, data: []const u8) !void {
    try self.req.respond(
        data,
        .{ .extra_headers = try self.mergeHeaders(&.{.{ .name = "content-type", .value = "text/html" }}) },
    );
}

/// send a response of type text/html with a formatted print
pub fn htmlFmt(self: *HTTPRequest, comptime fmt: []const u8, args: anytype) !void {
    try self.html(try std.fmt.allocPrint(self.arena, fmt, args));
}

/// send a response of type application/json with the given data
pub fn json(self: *HTTPRequest, data: anytype) !void {
    var buffer: [4096]u8 = undefined;

    var body_writer = try self.req.respondStreaming(
        &buffer,
        .{
            .respond_options = .{
                .extra_headers = try self.mergeHeaders(&.{.{ .name = "content-type", .value = "application/json" }}),
            },
        },
    );

    try std.json.Stringify.value(data, .{}, &body_writer.writer);
    try body_writer.end();
}

/// extract the full query params from the request
pub fn query(self: HTTPRequest) ![]const u8 {
    const target = self.req.head.target;
    const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
    return target[query_idx + 1 ..];
}

/// read Datastar signals from the request into the given struct type, return an instance of this struct
pub fn readSignals(self: *HTTPRequest, comptime T: type) !T {
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
                    const decoded = try datastar.urlDecode(arena, encoded_val);

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
            self.req_payload = self.arena.dupe(u8, body) catch null;
            return std.json.parseFromSliceLeaky(
                T,
                arena,
                body,
                .{ .ignore_unknown_fields = true },
            );
        },
    }
}

/// set a cookie that will be included in the response header
pub fn setCookie(self: *HTTPRequest, name: []const u8, value: []const u8) !void {
    const cookie_val = try std.fmt.allocPrint(self.arena, "{s}={s}; Path=/; HttpOnly; SameSite=Lax", .{ name, value });
    const current_list = if (self.extra_headers) |h| h else &[_]std.http.Header{};
    const new_list = try self.arena.alloc(std.http.Header, current_list.len + 1);

    if (current_list.len > 0) {
        @memcpy(new_list[0..current_list.len], current_list);
    }

    new_list[current_list.len] = .{ .name = "set-cookie", .value = cookie_val };

    self.extra_headers = new_list;
}

/// get a cookie from the request
pub fn getCookie(self: *HTTPRequest, name: []const u8) ?[]const u8 {
    var it = self.req.iterateHeaders();
    while (it.next()) |header| {
        // Find the "Cookie" header (case-insensitive check)
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {

            // Tokenize by ';' to handle "key1=val1; key2=val2"
            var cookie_it = std.mem.tokenizeScalar(u8, header.value, ';');
            while (cookie_it.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " ");

                if (std.mem.indexOfScalar(u8, trimmed, '=')) |idx| {
                    const key = trimmed[0..idx];

                    if (std.mem.eql(u8, key, name)) {
                        return trimmed[idx + 1 ..];
                    }
                }
            }
        }
    }
    return null;
}
