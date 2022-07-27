const builtin = @import("builtin");
const std = @import("std");
const os = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) @compileError("zig-ptrace only supports Linux");
}

pub const TRACEME = 0;
pub const PEEKTEXT = 1;
pub const PEEKDATA = 2;
pub const PEEKUSER = 3;
pub const POKETEXT = 4;
pub const POKEDATA = 5;
pub const POKEUSER = 6;
pub const CONT = 7;
pub const KILL = 8;
pub const SINGLESTEP = 9;

pub const ATTACH = 16;
pub const DETACH = 17;

pub const SYSCALL = 24;

const Arch = switch (builtin.cpu.arch) {
    .i386, .x86_64 => @import("ptrace/x86.zig"),
    else => struct {}, // allow code that doesn't use any platform-specific features to compile
};
pub usingnamespace Arch;

pub const SETOPTIONS = 0x4200;
pub const GETEVENTMSG = 0x4201;
pub const GETSIGINFO = 0x4202;
pub const SETSIGINFO = 0x4203;

pub const GETREGSET = 0x4204;
pub const SETREGSET = 0x4205;

pub const SEIZE = 0x4206;
pub const INTERRUPT = 0x4207;
pub const LISTEN = 0x4208;

pub const PEEKSIGINFO = 0x4209;
pub const PeeksiginfoArgs = extern struct {
    off: u64,
    flags: u32,
    nr: i32,
};

pub const GETSIGMASK = 0x420a;
pub const SETSIGMASK = 0x420b;

pub const SECCOMP_GET_FILTER = 0x420c;
pub const SECCOMP_GET_METADATA = 0x420d;
pub const SeccompMetadata = extern struct {
    filter_off: u64,
    flags: u64,
};

pub const GET_SYSCALL_INFO = 0x420e;
pub const SyscallInfo = extern struct {
    op: Op,
    pad: [3]u8,
    arch: u32,
    instruction_pointer: u64,
    stack_pointer: u64,
    extra: extern union {
        entry: extern struct {
            nr: u64,
            args: [6]u64,
        },
        exit: extern struct {
            rval: i64,
            is_error: u8,
        },
        seccomp: extern struct {
            nr: u64,
            args: [6]u64,
            ret_data: u32,
        },
    },

    pub const Op = enum(u8) {
        NONE = 0,
        ENTRY = 1,
        EXIT = 2,
        SECCOMP = 3,
    };
};

pub const EVENTMSG = struct {
    pub const SYSCALL_ENTRY = 1;
    pub const SYSCALL_EXIT = 2;
};

pub const PEEKSIGINFO_SHARED = 1 << 0;

pub const EVENT = struct {
    pub const FORK = 1;
    pub const VFORK = 2;
    pub const CLONE = 3;
    pub const EXEC = 4;
    pub const VFORK_DONE = 5;
    pub const EXIT = 6;
    pub const SECCOMP = 7;

    pub const STOP = 128;
};

pub const O = struct {
    pub const TRACESYSGOOD = 1;
    pub const TRACEFORK = 1 << EVENT.FORK;
    pub const TRACEVFORK = 1 << EVENT.VFORK;
    pub const TRACECLONE = 1 << EVENT.CLONE;
    pub const TRACEVFORKDONE = 1 << EVENT.VFORK_DONE;
    pub const TRACEEXIT = 1 << EVENT.EXIT;
    pub const TRACESECCOMP = 1 << EVENT.SECCOMP;

    // options without a corresponding event
    pub const EXITKILL = 1 << 20;
    pub const SUSPEND_SECCOMP = 1 << 21;

    pub const MASK = 0xff | EXITKILL | SUSPEND_SECCOMP;
};

pub const NoSuchProcessError = error{NoSuchProcess};

pub const RestartError = error{
    NoSuchProcess,
    InvalidSignal,
};

