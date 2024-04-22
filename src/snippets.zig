const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

const elf = std.elf;
const linux = std.os.linux;
const ElfFile = @import("ElfFile");

const is_root = @This() == root;

const functions = struct {
    // export functions we want to make available
    export fn _syscall() callconv(.Naked) noreturn {
        _ = @call(.always_inline, linux.syscall0, .{undefined});
        unreachable;
    }
    export fn _exit() callconv(.Naked) noreturn {
        _ = @call(.always_inline, linux.syscall1, .{ .exit, @as(usize, @bitCast(@as(isize, 0))) });
        unreachable;
    }
    export fn _trap() callconv(.Naked) noreturn {
        asm volatile ("int3");
        unreachable;
    }
};

const library = struct {
    // get the object file's raw bytes
    const object = @embedFile("generated/snippets.o");
    const elf_file = ElfFile.fromMemory(@alignCast(object)) catch unreachable;

    // make the contents of each function available
    pub const syscall = elf_file.comptimeFn("_syscall");
    pub const exit = elf_file.comptimeFn("_exit");
    pub const trap = elf_file.comptimeFn("_trap");
};

// magically make this file do different things depending on how it's used
pub usingnamespace if (is_root) functions else library;

test "has valid elf" {
    //std.testing.refAllDecls(library);
    try std.testing.expect(library.elf_file.strings != null);
    try std.testing.expect(library.elf_file.getFn("_syscall") != null);
    try std.testing.expect(library.elf_file.getFn("_exit") != null);
}
