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
    fn addPayload(self: @This(), name: []const u8, root_src: []const u8) *std.build.LibExeObjStep {
        const obj = self.builder.addObject(name, root_src);
        obj.addPackage(self.package);
        obj.setBuildMode(.ReleaseFast);
        obj.setTarget(self.target);
        obj.single_threaded = true;
        obj.strip = true;
        obj.code_model = .small;
        return obj;
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
    tracer.addPackage(utils_package);
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

    const echo = helper.addExe("echo", "test/echo.zig");
    _ = echo;

    const inject_hello = helper.addExe("injector", "test/inject_hello.zig");
    //inject_hello.use_stage1 = true;

    const hello_payload = helper.addPayload("hello_world", "test/payloads/hello_world.zig");
    hello_payload.addPackage(utils_package);
    hello_payload.setBuildMode(.ReleaseSmall);
    const inject_step = std.build.RunStep.create(b, "run injector");
    inject_step.addArtifactArg(inject_hello);
    inject_step.addArtifactArg(hello_payload);
    if (b.args) |args| {
        if (args.len >= 1)
            inject_step.addArg(args[0]);
    }

    const embed_tool = b.addExecutable("embed", "tools/artifact-to-embedfile.zig");
    const embed_snippets = embed_tool.run();

    const embed_object_name = "snippets.o";
    const embed_object_path = "src/generated/" ++ embed_object_name;
    const embed_package_path = "src/generated/snippets.zig";
    const embed_package = std.build.Pkg{
        .name = "artifacts",
        .source = .{ .path = embed_package_path },
    };
    const snippets_root = helper.addPayload("snippets", "src/snippets.zig");
    //snippets_root.strip = false;
    const cp_tool = b.addSystemCommand(&[_][]const u8{"cp"});
    cp_tool.addArtifactArg(snippets_root);
    cp_tool.addArg(embed_object_path);
    embed_snippets.addArg(embed_package_path);
    embed_snippets.addArg(embed_object_name);
    embed_snippets.step.dependOn(&cp_tool.step);

    inject_step.step.dependOn(&embed_snippets.step);
    inject_hello.addPackage(embed_package);

    const inject_run_step = b.step("inject", "Inject the 'Hello World' payload into the target process");
    inject_run_step.dependOn(&inject_step.step);

    const runner_step = std.build.RunStep.create(b, "run tracer");
    runner_step.addArtifactArg(tracer);
    runner_step.addArtifactArg(tracee);

    const run_step = b.step("run", "Run the tracer program");
    run_step.dependOn(&runner_step.step);

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.addPackage(embed_package);
    main_tests.step.dependOn(&embed_snippets.step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
