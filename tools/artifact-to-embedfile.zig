const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) return error.InvalidUsage;

    const out_file = args[1];
    const file = try std.fs.cwd().createFileZ(out_file, .{});
    //errdefer std.fs.cwd().deleteFileZ(out_file) catch {};
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());
    defer buffer.flush() catch {};
    const writer = buffer.writer();
    try writer.print("// AUTO GENERATED BY " ++ @src().file ++ "\n", .{});

    for (args[2..]) |path| {
        const begin = if (std.mem.lastIndexOf(u8, path, "/")) |idx| idx + 1 else 0;
        const end = std.mem.lastIndexOf(u8, path, ".") orelse path.len;
        const basename = path[begin..end];
        try writer.print("pub const {s} = @embedFile(\"{s}\");\n", .{ basename, path });
    }
}
