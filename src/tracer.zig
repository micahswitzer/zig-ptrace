const std = @import("std");
const ptrace = @import("ptrace.zig");
const hl = @import("highlevel.zig");
const utils = @import("utils.zig");

const print = utils.makePrefixedPrint("p");

fn dumpSyscallInfo(thread: hl.Thread) !void {
    if (comptime @hasDecl(ptrace, "getRegs")) {
        const r = try ptrace.getRegs(thread.tid);
        print(
            \\   REGS:
            \\    syscall = {}
            \\     arg0 = {}
            \\     arg1 = {}
            \\     arg2 = {}
            \\     arg3 = {}
            \\     arg4 = {}
            \\     arg5 = {}
            \\    ret = {}
        , .{r.syscall()} ++ r.args() ++ .{r.ret()});
    }
}

pub fn main() !void {
    if (std.os.argv.len != 2) return error.InvalidUsage;
    const tracee_path = std.os.argv[1];

    print("Starting {s}", .{tracee_path});
    var thread = try hl.Thread.attachSpawned(tracee_path);
    print("Child spawned as PID {}", .{thread.tid});
    while (thread.isAttached()) {
        print(" {?}", .{thread.state});
        try dumpSyscallInfo(thread);
        thread.resumeExecution() catch |err| switch (err) {
            error.NotRunning => break,
            // we don't inject new signals and we only call
            // this when we're in the correct state
            else => unreachable,
        };
        _ = thread.waitStopped() catch |err| {
            if (err == error.NotRunning)
                break;
            return err;
        };
    }
    print("Detached: {?}", .{thread.state});
    dumpSyscallInfo(thread) catch {};

    // ensure it's detached
    thread.detach() catch {};
    print("Done", .{});
}
