const std = @import("std");
const datastar = @import("datastar");
const pubsub = datastar.pubsub;

const Io = std.Io;
const HTTPRequest = datastar.HTTPRequest;
const Allocator = std.mem.Allocator;

const PORT = 8082;

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
pub fn main() !void {
    // Setup an allocator and io
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Create the global app instance
    var app = try App.init(io, allocator);
    defer app.deinit();

    // create the server
    const HTTPServer = datastar.Server(*App);
    var server = try HTTPServer.initIp6(io, allocator, PORT);
    server.setContext(app);
    defer server.deinit();

    {
        const r = server.router;
        r.get("/", index);
        r.get("/cats", catsList);
        r.post("/bid/:id", postBid);
    }

    // run the server
    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    try server.rebooter();
    try server.run();
}

fn index(app: *App, http: *HTTPRequest) !void {
    _ = app;
    try http.html(@embedFile("02_index.html"));
}

fn catsList(app: *App, http: *HTTPRequest) !void {
    var sse = try datastar.NewSSESync(http);
    try publishCatList(app, &sse);

    var mq = try app.pubsub.connect();
    defer mq.deinit();

    try mq.subscribe(.cats);
    mq.setTimeout(30 * std.time.ns_per_s);

    while (try mq.next()) |event| {
        switch (event) {
            .msg => try publishCatList(app, &sse),
            .timeout => try sse.keepalive(),
        }
    }
}

fn publishCatList(app: *App, sse: *datastar.SSE) !void {
    var w = sse.patchElementsWriter(.{});
    try w.print(
        \\<div id="cat-list" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 mt-4 h-full" data-signals="{{ bids: [{d},{d},{d},{d},{d},{d}] }}">
    , .{
        app.cats.items[0].bid,
        app.cats.items[1].bid,
        app.cats.items[2].bid,
        app.cats.items[3].bid,
        app.cats.items[4].bid,
        app.cats.items[5].bid,
    });

    for (app.cats.items) |cat| {
        try cat.render(w);
    }
    try w.writeAll(
        \\</div>
    );
    try sse.flush();
}

fn postBid(app: *App, http: *HTTPRequest) !void {
    app.mutex.lock();
    defer {
        app.mutex.unlock();
    }

    const id_param = http.params.get("id") orelse "0";
    const id = try std.fmt.parseInt(usize, id_param, 10);

    if (id < 0 or id >= app.cats.items.len) {
        return error.InvalidID;
    }

    const signals = try http.readSignals(struct { bids: []usize });
    const new_bid = signals.bids[id];
    app.cats.items[id].bid = new_bid;

    // update any screens subscribed to "cats"
    try app.broadcast();
}

const Cat = struct {
    id: u8,
    name: []const u8,
    img: []const u8,
    bid: usize = 0,

    pub fn render(cat: Cat, w: anytype) !void {
        try w.print(
            \\<div class="card w-8/12 bg-slate-300 card-lg shadow-sm m-auto mt-4">
            \\  <div class="card-body" id="cat-{[id]}">
            \\    <h2 class="card-title">#{[id]} {[name]s}</h2>
            \\    <div class="avatar">
            \\      <div class="w-48 h-48 rounded-full">
            \\        <img src="{[img]s}">
            \\      </div>
            \\    </div>
            \\    <label class="input">$ 
            \\      <input type="number" placeholder="Bid" class="grow" data-bind:bids.{[id]} />
            \\    </label>
            \\    <div class="justify-end card-actions">
            \\      <button class="btn btn-primary" data-on:click="@post('/bid/{[id]}', {{filterSignals: {{include: '^bids$'}}}})">Place Bid</button>
            \\    </div>
            \\  </div>
            \\</div>
        , .{
            .id = cat.id,
            .name = cat.name,
            .img = cat.img,
        });
    }
};

const Cats = std.ArrayList(Cat);

// Schema for messages passed over pubsub
const MQSchema = union(enum) {
    cats: void,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    cats: Cats,
    mutex: std.Thread.Mutex,
    pubsub: pubsub.PubSub(MQSchema),

    pub fn init(io: Io, allocator: Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .io = io,
            .allocator = allocator,
            .mutex = .{},
            .cats = try createCats(allocator),
            .pubsub = pubsub.PubSub(MQSchema).init(io, allocator),
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.cats.deinit(app.allocator);
        app.allocator.destroy(app);
    }

    pub fn broadcast(app: *App) !void {
        try app.pubsub.publish(.{ .cats = {} }, .all);
    }
};

fn createCats(allocator: Allocator) !Cats {
    var cats: Cats = .empty;
    errdefer cats.deinit(allocator);
    try cats.append(allocator, .{
        .id = 0,
        .name = "Harry",
        .img = "https://images.unsplash.com/photo-1514888286974-6c03e2ca1dba?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Mnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 1,
        .name = "Meghan",
        .img = "https://images.unsplash.com/photo-1574144611937-0df059b5ef3e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MTR8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(allocator, .{
        .id = 2,
        .name = "Prince",
        .img = "https://images.unsplash.com/photo-1574158622682-e40e69881006?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8MjB8fGNhdHxlbnwwfHwwfHx8MA%3D%3D",
    });
    try cats.append(allocator, .{
        .id = 3,
        .name = "Fluffy",
        .img = "https://plus.unsplash.com/premium_photo-1664299749481-ac8dc8b49754?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8OXx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 4,
        .name = "Princessa",
        .img = "https://images.unsplash.com/photo-1472491235688-bdc81a63246e?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8Nnx8Y2F0fGVufDB8fDB8fHww",
    });
    try cats.append(allocator, .{
        .id = 5,
        .name = "Tiger",
        .img = "https://plus.unsplash.com/premium_photo-1673967770669-91b5c2f2d0ce?w=500&auto=format&fit=crop&q=60&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxzZWFyY2h8NXx8a2l0dGVufGVufDB8fDB8fHww",
    });
    return cats;
}
