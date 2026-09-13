const std = @import("std");

const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const install_step = b.getInstallStep();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path("src/root.zig");
    const version: std.SemanticVersion = try .parse(manifest.version);

    // Public root module
    const root_mod = b.addModule("argzon", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = root_source_file,
        .strip = b.option(bool, "strip", "Strip binary"),
    });

    // Library
    const lib = b.addLibrary(.{
        .name = "argzon",
        .version = version,
        .root_module = root_mod,
    });
    b.installArtifact(lib);

    // Documentation
    const docs_step = b.step("doc", "Emit documentation");

    const docs_install = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = lib.getEmittedDocs(),
    });
    docs_step.dependOn(&docs_install.step);

    // Example suite
    const examples_step = b.step("run", "Run example suite");

    const example_opt = b.option(Example, "example", "Run example");

    inline for (comptime std.meta.tags(Example)) |EXAMPLE| {
        const example_exe = b.addExecutable(.{
            .name = @tagName(EXAMPLE),
            .version = version,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(EXAMPLES_DIR ++ @tagName(EXAMPLE) ++ "/main.zig"),
                .imports = &.{
                    .{ .name = "argzon", .module = root_mod },
                },
            }),
        });

        if (example_opt == null or example_opt.? == EXAMPLE) {
            const example_run = b.addRunArtifact(example_exe);
            example_run.addArgs(switch (EXAMPLE) {
                .basic => &.{
                    "-o", "zig", "-o",  "zon",
                    "-f", "-f",  "-f",  "-f",
                    "po", "sit", "ion", "als",
                },
                .zig => &.{
                    "zen",
                },
            });
            examples_step.dependOn(&example_run.step);
        }
    }

    // Test suite
    const tests_step = b.step("test", "Run test suite");

    const tests = b.addTest(.{
        .root_module = root_mod,
    });

    const tests_run = b.addRunArtifact(tests);
    tests_step.dependOn(&tests_run.step);
    install_step.dependOn(tests_step);

    // Formatting check
    const fmt_step = b.step("fmt", "Check formatting");

    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src/"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path(EXAMPLES_DIR),
        },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    install_step.dependOn(fmt_step);

    // Compilation check for ZLS Build-On-Save
    // See: https://zigtools.org/zls/guides/build-on-save/
    const check_step = b.step("check", "Check compilation");
    const check_exe = b.addExecutable(.{
        .name = "argzon",
        .version = version,
        .root_module = root_mod,
    });
    check_step.dependOn(&check_exe.step);
}

const EXAMPLES_DIR = "examples/";

const Example = enum {
    basic,
    zig,
};
