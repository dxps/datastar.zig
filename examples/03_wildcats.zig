const std = @import("std");
const datastar = @import("datastar");
const pubsub = datastar.pubsub;

const Io = std.Io;
const HTTPRequest = datastar.HTTPRequest;
const Allocator = std.mem.Allocator;

const PORT = 8083;

// Schema for messages passed over pubsub
const MQSchema = union(enum) {
    cats: void,
    prefs: void,
};

// This example demonstrates a simple auction site that uses
// SSE and pub/sub to have realtime updates of bids on a Cat auction
// with session based preferences
pub fn main() !void {
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

    // create the routes
    {
        const r = server.router;
        r.get("/", index);
        r.get("/style.css", styleCss);
        r.get("/cats", catsList);
        r.post("/bid/:id", postBid);
        r.post("/sort", postSort);
    }

    // run the server
    std.debug.print("listening http://localhost:{d}/\n", .{PORT});
    try server.rebooter();
    try server.run();
}

fn index(app: *App, http: *HTTPRequest) !void {
    // ensure they have a cookie
    const session_string = http.getCookie("session") orelse blk: {
        const new_session_string = try std.fmt.allocPrint(http.arena, "{}", .{try app.newSessionID()});
        try http.setCookie("session", new_session_string);
        break :blk new_session_string;
    };
    try app.ensureSession(session_string);
    try http.html(@embedFile("03_index.html"));
}

fn styleCss(_: *App, http: *HTTPRequest) !void {
    return http.html(@embedFile("style.css"));
}

fn catsList(app: *App, http: *HTTPRequest) !void {
    const session = http.getCookie("session") orelse return error.NoCookie;
    const sort_prefs = app.sessions.get(session) orelse return error.NoSortPrefs;
    std.debug.print("catList for session {s} with prefs {t}\n", .{ session, sort_prefs.sort });

    var sse = try http.NewSSESync();
    defer sse.close();

    // Because we push all state at the start of this SSE, we dont need a
    // separate /hotreload endpoint
    try app.pushAll(&sse, session);

    var mq = try app.pubsub.connect();
    defer mq.deinit();

    mq.setFilter(.fromSlice(session));
    try mq.subscribe(.cats);
    try mq.subscribe(.prefs);
    mq.setTimeout(30 * std.time.ns_per_s);

    while (try mq.next()) |event| {
        std.debug.print("Session {s} got event {f}\n", .{ session, event });
        switch (event) {
            .msg => |m| switch (m.topic) {
                .cats => try app.pushCatList(&sse, session),
                .prefs => try app.pushAll(&sse, session),
            },
            .timeout => try sse.keepalive(),
        }
    }
}

fn postBid(app: *App, http: *HTTPRequest) !void {
    // get the numeric cat_id from the request params POST /bid/:id
    const cat_id = http.params.getInt(usize, "id") orelse return error.InvalidCat;

    if (cat_id < 0 or cat_id >= app.cats.items.len) {
        return error.InvalidID;
    }

    app.mutex.lock();
    defer app.mutex.unlock();
    app.sortCats(.id);

    const signals = try http.readSignals(struct { bids: []usize });
    const new_bid = signals.bids[cat_id];

    const now = try Io.Clock.real.now(app.io);

    app.cats.items[cat_id].bid = new_bid;
    app.cats.items[cat_id].ts = now;

    // broadcast an update to the cats list, because the bid values have changed
    try app.pubsub.publish(.{ .cats = {} }, .all);

    try http.json(.{ .bid = "ok", .id = cat_id, .value = new_bid });
}

