const std = @import("std");

// Names of the PCAN examples under examples/, one .zig file each. Built and
// wired into run steps the same way zig-easy-cli's own build.zig does it
// for its examples/ directory. Each imports the "pcan" module.
const pcan_examples = &.{
    "pcan_send",
    "pcan_recv",
};

// Names of the SocketCAN examples under examples/. Each imports the
// "socketcan" module.
const socketcan_examples = &.{
    "socketcan_send",
    "socketcan_recv",
};

/// Builds one example executable and its `zig build <name>` run step,
/// following the same pattern as zig-easy-cli's build.zig.
fn addExample(
    b: *std.Build,
    examples_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime name: []const u8,
    import_name: []const u8,
    import_module: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = import_name, .module = import_module },
            },
        }),
    });
    examples_step.dependOn(&example.step);

    const example_run = b.addRunArtifact(example);
    example_run.addPassthruArgs();
    const run_example_step = b.step(name, "Run " ++ name);
    run_example_step.dependOn(&example_run.step);
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zig_easy_cli = b.dependency("zig_easy_cli", .{ .target = target, .optimize = optimize });
    const root_mod = b.addModule("canzig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = b.addModule("socketcan", .{ .root_source_file = b.path("src/socketcan.zig") });

    const main_mod = b.addModule("demo", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "canzig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_module = root_mod,
    });
    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "canzig",
        .root_module = main_mod,
    });
    exe.root_module.addImport("parser", zig_easy_cli.module("parser"));
    // exe.root_module.addImport("zig_easy_cli", zig_easy_cli);
    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // The pcan.zig adapter talks to libpcanbasic.so/PCANBasic.dll through
    // dlopen/LoadLibrary; on Linux it needs libc linked in so that
    // `std.DynLib` resolves to the real dlopen-backed implementation
    // (otherwise the dependency-unaware ELF loader crashes as soon as the
    // library calls into libc). Declared once here and imported by every
    // example below.
    const pcan_mod = b.createModule(.{
        .root_source_file = b.path("src/pcan.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // socketcan.zig only uses raw posix syscalls, so unlike pcan_mod it
    // needs no special build options.
    const socketcan_mod = b.createModule(.{
        .root_source_file = b.path("src/socketcan.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Same pattern as zig-easy-cli's build.zig: one executable and one run
    // step per example, named after the example itself
    // (e.g. `zig build pcan_send -- 123 0102030405060708`).
    const examples_step = b.step("examples", "Build the PCAN and SocketCAN examples");

    inline for (pcan_examples) |example_name| {
        addExample(b, examples_step, target, optimize, example_name, "pcan", pcan_mod);
    }
    inline for (socketcan_examples) |example_name| {
        addExample(b, examples_step, target, optimize, example_name, "socketcan", socketcan_mod);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    // TODO: add other unit tests suites
    const kcd_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = zig_easy_cli.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(kcd_unit_tests);

    kcd_unit_tests.root_module.addIncludePath(
        std.Build.LazyPath{ .cwd_relative = "src/test_files/can_definition_sample.kcd" },
    );

    const run_exe_unit_tests = b.addRunArtifact(kcd_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
