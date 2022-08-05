const std = @import("std");
const utils = @import("utils.zig");

const File = std.fs.File;
const Dir = std.fs.Dir;
const IterableDir = std.fs.IterableDir;

const Pid = std.os.pid_t;

pub const PROC = "/proc";
pub const PROC_SELF = PROC ++ "/self";
pub const PID_MAX_CHARS = utils.maxCharsForInt(Pid);

pub const EXE = "exe";
pub const MAPS = "maps";
pub const STATUS = "status";
pub const TASKS = "tasks";
pub const Entry = enum {
    exe,
    maps,
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

/// Get a zero-terminated string with the proc entry for the pid specified
/// Use the type `PathBuffer` to ensure a large enough array
pub fn getProcPathZ(comptime entry: Entry, pid: Pid, buffer: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, PROC ++ "/{}/" ++ @tagName(entry), .{pid});
}

pub fn getExePathZ(pid: Pid, buffer: []u8) ![]u8 {
    var path_buffer: PathBuffer = undefined;
    // we always pass a large enough array, so we know that this format will not fail
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
};
