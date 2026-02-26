const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Dependencies ---
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite_dep = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // --- Main module ---
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("httpz", httpz_dep.module("httpz"));
    main_mod.addImport("clap", clap_dep.module("clap"));
    main_mod.addImport("zqlite", zqlite_dep.module("zqlite"));

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "zclaw",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zclaw gateway");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const test_step = b.step("test", "Run all unit tests");

    // Main server tests (needs httpz)
    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("httpz", httpz_dep.module("httpz"));
    main_test_mod.addImport("clap", clap_dep.module("clap"));
    main_test_mod.addImport("zqlite", zqlite_dep.module("zqlite"));
    const main_tests = b.addTest(.{ .root_module = main_test_mod });
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    // Library tests (all non-server modules)
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_mod.addImport("zqlite", zqlite_dep.module("zqlite"));
    const lib_tests = b.addTest(.{ .root_module = lib_test_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
