//! Root source file that exposes the library's API to users and Autodoc.

const std = @import("std");

const args = @import("args.zig");

pub const FMT_WIDTH = args.FMT_WIDTH;
pub const MAX_BUF_SIZE = args.MAX_BUF_SIZE;

pub const Error = args.Error;
pub const Args = args.CommandArgs;
pub const CliOptions = args.CliOptions;
pub const HelpOptions = args.HelpOptions;
pub const ParseOptions = args.ParseOptions;

test {
    std.testing.refAllDecls(@This());
}
