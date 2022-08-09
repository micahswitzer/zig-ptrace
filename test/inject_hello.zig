const std = @import("std");
const ptrace = @import("ptrace");

const elf = std.elf;
const linux = std.os.linux;
const inject = ptrace.inject;
const ll = ptrace.lowlevel;
const proc = ptrace.proc;

const log = std.log;

const LOAD_ADDR = 0xaa000000;

const RegionInfo = struct {
    file_bytes: []const u8,
    mem_size: usize,
    load_addr: usize,
};

pub const log_level: std.log.Level = .debug;

pub fn main() !void {
    if (std.os.argv.len != 3) {
        log.err("Expect 3 args, got {}", .{std.os.argv.len});
        return;
    }
    const payload_path = std.os.argv[1];
    const pid_str = std.mem.sliceTo(std.os.argv[2], 0);
    const pid = try std.fmt.parseUnsigned(ptrace.system.Pid, pid_str, 10);

    log.info("Opening payload file at {s}", .{payload_path});
    const payload_file = try std.fs.openFileAbsoluteZ(payload_path, .{});
    defer payload_file.close();
    const payload_stat = try payload_file.stat();
    const payload_size = payload_stat.size;
    const payload_mapped = try std.os.mmap(null, payload_size, std.os.PROT.READ, std.os.MAP.PRIVATE, payload_file.handle, 0);
    defer std.os.munmap(payload_mapped);
    const payload_elf = try inject.ElfFile.fromMemory(payload_mapped);

    log.info("Finding executable segments", .{});
    const payload_exe = blk: {
        // first look through the program headers
        if (payload_elf.program_headers) |phdrs|
            for (phdrs) |phdr| {
                if (phdr.p_flags & elf.PF_X == 0 or phdr.p_type & elf.PT_LOAD == 0)
                    continue;
                break :blk RegionInfo{
                    .file_bytes = payload_mapped[phdr.p_offset .. phdr.p_offset + phdr.p_filesz],
                    .mem_size = phdr.p_memsz,
                    .load_addr = phdr.p_vaddr,
                };
            } else log.warn("The payload doesn't have an executable LOAD segment. Searching sections instead", .{});
        const sh_flags = elf.SHF_ALLOC | elf.SHF_EXECINSTR;
        if (payload_elf.section_headers) |shdrs|
            for (shdrs) |shdr| {
                if (shdr.sh_flags & sh_flags != sh_flags or shdr.sh_type != elf.SHT_PROGBITS)
                    continue;
                break :blk RegionInfo{
                    .file_bytes = payload_mapped[shdr.sh_offset .. shdr.sh_offset + shdr.sh_size],
                    .mem_size = shdr.sh_size,
                    .load_addr = shdr.sh_addr,
                };
            };
        log.err("The payload doesn't have an executable ALLOC section", .{});
        return error.BadPayload;
    };

    if (payload_elf.rel) |rel| for (rel) |r| {
        const symbol = payload_elf.symbols.?[r.r_sym()];
        const sym_name = payload_elf.getString(symbol.st_name) orelse "<N/A>";
        const section = payload_elf.section_headers.?[symbol.st_shndx];
        const sh_name = payload_elf.getString(section.sh_name) orelse "<N/A>";
        log.debug("REL for symbol {s} in {s} at offset {}", .{ sym_name, sh_name, r.r_offset });
    };

    if (payload_elf.rela) |rela| for (rela) |r| {
        const symbol = payload_elf.symbols.?[r.r_sym()];
        const sym_name = payload_elf.getString(symbol.st_name) orelse "<N/A>";
        const section = payload_elf.section_headers.?[symbol.st_shndx];
        const sh_name = payload_elf.getString(section.sh_name) orelse "<N/A>";
        log.debug("RELA for symbol {s} in {s} at offset {}, addend {}", .{ sym_name, sh_name, r.r_offset, r.r_addend });
    };

    log.info("Payload successfully loaded", .{});
    const proc_dir = try proc.ProcDir.open(pid);
    defer proc_dir.close();

    // we might make this custom in the future
    const load_request = if (payload_exe.load_addr == 0) blk: {
        log.info("Scanning target address space for a suitable load address", .{});
        const maps_file = try proc_dir.getMapsFile();
        defer maps_file.close();

        var min_addr: usize = std.math.maxInt(usize);
        var maps_iter = proc.maps.iterator(maps_file.reader());
        while (try maps_iter.next()) |entry| {
            if (entry.path == null) continue;
            min_addr = @minimum(min_addr, entry.start);
        }
        break :blk std.mem.alignBackward(min_addr - payload_exe.mem_size, std.mem.page_size);
    } else payload_exe.load_addr;

    log.info("Attaching to the target process", .{});
    // everything is good thus far, so inject into the target process
    var thread = try ll.attachThread(pid);
    while (try thread.nextSignal()) |sig| {
        try thread.cont(switch (sig) {
            linux.SIG.STOP => break,
            linux.SIG.TRAP => 0,
            else => sig,
        });
    } else {
        switch (thread.state) {
            .Terminated => |sig| log.err("The target process terminated with signal {} ({s}) while we were attaching to it", .{ sig, ll.signalToString(sig) }),
            .Exited => |code| log.err("The target process exited with code {} before we could finish waiting for it to stop", .{code}),
            else => unreachable,
        }
        return error.TargetExited;
    }

    log.info("Asking kernel for {} bytes at {x}", .{ payload_exe.mem_size, load_request });
    const load_addr = blk: {
        const res = try thread.doSyscall(
            .mmap,
            .{ load_request, payload_exe.mem_size, linux.PROT.EXEC | linux.PROT.READ, linux.MAP.PRIVATE | linux.MAP.ANONYMOUS, @bitCast(usize, @as(isize, -1)), 0 },
        );
        const err = linux.getErrno(res);
        if (err != .SUCCESS)
            return std.os.unexpectedErrno(err);
        break :blk res;
    };
    log.info("Kernel gave us {x}. Copying code into region", .{load_addr});
    {
        const proc_mem = try proc_dir.getMemFile();
        defer proc_mem.close();
        try proc_mem.pwriteAll(payload_exe.file_bytes, load_addr);
    }

    log.info("Done!", .{});
}
