const std = @import("std");
const ptrace = @import("ptrace.zig");
const util = @import("utils.zig");
const snippets = @import("snippets.zig");
const proc = @import("proc.zig");

const linux = std.os.linux;
const os = std.os;

const Options = ptrace.Options;
const Pid = ptrace.Pid;
const Signal = ptrace.Signal;
const SigInfo = ptrace.SigInfo;
const UserRegs = ptrace.UserRegs;

/// A linux-specific flag to waitpid that says to wait on either a cloned or
/// non-cloned child
const __WALL = 0x40000000;

const log = std.log.scoped(.lowlevel);

pub const Thread = struct {
    id: Pid,
    state: State = .Detached,

    /// Tracks the state of a thread that is traced, was traced, or is about to be traced
    pub const State = union(enum) {
        /// The thread is stopped due to receiving the specified signal
        Stopped: Signal,
        /// The thread was terminated due to the specified signal
        Terminated: Signal,
        /// The thread exited normally with the specified exit code
        Exited: u8,
        /// The thread is attached and running
        Running,
        /// The thread has already been cleaned up and no exit information exists for it
        Gone,
        /// The thread is presumably running, but is not attached
        Detached,

        pub fn fromStatus(status: u32) State {
            if (os.W.IFSTOPPED(status))
                return State{ .Stopped = os.W.STOPSIG(status) };
            if (os.W.IFSIGNALED(status))
                return State{ .Terminated = os.W.TERMSIG(status) };
            if (os.W.IFEXITED(status))
                return State{ .Exited = os.W.EXITSTATUS(status) };
            unreachable;
        }
    };

    pub fn printState(thread: Thread, writer: anytype) !void {
        return switch (thread.state) {
            .Stopped => |sig| writer.print("Stopped: {s}", .{signalToString(sig)}),
            .Terminated => |sig| writer.print("Terminated: {s}", .{signalToString(sig)}),
            .Exited => |code| writer.print("Exited: {}", .{code}),
            .Running, .Gone, .Detached => writer.print("{s}", .{@tagName(thread.state)}),
        };
    }

    pub fn isAttached(self: Thread) bool {
        return switch (self.state) {
            .Running, .Stopped => true,
            .Terminated, .Exited, .Gone, .Detached => false,
        };
    }

    pub fn waitUnchecked(self: *Thread) !void {
        // if we try to wait when the thread is stopped then we almost
        // certainly guarantee a deadlock will occur
        std.debug.assert(self.state == .Running);
        var status: u32 = undefined;
        const res = linux.waitpid(self.id, &status, __WALL);
        switch (linux.getErrno(res)) {
            .SUCCESS => {
                const pid = @intCast(Pid, res);
                std.debug.assert(pid == self.id);
                self.state = State.fromStatus(status);
            },
            .CHILD => {
                self.state = .Gone;
                return error.NoSuchProcess;
            },
            // the PID file descriptor *should* always be blocking
            .AGAIN => unreachable,
            // interrupted by a signal (how should this be handled?)
            .INTR => unreachable,
            // we know we passed in good arguments
            .INVAL => unreachable,
            .SRCH => unreachable,
            // everything else will not be returned in any condition
            else => unreachable,
        }
    }

    pub fn wait(self: *Thread) !void {
        if (self.state != .Running)
            return error.NotRunning;
        return self.waitUnchecked();
    }

    pub fn waitSignaled(self: *Thread) !Signal {
        switch (self.state) {
            .Running => {},
            .Stopped => |signal| return signal,
            else => return error.InvalidState,
        }
        try self.waitUnchecked();
        switch (self.state) {
            .Stopped => |signal| return signal,
            .Terminated, .Exited => return error.NoSuchProcess,
            else => unreachable,
        }
    }

    /// Returns the signal the process is stopped at until the process ends
    /// Note: this function will not automatically resume the thread if it's already stopped
    pub fn nextSignal(self: *Thread) !?Signal {
        return self.waitSignaled() catch |err| switch (err) {
            error.NoSuchProcess => return null,
            else => return err,
        };
    }

    pub fn stopUnchecked(self: *Thread) !void {
        std.debug.assert(self.state == .Running);
        const res = linux.tgkill(0, self.id, linux.SIG.STOP);
        switch (linux.getErrno(res)) {
            .SUCCESS => return,
            .AGAIN => unreachable,
            .INVAL => unreachable,
            // we're already attached to this thread, so we have permission to send it signals
            .PERM => unreachable,
            .SRCH => {
                self.state = .Gone;
                return error.NoSuchProcess;
            },
            else => unreachable,
        }
    }

    /// We quite commonly need to assert that this thread is stopped
    fn assertStopped(self: Thread) void {
        // if this trips, the calling code is buggy
        std.debug.assert(self.state == .Stopped);
    }

    fn testStopped(self: Thread) error{NotStopped}!void {
        if (self.state != .Stopped)
            return error.NotStopped;
    }

    pub fn peekTextUnchecked(self: *Thread, addr: usize) !usize {
        self.assertStopped();
        return ptrace.peekText(self.id, addr) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
    }

    pub fn readTextUnchecked(self: *Thread, addr: usize, buffer: []u8) !void {
        self.assertStopped();
        const word_size = @sizeOf(usize);
        const start_raw = addr;
        const start_addr = std.mem.alignBackward(start_raw, word_size);
        const offset = start_raw - start_addr;
        const end_raw = start_raw + buffer.len;
        const to_write = end_raw - start_raw;
        var read_at = start_addr;
        var write_idx: usize = 0;

        // I love unaligned memory access :)
        if (offset != 0) {
            const word = try self.peekTextUnchecked(start_addr);
            const bytes = std.mem.toBytes(word);
            const write_count = @minimum(word_size - offset, to_write);
            const write_bytes = bytes[offset .. offset + write_count];
            std.mem.copy(u8, buffer, write_bytes);
            read_at += word_size;
            write_idx += write_count;
        }
        while (to_write - write_idx >= word_size) {
            const word = try self.peekTextUnchecked(read_at);
            const bytes = std.mem.toBytes(word);
            std.mem.copy(u8, buffer[write_idx..], &bytes);
            read_at += word_size;
            write_idx += word_size;
        }
        const remaining = to_write - write_idx;
        if (remaining != 0) {
            const word = try self.peekTextUnchecked(read_at);
            const bytes = std.mem.toBytes(word);
            std.mem.copy(u8, buffer[write_idx..], bytes[0..remaining]);
        }
    }

    pub fn readMem(self: Thread, addr: usize, buffer: []u8) !void {
        const proc_mem = try proc.openProcFile(.mem, self.id);
        defer proc_mem.close();
        try proc_mem.seekTo(addr);
        try proc_mem.reader().readNoEof(buffer);
    }

    pub fn writeMem(self: Thread, addr: usize, data: []const u8) !void {
        const proc_mem = try proc.openProcFileWriteable(.mem, self.id);
        defer proc_mem.close();
        try proc_mem.seekTo(addr);
        try proc_mem.writeAll(data);
    }

    pub fn doSyscall(self: *Thread, sys: linux.SYS, arguments: ptrace.Args) !usize {
        self.assertStopped();
        const regs_orig = try self.getRegsUnchecked();
        var text_orig: [snippets.syscall.len]u8 = undefined;
        const pc = regs_orig.getPC();
        try self.readMem(pc, &text_orig);
        const regs_syscall = blk: {
            var regs = regs_orig;
            regs.setSyscall(sys);
            regs.setArgs(arguments);
            break :blk regs;
        };
        try self.writeMem(pc, snippets.syscall);
        // we want to be able to catch errors normally, so only errdefer here
        errdefer self.writeMem(pc, &text_orig) catch {};
        try self.setRegsUnchecked(regs_syscall);
        errdefer self.setRegs(regs_orig) catch {};

        // the ptrace syscall command will trap on syscall entry and exit
        try self.syscallUnchecked(switch (self.state.Stopped) {
            linux.SIG.STOP, linux.SIG.TRAP => 0,
            else => |sig| sig,
        });
        // just wait until the trap and then immediately continue
        // TODO detect when we trap on code other than a syscall
        // (will this happen if we ensure the next instruction is `syscall`?)
        while (try self.nextSignal()) |sig| {
            if (sig == linux.SIG.TRAP)
                break;
            if (sig == linux.SIG.STOP) {
                log.err("Unexpected SIGSTOP, expected SIGTRAP", .{});
                try self.contUnchecked(0);
            }
            try self.contUnchecked(sig);
        } else {
            log.err("Process died while waiting for syscall to start", .{});
            return error.NoSuchProcess;
        }
        // TODO probably not the right resume signal for every situation
        try self.syscallUnchecked(0);
        // now we wait for the syscall to complete
        while (try self.nextSignal()) |sig| {
            if (sig == linux.SIG.TRAP)
                break;
            if (sig == linux.SIG.STOP) {
                log.err("Unexpected SIGSTOP, expected SIGTRAP", .{});
                try self.contUnchecked(0);
            }
            try self.contUnchecked(sig);
        } else {
            // TODO this might happen with system calls such as `exit` and `abort`?
            log.err("Process died while waiting for syscall to complete", .{});
            return error.NoSuchProcess;
        }
        // inspect the results and restore the original state
        const regs_result = try self.getRegsUnchecked();
        try self.writeMem(pc, &text_orig);
        try self.setRegsUnchecked(regs_orig);
        return regs_result.getRet();
    }

    pub fn getRegsUnchecked(self: *Thread) !UserRegs {
        self.assertStopped();
        return ptrace.getRegs(self.id) catch |err| {
            switch (err) {
                // exhaustive matching will ensure we handle any new errors that are added
                error.NoSuchProcess => self.state = .Gone,
            }
            return err;
        };
    }

    pub fn getRegs(self: *Thread) !UserRegs {
        try self.testStopped();
        return self.getRegsUnchecked();
    }

    pub fn setRegsUnchecked(self: *Thread, regs: UserRegs) !void {
        self.assertStopped();
        ptrace.setRegs(self.id, regs) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
    }

    pub fn setRegs(self: *Thread, regs: UserRegs) !void {
        try self.testStopped();
        return self.setRegsUnchecked(regs);
    }

    pub fn getSigInfoUnchecked(self: *Thread) !SigInfo {
        self.assertStopped();
        return ptrace.getSigInfo(self.id) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
    }

    pub fn getSigInfo(self: *Thread) !SigInfo {
        try self.testStopped();
        return self.getSigInfoUnchecked();
    }

    pub fn setOptionsUnchecked(self: *Thread, options: Options) !void {
        self.assertStopped();
        ptrace.setOptions(self.id, options) catch |err| {
            if (err == error.NoSuchProcess)
                self.state == .Gone;
            return err;
        };
    }

    pub fn setOptions(self: *Thread, options: Options) !void {
        try self.testStopped();
        return self.setOptionsUnchecked(options);
    }

    pub fn contUnchecked(self: *Thread, sig: Signal) !void {
        self.assertStopped();
        ptrace.cont(self.id, sig) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
        self.state = .Running;
    }

    /// Thread must be Stopped
    pub fn cont(self: *Thread, sig: Signal) !void {
        try self.testStopped();
        return self.contUnchecked(sig);
    }

    pub fn syscallUnchecked(self: *Thread, sig: Signal) !void {
        self.assertStopped();
        ptrace.syscall(self.id, sig) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
        self.state = .Running;
    }

    pub fn syscall(self: *Thread, sig: Signal) !void {
        try self.testStopped();
        return self.syscallUnchecked(sig);
    }

    pub fn attachUnchecked(self: *Thread) !void {
        std.debug.assert(self.state == .Detached);
        ptrace.attach(self.id) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone;
            return err;
        };
        self.state = .Running;
    }

    pub fn attach(self: *Thread) !void {
        if (self.state != .Detached)
            return error.InvalidState;
        return self.attachUnchecked();
    }

    pub fn detachUnchecked(self: *Thread, sig: Signal) !void {
        self.assertStopped();
        ptrace.detach(self.id, sig) catch |err| {
            if (err == error.NoSuchProcess)
                self.state = .Gone; // TODO should this be an error?
            return err;
        };
        self.state = .Detached;
    }

    pub fn detach(self: *Thread, sig: Signal) !void {
        try self.testStopped();
        return self.detachUnchecked(sig);
    }
};

