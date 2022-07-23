const std = @import("std");
const print = std.debug.print;
const linux = std.os.linux;
const ptrace = @import("ptrace.zig");

const MS = 1000 * 1000;
const S = MS * 1000;

pub fn main() !void {
    print("[m] Starting up.\n", .{});
    const pid = linux.fork();
    if (pid == 0) {
        print("[f] Hello world.\n", .{});
        try ptrace.traceMe();
        print("[f] Now traced.\n", .{});
        try std.os.raise(@intCast(i32, linux.SIG.STOP));
        print("[f] Resumed.\n", .{});
        try linux.exit(0);
    }
    print("[m] Child's PID: {d}\n", .{pid});
    std.time.sleep(2 * S);
    const res = std.os.waitpid(@intCast(i32, pid), 0);
    print("[m] Child is now stopped: {}\n", .{res.status});
    std.time.sleep(2 * S);
}
