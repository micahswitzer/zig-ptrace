const std = @import("std");
const print = @import("utils.zig").makePrefixedPrint("c");

pub fn main() void {
    print("Going to sleep...", .{});
    std.os.nanosleep(2, 0);
    print("Waking up...", .{});
}
