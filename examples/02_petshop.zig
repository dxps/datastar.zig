const std = @import("std");
const Io = std.Io;
const datastar = @import("datastar");
const HTTPRequest = datastar.HTTPRequest;
const App = @import("02_cats.zig").App;

const Allocator = std.mem.Allocator;

const PORT = 8082;

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();
    const HTTPServer = datastar.Server(*App);

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var server = try HTTPServer.initIp6(io, allocator, PORT);
    server.setContext(app);
    defer server.deinit();

    const r = server.router;
    r.get("/", index);
    r.get("/cats", catsList);
    r.post("/bid/:id", postBid);

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    std.debug.print("... or any other IP address pointing to this machine\n", .{});
    try server.rebooter();
    try server.run();
}

fn index(app: *App, http: *HTTPRequest) !void {
    _ = app;
    try http.html(@embedFile("02_index.html"));
}

fn catsList(app: *App, http: *HTTPRequest) !void {
    var subs = app.subscribers;
    var sse = try datastar.NewSSESync(http);

    {
        app.mutex.lock();
        defer app.mutex.unlock();
        try subs.subscribe("cats", &sse, App.publishCatList);
    }

    sse.keepalive(http.io, .fromSeconds(30));
    subs.unsubscribe(&sse);
}

fn postBid(app: *App, http: *HTTPRequest) !void {
    std.debug.print("POST /bid start lock\n", .{});
    app.mutex.lock();
    std.debug.print("POST /bid locked app\n", .{});
    defer {
        app.mutex.unlock();
        std.debug.print("POST /bid unlocked app\n", .{});
    }

    const id_param = http.params.get("id") orelse "0";
    const id = try std.fmt.parseInt(usize, id_param, 10);

    if (id < 0 or id >= app.cats.items.len) {
        return error.InvalidID;
    }

    const Bids = struct {
        bids: []usize,
    };
    const signals = try http.readSignals(Bids);
    // std.debug.print("bids {any}\n", .{signals.bids});
    const new_bid = signals.bids[id];
    // std.debug.print("new bid {}\n", .{new_bid});
    app.cats.items[id].bid = new_bid;

    // update any screens subscribed to "cats"
    try app.subscribers.publish("cats");
}
