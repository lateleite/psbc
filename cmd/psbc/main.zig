const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const fatal = std.process.fatal;

const argzon = @import("argzon");

const gnm = @import("gnm");
const psbc = @import("psbc");
const gcn = gnm.gcn;
const psb = gnm.psb;

const cli = .{
    .name = "psbc",
    .description = "A free PlayStation Shader Binary (PSB) compiler",
    .positionals = .{
        .{
            .meta = .INPUT,
            .type = "string",
            .description = "Input path to the SPIRV shader file",
        },
        .{
            .meta = .OUTPUT,
            .type = "string",
            .description = "Output path for the new PlayStation Shader Binary file",
        },
    },
    .options = .{
        .{
            .short = 's',
            .long = "stage",
            .type = "MesaShaderStage",
            .description = "Shader program's stage/type",
        },
        .{
            .short = 'e',
            .long = "entry",
            .type = "string",
            .default = "main",
            .description = "Shader's entrypoint name",
        },
    },
    .flags = .{
        .{
            .short = 'n',
            .long = "neo",
            .description = "Target the PS4 Pro (NEO) instead of a base PS4",
        },
        .{
            .short = 'd',
            .long = "debug",
            .description = "Disable code optimizations",
        },
        .{
            .short = 'v',
            .long = "verbose",
            .description = "Enable verbose message output",
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const Args = argzon.Args(cli, .{
        .enums = &.{
            psbc.MesaShaderStage,
        },
    });
    var args = try Args.parse(gpa, init.minimal.args, stderr, .{});
    defer args.free(gpa);

    const in_file_path = args.positionals.INPUT;
    const in_file = Io.Dir.cwd().openFile(io, in_file_path, .{}) catch |err| {
        fatal("Failed to open ipnut file {s} with {}", .{ in_file_path, err });
    };
    defer in_file.close(io);

    const out_file_path = args.positionals.OUTPUT;
    const out_file = Io.Dir.cwd().createFile(io, out_file_path, .{}) catch |err| {
        fatal("Failed to create output file {s} with {}", .{ out_file_path, err });
    };
    defer out_file.close(io);

    var in_reader = in_file.reader(io, &.{});
    const input_spirv_bytes = try in_reader.interface.allocRemainingAlignedSentinel(arena, .unlimited, .@"16", 0);

    if (input_spirv_bytes.len == 0) {
        fatal("Input SPIRV file \"{s}\" is empty", .{in_file_path});
    }
    if ((input_spirv_bytes.len & 3) != 0) {
        fatal(
            "Input SPIRV file  \"{s}\"'s byte size is not a multiple of 4. Its byte size is {}",
            .{ in_file_path, input_spirv_bytes.len },
        );
    }

    const input_spirv = @as([*]const u32, @ptrCast(@alignCast(
        input_spirv_bytes,
    )))[0 .. input_spirv_bytes.len / @sizeOf(u32)];

    psbc.globalInit();
    defer psbc.globalDeinit();

    const gfx_level = psbc.getGfxLevel(.{ .is_neo = args.flags.neo });
    const chip_family = psbc.getChipFamily(.{ .is_neo = args.flags.neo });
    const nir_options = psbc.getDefaultNirOptions(gfx_level, chip_family);
    const nir = try psbc.spirvToNir(input_spirv, &nir_options, .{
        .entry_point = args.options.entry,
        .stage = args.options.stage,
        .is_neo = args.flags.neo,
        .should_optimize = !args.flags.debug,
    });

    if (args.flags.verbose) {
        try stdout.print(
            \\========================
            \\BEFORE NIR OPTIMISATIONS
            \\========================
            \\
        , .{});
        try stdout.flush();
        psbc.printNirToStdout(nir);
    }

    psbc.optimize(nir, .{ .should_optimize = args.flags.debug == false });

    if (args.flags.verbose) {
        try stdout.print(
            \\=======================
            \\AFTER NIR OPTIMISATIONS
            \\=======================
            \\
        , .{});
        try stdout.flush();
        psbc.printNirToStdout(nir);
    }

    var write_buf: [4096]u8 = undefined;
    var out_file_writer = out_file.writer(io, &write_buf);
    try psbc.nirToGcn(nir, &out_file_writer.interface, .{
        .stage = args.options.stage,
        .is_neo = args.flags.neo,
        .should_optimize = args.flags.debug == false,
        .verbose = args.flags.verbose,
    });

    try out_file_writer.flush();
}
