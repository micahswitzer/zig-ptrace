const std = @import("std");
const Build = std.Build;
const Compile = Build.Step.Compile;
const Module = Build.Module;

const Import = struct {
    name: []const u8,
    module: *Module,
};

fn addImports(compilation: *Compile, imports: []const Import) void {
    for (imports) |import| {
        compilation.root_module.addImport(import.name, import.module);
    }
}

const ExeHelper = struct {
    optimize: std.builtin.Mode,
    target: Build.ResolvedTarget,
    imports: []const Import,
    builder: *std.Build,

    fn addExe(self: @This(), name: []const u8, root_src: []const u8) *Compile {
        const exe = self.builder.addExecutable(.{
            .name = name,
            .root_source_file = self.builder.path(root_src),
            .target = self.target,
            .optimize = self.optimize,
        });
        addImports(exe, self.imports);
        self.builder.installArtifact(exe);
        return exe;
    }

    fn addPayload(self: @This(), name: []const u8, root_src: []const u8) *Compile {
        const obj = self.builder.addObject(.{
            .name = name,
            .root_source_file = self.builder.path(root_src),
            .target = self.target,
            .optimize = .ReleaseSmall,
        });
        addImports(obj, self.imports);
        obj.root_module.single_threaded = true;
        obj.root_module.strip = true;
        obj.root_module.code_model = .small;
        return obj;
    }

    fn addTest(self: @This(), root_src: []const u8) *Compile {
        const tst = self.builder.addTest(.{
            .root_source_file = self.builder.path(root_src),
            .target = self.target,
            .optimize = self.optimize,
        });
        addImports(tst, self.imports);
        return tst;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
    });
    const elf_file = b.createModule(.{
        .root_source_file = b.path("src/ElfFile.zig"),
    });

    const ptrace = b.addModule("ptrace", .{
        .root_source_file = b.path("src/main.zig"),
    });
    ptrace.addImport("utils", utils);
    ptrace.addImport("ElfFile", elf_file);

    const helper = ExeHelper{
        .optimize = optimize,
        .target = target,
        .imports = &[_]Import{
            .{ .name = "ptrace", .module = ptrace },
            .{ .name = "utils", .module = utils },
        },
        .builder = b,
    };

    const tracer = helper.addExe("tracer", "test/tracer.zig");
    const tracee = helper.addExe("tracee", "test/tracee.zig");

    _ = helper.addExe("threaded", "test/threaded.zig");

    const raise_before_stop = helper.addExe("raise_before_stop", "test/raise_signal_before_stop.zig");
    raise_before_stop.root_module.single_threaded = true;
    _ = helper.addExe("handle_before_stop", "test/handle_signal_before_stop.zig");
    _ = helper.addExe("echo", "test/echo.zig");

    const inject_hello = helper.addExe("injector", "test/inject_hello.zig");

    const hello_payload = helper.addPayload("hello_world", "test/payloads/hello_world.zig");

    const inject_step = b.addRunArtifact(inject_hello);
    inject_step.addArtifactArg(hello_payload);
    if (b.args) |args| {
        if (args.len >= 1)
            inject_step.addArg(args[0]);
    }

    const embed_object_name = "snippets.o";
    const embed_object_path = "src/generated/" ++ embed_object_name;
    const snippets_root = helper.addPayload("snippets", "src/snippets.zig");

    const embed_module = &snippets_root.root_module;
    embed_module.addImport("ElfFile", elf_file);
    ptrace.addImport("embed", embed_module);

    const cp_tool = b.addSystemCommand(&[_][]const u8{"cp"});
    cp_tool.addArtifactArg(snippets_root);
    cp_tool.addArg(embed_object_path);

    inject_hello.root_module.addImport("embed", embed_module);
    inject_hello.step.dependOn(&cp_tool.step);

    const inject_run_step = b.step("inject", "Inject the 'Hello World' payload into the target process");
    inject_run_step.dependOn(&inject_step.step);

    const runner_step = b.addRunArtifact(tracer);
    runner_step.addArtifactArg(tracee);

    const run_step = b.step("run", "Run the tracer program");
    run_step.dependOn(&runner_step.step);

    const main_tests = helper.addTest("src/main.zig");
    main_tests.root_module.addImport("embed", embed_module);
    main_tests.root_module.addImport("ElfFile", elf_file);
    main_tests.step.dependOn(&cp_tool.step);

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
