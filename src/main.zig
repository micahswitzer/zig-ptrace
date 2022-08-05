// this is the API exposed to consumers of this package
pub const highlevel = @import("highlevel.zig");
pub const lowlevel = @import("lowlevel.zig");
pub const system = @import("ptrace.zig");

test {
    _ = highlevel;
    _ = lowlevel;
    _ = system;
}
