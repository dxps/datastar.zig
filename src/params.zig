const std = @import("std");

const Io = std.Io;
const Params = @This();

names: [8][]const u8 = undefined,
values: [8][]const u8 = undefined,
count: usize = 0,

pub fn get(self: Params, name: []const u8) ?[]const u8 {
    for (0..self.count) |i| {
        if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
    }
    return null;
}

pub fn getInt(self: Params, T: type, name: []const u8) ?T {
    for (0..self.count) |i| {
        if (std.mem.eql(u8, self.names[i], name)) {
            return std.fmt.parseInt(T, self.values[i], 10) catch null;
        }
    }
    return null;
}

pub fn format(self: Params, writer: *Io.Writer) !void {
    try writer.writeAll("Params { ");
    for (0..self.count) |i| {
        if (i > 0) {
            try writer.writeAll(", ");
        }
        try writer.print("  {s}: \"{s}\"", .{ self.names[i], self.values[i] });
    }
    try writer.writeAll("}");
}
