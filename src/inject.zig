const std = @import("std");
const builtin = @import("builtin");

const elf = std.elf;

pub const PayloadResult = enum(c_int) {
    success,
    success_unload,
    error_unload,
    error_terminate,
};

const system_is_64 = switch (builtin.cpu.arch.ptrBitWidth()) {
    32 => false,
    64 => true,
    else => @compileError("Unsupported target CPU architecture"),
};
const system_endian = builtin.cpu.arch.endian();
const elf_type_prefix = if (system_is_64) "Elf64_" else "Elf32_";
fn ElfType(comptime name: []const u8) type {
    return @field(std.elf, elf_type_prefix ++ name);
}

pub const ElfStorage = []align(@alignOf(elf.Ehdr)) const u8;

const log = std.log.scoped(.inject);

/// Represents an ELF file in memory that is the same class and endianness
pub const ElfFile = struct {
    storage: ElfStorage,
    elf_header: *const elf.Ehdr,
    program_headers: ?[]const elf.Phdr,
    section_headers: ?[]const elf.Shdr,
    symbols: ?[]const elf.Sym,
    section_strings: ?[:0]const u8,
    strings: ?[:0]const u8,
    rel: ?[]const elf.Rel,
    rela: ?[]const elf.Rela,

    pub fn fromMemory(storage: ElfStorage) !@This() {
        const hdr = @ptrCast(*const elf.Ehdr, storage);
        if (!std.mem.eql(u8, hdr.e_ident[0..4], elf.MAGIC)) return error.InvalidElfMagic;
        if (hdr.e_ident[elf.EI_VERSION] != 1) return error.InvalidElfVersion;
        const elf_endian: std.builtin.Endian = switch (hdr.e_ident[elf.EI_DATA]) {
            elf.ELFDATA2LSB => .Little,
            elf.ELFDATA2MSB => .Big,
            else => return error.InvalidElfEndian,
        };
        if (elf_endian != system_endian) return error.ElfEndianMismatch;
        const elf_is_64 = switch (hdr.e_ident[elf.EI_CLASS]) {
            elf.ELFCLASS32 => false,
            elf.ELFCLASS64 => true,
            else => return error.InvalidElfClass,
        };
        if (elf_is_64 != system_is_64) return error.ElfClassMismatch;
        if (hdr.e_phentsize != 0 and hdr.e_phentsize != @sizeOf(elf.Phdr)) {
            log.err("Expected program headers of size {}, but got headers of size {}", .{ @sizeOf(elf.Phdr), hdr.e_phentsize });
            return error.InvalidElfProgramHeaderSize;
        }
        if (hdr.e_shentsize != 0 and hdr.e_shentsize != @sizeOf(elf.Shdr)) {
            log.err("Expected program headers of size {}, but got headers of size {}", .{ @sizeOf(elf.Phdr), hdr.e_phentsize });
            return error.InvalidElfSectionHeaderSize;
        }

        // we can now safely access class-specific fields
        const phdrs: ?[]const elf.Phdr = if (hdr.e_phoff != 0) @ptrCast([*]const elf.Phdr, @alignCast(@alignOf(elf.Phdr), storage.ptr + hdr.e_phoff))[0..hdr.e_phnum] else null;
        const shdrs: ?[]const elf.Shdr = if (hdr.e_shoff != 0) @ptrCast([*]const elf.Shdr, @alignCast(@alignOf(elf.Shdr), storage.ptr + hdr.e_shoff))[0..hdr.e_shnum] else null;

        var symbols: ?[]const elf.Sym = null;
        var section_strings: ?[:0]const u8 = null;
        var strings: ?[:0]const u8 = null;
        var rel: ?[]const elf.Rel = null;
        var rela: ?[]const elf.Rela = null;

        var strtab_count: usize = 0;
        if (shdrs) |sections| for (sections[1..]) |section| {
            switch (section.sh_type) {
                elf.SHT_SYMTAB => {
                    if (section.sh_entsize != @sizeOf(elf.Sym)) {
                        log.warn("Symbol table entry size mismatch, got {}, expected {}", .{ section.sh_entsize, @sizeOf(elf.Sym) });
                        continue;
                    }
                    const count = section.sh_size / section.sh_entsize;
                    symbols = @ptrCast([*]const elf.Sym, @alignCast(@alignOf(elf.Sym), storage.ptr + section.sh_offset))[0..count];
                },
                elf.SHT_STRTAB => {
                    const strtab = std.meta.assumeSentinel(storage[section.sh_offset .. section.sh_offset + section.sh_size - 1], 0);
                    switch (strtab_count) {
                        0 => section_strings = strtab,
                        1 => strings = strtab,
                        else => log.warn("Additional string table will be ignored {}", .{strtab_count}),
                    }
                    strtab_count += 1;
                },
                elf.SHT_REL => {
                    if (section.sh_entsize != @sizeOf(elf.Rel)) {
                        log.warn("Relocation table entry size mismatch, got {}, expected {}", .{ section.sh_entsize, @sizeOf(elf.Rel) });
                        continue;
                    }
                    const count = section.sh_size / section.sh_entsize;
                    rel = @ptrCast([*]const elf.Rel, @alignCast(@alignOf(elf.Rel), storage.ptr + section.sh_offset))[0..count];
                },
                elf.SHT_RELA => {
                    if (section.sh_entsize != @sizeOf(elf.Rela)) {
                        log.warn("RelocationA table entry size mismatch, got {}, expected {}", .{ section.sh_entsize, @sizeOf(elf.Rela) });
                        continue;
                    }
                    const count = section.sh_size / section.sh_entsize;
                    rela = @ptrCast([*]const elf.Rela, @alignCast(@alignOf(elf.Rela), storage.ptr + section.sh_offset))[0..count];
                },
                else => {},
            }
        };

        return @This(){
            .storage = storage,
            .elf_header = hdr,
            .program_headers = phdrs,
            .section_headers = shdrs,
            .symbols = symbols,
            .section_strings = section_strings,
            .strings = strings,
            .rel = rel,
            .rela = rela,
        };
    }

    pub fn getString(self: @This(), index: usize) ?[:0]const u8 {
        if (self.strings == null or index == 0 or index > self.strings.?.len) return null;
        return std.mem.sliceTo(self.strings.?[index..], 0);
    }

    pub fn getSymbol(self: @This(), name: []const u8, sym_type: u4) ?[]const u8 {
        if (self.section_headers == null or self.symbols == null or self.strings == null) return null;
        for (self.symbols.?) |sym| {
            if (sym.st_info & 0xf != sym_type) continue;
            if (sym.st_name == 0) continue;
            const sym_name = self.getString(sym.st_name) orelse continue;
            if (!std.mem.eql(u8, sym_name, name)) {
                log.debug("Symbol name {s} doesn't match desired name {s}", .{ sym_name, name });
                continue;
            }
            const section = self.section_headers.?[sym.st_shndx];
            const start = section.sh_offset + sym.st_value;
            const end = start + sym.st_size;
            return self.storage[start..end];
        }
        return null;
    }

    pub fn getFn(self: @This(), name: []const u8) ?[]const u8 {
        return self.getSymbol(name, elf.STT_FUNC);
    }

    fn comptimeFnSize(comptime self: @This(), comptime name: []const u8) usize {
        return (self.getFn(name) orelse unreachable).len;
    }
    /// this copies the function contents outside of the object file so that the
    /// whole object doesn't need to be included in the output binary
    pub fn comptimeFn(comptime self: @This(), comptime name: []const u8) *const [self.comptimeFnSize(name):0]u8 {
        const slice = self.getFn(name) orelse unreachable;
        var buf: [slice.len:0]u8 = undefined;
        std.mem.copy(u8, &buf, slice);
        buf[buf.len] = 0;
        return &buf;
    }
};

test {
    std.testing.refAllDecls(@This());
}
