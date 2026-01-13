const std = @import("std");
const http = std.http;

pub fn main() !void {
    // Just checking if code compiles
    var server: http.Server = undefined;
    var req: http.Server.Request = undefined;
    
    _ = server;
    // Check reader methods
    _ = req.reader();
    
    // Check if readerExpectNone exists
    var buf: [1024]u8 = undefined;
    _ = req.readerExpectNone(&buf);
}
