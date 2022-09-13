const builtin = @import("builtin");
const std = @import("std");
const linux = std.os.linux;
const os = std.os;

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
    // allow code that doesn't use any platform-specific features to compile
    else => struct {},
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
    pub const TRACEEXEC = 1 << EVENT.EXEC;
    pub const TRACEVFORKDONE = 1 << EVENT.VFORK_DONE;
    pub const TRACEEXIT = 1 << EVENT.EXIT;
    pub const TRACESECCOMP = 1 << EVENT.SECCOMP;

    // options without a corresponding event
    pub const EXITKILL = 1 << 20;
    pub const SUSPEND_SECCOMP = 1 << 21;

    pub const MASK = 0xff | EXITKILL | SUSPEND_SECCOMP;
};
/// can potentially allow for more efficient storage
pub const Options = std.math.IntFittingRange(0, O.MASK);

pub const NoSuchProcessError = error{NoSuchProcess};

pub const RestartError = error{
    NoSuchProcess,
    InvalidSignal,
};

// all possible errors
pub const PtraceError = error{
    RegisterAlloc, // EBUSY on i386
    InvalidMemArea, // EFAULT or EIO
    InvalidOption, // EINVAL
    InvalidSignal, // EIO
    NotPermitted, // EPERM
    NoSuchProcess, // ESRCH
};

// currently we depend on std.os.linux's definition of these,
// we having these here makes it easy to change that in the future
pub const Pid = linux.pid_t;
pub const SigInfo = linux.siginfo_t;
pub const Signal = u32;

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

pub const TraceMeError = error{NotPermitted};
pub fn traceMe() TraceMeError!void {
    const rc = ptrace1(TRACEME);
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted, // the calling thread is already being traced
        else => unreachable,
    }
}

const MemoryOperationError = error{ InvalidMemArea, NoSuchProcess };
pub fn peekText(pid: Pid, addr: usize) MemoryOperationError!usize {
    var res: usize = undefined;
    const rc = ptrace4(PEEKTEXT, pid, addr, @ptrToInt(&res));
    switch (linux.getErrno(rc)) {
        .SUCCESS => return res,
        .FAULT, .IO => return error.InvalidMemArea,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
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
        switch (linux.getErrno(rc)) {
            .SUCCESS => return user_regs,
            .SRCH => return error.NoSuchProcess,
            else => unreachable,
        }
    }
} else struct {};

pub usingnamespace if (@hasDecl(Arch, "SETREGS")) struct {
    pub fn setRegs(pid: Pid, user_regs: Arch.UserRegs) NoSuchProcessError!void {
        const rc = ptrace4(
            Arch.SETREGS,
            pid,
            comptime if (builtin.cpu.arch.isSPARC()) @ptrToInt(&user_regs) else undefined,
            comptime if (!builtin.cpu.arch.isSPARC()) @ptrToInt(&user_regs) else undefined,
        );
        switch (linux.getErrno(rc)) {
            .SUCCESS => return,
            .SRCH => return error.NoSuchProcess,
            else => unreachable,
        }
    }
} else struct {};

pub fn getSigInfo(pid: Pid) NoSuchProcessError!SigInfo {
    var siginfo: SigInfo = undefined;
    const rc = ptrace4(GETSIGINFO, pid, undefined, @ptrToInt(&siginfo));
    switch (linux.getErrno(rc)) {
        .SUCCESS => return siginfo,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub const SetOptionsError = error{ InvalidOption, NoSuchProcess };
pub fn setOptions(pid: Pid, options: Options) SetOptionsError!void {
    switch (linux.getErrno(ptrace4(SETOPTIONS, pid, undefined, @intCast(usize, options)))) {
        .SUCCESS => return,
        .INVAL => return error.InvalidOption,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub fn cont(pid: Pid, sig: Signal) RestartError!void {
    const rc = ptrace4(CONT, pid, undefined, sig);
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .IO => return error.InvalidSignal,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub fn syscall(pid: Pid, sig: Signal) RestartError!void {
    const rc = ptrace4(SYSCALL, pid, undefined, sig);
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .IO => return error.InvalidSignal,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub const AttachError = error{ NotPermitted, NoSuchProcess };
pub fn attach(pid: Pid) AttachError!void {
    const rc = ptrace2(ATTACH, pid);
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .PERM => return error.NotPermitted,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub const SeizeError = error{ InvalidOption, NotPermitted, NoSuchProcess };
pub fn seize(pid: Pid, options: Options) SeizeError!void {
    const rc = ptrace4(SEIZE, pid, 0, @intCast(usize, options));
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .INVAL => return error.InvalidOption,
        .PERM => return error.NotPermitted,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

pub fn detach(pid: Pid, sig: Signal) RestartError!void {
    const rc = ptrace4(DETACH, pid, undefined, sig);
    switch (linux.getErrno(rc)) {
        .SUCCESS => return,
        .IO => return error.InvalidSignal,
        .SRCH => return error.NoSuchProcess,
        else => unreachable,
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}

test "traceme behaves as expected" {
    try traceMe();
    try std.testing.expectError(error.NotPermitted, traceMe());
}
