const std = @import("std");
const builtin = @import("builtin");

const elf = std.elf;

const system_is_64 = switch (@sizeOf(usize)) {
    4 => false,
    8 => true,
    else => @compileError("Unsupported target CPU architecture"),
};
const system_endian = builtin.cpu.arch.endian();

const Storage = []align(@alignOf(elf.Ehdr)) const u8;

const log = std.log.scoped(.ElfFile);

/// Represents an ELF file in memory that is the same class and endianness
storage: Storage,
elf_header: *const elf.Ehdr,
program_headers: ?[]const elf.Phdr,
section_headers: ?[]const elf.Shdr,
symbols: ?[]const elf.Sym,
section_strings: ?[:0]const u8,
strings: ?[:0]const u8,
rel: ?[]const elf.Rel,
rela: ?[]const elf.Rela,

const ElfFile = @This();

pub fn fromMemory(storage: Storage) !ElfFile {
    const hdr: *const elf.Ehdr = @ptrCast(storage);
    if (!std.mem.eql(u8, hdr.e_ident[0..4], elf.MAGIC))
        return error.InvalidElfMagic;
    if (hdr.e_ident[elf.EI_VERSION] != 1)
        return error.InvalidElfVersion;
    const elf_endian: std.builtin.Endian = switch (hdr.e_ident[elf.EI_DATA]) {
        elf.ELFDATA2LSB => .little,
        elf.ELFDATA2MSB => .big,
        else => return error.InvalidElfEndian,
    };
    if (elf_endian != system_endian)
        return error.ElfEndianMismatch;
    const elf_is_64 = switch (hdr.e_ident[elf.EI_CLASS]) {
        elf.ELFCLASS32 => false,
        elf.ELFCLASS64 => true,
        else => return error.InvalidElfClass,
    };
    if (elf_is_64 != system_is_64)
        return error.ElfClassMismatch;
    if (hdr.e_phentsize != 0 and hdr.e_phentsize != @sizeOf(elf.Phdr)) {
        log.err(
            "Expected program headers of size {}, but got headers of size {}",
            .{ @sizeOf(elf.Phdr), hdr.e_phentsize },
        );
        return error.InvalidElfProgramHeaderSize;
    }
    if (hdr.e_shentsize != 0 and hdr.e_shentsize != @sizeOf(elf.Shdr)) {
        log.err(
            "Expected program headers of size {}, but got headers of size {}",
            .{ @sizeOf(elf.Phdr), hdr.e_phentsize },
        );
        return error.InvalidElfSectionHeaderSize;
    }

    // we can now safely access class-specific fields
    const phdrs: ?[]const elf.Phdr = if (hdr.e_phoff != 0)
        @as([*]const elf.Phdr, @ptrCast(@alignCast(storage.ptr + hdr.e_phoff)))[0..hdr.e_phnum]
    else
        null;
    const shdrs: ?[]const elf.Shdr = if (hdr.e_shoff != 0)
        @as([*]const elf.Shdr, @ptrCast(@alignCast(storage.ptr + hdr.e_shoff)))[0..hdr.e_shnum]
    else
        null;

    var symbols: ?[]const elf.Sym = null;
    var section_strings: ?[:0]const u8 = null;
    var strings: ?[:0]const u8 = null;
    var rel: ?[]const elf.Rel = null;
    var rela: ?[]const elf.Rela = null;

    var strtab_count: usize = 0;
    if (shdrs) |sections| for (sections[1..], 1..) |section, section_idx| {
        switch (section.sh_type) {
            elf.SHT_SYMTAB => {
                if (section.sh_entsize != @sizeOf(elf.Sym)) {
                    log.warn(
                        "Symbol table entry size mismatch, got {}, expected {}",
                        .{ section.sh_entsize, @sizeOf(elf.Sym) },
                    );
                    continue;
                }
                const count = section.sh_size / section.sh_entsize;
                symbols = @as([*]const elf.Sym, @ptrCast(@alignCast(storage.ptr + section.sh_offset)))[0..count];
            },
            elf.SHT_STRTAB => {
                const strtab: [:0]const u8 = storage[section.sh_offset .. section.sh_offset + section.sh_size - 1 :0];
                if (section_idx == hdr.e_shstrndx) {
                    section_strings = strtab;
                } else {
                    if (strtab_count < 1) {
                        strings = strtab;
                    } else {
                        log.warn("Additional string table will be ignored {}", .{strtab_count});
                    }
                    strtab_count += 1;
                }
            },
            elf.SHT_REL => {
                if (section.sh_entsize != @sizeOf(elf.Rel)) {
                    log.warn(
                        "Relocation table entry size mismatch, got {}, expected {}",
                        .{ section.sh_entsize, @sizeOf(elf.Rel) },
                    );
                    continue;
                }
                const count = section.sh_size / section.sh_entsize;
                rel = @as([*]const elf.Rel, @ptrCast(@alignCast(storage.ptr + section.sh_offset)))[0..count];
            },
            elf.SHT_RELA => {
                if (section.sh_entsize != @sizeOf(elf.Rela)) {
                    log.warn(
                        "RelocationA table entry size mismatch, got {}, expected {}",
                        .{ section.sh_entsize, @sizeOf(elf.Rela) },
                    );
                    continue;
                }
                const count = section.sh_size / section.sh_entsize;
                rela = @as([*]const elf.Rela, @ptrCast(@alignCast(storage.ptr + section.sh_offset)))[0..count];
            },
            else => {},
        }
    };

    return .{
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

pub fn getString(self: ElfFile, index: usize) ?[:0]const u8 {
    if (self.strings == null or index == 0 or index > self.strings.?.len)
        return null;
    return std.mem.sliceTo(self.strings.?[index..], 0);
}

pub fn getFnOffset(self: ElfFile, name: []const u8) ?usize {
    if (self.section_headers == null or self.symbols == null or self.strings == null)
        return null;
    for (self.symbols.?) |sym| {
        if (sym.st_info & 0xf != elf.STT_FUNC) continue;
        if (sym.st_name == 0) continue;
        const sym_name = self.getString(sym.st_name) orelse continue;
        if (!std.mem.eql(u8, sym_name, name))
            continue;
        return sym.st_value;
    }
    return null;
}

pub fn getSymbol(self: ElfFile, name: []const u8, sym_type: u4) ?[]const u8 {
    if (self.section_headers == null or self.symbols == null or self.strings == null)
        return null;
    for (self.symbols.?) |sym| {
        if (sym.st_info & 0xf != sym_type or sym.st_name == 0)
            continue;
        const sym_name = self.getString(sym.st_name) orelse continue;
        if (!std.mem.eql(u8, sym_name, name))
            continue;
        const section = self.section_headers.?[sym.st_shndx];
        const start = section.sh_offset + sym.st_value;
        const end = start + sym.st_size;
        return self.storage[start..end];
    }
    return null;
}

pub fn getFn(self: ElfFile, name: []const u8) ?[]const u8 {
    return self.getSymbol(name, elf.STT_FUNC);
}

fn comptimeFnSize(comptime self: ElfFile, comptime name: []const u8) usize {
    return (self.getFn(name) orelse unreachable).len;
}
/// this copies the function contents outside of the object file so that the
/// whole object doesn't need to be included in the output binary
pub inline fn comptimeFn(comptime self: ElfFile, comptime name: []const u8) *const [self.comptimeFnSize(name)]u8 {
    comptime {
        const slice = self.getFn(name) orelse unreachable;
        return (&slice[0..slice.len]).*;
    }
}

test {
    std.testing.refAllDecls(ElfFile);
}