fn spawnee(prog: [*:0]const u8) anyerror {
    try traceMeAndStop();
    return os.execveZ(prog, &[_:null]?[*:0]const u8{ prog, null }, &[_:null]?[*:0]const u8{null});
}

pub fn spawnTraced(prog: [*:0]const u8) !Thread {
    const pid = try os.fork();
    if (pid == 0)
        // the child process can't return errors, so we abort here
        spawnee(prog) catch os.abort();
    return threadFromTraceme(pid);
}

pub fn traceMeAndStop() !void {
    try ptrace.traceMe();
    try os.raise(linux.SIG.STOP);
}

pub fn threadFromTraceme(tid: Pid) Thread {
    return Thread{ .id = tid, .state = .Running };
}

pub fn attachThread(tid: Pid) !Thread {
    var thread = Thread{ .id = tid };
    try thread.attachUnchecked();
    return thread;
}

/// WARNING: this doesn't guarantee *which* signal the thread is stopped on
pub fn attachThreadSignaled(tid: Pid) !Thread {
    var thread = try attachThread(tid);
    _ = try thread.waitSignaled();
    return thread;
}

pub fn signalToString(sig: Signal) []const u8 {
    return util.intDeclToString(linux.SIG, sig) orelse "UNKNOWN";
}

test "thread create and wait" {
    var thread = try spawnTraced("/bin/ls");
    try std.testing.expectEqual(@as(Signal, linux.SIG.STOP), try thread.waitSignaled());
    try thread.cont(0);
    try std.testing.expectEqual(@as(Signal, linux.SIG.TRAP), try thread.waitSignaled());
    try thread.detach(0);
}

test {
    _ = snippets;
}
