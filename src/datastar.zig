const std = @import("std");
pub const pubsub = @import("pubsub");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const server_module = @import("server.zig");
pub const Server = server_module.Server;
pub const HTTPRequest = server_module.HTTPRequest;

pub const Command = enum {
    patchElements,
    patchSignals,
    executeScript,
};

pub const PatchMode = enum {
    inner,
    outer,
    replace,
    prepend,
    append,
    before,
    after,
    remove,
};

pub const NameSpace = enum {
    html,
    svg,
    mathml,
};

pub const PatchElementsOptions = struct {
    mode: PatchMode = .outer,
    selector: ?[]const u8 = null,
    view_transition: bool = false,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
    namespace: NameSpace = .html,
};

pub const PatchSignalsOptions = struct {
    only_if_missing: bool = false,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

pub const ScriptAttributes = std.StringArrayHashMap([]const u8);

pub const ExecuteScriptOptions = struct {
    auto_remove: bool = true, // by default remove the script after use, otherwise explicity set this to false if you want to keep the script loaded
    attributes: ?ScriptAttributes = null,
    event_id: ?[]const u8 = null,
    retry_duration: ?i64 = null,
};

const DEFAULT_BUFFER_SIZE = 8 * 1024;

pub const SSEOptions = struct {
    buffer_size: usize = DEFAULT_BUFFER_SIZE,
    sync: bool = false,
};

pub const SSE = struct {
    stream: *std.http.BodyWriter,
    output_buffer: Io.Writer.Allocating,
    msg: ?Message = null,
    buffer_size: usize = DEFAULT_BUFFER_SIZE,
    sync: bool, // the SSE is operating in sync mode - patches are posted immediately
    chunked: bool = false, // set to true if we want to do the chunking manually ourselves
    io: Io, // what IO implementation are we running under ?
    start_time: std.Io.Timestamp,

    pub fn deinit(self: *SSE) void {
        self.flush() catch {};
        self.output_buffer.deinit();
    }

    pub fn flush(self: *SSE) !void {
        if (self.msg) |*msg| try msg.end();
        const data = self.output_buffer.written();

        // write to the bodyWriter, on flush this gets chunked and forwarded to the final_output
        try self.stream.writer.writeAll(data);

        if (self.sync) {
            // in sync mode, we need to manually trip the end-of-chunk by adding \r\n
            // then tell the BodyWriter to flush itself to the underlying socket connection
            try self.stream.writer.writeAll("\r\n");
            try self.stream.writer.flush();
            try self.stream.flush(); // flushing the BodyWriter does the work of writing to the http_protocol_output
            _ = self.output_buffer.writer.consume(data.len + 2);
            return;
        }
        _ = self.output_buffer.writer.consume(data.len);
    }

    /// close() is used for short lived SSE only
    /// on close(), this will populate the response body the call res.write()
    /// which will output both the header and the body using async IO
    pub fn close(self: *SSE) void {
        self.stream.writer.writeAll(self.body()) catch {};
        self.stream.end() catch {};
    }

    // Sends a keepalive packet on a connected SSE
    // this is a HTML patchElement with no id, sending the time elapsed inside the SSE, in seconds
    pub fn keepalive(self: *SSE) !void {
        const clock: std.Io.Clock = .real;
        const now = try clock.now(self.io);
        try self.patchElementsFmt(
            \\<keepaline data-time="{}" />
        , .{self.start_time.durationTo(now).toSeconds()}, .{});
    }

    pub fn writer(self: *Message) ?*Io.Writer {
        if (self.msg) |msg| {
            return &msg.interface;
        }
        return null;
    }

    pub fn buffered(self: *SSE) []u8 {
        return self.output_buffer.written();
    }

    pub fn body(self: *SSE) []u8 {
        self.flush() catch {};
        return self.buffered();
    }

    pub fn patchElements(self: *SSE, elements: []const u8, opt: PatchElementsOptions) !void {
        var msg: Message = undefined;
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.writeAll(elements);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsFmt(self: *SSE, comptime elements: []const u8, args: anytype, opt: PatchElementsOptions) !void {
        var msg: Message = undefined;
        msg.init(.patchElements, opt, &self.output_buffer.writer);
        try msg.header();
        var w = &msg.interface;
        try w.print(elements, args);
        try msg.end();
        try self.flush();
    }

    pub fn patchElementsWriter(self: *SSE, opt: PatchElementsOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchElements, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.patchElements, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }

    pub fn patchSignals(self: *SSE, value: anytype, json_opt: std.json.Stringify.Options, opt: PatchSignalsOptions) !void {
        var msg: Message = undefined;
        msg.init(.patchSignals, opt, &self.output_buffer.writer);
        try msg.header();

        const json_formatter = std.json.fmt(value, json_opt);
        try json_formatter.format(&msg.interface);
        try msg.end();
        try self.flush();
    }

    pub fn patchSignalsWriter(self: *SSE, opt: PatchSignalsOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.patchSignals, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.patchSignals, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }

    pub fn executeScript(self: *SSE, script: []const u8, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = undefined;
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.writeAll(script);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptFmt(self: *SSE, comptime script: []const u8, args: anytype, opt: ExecuteScriptOptions) !void {
        try self.flush();
        var msg: Message = undefined;
        msg.init(.executeScript, opt, &self.output_buffer.writer);
        var w = &msg.interface;
        try msg.header();
        try w.print(script, args);
        try msg.end();
        try self.flush();
    }

    pub fn executeScriptWriter(self: *SSE, opt: ExecuteScriptOptions) *Io.Writer {
        if (self.msg) |*msg| {
            msg.swapTo(.executeScript, opt);
        } else {
            self.msg = .{};
            self.msg.?.init(.executeScript, opt, &self.output_buffer.writer);
        }
        return &self.msg.?.interface;
    }
};

pub fn readSignals(comptime T: type, arena: std.mem.Allocator, req: *std.http.Server.Request) !T {
    switch (req.head.method) {
        .GET => {
            const target = req.head.target;
            const query_idx = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingDatastarKey;
            const query_string = target[query_idx + 1 ..];

            var it = std.mem.tokenizeScalar(u8, query_string, '&');
            while (it.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "datastar=")) {
                    const encoded_val = pair["datastar=".len..];
                    const decoded = try Server.urlDecode(arena, encoded_val);

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
pub fn NewSSE(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{});
}

pub fn NewSSESync(http: *HTTPRequest) !SSE {
    return NewSSEOpt(http, .{ .sync = true });
}

pub fn NewSSEOpt(http: *HTTPRequest, opt: SSEOptions) !SSE {
    const buf_size = if (opt.buffer_size != 0) opt.buffer_size else DEFAULT_BUFFER_SIZE;
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
    res.* = try http.req.respondStreaming(
        buf,
        .{ .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        } } },
    );
    const allocating_writer = blk: {
        if (opt.buffer_size == 0) break :blk Io.Writer.Allocating.init(http.arena);
        break :blk Io.Writer.Allocating.initCapacity(http.arena, opt.buffer_size) catch Io.Writer.Allocating.init(http.arena);
    };
    if (opt.sync) {
        try res.flush();
    }

    const clock: std.Io.Clock = .real;
    return SSE{
        .stream = res,
        .output_buffer = allocating_writer,
        .buffer_size = opt.buffer_size,
        .sync = opt.sync,
        .io = http.io,
        .start_time = try clock.now(http.io),
    };
}

pub const Message = struct {
    out_buffer: *Io.Writer = undefined, // an intermediate buffer to write the expanded Datastar event stream to
    input_buffer: [8 * 1024]u8 = undefined,
    started: bool = false,
    command: Command = .patchElements,

    patch_element_options: PatchElementsOptions = .{},
    patch_signal_options: PatchSignalsOptions = .{},
    execute_script_options: ExecuteScriptOptions = .{},

    line_in_progress: bool = false,
    interface: Io.Writer = undefined,

    fn init(m: *Message, comptime command: Command, opt: anytype, out_buffer: *Io.Writer) void {
        m.out_buffer = out_buffer;
        m.command = command;
        m.interface = .{
            .buffer = &m.input_buffer,
            .vtable = &.{
                .drain = &drain,
            },
        };
        switch (command) {
            .patchElements => {
                m.patch_element_options = opt;
            },
            .patchSignals => {
                m.patch_signal_options = opt;
            },
            .executeScript => {
                m.execute_script_options = opt;
            },
        }
    }

    pub fn swapTo(self: *Message, comptime command: Command, opt: anytype) void {
        // always just swap to new command
        self.end() catch {};
        self.command = command;
        switch (command) {
            .patchElements => {
                self.patch_element_options = opt;
            },
            .patchSignals => {
                self.patch_signal_options = opt;
            },
            .executeScript => {
                self.execute_script_options = opt;
            },
        }
    }

    pub fn end(self: *Message) !void {
        var me = &self.interface;
        try me.flush();

        if (self.started) {
            self.started = false;
            self.line_in_progress = false;

            // const w = self.stream_writer;
            const w = self.out_buffer;

            switch (self.command) {
                else => {},
                .executeScript => {
                    // need to close off the script tag !!
                    try w.writeAll("</script>");
                },
            }
            try w.writeAll("\n\n");
            try w.flush();
        }
    }

    pub fn header(self: *Message) !void {
        // var w = self.stream_writer;
        var w = self.out_buffer;

        switch (self.command) {
            .patchElements => {
                try w.writeAll("event: datastar-patch-elements\n");
                if (self.patch_element_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.patch_element_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (self.patch_element_options.selector) |s| {
                    try w.print("data: selector {s}\n", .{s});
                }
                if (self.patch_element_options.view_transition) {
                    try w.print("data: useViewTransition true\n", .{});
                }
                const mt = self.patch_element_options.mode;
                switch (mt) {
                    .outer => {},
                    else => try w.print("data: mode {t}\n", .{mt}),
                }
                switch (self.patch_element_options.namespace) {
                    .html => {},
                    .svg => try w.writeAll("data: namespace svg\n"),
                    .mathml => try w.writeAll("data: namespace mathml\n"),
                }
            },
            .patchSignals => {
                try w.writeAll("event: datastar-patch-signals\n");
                if (self.patch_signal_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.patch_signal_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                if (self.patch_signal_options.only_if_missing) {
                    try w.writeAll("data: onlyIfMissing true\n");
                }
            },
            .executeScript => {
                try w.writeAll("event: datastar-patch-elements\n");
                if (self.execute_script_options.event_id) |event_id| {
                    try w.print("id: {s}\n", .{event_id});
                }
                if (self.execute_script_options.retry_duration) |retry| {
                    try w.print("retry: {}\n", .{retry});
                }
                try w.writeAll("data: mode append\ndata: selector body\ndata: elements <script");

                // now add the attribs if any are supplied
                if (self.execute_script_options.attributes) |attribs| {
                    for (attribs.keys(), attribs.values()) |key, value| {
                        try w.print(" {s}=\"{s}\"", .{ key, value });
                    }
                }
                if (self.execute_script_options.auto_remove) {
                    try w.writeAll(" data-effect=\"el.remove()\"");
                }

                try w.writeAll(">");
                self.line_in_progress = true; // because the script content is appended to the script declaration line !!
            },
        }
        self.started = true;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        var self: *Message = @fieldParentPtr("interface", w);
        _ = splat;

        if (!self.started) {
            try self.header();
        }

        var written: usize = 0;

        if (w.end > 0) {
            written += try writeBytesScan(self, self.out_buffer, w.buffered());
        }
        written += try writeBytesScan(self, self.out_buffer, data[0]);

        // TODO - we have the expanded contents in self.out_buffer here - debug that, then send the whole contents of the out_buffer to the self.stream_writer
        return w.consume(written);
    }

    // implementation of writeBytes using SIMD scan of the input to find newlines
    fn writeBytesScan(self: *Message, stream_writer: *Io.Writer, bytes: []const u8) !usize {
        const prefix = switch (self.command) {
            .patchElements, .executeScript => "data: elements ",
            .patchSignals => "data: signals ",
        };

        var rest = bytes;

        while (std.mem.indexOfScalar(u8, rest, '\n')) |idx| {
            const line = rest[0 .. idx + 1];

            // Start a line if we aren't already in one
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
            }
            try stream_writer.writeAll(line); // includes \n
            self.line_in_progress = false;

            // Advance past the newline, if there is more
            rest = rest[idx + 1 ..];
        }

        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try stream_writer.writeAll(prefix);
                self.line_in_progress = true;
            }
            try stream_writer.writeAll(rest);
        }

        return bytes.len;
    }
};

test "PatchElementsOptions default values" {
    const opts = PatchElementsOptions{};
    try std.testing.expectEqual(PatchMode.outer, opts.mode);
    try std.testing.expect(opts.selector == null);
    try std.testing.expect(opts.view_transition == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
    try std.testing.expectEqual(NameSpace.html, opts.namespace);
}

test "PatchSignalsOptions default values" {
    const opts = PatchSignalsOptions{};
    try std.testing.expect(opts.only_if_missing == false);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "ExecuteScriptOptions default values" {
    const opts = ExecuteScriptOptions{};
    try std.testing.expect(opts.auto_remove == true);
    try std.testing.expect(opts.attributes == null);
    try std.testing.expect(opts.event_id == null);
    try std.testing.expect(opts.retry_duration == null);
}

test "SSEOptions default values" {
    const opts = SSEOptions{};
    try std.testing.expectEqual(DEFAULT_BUFFER_SIZE, opts.buffer_size);
    try std.testing.expect(opts.sync == false);
}

test "Command enum values" {
    try std.testing.expect(@typeInfo(Command) == .@"enum");
    const cmd1: Command = .patchElements;
    const cmd2: Command = .patchSignals;
    const cmd3: Command = .executeScript;

    try std.testing.expect(cmd1 != cmd2);
    try std.testing.expect(cmd2 != cmd3);
    try std.testing.expect(cmd1 != cmd3);
}

test "PatchMode enum values" {
    const modes = [_]PatchMode{
        .inner,
        .outer,
        .replace,
        .prepend,
        .append,
        .before,
        .after,
        .remove,
    };

    // Just verify all modes are distinct
    for (modes, 0..) |mode1, i| {
        for (modes[i + 1 ..]) |mode2| {
            try std.testing.expect(mode1 != mode2);
        }
    }
}

test "NameSpace enum values" {
    try std.testing.expectEqual(NameSpace.html, NameSpace.html);
    try std.testing.expectEqual(NameSpace.svg, NameSpace.svg);
    try std.testing.expectEqual(NameSpace.mathml, NameSpace.mathml);

    try std.testing.expect(NameSpace.html != NameSpace.svg);
    try std.testing.expect(NameSpace.svg != NameSpace.mathml);
}

test "Message.init sets correct command and options for patchElements" {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer().any();

    var msg: Message = undefined;
    const opts = PatchElementsOptions{ .mode = .inner, .selector = "#test" };
    msg.init(.patchElements, opts, &writer);

    try std.testing.expectEqual(Command.patchElements, msg.command);
    try std.testing.expectEqual(PatchMode.inner, msg.patch_element_options.mode);
    try std.testing.expectEqualStrings("#test", msg.patch_element_options.selector.?);
}

test "Message.init sets correct command and options for patchSignals" {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer().any();

    var msg: Message = undefined;
    const opts = PatchSignalsOptions{ .only_if_missing = true };
    msg.init(.patchSignals, opts, &writer);

    try std.testing.expectEqual(Command.patchSignals, msg.command);
    try std.testing.expect(msg.patch_signal_options.only_if_missing);
}

test "Message.init sets correct command and options for executeScript" {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    var writer = fbs.writer().any();

    var msg: Message = undefined;
    const opts = ExecuteScriptOptions{ .auto_remove = false };
    msg.init(.executeScript, opts, &writer);

    try std.testing.expectEqual(Command.executeScript, msg.command);
    try std.testing.expect(!msg.execute_script_options.auto_remove);
}

test "ScriptAttributes can store key-value pairs" {
    var attrs = ScriptAttributes.init(std.testing.allocator);
    defer attrs.deinit();

    try attrs.put("type", "module");
    try attrs.put("async", "true");

    try std.testing.expectEqual(2, attrs.count());
    try std.testing.expectEqualStrings("module", attrs.get("type").?);
    try std.testing.expectEqualStrings("true", attrs.get("async").?);
}

test "PatchElementsOptions with custom values" {
    const opts = PatchElementsOptions{
        .mode = .inner,
        .selector = "#content",
        .view_transition = true,
        .event_id = "evt-123",
        .retry_duration = 5000,
        .namespace = .svg,
    };

    try std.testing.expectEqual(PatchMode.inner, opts.mode);
    try std.testing.expectEqualStrings("#content", opts.selector.?);
    try std.testing.expect(opts.view_transition);
    try std.testing.expectEqualStrings("evt-123", opts.event_id.?);
    try std.testing.expectEqual(5000, opts.retry_duration.?);
    try std.testing.expectEqual(NameSpace.svg, opts.namespace);
}