fn postSort(app: *App, http: *HTTPRequest) !void {
    const session = http.getCookie("session") orelse return error.NoSession;
    const filter_id: pubsub.FilterId = .fromSlice(session);

    app.mutex.lock();
    defer app.mutex.unlock();

    var opt = try http.readSignals(struct { sort: []const u8 });
    const new_sort: SortType = .fromString(opt.sort);

    std.debug.print("postSort session {s} has requested sort {t}\n", .{ session, new_sort });

    const prefs: SessionPrefs = app.sessions.get(session) orelse .{ .sort = .id };
    std.debug.print(
        "Existing prefs for session {s} are {t} -> new sort {t}\n",
        .{ session, prefs.sort, new_sort },
    );

    try app.sessions.put(session, .{ .sort = new_sort });

    // broadcast updates to people on this session, telling them their
    // sort criterior has changed
    // The consumer of this message will then update both prefs and
    // print a new cat list
    try app.pubsub.publish(.{ .prefs = {} }, filter_id);
    try http.json(.{ .sort = new_sort });
}

const Cat = struct {
    id: u8,
    name: []const u8,
    img: []const u8,
    bid: usize = 0,
    ts: std.Io.Timestamp = .zero,

    pub fn render(cat: Cat, w: anytype) !void {
        try w.print(
            \\<div class="card w-8/12 bg-slate-300 card-lg shadow-sm m-auto mt-4">
            \\  <div class="card-body" id="cat-{[id]}">
            \\    <h2 class="card-title">#{[id]} {[name]s}</h2>
            \\ <div class="flex flex-row gap-4">
            \\    <div class="avatar">
            \\      <div class="w-48 h-48 rounded-{[box_type]s}">
            \\        <img src="{[img]s}">
            \\      </div>
            \\    </div>
            \\    <div>{[comment]s}</div>
            \\ </div>
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
            .box_type = if (cat.id == 4) "xl" else "full",
            .comment = if (cat.id == 4) "" else "",
        });
    }
};

const Cats = std.ArrayList(Cat);

const SortType = enum {
    id,
    low,
    high,
    recent,

    pub fn fromString(s: []const u8) SortType {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "recent")) return .recent;
        return .id;
    }
};

const SessionPrefs = struct {
    sort: SortType = .id,
};

