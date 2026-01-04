const std = @import("std");
const datastar = @import("datastar");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const PORT = 7331;

const HTTPRequest = datastar.HTTPRequest;

// Run Datastar validation test suite backend in Zig
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var server = try datastar.Server(void).init(io, allocator, "0.0.0.0", PORT);
    defer server.deinit();

    var r = server.router;

    r.get("/", index);
    r.get("/test", runTest); // get will use the query params
    r.post("/test", runTest); // post will use the request body

    try server.run();
}

fn index(http: *HTTPRequest) !void {
    try http.html(
        \\See the docs at https://github.com/starfederation/datastar/blob/develop/sdk/tests/README.md
        \\to run the official Datastar SDK test validator against this test suite
    );
}

/// Data mapping for how test cases are passed in
const TestInput = struct {
    events: []TestEvent,
};

const TestEvent = struct {
    type: []const u8,
    eventId: ?[]const u8 = null,
    retryDuration: ?i64 = null,

    // patchElements options
    elements: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    useViewTransition: ?bool = null,
    namespace: ?[]const u8 = null,

    // patch Signals options
    signals: ?std.json.ArrayHashMap(std.json.Value) = null,
    @"signals-raw": ?[]const u8 = null,
    onlyIfMissing: ?bool = null,

    // executeScript options
    script: ?[]const u8 = null,
    attributes: ?TestEventAttribute = null,
    autoRemove: ?bool = null,
};

const TestEventAttribute = struct {
    type: []const u8,
    blocking: ?[]const u8 = null,
};

fn runTest(http: *HTTPRequest) !void {
    // Debug the input packet
    switch (http.req.head.method) {
        .GET => {
            std.debug.print("GET {s}\n", .{http.req.head.target});
            // const query = try http.query();
            // std.debug.print("GET params:\n{s}\n", .{query});
        },
        .POST => {
            std.debug.print("GET {s} {?} bytes\n", .{ http.req.head.target, http.req.head.content_length });
            _ = http.req.head.content_length orelse return error.MissingContentLength;
        },
        else => {
            std.debug.print("Invalid test HTTP method {t}\n", .{http.req.head.method});
            try http.req.respond("Invalid test HTTP method", .{ .status = .bad_request });
            return;
        },
    }

    // read the TestInput params
    const testInput = try http.readSignals(struct { events: []TestEvent });

    var sse = try datastar.NewSSE(http);
    defer sse.close();

    if (testInput.events.len < 1) {
        try http.req.respond("Empty Test Input", .{ .status = .bad_request });
        std.debug.print("Empty Test Input\n", .{});
        return;
    }

    for (testInput.events) |event| {
        std.debug.print("Event {s}\n", .{event.type});

        if (std.mem.eql(u8, event.type, "patchElements")) {
            if (event.elements == null and event.selector == null) {
                try http.req.respond("PatchElements needs at least 1 of element or selector", .{ .status = .bad_request });
                std.debug.print("PatchElements needs at least 1 of element, or selector\n", .{});
                return;
            }

            try sse.patchElements(event.elements orelse "", .{
                .mode = blk: {
                    if (event.mode) |mode| {
                        if (std.meta.stringToEnum(datastar.PatchMode, mode)) |parsed_mode| {
                            break :blk parsed_mode;
                        } else {
                            try http.req.respond("Invalid PatchElements mode", .{ .status = .bad_request });
                            std.debug.print("Invalid patchElements mode '{s}'\n", .{mode});
                            return;
                        }
                    }
                    break :blk .outer;
                },
                .selector = event.selector,
                .view_transition = if (event.useViewTransition) |vt| vt else false,
                .event_id = event.eventId,
                .retry_duration = event.retryDuration,
                .namespace = blk: {
                    if (event.namespace) |ns| {
                        if (std.meta.stringToEnum(datastar.NameSpace, ns)) |parsed_namespace| {
                            break :blk parsed_namespace;
                        } else {
                            try http.req.respond("Invalid PatchElements namespace", .{ .status = .bad_request });
                            std.debug.print("Invalid patchElements namespace '{s}'\n", .{ns});
                            return;
                        }
                    }
                    break :blk .html;
                },
            });
        }

        if (std.mem.eql(u8, event.type, "patchSignals")) {
            // check if multiline signals are present first !!
            if (event.@"signals-raw") |signals| {
                std.debug.print("    multiline signals raw string: {any}\n", .{signals});
                var w = sse.patchSignalsWriter(.{
                    .only_if_missing = event.onlyIfMissing orelse false,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });

                var escape: bool = false;
                for (signals) |ch| {
                    switch (ch) {
                        else => {
                            if (escape) {
                                switch (ch) {
                                    else => try w.writeByte(ch),
                                    'n' => try w.writeAll("\n"),
                                }
                                escape = false;
                            } else {
                                try w.writeByte(ch);
                            }
                        },
                        '\\' => escape = true,
                    }
                }

                return;
            }

            // Check if the 'signals' field was present and parsed
            if (event.signals) |signals| {
                std.debug.print("    signals: {any}\n", .{signals});
                var it = signals.map.iterator();
                while (it.next()) |entry| {
                    std.debug.print("     {s}:{any}\n", .{
                        entry.key_ptr.*,
                        entry.value_ptr.*,
                    });
                }
                try sse.patchSignals(signals, .{}, .{
                    .only_if_missing = event.onlyIfMissing orelse false,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });
            } else {
                std.debug.print("    signals: null\n", .{});
            }
        }

        if (std.mem.eql(u8, event.type, "executeScript")) {
            if (event.script) |script| {
                try sse.executeScript(script, .{
                    .auto_remove = event.autoRemove orelse true,
                    .event_id = event.eventId,
                    .retry_duration = event.retryDuration,
                });
            } else {
                try http.req.respond("executeScript is missing the script param", .{ .status = .bad_request });
                std.debug.print("executeScript is missing the script param\n", .{});
                return;
            }
        }
    }
}
