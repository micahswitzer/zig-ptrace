const std = @import("std");
const utils = @import("utils.zig");
pub const maps = @import("maps.zig");

const File = std.fs.File;
const Dir = std.fs.Dir;
const IterableDir = std.fs.IterableDir;

const Pid = std.os.pid_t;

pub const PROC = "/proc";
pub const PROC_SELF = PROC ++ "/self";
pub const PID_MAX_CHARS = utils.maxCharsForInt(Pid);

/// The proc filesystem is funny and will append this to link targets that have been deleted.
/// The unfortunate part is that you can't tell if the file was actually deleted, or if its
/// name just happens to end the same way...
pub const LINK_TARGET_DELETED = " (deleted)";

pub const EXE = "exe";
pub const MAPS = "maps";
pub const MEM = "mem";
pub const PERSONALITY = "personality";
pub const STATUS = "status";
pub const TASKS = "tasks";
pub const Entry = enum {
    exe,
    maps,
    mem,
    personality,
    status,
    tasks,
};
pub const ENTRY_MAX_CHARS = blk: {
    var max = 0;
    inline for (std.meta.tags(Entry)) |tag| {
        max = std.math.max(max, @tagName(tag).len);
    }
    break :blk max;
};

pub const PATH_MAX = PROC.len + 1 + PID_MAX_CHARS + 1 + ENTRY_MAX_CHARS + 1;
pub const PathBuffer = [PATH_MAX]u8;

pub const PER = struct {
    pub const LINUX = 0;
    pub const LINUX32 = 8;
};

/// Get a zero-terminated string with the proc entry for the pid specified
/// Use the type `PathBuffer` to ensure a large enough buffer array
pub fn getProcPathZ(comptime entry: Entry, pid: Pid, buffer: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, PROC ++ "/{}/" ++ @tagName(entry), .{pid});
}

pub fn openProcFile(comptime entry: Entry, pid: Pid) !std.fs.File {
    var path_buf: PathBuffer = undefined;
    const path = getProcPathZ(entry, pid, &path_buf) catch unreachable;
    return std.fs.openFileAbsoluteZ(path, .{});
}

pub fn openProcFileWriteable(comptime entry: Entry, pid: Pid) !std.fs.File {
    var path_buf: PathBuffer = undefined;
    const path = getProcPathZ(entry, pid, &path_buf) catch unreachable;
    return std.fs.openFileAbsoluteZ(path, .{ .mode = .write_only });
}

pub fn getExePath(pid: Pid, buffer: []u8) ![]u8 {
    var path_buffer: PathBuffer = undefined;
    // we always pass a large enough buffer, so we know that this format will not fail
    const proc_path = getProcPathZ(.exe, pid, &path_buffer) catch unreachable;
    return std.os.readlinkZ(proc_path, buffer);
}

pub const TaskDir = struct {
    dir: IterableDir,

    pub const Iterator = struct {
        iter: IterableDir.Iterator,

        pub fn next(self: *@This()) !?Pid {
            if (try self.iter.next()) |entry| {
                std.debug.assert(entry.kind == .Directory);
                return std.fmt.parseInt(Pid, entry.name, 10) catch unreachable;
            }
            return null;
        }
    };

    pub fn close(self: *@This()) void {
        self.dir.close();
    }

    pub fn iterate(self: @This()) Iterator {
        return Iterator{ .iter = self.dir.iterate() };
    }
};

