const std = @import("std");
const pt = @import("ptrace.zig");

const linux = std.os.linux;
const os = std.os;
const Pid = pt.Pid;
const UserRegs = pt.UserRegs;

pub const Thread = struct {
    tid: Pid,
    pid: Pid,
    state: State,
    /// The signal to inject into the thread on the next restart
    inject: Signal = 0,
    regs: UserRegs = undefined,

    const Self = @This();

    const Signal = u32;

    pub const State = union(enum) {
        Stopped: Signal,
        Terminated: Signal,
        Exited: u8,
        Running,
        /// The thread has already been cleaned up and no exit information exists for it
        Gone,
        /// The thread has been detached from its tracer (us)
        Detached,

        pub fn fromCode(code: u32) State {
            if (os.W.IFSTOPPED(code))
                return State{ .Stopped = os.W.STOPSIG(code) };
            if (os.W.IFSIGNALED(code))
                return State{ .Terminated = os.W.TERMSIG(code) };
            if (os.W.IFEXITED(code))
                return State{ .Exited = os.W.EXITSTATUS(code) };
            unreachable;
        }
    };

    pub fn isAttached(self: Self) bool {
        return switch (self.state) {
            .Stopped, .Running => true,
            .Exited, .Terminated, .Gone, .Detached => false,
        };
    }

    fn handleSignal(self: *Self, signal: Signal) void {
        self.inject = switch (signal) {
            os.SIG.STOP => 0,
            os.SIG.TRAP => 0,
            else => signal,
        };
    }

    /// Wait until the thread is stopped by a signal
    pub fn waitStopped(self: *Self) !Signal {
        // TODO: should this be an error? we expected to be running?
        // I think no, this acts as a synchronization of sorts. don't care going in, stopped going out
        switch (self.state) {
            .Stopped => |sig| return sig,
            else => {},
        }
        const res = os.waitpid(self.tid, 0);
        std.debug.assert(res.pid == self.tid);
        self.state = State.fromCode(res.status);
        switch (self.state) {
            .Stopped => |sig| {
                self.handleSignal(sig);
                return sig;
            },
            else => return error.NotRunning,
        }
    }

    const NotRunningError = error{NotRunning};
    const RestartError = NotRunningError || error{
        InvalidSignal,
    };
    const RestartAction = enum { cont, detach };
    fn restart(self: *Self, comptime action: RestartAction) RestartError!void {
        switch (self.state) {
            .Stopped => {
                const func = switch (action) {
                    .cont => pt.cont,
                    .detach => pt.detach,
                };
                func(self.tid, self.inject) catch |err| {
                    switch (err) {
                        error.NoSuchProcess => {
                            self.state = .Gone;
                            return error.NotRunning;
                        },
                        error.InvalidSignal => return RestartError.InvalidSignal,
                    }
                };
            },
            // this function is internal and must be used when we *know* the process is stopped
            else => unreachable,
        }
        self.state = switch (action) {
            .cont => .Running,
            .detach => .Detached,
        };
    }

    /// Restart the thread
    fn cont(self: *Self) RestartError!void {
        return self.restart(.cont);
    }

    pub const ResumeError = RestartError || error{InvalidState};
    pub fn resumeExecution(self: *Self) !void {
        switch (self.state) {
            .Stopped => try self.cont(),
            else => return error.InvalidState,
        }
    }

    /// Wait until the thread stops due to a SIGSTOP
    pub fn waitStoppedStop(self: *Self) !void {
        try self.waitStoppedSig(os.SIG.STOP);
    }

    /// Wait until the thread stops due to the specified signal
    pub fn waitStoppedSig(self: *Self, signal: Signal) !void {
        while ((try self.waitStopped()) != signal) {
            try self.cont();
        }
    }

    /// Ensure the thread is stopped with `SIGSTOP`
    pub fn stop(self: *Self) !void {
        if (self.state == .Stopped)
            return;

        if (self.state != .Running)
            return error.NotRunning;

        // we must politely ask it to stop
        const errno = linux.getErrno(linux.tgkill(self.pid, self.tid, os.SIG.STOP));
        switch (errno) {
            .SUCCESS => try self.waitStoppedStop(),
            .SRCH => {
                // the process has died unexpectedly
                self.state = .Gone;
                return error.NotRunning;
            },
            .INVAL => unreachable, // I'm not sure how this differs from ESRCH
            .AGAIN => unreachable, // not sending a real-time signal
            .PERM => unreachable, // if we can ptrace, then we can kill
            else => unreachable, // all other error codes cannot be produced by tgkill
        }
    }

    pub fn attachPid(pid: Pid) !Self {
        try pt.attach(pid);
        return Self{
            .pid = pid,
            .tid = pid,
            .state = .Running,
        };
    }

    pub fn attachSpawned(program: [*:0]const u8) !Self {
        const pid = try spawn(program, true, true);
        var thread = Self{
            .pid = pid,
            .tid = pid,
            .state = .Running,
        };
        // TODO: we know that an exec will occur as well so we should probably
        // synchronize until just after that happens?
        try thread.waitStoppedStop();
        return thread;
    }

    pub fn readRegs(self: *Self) !void {
        _ = self;
        @compileError("TODO");
    }

    pub fn detach(self: *Self) !void {
        // TODO: restore execution to the last known-good state
        // We should try to keep the tracee from crashing, but ultimately
        // the goal is the reliability of *this* program

        // PTRACE_DETACH can only be called if the process is stopped so do that here
        try self.stop();
        try self.restart(.detach);
    }
};

fn spawnee(prog: [*:0]const u8, traceme: bool, stop: bool) !void {
    // TODO: figure out how to handle errors from these functions
    if (traceme)
        try pt.traceMe();

    if (stop)
        try os.raise(os.SIG.STOP);

    return os.execveZ(prog, &[_:null]?[*:0]const u8{ prog, null }, &[_:null]?[*:0]const u8{null});
}

fn spawn(prog: [*:0]const u8, traceme: bool, stop: bool) !Pid {
    const pid = try os.fork();
    if (pid == 0)
        // the child process can't return errors, so we abort here
        spawnee(prog, traceme, stop) catch os.abort();
    return pid;
}

test {
    _ = pt;
}

test "thread create and wait" {
    var thread = try Thread.attachSpawned("/bin/ls");
    try std.testing.expectEqual(Thread.State{ .Stopped = os.SIG.STOP }, thread.state);
    try thread.cont();
    try thread.waitStoppedSig(os.SIG.TRAP);
    try std.testing.expectEqual(Thread.State{ .Stopped = os.SIG.TRAP }, thread.state);
    try thread.detach();
}
