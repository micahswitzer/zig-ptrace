const std = @import("std");

// this package is used for building the test/sample programs
const ptrace_package = std.build.Pkg{
    .name = "ptrace",
    .source = .{ .path = "src/main.zig" },
};
const utils_package = std.build.Pkg{
    .name = "utils",
    .source = .{ .path = "src/utils.zig" },
};

const ExeHelper = struct {
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
    package: std.build.Pkg,
    builder: *std.build.Builder,
    fn addExe(self: @This(), name: []const u8, root_src: []const u8) *std.build.LibExeObjStep {
        const exe = self.builder.addExecutable(name, root_src);
        exe.addPackage(self.package);
        exe.setBuildMode(self.mode);
        exe.setTarget(self.target);
        exe.install();
        return exe;
    }
};

pub fn build(b: *std.build.Builder) void {
    // my code confuses stage 1 and we should be moving away from it anyways
    b.use_stage1 = false;

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const helper = ExeHelper{ .mode = mode, .target = target, .package = ptrace_package, .builder = b };

    const tracer = b.addExecutable("tracer", "test/tracer.zig");
    tracer.addPackage(ptrace_package);
    tracer.setBuildMode(mode);
    tracer.setTarget(target);
    tracer.install();

    const tracee = b.addExecutable("tracee", "test/tracee.zig");
    tracee.addPackage(ptrace_package);
    tracee.addPackage(utils_package);
    tracee.setBuildMode(mode);
    tracee.setTarget(target);
    tracee.install();

    const threaded = helper.addExe("threaded", "test/threaded.zig");
    _ = threaded;
    const raise_before_stop = helper.addExe("raise_before_stop", "test/raise_signal_before_stop.zig");
    raise_before_stop.single_threaded = true;
    raise_before_stop.addPackage(utils_package);
    const handle_before_stop = helper.addExe("handle_before_stop", "test/handle_signal_before_stop.zig");
    handle_before_stop.addPackage(utils_package);

    const runner_step = std.build.RunStep.create(b, "run tracer");
    runner_step.addArtifactArg(tracer);
    runner_step.addArtifactArg(tracee);

    const run_step = b.step("run", "Run the tracer program");
    run_step.dependOn(&runner_step.step);

    const main_tests = b.addTest("src/highlevel.zig");
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
