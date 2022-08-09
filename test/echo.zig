const std = @import("std");

var buffer: [4096]u8 = undefined;

fn readData(reader: anytype, buf: []u8) !?[]const u8 {
    const size = try reader.read(buf);
    if (size == 0)
        return null;
    return buf[0..size];
}

pub fn main() !void {
    const reader = std.io.getStdIn().reader();
    const writer = std.io.getStdOut().writer();
    while (try readData(reader, &buffer)) |data| {
        try writer.writeAll(data);
    }
}
