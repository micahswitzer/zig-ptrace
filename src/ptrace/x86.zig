const builtin = @import("builtin");
const utils = @import("../utils.zig");
const Args = utils.UniformTuple([6]type, usize);

// x86-specific constants
pub const GETREGS = 12;
pub const SETREGS = 13;
pub const GETFPREGS = 14;
pub const SETFPREGS = 15;
pub const GETFPXREGS = 18;
pub const SETFPXREGS = 19;
pub const OLDSETOPTIONS = 21;
pub const GET_THREAD_AREA = 25;
pub const SET_THREAD_AREA = 26;

pub const ARCH_PRCTL = if (builtin.cpu.arch == .x86_64) 30 else @compileError("PTRACE_ARCH_PRCTL is only available on x86_64");

pub const SYSEMU = 31;
pub const SYSEMU_SINGLESTEP = 32;
pub const SINGLEBLOCK = 33;

// x86-specific structures
pub const UserRegs = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        r15: u64,
        r14: u64,
        r13: u64,
        r12: u64,
        rbp: u64,
        rbx: u64,
        r11: u64,
        r10: u64,
        r9: u64,
        r8: u64,
        rax: u64,
        rcx: u64,
        rdx: u64,
        rsi: u64,
        rdi: u64,
        orig_rax: u64,
        rip: u64,
        cs: u64,
        eflags: u64,
        rsp: u64,
        ss: u64,
        fs_base: u64,
        gs_base: u64,
        ds: u64,
        es: u64,
        fs: u64,
        gs: u64,

        pub inline fn syscall(self: @This()) usize {
            return self.rax;
        }
        pub inline fn args(self: @This()) Args {
            return .{ self.rdi, self.rsi, self.rdx, self.r10, self.r8, self.r9 };
        }
        pub inline fn ret(self: @This()) usize {
            return self.rax;
        }
    },
    .i386 => extern struct {
        ebx: u32,
        ecx: u32,
        edx: u32,
        esi: u32,
        edi: u32,
        ebp: u32,
        eax: u32,
        xds: u32,
        xes: u32,
        xfs: u32,
        xgs: u32,
        orig_eax: u32,
        eip: u32,
        xcs: u32,
        eflags: u32,
        esp: u32,
        xss: u32,

        pub inline fn syscall(self: @This()) usize {
            return self.eax;
        }
        pub inline fn args(self: @This()) Args {
            return .{ self.ebx, self.ecx, self.edx, self.esi, self.edi, self.ebp };
        }
        pub inline fn ret(self: @This()) usize {
            return self.eax;
        }
    },
    else => unreachable,
};