pub const PtraceError = error{
    RegisterAlloc, // EBUSY on i386
    InvalidMemArea, // EFAULT or EIO
    InvalidOption, // EINVAL
    InvalidSignal, // EIO
    NotPermitted, // EPERM
    NoSuchProcess, // ESRCH
    NotStopped, // ESRCH
    NotTraced, // ESRCH
} || std.os.UnexpectedError;

pub const Pid = os.pid_t;

inline fn ptrace1(request: usize) usize {
    return os.syscall1(.ptrace, request);
}

inline fn ptrace2(request: usize, pid: Pid) usize {
    return os.syscall2(.ptrace, request, pid2arg(pid));
}

inline fn ptrace4(request: usize, pid: Pid, addr: usize, data: usize) usize {
    return os.syscall4(.ptrace, request, pid2arg(pid), addr, data);
}

inline fn pid2arg(pid: Pid) usize {
    return @bitCast(usize, @as(isize, pid));
}

pub fn traceMe() PtraceError!void {
    const rc = ptrace1(TRACEME);
    switch (os.getErrno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

/// TODO: this is straight up wrong
pub fn peekText(pid: Pid, addr: usize) PtraceError!usize {
    var res: usize = undefined;
    const rc = ptrace4(PEEKTEXT, pid, addr, @ptrToInt(&res));
    switch (os.getErrno(rc)) {
        .SUCCESS => return res,
        .PERM => return error.NotPermitted,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub usingnamespace if (@hasDecl(Arch, "GETREGS")) struct {
    pub fn getRegs(pid: Pid) NoSuchProcessError!Arch.UserRegs {
        var user_regs: Arch.UserRegs = undefined;
        const regs_ptr = @ptrToInt(&user_regs);
        const rc = ptrace4(
            Arch.GETREGS,
            pid,
            // the order of these arguments is swapped on SPARC
            comptime if (builtin.cpu.arch.isSPARC()) regs_ptr else undefined,
            comptime if (!builtin.cpu.arch.isSPARC()) regs_ptr else undefined,
        );
        switch (os.getErrno(rc)) {
            .SUCCESS => return user_regs,
            .SRCH => return error.NoSuchProcess,
            // we guarentee all of the required invariants are upheld to prevent these errors
            .FAULT => unreachable,
            .IO => unreachable,
            .PERM => unreachable,
            else => unreachable,
        }
    }
} else struct {
    // this error prevents @hasDecl() from being useful...
    //pub const getRegs = @compileError("PTRACE_GETREGS is not available on " ++ @tagName(builtin.cpu.arch));
};

pub fn setRegs(pid: Pid, user_regs: Arch.UserRegs) PtraceError!void {
    const rc = ptrace4(Arch.SETREGS, pid, undefined, @ptrToInt(&user_regs));
    switch (os.getErrno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub fn getSigInfo(pid: Pid) PtraceError!os.siginfo_t {
    var siginfo: os.siginfo_t = undefined;
    const rc = ptrace4(GETSIGINFO, pid, undefined, @ptrToInt(&siginfo));
    switch (os.getErrno(rc)) {
        .SUCCESS => return siginfo,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub fn cont(pid: Pid, sig: u32) RestartError!void {
    const rc = ptrace4(CONT, pid, undefined, sig);
    switch (os.getErrno(rc)) {
        .SUCCESS => return,
        .SRCH => return error.NoSuchProcess,
        .IO => return error.InvalidSignal,
        else => unreachable,
    }
}

pub fn attach(pid: Pid) PtraceError!void {
    const rc = ptrace2(ATTACH, pid);
    switch (os.getErrno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        else => |err| return std.os.unexpectedErrno(err),
    }
}

pub fn detach(pid: Pid, sig: u32) RestartError!void {
    const rc = ptrace4(DETACH, pid, undefined, sig);
    switch (os.getErrno(rc)) {
        .SUCCESS => return,
        .SRCH => return error.NoSuchProcess,
        .IO => return error.InvalidSignal,
        else => unreachable,
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}

test "traceme doesn't error" {
    try traceMe();
}