pub const ThreadStatus = struct {
    Tgid: Pid,
    Ngid: Pid,
    Pid: Pid,
    PPid: Pid,
    TracerPid: Pid,

    const NUM_FIELDS = @typeInfo(@This()).Struct.fields.len;
    const MAX_NAME_LEN = utils.maxFieldNameLen(@This());
    const BUFFER_SIZE = MAX_NAME_LEN + 2 + PID_MAX_CHARS + 2;

    fn fromReader(reader: anytype) !@This() {
        var buffer: [BUFFER_SIZE]u8 = undefined;
        var good_line = true;
        var fields_remaining = @intCast(std.math.IntFittingRange(0, NUM_FIELDS), NUM_FIELDS);
        var status: @This() = undefined;
        while (fields_remaining > 0) {
            const line = reader.readUntilDelimiter(&buffer, '\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    good_line = false;
                    continue;
                },
                else => return err,
            };

            if (!good_line) {
                good_line = true;
                continue;
            }

            var parts = std.mem.split(u8, line, ":\t");
            const name = parts.next() orelse continue;
            const pid_str = parts.rest();
            if (pid_str.len == 0) continue;

            inline for (@typeInfo(@This()).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    @field(status, field.name) = try std.fmt.parseInt(Pid, pid_str, 10);
                    fields_remaining -= 1;
                    break;
                }
            }
        }
        return status;
    }

    pub fn fromFile(file: File) !@This() {
        const reader = file.reader();
        return fromReader(reader);
    }
};

test "parse ThreadStatus from buffer" {
    const sample_data =
        \\Name:	init
        \\Umask:	0022
        \\State:	S (sleeping)
        \\Tgid:	1
        \\Ngid:	0
        \\Pid:	7
        \\PPid:	0
        \\TracerPid:	0
        \\Uid:	0	0	0	0
        \\Gid:	0	0	0	0
        \\FDSize:	128
        \\Groups:
        \\NStgid:	1
    ;
    var stream = std.io.fixedBufferStream(sample_data);
    const status = try ThreadStatus.fromReader(stream.reader());
    try std.testing.expectEqual(ThreadStatus{
        .Tgid = 1,
        .Ngid = 0,
        .Pid = 7,
        .PPid = 0,
        .TracerPid = 0,
    }, status);
}

test "parse ThreadStatus from host" {
    const file = try std.fs.openFileAbsoluteZ(PROC_SELF ++ "/" ++ STATUS, .{});
    const status = try ThreadStatus.fromFile(file);
    _ = status;
}

pub const ProcDir = struct {
    fd: std.os.fd_t,

    const OPEN_DIR_FLAGS = std.os.O.RDONLY | std.os.O.CLOEXEC | std.os.O.DIRECTORY | std.os.O.PATH;
    const OPEN_FILE_FLAGS = std.os.O.RDONLY | std.os.O.CLOEXEC;

    fn getFile(self: @This(), path: [*:0]const u8) !File {
        return File{
            .handle = try std.os.openatZ(self.fd, path, OPEN_FILE_FLAGS, 0),
        };
    }

    fn getFileWritable(self: @This(), path: [*:0]const u8) !File {
        return File{
            .handle = try std.os.openatZ(self.fd, path, std.os.O.RDWR | std.os.O.CLOEXEC, 0),
        };
    }

    pub fn openSelf() !@This() {
        return @This(){
            .fd = try std.os.openZ(PROC_SELF, OPEN_DIR_FLAGS, 0),
        };
    }

    pub fn open(pid: Pid) !@This() {
        var path_buf: [PROC.len + 1 + PID_MAX_CHARS + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, PROC ++ "/{}", .{pid}) catch unreachable;
        return @This(){
            .fd = try std.os.openZ(path, OPEN_DIR_FLAGS, 0),
        };
    }

    pub fn close(self: @This()) void {
        std.os.close(self.fd);
    }

    pub fn getExePath(self: @This(), buf: []u8) ![]u8 {
        return std.os.readlinkatZ(self.fd, EXE, buf);
    }

    pub fn getMapsFile(self: @This()) !File {
        return self.getFile(MAPS);
    }

    pub fn getTasksDir(self: @This()) !TaskDir {
        const dir = IterableDir{
            .dir = .{ .fd = try std.os.openatZ(self.fd, TASKS, OPEN_DIR_FLAGS, 0) },
        };
        return TaskDir{ .dir = dir };
    }

    pub fn getStatus(self: @This()) !ThreadStatus {
        const file = try self.getFile(STATUS);
        defer file.close();
        return try ThreadStatus.fromFile(file);
    }

    pub fn getPersonality(self: @This()) !u32 {
        const file = try self.getFile(PERSONALITY);
        defer file.close();
        var persona_hex: [8]u8 = undefined;
        try file.reader().readNoEof(&persona_hex);
        return std.fmt.parseUnsigned(u32, persona_hex, 16);
    }

    pub fn getMemFile(self: @This()) !File {
        return self.getFileWritable(MEM);
    }
};

