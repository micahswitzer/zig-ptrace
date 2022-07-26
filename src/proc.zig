const std = @import("std");
const Pid = std.os.pid_t;

pub const ROOT = "/proc";
pub const PID_MAX_CHARS = std.math.log10(std.math.maxInt(Pid)) + 1;

pub const MAPS = "maps";
pub const EXE = "exe";
pub const TASKS = "tasks";
pub const Entry = enum {
    maps,
    exe,
    tasks,
};
pub const ENTRY_MAX_CHARS = blk: {
    var max = 0;
    inline for (std.meta.tags(Entry)) |tag| {
        max = std.math.max(max, @tagName(tag).len);
    }
    break :blk max;
};

pub const PATH_MAX = ROOT.len + 1 + PID_MAX_CHARS + 1 + ENTRY_MAX_CHARS + 1;
pub const PathBuffer = [PATH_MAX]u8;

/// Get a zero-terminated string with the proc entry for the pid specified
/// Use the type `PathBuffer` to ensure a large enough array
pub fn getProcPathZ(comptime entry: Entry, pid: Pid, buffer: []u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ROOT ++ "/{}/" ++ @tagName(entry), .{pid});
}

pub fn getExePathZ(pid: Pid, buffer: []u8) ![]u8 {
    var path_buffer: PathBuffer = undefined;
    // we always pass a large enough array, so we know that this format will not fail
    const proc_path = getProcPathZ(.exe, pid, &path_buffer) catch unreachable;
    return std.os.readlinkZ(proc_path, buffer);
}

pub const ProcDir = struct {
    fd: std.os.fd_t,

    const DIR_OPEN_FLAGS = std.os.O.CLOEXEC | std.os.O.DIRECTORY | std.os.O.PATH;

    pub fn openSelf() !@This() {
        return @This(){
            .fd = try std.os.openZ(ROOT ++ "/self", DIR_OPEN_FLAGS, 0),
        };
    }

    pub fn open(pid: Pid) !@This() {
        var path_buf: [ROOT.len + 1 + PID_MAX_CHARS + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, ROOT ++ "/{}", .{pid}) catch unreachable;
        return @This(){
            .fd = try std.os.openZ(path, DIR_OPEN_FLAGS, 0),
        };
    }

    pub fn close(this: @This()) void {
        std.os.close(this.fd);
    }

    pub fn getExePath(this: @This(), buf: []u8) ![]u8 {
        return std.os.readlinkatZ(this.fd, EXE, buf);
    }

    pub fn getMapsFile(this: @This()) !std.fs.File {
        return std.fs.File{
            .handle = try std.os.openatZ(this.fd, MAPS, std.os.O.CLOEXEC | std.os.O.RDONLY, 0),
        };
    }
};
