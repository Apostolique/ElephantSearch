const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Not standardOptimizeOption: giving that a preferred mode replaces
    // -Doptimize with -Drelease and still defaults to debug, which is three to
    // four times slower and not what anyone building this wants by accident.
    // Safe rather than fast because the MFT reader and the cache both parse
    // binary laid down by something else, and a bound this code misses should
    // stop the program rather than corrupt it. -Doptimize=ReleaseFast is
    // another third faster again if that matters more.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    // The version lives in build.zig.zon and nowhere else. The programs print
    // it, and the resource file and the manifest get it written in.
    const version = std.SemanticVersion.parse(zon.version) catch
        @panic("the version in build.zig.zon is not major.minor.patch");
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const generated = b.addWriteFiles();
    _ = generated.add("version.h", b.fmt(
        \\#define ES_VERSION {d},{d},{d},0
        \\#define ES_VERSION_STR "{d}.{d}.{d}"
        \\
    , .{ version.major, version.minor, version.patch, version.major, version.minor, version.patch }));
    const manifest = generated.add("elephant-gui.manifest", std.mem.replaceOwned(
        u8,
        b.allocator,
        @embedFile("src/elephant-gui.manifest"),
        "@VERSION@",
        b.fmt("{d}.{d}.{d}.0", .{ version.major, version.minor, version.patch }),
    ) catch @panic("OOM"));

    const exe = b.addExecutable(.{
        .name = "elephant",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("src/elephant.rc"),
        .include_paths = &.{generated.getDirectory()},
    });
    b.installArtifact(exe);

    // The window is its own binary rather than a flag on the first one. A
    // windows subsystem program started from a terminal has no console to write
    // to, and a console one started from Explorer opens a black rectangle
    // behind the window; the subsystem is fixed in the header and neither can
    // be argued out of it afterwards.
    const gui = b.addExecutable(.{
        .name = "elephant-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Themed common controls, per-monitor DPI, and the version number the
        // dark mode checks read.
        .win32_manifest = manifest,
    });
    gui.root_module.addOptions("build_options", options);
    gui.root_module.addWin32ResourceFile(.{
        .file = b.path("src/elephant.rc"),
        .flags = &.{"/dES_WINDOW"},
        .include_paths = &.{generated.getDirectory()},
    });
    gui.subsystem = .windows;
    b.installArtifact(gui);

    // The service gets a binary of its own too, so what runs as LocalSystem
    // holds the volume reader and the pipe and none of the rest.
    const service = b.addExecutable(.{
        .name = "elephant-service",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/service_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    service.root_module.addOptions("build_options", options);
    service.root_module.addWin32ResourceFile(.{
        .file = b.path("src/elephant.rc"),
        .flags = &.{"/dES_SERVICE"},
        .include_paths = &.{generated.getDirectory()},
    });
    b.installArtifact(service);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run ElephantSearch");
    run_step.dependOn(&run_cmd.step);

    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gui.addArgs(args);
    const run_gui_step = b.step("run-gui", "Run the ElephantSearch window");
    run_gui_step.dependOn(&run_gui.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Kept out of `test` because it reads a real volume, which needs elevation
    // or the service and takes seconds rather than milliseconds. A program
    // rather than a test, so the report it prints is not taken for a failure.
    const verify = b.addExecutable(.{
        .name = "verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("verify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const verify_step = b.step("verify", "Check the MFT reader against a real drive");
    verify_step.dependOn(&b.addRunArtifact(verify).step);
}
