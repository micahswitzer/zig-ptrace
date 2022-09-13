const std = @import("std");
const utils = @import("utils");
const linux = std.os.linux;

const Signal = utils.Signal;
const SignalInfo = std.os.linux.siginfo_t;

const SUID_DUMP_DISABLE = 0;

fn sigHandler(sig: Signal, info: *const SignalInfo) void {
    _ = sig;
    _ = info;
}

const SIGNAL = std.os.linux.SIG.USR1;
const SIGNAL_NAME = utils.intDeclToString(std.os.linux.SIG, SIGNAL).?;

pub fn main() u8 {
    std.debug.print("Starting.\n", .{});
    utils.setSignalAction(SIGNAL, sigHandler) catch return 1;
    _ = std.os.prctl(linux.PR.SET_DUMPABLE, .{SUID_DUMP_DISABLE}) catch return 2;

    std.debug.print("Registered signal handler for " ++ SIGNAL_NAME ++ "\n", .{});

    while (true) {
        std.os.raise(SIGNAL) catch break;
    }

    std.debug.print("Exiting.\n", .{});
    return 0;
}
