const std = @import("std");
const print = @import("utils").makePrefixedPrint("c");

pub fn main() void {
    print("Going to sleep...", .{});
    std.posix.nanosleep(2, 0);
    print("Waking up...", .{});
}
