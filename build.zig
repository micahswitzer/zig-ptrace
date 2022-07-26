const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const tracer = b.addExecutable("tracer", "src/tracer.zig");
    tracer.setBuildMode(mode);
    tracer.install();

    const tracee = b.addExecutable("tracee", "src/tracee.zig");
    tracee.setBuildMode(mode);
    tracee.install();

    const runner_step = std.build.RunStep.create(b, "run tracer");
    runner_step.addArtifactArg(tracer);
    runner_step.addArtifactArg(tracee);

    const run_step = b.step("run", "Run the tracer program");
    run_step.dependOn(&runner_step.step);

    const main_tests = b.addTest("src/highlevel.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
