const std = @import("std");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var server = try datastar.HTTPServer.init(init, .{
        .port = 8090,
        .allocator = std.heap.smp_allocator,
        .log = .{
            .format = .terminal,
            .theme = .monochrom,
        },
        .watch = true,
        .threads = 255,
        .fd_limit = .max,
        // comment this out to return to using sane threads
        .sse_concurrency = .fibers,
    });
    defer server.deinit();

    {
        const r = server.router;
        r.get("/", handler);
        r.get("/log", handlerLogged);
        r.get("/sse", sseHandler);
    }

    std.debug.print("Zig Datastar 0.16-dev SSE Server running at http://localhost:8090\n", .{});
    try server.run();
}

pub fn handler(http: *HTTPRequest) !void {
    return http.html(@embedFile("index.html"));
}

pub fn handlerLogged(http: *HTTPRequest) !void {
    var t1 = std.Io.Timestamp.now(http.io, std.Io.Clock.real);
    defer {
        std.debug.print("Zig index handler took {} microseconds\n", .{@divTrunc(t1.untilNow(http.io, std.Io.Clock.real).toNanoseconds(), std.time.ns_per_ms)});
    }
    return http.html(@embedFile("index.html"));
}

pub fn sseHandler(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements(@embedFile("index.html"), .{});
}