const App = struct {
    io: Io,
    allocator: Allocator,
    cats: Cats,
    mutex: std.Thread.Mutex,
    pubsub: pubsub.PubSub(MQSchema),
    next_session_id: usize = 1,
    sessions: std.StringHashMap(SessionPrefs),
    last_sort: SortType = .id,

    pub fn init(io: Io, allocator: Allocator) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .io = io,
            .allocator = allocator,
            .mutex = .{},
            .pubsub = pubsub.PubSub(MQSchema).init(io, allocator),
            .cats = try createCats(allocator),
            .sessions = std.StringHashMap(SessionPrefs).init(allocator),
        };
        return app;
    }

    pub fn deinit(app: *App) void {
        app.cats.deinit(app.allocator);
        // var it = app.sessions.keyIterator();
        // while (it.next()) |*k| {
        //     app.allocator.free(k);
        // }
        app.sessions.deinit();
        app.allocator.destroy(app);
    }

    pub fn newSessionID(app: *App) !usize {
        app.mutex.lock();
        defer app.mutex.unlock();
        const s = app.next_session_id;
        app.next_session_id += 1;

        const session_id = try std.fmt.allocPrint(app.allocator, "{d}", .{s});
        try app.sessions.put(session_id, .{});

        std.debug.print("App Sessions after adding a new session ID:\n", .{});
        var it = app.sessions.keyIterator();
        while (it.next()) |k| {
            std.debug.print("- {s}\n", .{k.*});
        }

        return s;
    }

    pub fn ensureSession(app: *App, session_id: []const u8) !void {
        app.mutex.lock();
        defer app.mutex.unlock();

        if (app.sessions.get(session_id) == null) {
            try app.sessions.put(try app.allocator.dupe(u8, session_id), .{});
            std.debug.print("Had to add session {s} to my sessions list, because the client says its there, but I dont know about it\n", .{session_id});
        }
    }

    fn catSortID(_: void, cat1: Cat, cat2: Cat) bool {
        return cat1.id < cat2.id;
    }

    fn catSortLow(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.bid == cat2.bid) return cat1.id < cat2.id;
        return cat1.bid < cat2.bid;
    }

    fn catSortHigh(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.bid == cat2.bid) return cat1.id < cat2.id;
        return cat1.bid > cat2.bid;
    }

    fn catSortRecent(_: void, cat1: Cat, cat2: Cat) bool {
        if (cat1.ts.nanoseconds == cat2.ts.nanoseconds) return cat1.id < cat2.id;
        return cat1.ts.nanoseconds > cat2.ts.nanoseconds;
    }

    pub fn sortCats(app: *App, sort: SortType) void {
        std.debug.print("sorting by {} with last sort {}\n", .{ sort, app.last_sort });
        if (app.last_sort == sort) return;

        switch (sort) {
            .id => std.sort.block(Cat, app.cats.items, {}, catSortID),
            .low => std.sort.block(Cat, app.cats.items, {}, catSortLow),
            .high => std.sort.block(Cat, app.cats.items, {}, catSortHigh),
            .recent => std.sort.block(Cat, app.cats.items, {}, catSortRecent),
        }
        app.last_sort = sort;
    }

    pub fn pushAll(app: *App, sse: *datastar.SSE, session: []const u8) !void {
        try app.pushPrefs(sse, session);
        try app.pushCatList(sse, session);
    }

    pub fn pushCatList(app: *App, sse: *datastar.SSE, session: []const u8) !void {
        app.mutex.lock();
        defer app.mutex.unlock();

        const sort_prefs = app.sessions.get(session) orelse return error.NoSortPrefs;
        std.debug.print("pushCatList for session {s} with prefs {}\n", .{ session, sort_prefs });

        app.sortCats(.id);

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
        app.sortCats(sort_prefs.sort);

        for (app.cats.items) |cat| {
            try cat.render(w);
        }
        try w.writeAll(
            \\</div>
        );
        try sse.flush();
    }

    pub fn pushPrefs(app: *App, sse: *datastar.SSE, session: []const u8) !void {
        // just get the session prefs for the given session, and patch the signals
        // on the client to update.
        // So this is called when any other client sharing the same session
        // changes their preference
        std.debug.print("Update signals for session {s}\n", .{session});
        if (app.sessions.get(session)) |prefs| {
            std.debug.print("New pref is {t}\n", .{prefs.sort});
            try sse.patchSignals(.{
                .sort = @tagName(prefs.sort),
            }, .{}, .{});
        }
    }
};

fn createCats(gpa: Allocator) !Cats {
    var cats: Cats = .empty;
    errdefer cats.deinit(gpa);
    try cats.append(gpa, .{
        .id = 0,
        .name = "Harry",
        .img = "https://plus.unsplash.com/premium_photo-1664304391609-9aa6b41d5dfa?q=80&w=880&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 1,
        .name = "Meghan",
        .img = "https://images.unsplash.com/photo-1682959572189-048deb6e1d9d?q=80&w=687&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 2,
        .name = "Prince",
        .img = "https://plus.unsplash.com/premium_photo-1730233719882-890f7043eb9e?q=80&w=687&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 3,
        .name = "Fluffy",
        .img = "https://images.unsplash.com/photo-1557692538-9564c4b2cd13?q=80&w=765&auto=format&fit=crop&ixlib=rb-4.1.0&ixid=M3wxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHx8fA%3D%3D",
    });
    try cats.append(gpa, .{
        .id = 4,
        .name = "Karyn & Karren",
        .img = "https://img.daisyui.com/images/profile/demo/yellingwoman@192.webp",
    });

    try cats.append(gpa, .{
        .id = 5,
        .name = "Tiger",
        .img = "https://img.daisyui.com/images/profile/demo/yellingcat@192.webp",
    });
    return cats;
}
