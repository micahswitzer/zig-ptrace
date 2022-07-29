const std = @import("std");

const PrintFn = fn (comptime []const u8, anytype) void;
/// Helper function to get a print function prefixed with the specified compile-time string
pub fn makePrefixedPrint(comptime prefix: []const u8) PrintFn {
    const Closure = struct {
        pub fn f(comptime fmt: []const u8, args: anytype) void {
            std.debug.print("[" ++ prefix ++ "] " ++ fmt ++ "\n", args);
        }
    };
    return Closure.f;
}

/// Helper function used for formatting the path of a file in the same directory as the prodided source path
pub fn replaceBasename(buffer: []u8, original: []const u8, replacement: []const u8) ![:0]u8 {
    const idx = std.mem.lastIndexOfScalar(u8, original, '/').?;
    const new_len = idx + replacement.len;
    if (new_len >= buffer.len)
        return error.BufferTooSmall;
    std.mem.copy(u8, buffer[idx + 1 ..], replacement);
    buffer[new_len] = 0;
    return std.meta.assumeSentinel(buffer[0..new_len], 0);
}

pub fn arrayInit(comptime T: type, val: @typeInfo(T).Array.child) T {
    var arr: T = undefined;
    inline for (arr) |*el| {
        el.* = val;
    }
    return arr;
}

/// For an array type `T`, create an equivalent tuple
/// with each element initialized with value `val`.
pub fn UniformTuple(comptime T: type, comptime val: @typeInfo(T).Array.child) type {
    return std.meta.Tuple(&arrayInit(T, val));
}
