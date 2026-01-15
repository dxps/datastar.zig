const std = @import("std");
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var server = try datastar.Server().from(init, .{ .port = 8090, .log = .{ .theme = .monochrom } });
    defer server.deinit();
    try server.maxFdLimits();
    try server.rebooter(init.minimal.args);

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
    var t1 = try std.time.Timer.start();
    defer {
        std.debug.print("Zig index handler took {} microseconds\n", .{t1.read() / std.time.ns_per_ms});
    }
    return http.html(@embedFile("index.html"));
}

pub fn sseHandler(http: *HTTPRequest) !void {
    var sse = try http.NewSSE();
    defer sse.close();

    try sse.patchElements(@embedFile("index.html"), .{});
}
