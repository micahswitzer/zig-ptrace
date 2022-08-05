const std = @import("std");
const ptrace = @import("ptrace");
const ll = ptrace.lowlevel;
const utils = @import("utils");

const print = utils.makePrefixedPrint("p");
const STOP = std.os.linux.SIG.STOP;
const TRAP = std.os.linux.SIG.TRAP;

fn printState(thread: ll.Thread) void {
    const writer = std.io.getStdOut().writer();
    thread.printState(writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
}

pub fn main() !void {
    if (std.os.argv.len != 2) return error.InvalidUsage;
    const tracee_path = std.os.argv[1];

    print("Starting {s}", .{tracee_path});
    var thread = try ll.spawnTraced(tracee_path);
    print("Child spawned as PID {}", .{thread.id});
    printState(thread);
    while (thread.isAttached()) {
        const sig = thread.waitSignaled() catch |err| switch (err) {
            error.NoSuchProcess => break,
            else => return err,
        };
        printState(thread);
        if (sig == STOP or sig == TRAP) {
            try thread.contUnchecked(0);
        } else {
            try thread.contUnchecked(sig);
        }
    }
    printState(thread);

    // ensure it's detached
    if (thread.isAttached()) {
        thread.detach(switch (thread.state) {
            .Stopped => |sig| sig,
            else => 0,
        }) catch {};
        printState(thread);
    }

    print("Done", .{});
}
