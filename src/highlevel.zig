const builtin = @import("builtin");
const std = @import("std");
const pt = @import("ptrace.zig");
const Pid = pt.Pid;
const UserRegs = @import("userregs.zig").UserRegs;

const TCB = struct {
    tid: Pid,
    pid: Pid,
    state: State,
    regs: UserRegs = undefined,

    const Self = @This();

    const Signal = u32;

    pub const State = union(enum) {
        Stopped: Signal,
        Terminated: Signal,
        Exited: u8,
        Running,

        pub fn fromCode(code: u32) State {
            if (std.os.W.IFSTOPPED(code))
                return State{ .Stopped = std.os.W.STOPSIG(code) };
            if (std.os.W.IFSIGNALED(code))
                return State{ .Terminated = std.os.W.TERMSIG(code) };
            if (std.os.W.IFEXITED(code))
                return State{ .Exited = std.os.W.EXITSTATUS(code) };
            unreachable;
        }
    };

    pub fn getState(self: *const Self) State {
        return self.state;
    }

    fn waitSignaled(self: *Self) !Signal {
        // TODO: should this be an error? we expected to be running?
        if (self.state == .Stopped)
            return;
        const res = std.os.waitpid(self.tid, 0);
        if (res.pid != self.tid)
            return error.BadPid;
        self.state = State.fromCode(res);
        if (self.state == .Stopped) |sig|
            return sig;
        return error.NotRunning;
    }

    /// Wait until the thread stops due to a SIGSTOP
    pub fn waitStopped(self: *Self) !void {
        while (true) {
            const sig = try self.waitSignaled();
            if (sig == std.os.SIG.STOP)
                return;
            pt.cont(self.tid, sig);
        }
    }

    pub fn attachPid(pid: Pid) !Self {
        try pt.attach(pid);
        return Self{
            .pid = pid,
            .tid = pid,
        };
    }

    pub fn readRegs(self: *Self) !void {
        _ = self;
        @compileError("unimpl");
    }
};

fn spawn(prog: [:0]const u8) !Pid {
    const pid = try std.os.fork();
    if (pid == 0) {
        // child process
        // should never return
        std.os.execveZ("", &[_:null]?[*:0]const u8{prog}, &[_:null]?[*:0]const u8{}) catch {
            std.os.abort();
        };
        unreachable;
    }
    return pid;
}

test "valid" {
    //const allocator = std.testing.allocator;
    const pid = try spawn("./tracee");

    const tcb = try TCB.attachPid(pid);
    try tcb.waitStopped();
}
