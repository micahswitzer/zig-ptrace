const std = @import("std");

fn signal_handler(sig: c_int, info: *const std.os.siginfo_t, context: ?*const anyopaque) callconv(.C) void {
    _ = sig;
    _ = info;
    _ = context;
    std.io.getStdErr().writer().print("Got SIGINT on thread {}\n", .{pid}) catch unreachable;
    std.os.exit(1);
}

threadlocal var pid: std.os.pid_t = 0;

fn thread_main(index: usize) !void {
    const writer = std.io.getStdOut().writer();
    pid = std.os.linux.gettid();
    std.os.nanosleep(index, 0);
    while (true) {
        try writer.print("[{}] Hello from {}\n", .{ pid, index });
        std.os.nanosleep(5, 0);
    }
}

pub fn main() !void {
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;

    const new_action = std.os.Sigaction{
        .handler = .{ .sigaction = &signal_handler },
        .mask = std.os.linux.empty_sigset,
        .flags = std.os.linux.SA.SIGINFO,
        .restorer = null,
    };
    try std.os.sigaction(std.os.SIG.INT, &new_action, null);

    defer {
        for (threads) |*thread, i| {
            if (i == started)
                break;
            thread.join();
        }
    }
    for (threads) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, thread_main, .{i});
        started += 1;
    }
}
