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

/// Helper function used for formatting the path of a file in the same directory as the provided source path
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

fn isInt(value: anytype) bool {
    const T = @TypeOf(value);
    const ti = @typeInfo(T);
    return ti == .Int or ti == .ComptimeInt;
}

pub fn intDeclToString(comptime Namespace: type, value: anytype) ?[]const u8 {
    inline for (@typeInfo(Namespace).Struct.decls) |decl| {
        if (comptime isInt(@field(Namespace, decl.name)))
            if (@intCast(@TypeOf(value), @field(Namespace, decl.name)) == value)
                return decl.name;
    }
    return null;
}

const test_namespace = struct {
    const ONE = 0;
    const TWO = 1;
    const THREE = 4;
    const SEVEN = 11;
    const ELEVEN = "test";
    const BOOLEAN = false;

    const another_namespace = struct {};
};

test "intDeclToString" {
    try std.testing.expectEqualStrings(
        "SEVEN",
        intDeclToString(test_namespace, test_namespace.SEVEN).?,
    );
    try std.testing.expectEqualStrings(
        "TWO",
        intDeclToString(test_namespace, @intCast(u32, test_namespace.TWO)).?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        intDeclToString(test_namespace, 256),
    );
}

pub const DeclPred = fn (comptime type, comptime []const u8) bool;
pub fn maxDeclNameLen(comptime Namespace: type, comptime pred: DeclPred) usize {
    var max_len: usize = 0;
    inline for (@typeInfo(Namespace).Struct.decls) |decl| {
        if (pred(Namespace, decl.name))
            max_len = @maximum(max_len, decl.name.len);
    }
    return max_len;
}

pub fn maxFieldNameLen(comptime T: type) usize {
    var max_len: usize = 0;
    inline for (@typeInfo(T).Struct.fields) |field| {
        max_len = @maximum(max_len, field.name.len);
    }
    return max_len;
}

pub fn maxDeclValue(comptime Namespace: type) usize {
    var max_val: usize = 0;
    inline for (@typeInfo(Namespace).Struct.decls) |decl| {
        if (comptime isInt(@field(Namespace, decl.name)))
            max_val = @maximum(max_val, @field(Namespace, decl.name));
    }
    return max_val;
}

test "maxDeclNameLen" {
    const predicates = struct {
        fn isIntDecl(comptime T: type, comptime name: []const u8) bool {
            return isInt(@field(T, name));
        }
        fn alwaysTrue(comptime T: type, comptime name: []const u8) bool {
            _ = T;
            _ = name;
            return true;
        }
        fn isBoolDecl(comptime T: type, comptime name: []const u8) bool {
            return @TypeOf(@field(T, name)) == bool;
        }
    };

    try std.testing.expectEqual(
        @as(usize, 5),
        maxDeclNameLen(test_namespace, predicates.isIntDecl),
    );
    try std.testing.expectEqual(
        @as(usize, 17),
        maxDeclNameLen(test_namespace, predicates.alwaysTrue),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        maxDeclNameLen(test_namespace, predicates.isBoolDecl),
    );
}

test "maxDeclValue" {
    try std.testing.expectEqual(
        @as(usize, 11),
        maxDeclValue(test_namespace),
    );
}

pub fn maxCharsForInt(comptime T: type) comptime_int {
    return std.math.log10(std.math.maxInt(T)) + 1;
}

pub fn FieldType(comptime T: type, comptime field: []const u8) type {
    return @TypeOf(@field(@as(T, undefined), field));
}

pub const Signal = u6;
pub const SignalAction = fn (Signal, *const std.os.siginfo_t) void;
pub fn setSignalAction(signal: Signal, comptime handler: SignalAction) !void {
    const Closure = struct {
        fn sigaction(sig: c_int, info: *const std.os.siginfo_t, ucontext: ?*const anyopaque) callconv(.C) void {
            _ = ucontext;
            handler(@intCast(Signal, sig), info);
        }
    };
    const sigaction = std.os.Sigaction{
        .handler = .{ .sigaction = Closure.sigaction },
        .mask = std.os.linux.empty_sigset,
        .flags = std.os.linux.SA.SIGINFO,
    };
    try std.os.sigaction(signal, &sigaction, null);
}
