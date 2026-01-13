const std = @import("std");
const HTTPRequest = @import("http_request.zig");

const Log = @This();

const resetColor = "\x1b[0m";
const methodColor = "\x1b[1;30;46m";

pub const Level = enum {
    none,
    path,
    payload,
    signals,
    all,
};

pub const Format = enum {
    none,
    json,
    pretty,
};

level: Level = .path,
format: Format = .pretty,
slow: std.Io.Duration = .fromMilliseconds(200),
fast: std.Io.Duration = .fromNanoseconds(50_000),

pub fn info(log: Log, http: *HTTPRequest) void {
    const elapsed: std.Io.Duration = .fromNanoseconds(http.timer.read());
    std.log.info("{s}{t:<6}{s} {s:<60} {s}{}{s} {s}{:>8}{s} μs", .{
        methodColor,
        http.req.head.method,
        resetColor,
        getPathOnly(http),
        statusColor(http.status),
        @intFromEnum(http.status),
        resetColor,
        log.timerColor(elapsed, http.detach),
        @divTrunc(elapsed.toNanoseconds(), std.time.ns_per_us),
        resetColor,
    });
}

pub fn debug(_: Log, comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
}

pub fn payload(self: Log, http: *HTTPRequest) void {
    if (http.req_payload) |p| {
        self.debug(" > {s}", .{p});
    }
}

pub fn signals(_: Log, http: *HTTPRequest) void {
    if (http.query()) |query_params| {
        if (http.req.head.method == .GET and query_params.len > 0) {
            std.debug.print("about to do some trickery on query params {s}\n", .{query_params});
            const buf: []u8 = "";
            var decode_params = http.arena.dupe(u8, query_params) catch blk: {
                std.debug.print("failed to dupe the query params ???\n", .{});
                break :blk buf;
            };
            const start_index = if (std.mem.findScalar(u8, decode_params, '=')) |idx| idx + 1 else 0;
            std.debug.print("decode params is {s} using start index {}\n", .{ decode_params, start_index });
            decode_params = decode_params[start_index..];
            _ = std.mem.replaceScalar(u8, decode_params, '+', ' ');
            std.log.debug(" > Signals: {s}", .{
                std.Uri.percentDecodeInPlace(decode_params),
            });
        }
    }
}

pub fn err(_: Log, http: *HTTPRequest, error_value: anyerror, status: std.http.Status) void {
    std.log.err("{} {t} - {t} {s}", .{ error_value, status, http.req.head.method, http.req.head.target });
}

fn statusColor(status: std.http.Status) []const u8 {
    const code = @intFromEnum(status);
    return switch (code) {
        200...299 => "\x1b[32m", // Green
        300...399 => "\x1b[36m", // Cyan
        400...499 => "\x1b[33m", // Yellow
        500...599 => "\x1b[1;31m", // Red
        else => "\x1b[0m", // Reset/White
    };
}

/// choose a color based on the elapsed time - units are ns
fn timerColor(log: Log, duration: std.Io.Duration, detached: bool) []const u8 {
    const fast = log.fast.toNanoseconds();
    const slow = log.slow.toNanoseconds();
    const elapsed = duration.toNanoseconds();

    if (2 * elapsed <= fast) return "\x1b[1;32m"; // bold green for real fast
    if (elapsed >= 2 * slow) return if (detached) "\x1b[41;30m" else "\x1b[0;91m"; // bold red for real slow

    if (elapsed <= fast) return "\x1b[32m"; // green for fast
    if (elapsed >= slow) return if (detached) "\x1b[41;30m" else "\x1b[31m"; // red for slow

    return "\x1b[33m"; // yellow for average
}

fn getPathOnly(http: *HTTPRequest) []const u8 {
    const target = http.req.head.target;
    if (std.mem.findScalar(u8, target, '?')) |i| {
        return target[0..i];
    }
    return target;
}
