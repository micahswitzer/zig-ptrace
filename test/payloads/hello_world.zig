const std = @import("std");
const inject = @import("ptrace").inject;
const Result = inject.PayloadResult;
const utils = @import("utils");

export fn setup(load_addr: usize) Result {
    _ = load_addr;
    var b: [13]u8 = undefined;
    b[0] = 'H';
    b[1] = 'e';
    b[2] = 'l';
    b[3] = 'l';
    b[4] = 'o';
    b[5] = ' ';
    b[6] = 'W';
    b[7] = 'o';
    b[8] = 'r';
    b[9] = 'l';
    b[10] = 'd';
    b[11] = '!';
    b[12] = '\n';
    std.io.getStdOut().writeAll(&b) catch return .error_unload;
    return .success_unload;
}
