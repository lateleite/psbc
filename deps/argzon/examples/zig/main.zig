//! Zig 0.14.0 CLI without project- and module-specific parameters,
//! since there are no plans to support context-dependent streaming argument parsing.

const std = @import("std");

const argzon = @import("argzon");

const CLI = @import("cli.zon");

/// Source: https://github.com/ziglang/zig/blob/0.14.0/src/Compilation.zig#L369-L378
const RcIncludes = enum {
    /// Use MSVC if available, fall back to MinGW.
    any,
    /// Use MSVC include paths (MSVC install + Windows SDK, must be present on the system).
    msvc,
    /// Use MinGW include paths (distributed with Zig).
    gnu,
    /// Do not use any autodetected include paths.
    none,
};

/// Source: https://github.com/ziglang/zig/blob/0.14.0/src/link/Elf.zig#L208
const CompressDebugSections = enum {
    none,
    zlib,
    zstd,
};

/// Source: https://github.com/ziglang/zig/blob/0.14.0/lib/std/zig.zig#L239-L244
const BuildId = enum {
    none,
    fast,
    uuid,
    sha1,
    md5,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator(); // An arena is appropriate for this program
    const io = init.io;

    // Set up standard output writer
    var stdout_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const writer = &stdout_file_writer.interface;

    // Set up standard error writer
    var stderr_buf: [argzon.MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr_writer = &stderr_file_writer.interface;

    // Create arguments according to CLI and user enum definitions
    const Args = argzon.Args(CLI, .{
        .enums = &.{
            BuildId,
            RcIncludes,
            CompressDebugSections,
            std.zig.Color,
            std.Target.ObjectFormat,
            std.builtin.CodeModel,
            std.builtin.OptimizeMode,
        },
        .version = try .parse("0.14.0"),
    });

    // Write usage
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"USAGE"});
    try Args.writeUsage(writer);

    // Write help
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"HELP"});
    try Args.writeHelp(writer, .{ .desc_start_idx = 50 });

    // Parse command-line arguments
    var args: Args = try .parse(alloc, init.minimal.args, stderr_writer, .{ .is_gpa = false });

    // Print parsed arguments (all values must be initialized)
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n{f}", .{ "ARGUMENTS", args.format(null) });

    // Flush standard output
    try writer.flush();
}
