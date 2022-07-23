const std = @import("std");

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    std.log.info("Going to sleep...", .{});
    std.os.nanosleep(2, 0);
    std.log.info("Waking up...", .{});
}
