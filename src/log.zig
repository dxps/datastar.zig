const std = @import("std");
const HTTPRequest = @import("http_request.zig");

const Log = @This();

const resetColor = "\x1b[0m";
fn methodColor(method: std.http.Method) []const u8 {
    return switch (method) {
        .GET => "\x1b[1;30;45m", // purple
        .DELETE => "\x1b[1;30;41m", // red
        else => "\x1b[1;30;46m", // cyan
    };
}

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
// units here are microseconds
slow_ms: u64 = 200, // 200ms
fast_us: u64 = 20, // 20us

pub fn info(log: Log, http: *HTTPRequest) void {
    const elapsed: u64 = http.timer.read();
    std.log.info("{s}{}{s} {s}{t:<6}{s} {s:<60} {s}{:>8}{s} μs", .{
        statusColor(http.status),
        @intFromEnum(http.status),
        resetColor,
        methodColor(http.method),
        http.method,
        resetColor,
        getPathOnly(http),
        log.timerColor(elapsed, http.detach),
        @divTrunc(elapsed, 1_000),
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
        if (http.method == .GET and query_params.len > 0) {
            const buf: []u8 = "";
            var decode_params = http.arena.dupe(u8, query_params) catch blk: {
                break :blk buf;
            };
            const start_index = if (std.mem.findScalar(u8, decode_params, '=')) |idx| idx + 1 else 0;
            decode_params = decode_params[start_index..];
            _ = std.mem.replaceScalar(u8, decode_params, '+', ' ');
            std.log.debug(" > Signals: {s}", .{
                std.Uri.percentDecodeInPlace(decode_params),
            });
        }
    }
}

pub fn err(_: Log, http: *HTTPRequest, error_value: anyerror, status: std.http.Status) void {
    std.log.err("{} {t} - {t} {s}", .{ error_value, status, http.method, http.path });
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
fn timerColor(log: Log, elapsed: u64, detached: bool) []const u8 {
    const elapsed_us = @divTrunc(elapsed, 1000);
    const elapsed_ms = @divTrunc(elapsed_us, 1000);

    // is it fast ?
    if (2 * elapsed_us <= log.fast_us) return "\x1b[1;96m"; // bold cyan for real fast
    if (elapsed_us <= log.fast_us) return "\x1b[32m"; // green for fast

    // is it too slow ?
    if (elapsed_ms >= 2 * log.slow_ms) return if (detached) "\x1b[41;30m" else "\x1b[0;91m"; // bold red for real slow
    if (elapsed_ms >= log.slow_ms) return if (detached) "\x1b[41;30m" else "\x1b[31m"; // red for slow

    return "\x1b[33m"; // yellow for average
}

fn getPathOnly(http: *HTTPRequest) []const u8 {
    const target = http.path;
    if (std.mem.findScalar(u8, target, '?')) |i| {
        return target[0..i];
    }
    return target;
}
