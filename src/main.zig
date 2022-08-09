// this is the API exposed to consumers of this package
pub const highlevel = @import("highlevel.zig");
pub const inject = @import("inject.zig");
pub const lowlevel = @import("lowlevel.zig");
pub const proc = @import("proc.zig");
pub const system = @import("ptrace.zig");

test {
    _ = highlevel;
    _ = inject;
    _ = lowlevel;
    _ = proc;
    _ = system;
}
