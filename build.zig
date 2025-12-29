const std = @import("std");
const builtin = @import("builtin");

pub fn buildOld(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const datastar_module = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "examples/01_basic.zig", .name = "example_1" },
        .{ .file = "examples/02_petshop.zig", .name = "example_2" },
    };

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("datastar", datastar_module);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const datastar_module = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add test step for server.zig
    const server_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_server_tests = b.addRunArtifact(server_tests);

    // Add test step for datastar.zig
    const datastar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/datastar.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_datastar_tests = b.addRunArtifact(datastar_tests);

    // Create a "test" step that runs all tests
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_datastar_tests.step);

    // Individual test steps
    const test_server_step = b.step("test-server", "Run server tests");
    test_server_step.dependOn(&run_server_tests.step);

    const test_datastar_step = b.step("test-datastar", "Run datastar tests");
    test_datastar_step.dependOn(&run_datastar_tests.step);

    // Examples
    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    }{
        .{ .file = "tests/validation.zig", .name = "validation-test" },
        .{ .file = "examples/01_basic.zig", .name = "example_1" },
        .{ .file = "examples/02_petshop.zig", .name = "example_2" },
    };

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("datastar", datastar_module);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(ex.name, ex.file);
        run_step.dependOn(&run_cmd.step);
    }
}
