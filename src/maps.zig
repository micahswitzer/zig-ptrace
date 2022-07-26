const std = @import("std");

pub const MapEntry = struct {
    start: usize,
    end: usize,
    permissions: Permissions,
    offset: usize,
    device: Device,
    inode: usize,
    path: ?[]const u8,

    const Permissions = std.enums.EnumFieldStruct(enum {
        read,
        write,
        execute,
        private,
    }, bool, false);

    fn parsePermissions(perms: []const u8) !Permissions {
        try std.testing.expectEqual(@as(usize, 4), perms.len);
        return Permissions{
            .read = perms[0] == 'r',
            .write = perms[1] == 'w',
            .execute = perms[2] == 'x',
            .private = perms[3] == 'p',
        };
    }

    const Device = struct {
        major: u8,
        minor: u8,

        pub fn parse(device: []const u8) !Device {
            var devIt = std.mem.split(u8, device, ":");
            return Device{
                .major = try std.fmt.parseInt(u8, devIt.next() orelse return error.BadDevice, 10),
                .minor = try std.fmt.parseInt(u8, devIt.next() orelse return error.BadDevice, 10),
            };
        }
    };

    const Self = @This();

    inline fn getNext(it: anytype) ![]const u8 {
        if (it.next()) |tok|
            return tok;
        return error.UnexpectedEOL;
    }

    /// Requires `line` to live as long as the returned `MapEntry`
    pub fn parse(line: []const u8) !Self {
        var it = std.mem.tokenize(u8, line, " ");
        const addrTok = try getNext(&it);
        const permsTok = try getNext(&it);
        const offsetTok = try getNext(&it);
        const deviceTok = try getNext(&it);
        const inodeTok = try getNext(&it);
        const path = it.next();
        var addrIt = std.mem.split(u8, addrTok, "-");

        return Self{
            .start = try std.fmt.parseInt(usize, addrIt.next() orelse return error.BadAddress, 16),
            .end = try std.fmt.parseInt(usize, addrIt.next() orelse return error.BadAddress, 16),
            .permissions = try parsePermissions(permsTok),
            .offset = try std.fmt.parseInt(usize, offsetTok, 16),
            .device = try Device.parse(deviceTok),
            .inode = try std.fmt.parseInt(usize, inodeTok, 10),
            .path = path,
        };
    }

    pub fn Iterator(comptime T: type) type {
        comptime if (!@hasDecl(T, "readUntilDelimiter"))
            @compileError("T must be of type std.io.Reader()");
        return struct {
            reader: T,
            pub fn next(self: *const @This()) !?Self {
                var buf: [512]u8 = undefined;
                const line = self.reader.readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => |e| return e,
                };
                return try Self.parse(line);
            }
        };
    }
};

pub fn iterator(reader: anytype) MapEntry.Iterator(@TypeOf(reader)) {
    return .{
        .reader = reader,
    };
}

test "parse system maps" {
    const file = try std.fs.cwd().openFile("/proc/self/maps", .{});
    defer file.close();
    var reader = file.reader();
    const iter = iterator(reader);
    while (try iter.next()) |entry| {
        _ = entry;
    }
}

test "parse line with path" {
    const LINE = "56523759d000-5652375bd000 r--p 00000000 103:05 2361465                   /usr/bin/bash";
    const expected = MapEntry{
        .start = 0x56523759d000,
        .end = 0x5652375bd000,
        .permissions = .{ .read = true, .private = true },
        .offset = 0,
        .device = .{ .major = 103, .minor = 5 },
        .inode = 2361465,
        .path = LINE[73..],
    };
    const actual = try MapEntry.parse(LINE);
    try std.testing.expectEqual(expected, actual);
}

test "parse line without path" {
    const LINE = "56523759d000-5652375bd000 r-xp 00000000 103:05 2361465";
    const expected = MapEntry{
        .start = 0x56523759d000,
        .end = 0x5652375bd000,
        .permissions = .{ .read = true, .execute = true, .private = true },
        .offset = 0,
        .device = .{ .major = 103, .minor = 5 },
        .inode = 2361465,
        .path = null,
    };
    const actual = try MapEntry.parse(LINE);
    try std.testing.expectEqual(expected, actual);
}
