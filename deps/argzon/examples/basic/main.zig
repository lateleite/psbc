//! Basic CLI.

const std = @import("std");

const argzon = @import("argzon");

const CLI = @import("cli.zon");

pub fn main(init: std.process.Init) !void {
    // Debug mode will setup leak-checking, if possible on the target.
    const gpa = init.gpa;
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
    const Args = argzon.Args(CLI, .{ .enums = &.{std.zig.Ast.Mode} });

    // Write usage
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"USAGE"});
    try Args.writeUsage(writer);

    // Write help
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n", .{"HELP"});
    try Args.writeHelp(writer, .{});

    // Parse command-line arguments
    var args: Args = try .parse(gpa, init.minimal.args, stderr_writer, .{});
    defer args.free(gpa);

    // Print parsed arguments (all values must be initialized)
    try writer.print("{s:=^" ++ argzon.FMT_WIDTH ++ "}\n{f}", .{ "ARGUMENTS", args.format(null) });

    // Flush standard output
    try writer.flush();
}
