const std = @import("std");
const ll = @import("ptrace").lowlevel;
const utils = @import("utils");

var heap: [4096]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.FixedBufferAllocator.init(&heap);
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const subprocess_args: [1][]const u8 = .{args[1]};
    var process = std.ChildProcess.init(&subprocess_args, alloc);
    try process.spawn();
    errdefer {
        _ = process.kill() catch {};
    }

    std.time.sleep(1000 * 1000 * 1000 * 2);
    var thread = try ll.attachThread(process.pid);

    while (true) {
        const signal = try thread.waitSignaled();
        std.debug.print("Got SIG{s}\n", .{
            if (utils.intDeclToString(std.os.linux.SIG, signal)) |str|
                str[0..]
            else
                "UNKNOWN",
        });
        if (signal == std.os.linux.SIG.STOP) {
            try thread.detach(0);
            break;
        }
        try thread.contUnchecked(signal);
    }

    try std.os.kill(process.pid, std.os.linux.SIG.TERM);
    _ = try process.wait();
}
