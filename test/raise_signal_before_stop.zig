const std = @import("std");
const utils = @import("utils");

const Signal = utils.Signal;
const SignalInfo = std.os.linux.siginfo_t;

fn sigHandler(sig: Signal, info: *const SignalInfo) void {
    _ = sig;
    _ = info;
}

const SIGNAL = std.os.linux.SIG.USR1;
const SIGNAL_NAME = utils.intDeclToString(std.os.linux.SIG, SIGNAL).?;

pub fn main() void {
    std.debug.print("Starting.\n", .{});
    utils.setSignalAction(SIGNAL, sigHandler) catch return;

    std.debug.print("Registered signal handler for " ++ SIGNAL_NAME ++ "\n", .{});

    while (true) {
        std.os.raise(SIGNAL) catch break;
    }

    std.debug.print("Exiting.\n", .{});
}
