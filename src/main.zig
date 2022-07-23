//const std = @import("std");
//const testing = std.testing;
const ptrace = @import("ptrace.zig");

pub fn main() anyerror!void {
    try ptrace.traceMe();
}