fn pathsEqual(original: []const u8, target: []const u8, possibly_deleted: bool) bool {
    if (std.mem.eql(u8, original, target))
        return true;
    if (!possibly_deleted)
        return false;
    if (target.len + LINK_TARGET_DELETED.len != original.len)
        return false;
    const non_deleted_path = original[0 .. original.len - LINK_TARGET_DELETED.len];
    return std.mem.eql(u8, non_deleted_path, target);
}

test "pathsEqual" {
    try std.testing.expect(pathsEqual("/my/test/path", "/my/test/path", false));
    try std.testing.expect(!pathsEqual("/my/test/path", "/my/test/other/path", false));
    try std.testing.expect(pathsEqual("/my/test/path (deleted)", "/my/test/path", true));
    try std.testing.expect(!pathsEqual("/my/test/path (deleted)", "/my/test/other/path", true));
    try std.testing.expect(pathsEqual("/my/test/path (deleted)", "/my/test/path (deleted)", true));
}

pub usingnamespace if (@import("root") == @This()) struct {
    // this file is being built as the root module, so export the main function
    // this is done to avoid making `main` a part of the public API when this module
    // is being used as a library
    const log = std.log.scoped(.proc);
    pub const log_level: std.log.Level = .info;
    var exe_path_buf: [std.os.PATH_MAX]u8 = undefined;

    pub fn main() !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        _ = alloc;

        var proc_dir = try std.fs.openIterableDirAbsoluteZ(PROC, .{});
        defer proc_dir.close();
        var proc_iterator = proc_dir.iterate();

        while (try proc_iterator.next()) |proc_entry| {
            if (proc_entry.kind != .Directory)
                continue;
            std.debug.assert(proc_entry.name.len != 0);
            if (!std.ascii.isDigit(proc_entry.name[0]))
                continue;
            const pid = std.fmt.parseUnsigned(Pid, proc_entry.name, 10) catch |err| switch (err) {
                error.Overflow => {
                    if (std.debug.runtime_safety) {
                        log.warn("Tried to parse a PID that didn't fit the Pid type: {s}", .{proc_entry.name});
                        continue;
                    }
                    unreachable;
                },
                // the directory started with a number, but is not a pid dir
                error.InvalidCharacter => continue,
            };

            const maps_file = openProcFile(.maps, pid) catch |err|
                if (err == error.AccessDenied)
            {
                log.info("Don't have permission to look at maps for {}", .{pid});
                continue;
            } else return err;
            defer maps_file.close();
            const exe_path = try getExePath(pid, &exe_path_buf);
            // see note on `LINK_TARGET_DELETED` for why we can't know for sure (at this point)
            const possibly_deleted = std.mem.endsWith(u8, exe_path, LINK_TARGET_DELETED);
            log.debug("Parsing maps for PID {}, path = {s}, possibly_deleted = {}", .{ pid, exe_path, possibly_deleted });
            var buffered_reader = std.io.bufferedReader(maps_file.reader());
            const reader = buffered_reader.reader();
            // const reader = maps_file.reader();
            var maps_iterator = maps.iterator(reader);
            const exe_entry = blk: while (try maps_iterator.next()) |maps_entry| {
                if (!maps_entry.permissions.execute or maps_entry.path == null)
                    continue;
                if (!pathsEqual(exe_path, maps_entry.path.?, possibly_deleted)) {
                    log.debug("Path is not the executable: {s}", .{maps_entry.path.?});
                    continue;
                }
                var new_entry = maps_entry;
                // this won't be valid once the iterator goes out of scope, so just clear
                // it now since we don't need it anyways.
                new_entry.path = null;
                break :blk new_entry;
            } else unreachable;

            log.info("PID {} has its code loaded at {x}-{x}", .{ pid, exe_entry.start, exe_entry.end });
            if (possibly_deleted)
                log.warn("The executable path ends with '" ++ LINK_TARGET_DELETED ++ "', these results may be incorrect", .{});
        }
    }
} else struct {};
