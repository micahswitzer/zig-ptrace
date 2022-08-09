const std = @import("std");
const builtin = @import("builtin");
const utils = @import("../utils.zig");
pub const Args = utils.UniformTuple([6]type, usize);
const SYS = std.os.linux.SYS;

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

fn getRegArgs(regs: UserRegs) Args {
    const arg_names = UserRegs.args;
    var res: Args = undefined;
    var i: usize = 0;
    inline for (arg_names) |arg_name| {
        @field(res, std.fmt.comptimePrint("{}", .{i})) = @field(regs, arg_name);
        i += 1;
    }
    return res;
}

fn setRegArgs(regs: *UserRegs, args: Args) void {
    const arg_names = UserRegs.args;
    var i: usize = 0;
    inline for (arg_names) |arg_name| {
        @field(regs, arg_name) = @field(args, std.fmt.comptimePrint("{}", .{i}));
        i += 1;
    }
}

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

        pub const args = .{ "rdi", "rsi", "rdx", "r10", "r8", "r9" };

        pub inline fn getSyscall(self: @This()) usize {
            return self.rax;
        }
        pub fn getArgs(self: @This()) Args {
            var res: Args = undefined;
            inline for (@typeInfo(@TypeOf(args)).Struct.fields) |field| {
                @field(res, field.name) = @field(self, @field(args, field.name));
            }
            return res;
        }
        pub inline fn getRet(self: @This()) usize {
            return self.rax;
        }
        pub inline fn getPC(self: @This()) usize {
            return self.rip;
        }

        pub inline fn setSyscall(self: *@This(), sys: SYS) void {
            self.rax = @enumToInt(sys);
        }
        pub fn setArgs(self: *@This(), arg_values: Args) void {
            inline for (@typeInfo(@TypeOf(args)).Struct.fields) |field| {
                @field(self, @field(args, field.name)) = @field(arg_values, field.name);
            }
        }
        pub inline fn setRet(self: *@This(), value: usize) void {
            self.rax = value;
        }
        pub inline fn setPC(self: *@This(), value: usize) void {
            self.rip = value;
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

        const args = [_][]const u8{ "ebx", "ecx", "edx", "esi", "edi", "ebp" };

        pub inline fn getSyscall(self: @This()) usize {
            return self.eax;
        }
        pub fn getArgs(self: @This()) Args {
            return getRegArgs(self);
        }
        pub inline fn getRet(self: @This()) usize {
            return self.eax;
        }
        pub inline fn getPC(self: @This()) usize {
            return self.eip;
        }

        pub inline fn setSyscall(self: *@This(), sys: SYS) void {
            self.eax = @enumToInt(sys);
        }
        pub fn setArgs(self: *@This(), arg_values: Args) void {
            setRegArgs(self, arg_values);
        }
        pub inline fn setRet(self: *@This(), value: usize) void {
            self.eax = value;
        }
        pub inline fn setPC(self: *@This(), value: usize) void {
            self.eip = value;
        }
    },
    else => unreachable,
};
