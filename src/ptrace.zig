const builtin = @import("builtin");
const std = @import("std");
const os = std.os;
const linux = std.os.linux;
const UserRegs = @import("userregs.zig").UserRegs;

const PTRACE_TRACEME: usize = 0;
const PTRACE_PEEKTEXT: usize = 1;
const PTRACE_PEEKDATA: usize = 2;
const PTRACE_PEEKUSER: usize = 3;
const PTRACE_POKETEXT: usize = 4;
const PTRACE_POKEDATA: usize = 5;
const PTRACE_POKEUSER: usize = 6;
const PTRACE_CONT: usize = 7;
const PTRACE_KILL: usize = 8;
const PTRACE_SINGLESTEP: usize = 9;
const PTRACE_GETREGS: usize = 12;
const PTRACE_SETREGS: usize = 13;
const PTRACE_GETFPREGS: usize = 14;
const PTRACE_SETFPREGS: usize = 15;
const PTRACE_ATTACH: usize = 16;
const PTRACE_DETACH: usize = 17;
const PTRACE_GETFPXREGS: usize = 18;
const PTRACE_SETFPXREGS: usize = 19;
const PTRACE_SYSCALL: usize = 24;
const PTRACE_GET_THREAD_AREA: usize = 25;
const PTRACE_SET_THREAD_AREA: usize = 26;
const PTRACE_ARCH_PRCTL: usize = 30;
const PTRACE_SYSEMU: usize = 31;
const PTRACE_SYSEMU_SINGLESTEP: usize = 32;
const PTRACE_SINGLEBLOCK: usize = 33;
const PTRACE_SETOPTIONS: usize = 16896;
const PTRACE_GETEVENTMSG: usize = 16897;
const PTRACE_GETSIGINFO: usize = 16898;
const PTRACE_SETSIGINFO: usize = 16899;
const PTRACE_GETREGSET: usize = 16900;
const PTRACE_SETREGSET: usize = 16901;
const PTRACE_SEIZE: usize = 16902;
const PTRACE_INTERRUPT: usize = 16903;
const PTRACE_LISTEN: usize = 16904;
const PTRACE_PEEKSIGINFO: usize = 16905;
const PTRACE_GETSIGMASK: usize = 16906;
const PTRACE_SETSIGMASK: usize = 16907;
const PTRACE_SECCOMP_GET_FILTER: usize = 16908;
const PTRACE_SECCOMP_GET_METADATA: usize = 16909;
const PTRACE_GET_SYSCALL_INFO: usize = 16910;

//const c = @cImport({
//    @cInclude("sys/ptrace.h");
//});

comptime {
    std.debug.assert(builtin.os.tag == .linux);
}

pub const PtraceError = error{
    RegisterAlloc, // EBUSY on i386
    InvalidMemArea, // EFAULT or EIO
    InvalidOption, // EINVAL
    InvalidSignal, // EIO
    NotPermitted, // EPERM
    NoSuchProcess, // ESRCH
    NotStopped, // ESRCH
    NotTraced, // ESRCH
} || os.UnexpectedError;

pub const Pid = os.pid_t;

inline fn ptrace1(request: usize) usize {
    return linux.syscall1(.ptrace, request);
}

inline fn ptrace2(request: usize, pid: Pid) usize {
    return linux.syscall2(.ptrace, request, pid2arg(pid));
}

inline fn ptrace4(request: usize, pid: Pid, addr: usize, data: usize) usize {
    return linux.syscall4(.ptrace, request, pid2arg(pid), addr, data);
}

inline fn pid2arg(pid: Pid) usize {
    return @bitCast(usize, @as(isize, pid));
}

pub fn traceMe() PtraceError!void {
    const rc = linux.syscall1(.ptrace, PTRACE_TRACEME);
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return os.unexpectedErrno(err),
    }
}

/// TODO: this is straight up wrong
pub fn peekText(pid: Pid, addr: usize) PtraceError!usize {
    var res: usize = undefined;
    const rc = linux.syscall4(.ptrace, PTRACE_PEEKTEXT, pid2arg(pid), addr, @ptrToInt(&res));
    switch (os.errno(rc)) {
        .SUCCESS => return res,
        .PERM => return error.NotPermitted,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn getRegs(pid: Pid, user_regs: *UserRegs) PtraceError!void {
    const rc = linux.syscall4(.ptrace, PTRACE_GETREGS, pid2arg(pid), undefined, @ptrToInt(user_regs));
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn setRegs(pid: Pid, user_regs: *const UserRegs) PtraceError!void {
    const rc = linux.syscall4(.ptrace, PTRACE_SETREGS, pid2arg(pid), undefined, @ptrToInt(user_regs));
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn getSigInfo(pid: Pid) PtraceError!linux.siginfo_t {
    var siginfo: linux.siginfo_t = undefined;
    const rc = linux.syscall4(.ptrace, PTRACE_GETSIGINFO, pid2arg(pid), undefined, @ptrToInt(&siginfo));
    switch (os.errno(rc)) {
        .SUCCESS => return siginfo,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub const RestartError = error{
    NoSuchProcess,
    InvalidSignal,
};

pub fn cont(pid: Pid, sig: u32) RestartError!void {
    const rc = ptrace4(PTRACE_CONT, pid, undefined, sig);
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .SRCH => return error.NoSuchProcess,
        .IO => return error.InvalidSignal,
        else => unreachable,
    }
}

pub fn attach(pid: Pid) PtraceError!void {
    const rc = ptrace2(PTRACE_ATTACH, pid);
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn detach(pid: Pid, sig: u32) RestartError!void {
    const rc = ptrace4(PTRACE_DETACH, pid, undefined, sig);
    switch (os.errno(rc)) {
        .SUCCESS => return,
        .SRCH => return error.NoSuchProcess,
        .IO => return error.InvalidSignal,
        else => unreachable,
    }
}

// long ptrace(enum __ptrace_request request, pid_t pid,
//             void *addr, void *data);

//extern fn ptrace(usize, c_int, ?*c_void, ?*c_void) c_long;
test {
    _ = std.testing.refAllDecls(@This());
}

test "traceme doesn't error" {
    try traceMe();
}

//test "attach fails" {
//    try std.testing.expectError(error.Failed, attach(12345));
//}
