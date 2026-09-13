const std = @import("std");

const Type = std.builtin.Type;

pub const FMT_WIDTH = "70";
pub const MAX_BUF_SIZE = 1 << 12;
const EVAL_BRANCH_QUOTA = 100_000;

/// Command-line argument parsing error set.
pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error || std.fmt.ParseIntError;

/// Command-line argument parsing diagnostic.
const Diagnostic = union(enum) {
    Help,
    NoArgumentValue: [:0]const u8,
    UnexpectedArgument: [:0]const u8,
    UnexpectedSubcommand: [:0]const u8,
    UnexpectedArgumentValue: [2][:0]const u8,
    PresentNamedArgumentExclude: [3][:0]const u8,
    MissingNamedArgumentDependencies: [:0]const u8,
};

/// Command-line interface definition options.
pub const CliOptions = struct {
    /// User enum definitions.
    enums: []const type = &.{},
    /// Current semantic version.
    version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    /// Whether to append trailing full stop to description strings.
    add_desc_dot: bool = true,
};

/// Command-line argument parsing options.
pub const ParseOptions = struct {
    /// Whether to deallocate process arguments or not.
    is_gpa: bool = true,
};

/// Command-line interface help rendering options.
pub const HelpOptions = struct {
    /// Description start.
    desc_start_idx: u8 = 40,
    /// Line padding.
    padding: u8 = 0,
};

/// Command-line arguments parsed according to ZON CLI and user enum definitions.
pub fn CommandArgs(comptime cli: anytype, comptime cli_opts: CliOptions) type {
    @setEvalBranchQuota(EVAL_BRANCH_QUOTA);

    for (cli_opts.enums) |E| {
        if (@typeInfo(E) != .@"enum") {
            @compileError("User types must be enums: " ++ @typeName(E));
        }
    }

    const Cli = @TypeOf(cli);

    for (cli.name) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-' and char != '+') {
            @compileError("Name contains unsupported character: " ++ @as([1]u8, .{char}));
        }
    }

    const HAS_OPTIONS = @hasField(Cli, "options") and cli.options.len > 0;
    const HAS_FLAGS = @hasField(Cli, "flags") and cli.flags.len > 0;
    const HAS_POSITIONALS = @hasField(Cli, "positionals") and cli.positionals.len > 0;
    const HAS_SUBCOMMANDS = @hasField(Cli, "subcommands") and cli.subcommands.len > 0;

    // Enum of all short names, which automatically ensures uniqueness
    const Short = blk: {
        if ((!HAS_OPTIONS or cli.options.len == 0) and
            (!HAS_FLAGS or cli.flags.len == 0)) break :blk void;
        var num_fields_potential = 0;
        if (HAS_OPTIONS) num_fields_potential += cli.options.len;
        if (HAS_FLAGS) num_fields_potential += cli.flags.len;

        var field_names_buffer: [num_fields_potential][]const u8 = undefined;
        var field_idx = 0;
        if (HAS_OPTIONS) {
            for (cli.options) |param| {
                if (@hasField(@TypeOf(param), "short")) {
                    field_names_buffer[field_idx] = &.{param.short};
                    field_idx += 1;
                }
            }
        }
        if (HAS_FLAGS) {
            for (cli.flags) |param| {
                if (@hasField(@TypeOf(param), "short")) {
                    field_names_buffer[field_idx] = &.{param.short};
                    field_idx += 1;
                }
            }
        }
        if (field_idx == 0) break :blk void; // No short options

        const field_names: [field_idx][]const u8 = field_names_buffer[0..field_idx].*;

        const TagInt: type = std.math.IntFittingRange(0, field_names.len - 1);
        break :blk @Enum(
            TagInt,
            .exhaustive,
            &field_names,
            &std.simd.iota(TagInt, field_names.len),
        );
    };

    // Enum of all long names, which automatically ensures uniqueness
    const Long = blk: {
        if ((!HAS_OPTIONS or cli.options.len == 0) and
            (!HAS_FLAGS or cli.flags.len == 0)) break :blk void;
        var num_fields_potential = 0;
        if (HAS_OPTIONS) num_fields_potential += cli.options.len;
        if (HAS_FLAGS) num_fields_potential += cli.flags.len;

        var field_names_buffer: [num_fields_potential][]const u8 = undefined;
        var field_idx = 0;
        if (HAS_OPTIONS) {
            for (cli.options) |param| {
                field_names_buffer[field_idx] = param.long;
                field_idx += 1;
            }
        }
        if (HAS_FLAGS) {
            for (cli.flags) |param| {
                field_names_buffer[field_idx] = param.long;
                field_idx += 1;
            }
        }

        const field_names: [field_idx][]const u8 = field_names_buffer[0..field_idx].*;

        const TagInt: type = std.math.IntFittingRange(0, field_names.len - 1);
        break :blk @Enum(
            TagInt,
            .exhaustive,
            &field_names,
            &std.simd.iota(TagInt, field_names.len),
        );
    };

    // Static hash map of short name strings to long name enum literals
    const SHORT_LONG_MAP: std.StaticStringMap(Long) = blk: {
        if (Short == void or Long == void) break :blk .{};
        var num_shorts = 0;
        if (HAS_OPTIONS) num_shorts += cli.options.len;
        if (HAS_FLAGS) num_shorts += cli.flags.len;
        var short_longs: [num_shorts]struct { [:0]const u8, Long } = undefined;
        var short_long_idx = 0;
        if (HAS_OPTIONS) {
            for (cli.options) |param| {
                if (@hasField(@TypeOf(param), "short")) {
                    short_longs[short_long_idx] = .{ &.{param.short}, @field(Long, param.long) };
                    short_long_idx += 1;
                }
            }
        }
        if (HAS_FLAGS) {
            for (cli.flags) |param| {
                if (@hasField(@TypeOf(param), "short")) {
                    short_longs[short_long_idx] = .{ &.{param.short}, @field(Long, param.long) };
                    short_long_idx += 1;
                }
            }
        }
        break :blk .initComptime(short_longs[0..short_long_idx]);
    };

    const Feature = enum {
        dependencies,
        excludes,

        const Self = @This();

        const KV = struct {
            [:0]const u8,
            Value,
        };

        const Value = struct {
            long: Long,
            values_str: [:0]const u8,
        };

        fn initSlice(
            comptime self: Self,
            comptime named_params: anytype,
            comptime kvs: []KV,
            comptime kv_idx: *u8,
        ) void {
            const self_str = @tagName(self);
            for (named_params) |param| {
                if (@hasField(@TypeOf(param), self_str)) {
                    for (@field(param, self_str)) |value_str| {
                        const dep_long_size = std.mem.indexOfScalar(u8, value_str, ' ') orelse value_str.len;
                        const dep_long = value_str[0..dep_long_size];
                        if (std.mem.eql(u8, dep_long, param.long)) {
                            @compileError("Named parameter must not " ++ switch (self) {
                                .dependencies => "depend on",
                                .excludes => "exclude",
                            } ++ " itself: " ++ dep_long);
                        }
                        if (!@hasField(Long, dep_long)) {
                            @compileError("Unexpected named parameter in " ++ self_str ++ ": " ++ dep_long);
                        }
                        if (dep_long_size < value_str.len) {
                            const E = blk: {
                                for (cli.options) |option| {
                                    if (std.mem.eql(u8, dep_long, option.long)) {
                                        if (std.ascii.isLower(option.type[0]) or
                                            option.type[0] == '?' and std.ascii.isLower(option.type[1]))
                                        {
                                            @compileError("Non-enum option " ++ self_str ++ " must not have values: " ++ value_str);
                                        }
                                        if (@hasField(@TypeOf(option), "capacity")) {
                                            @compileError("Accumulated enum option " ++ self_str ++ " must not have values: " ++ value_str);
                                        }
                                        for (cli_opts.enums) |E| {
                                            if (std.mem.endsWith(u8, @typeName(E), option.type)) {
                                                break :blk E;
                                            }
                                        }
                                    }
                                }
                                @compileError("Unexpected non-accumulated enum option with values in " ++ self_str ++ ": " ++ value_str);
                            };
                            var value_str_iter = std.mem.tokenizeScalar(u8, value_str[dep_long_size + 1 ..], ' ');
                            outer: while (value_str_iter.next()) |dep_value| {
                                for (std.meta.fieldNames(E)) |field_name| {
                                    if (std.mem.eql(u8, dep_value, field_name)) {
                                        continue :outer;
                                    }
                                }
                                @compileError("Unexpected enum option value in " ++ self_str ++ ": " ++ dep_long ++ " " ++ dep_value);
                            }
                        }
                        kvs[kv_idx.*] = .{ param.long, .{
                            .long = @field(Long, dep_long),
                            .values_str = if (dep_long_size < value_str.len) value_str[dep_long_size + 1 ..] else "",
                        } };
                        kv_idx.* += 1;
                    }
                }
            }
        }
    };

    // Static hash map of dependent long name strings to dependencies
    const DEPENDENCY_MAP: std.StaticStringMap(Feature.Value) = blk: {
        if (Long == void) break :blk .{};
        var capacity = 0;
        if (HAS_OPTIONS) capacity += cli.options.len;
        if (HAS_FLAGS) capacity += cli.flags.len;
        var deps: [capacity]Feature.KV = undefined;
        var dep_idx: u8 = 0;
        if (HAS_OPTIONS) Feature.initSlice(.dependencies, cli.options, &deps, &dep_idx);
        if (HAS_FLAGS) Feature.initSlice(.dependencies, cli.flags, &deps, &dep_idx);
        break :blk .initComptime(deps[0..dep_idx]);
    };

    // Static hash map of excluding long name strings to excludes
    const EXCLUDE_MAP: std.StaticStringMap(Feature.Value) = blk: {
        if (Long == void) break :blk .{};
        var capacity = 0;
        if (HAS_OPTIONS) capacity += cli.options.len;
        if (HAS_FLAGS) capacity += cli.flags.len;
        var excludes: [capacity]Feature.KV = undefined;
        var exclude_idx: u8 = 0;
        if (HAS_OPTIONS) Feature.initSlice(.excludes, cli.options, &excludes, &exclude_idx);
        if (HAS_FLAGS) Feature.initSlice(.excludes, cli.flags, &excludes, &exclude_idx);
        break :blk .initComptime(excludes[0..exclude_idx]);
    };

    return struct {
        const Self = @This();

        /// Struct with option long names as fields.
        pub const Options = if (HAS_OPTIONS) NamedArgs(cli.options) else void;
        /// Struct with flag long names as fields.
        pub const Flags = if (HAS_FLAGS) NamedArgs(cli.flags) else void;
        /// Struct with positional meta names as fields.
        pub const Positionals = if (HAS_POSITIONALS) PositionalArgs(cli.positionals) else void;
        /// Union with subcommand names as fields.
        pub const Subcommands = if (HAS_SUBCOMMANDS) SubcommandArgs(cli.subcommands) else void;

        options: Options,
        flags: Flags,
        positionals: Positionals,
        subcommands_opt: ?Subcommands,

        const ParseCommandResult = union(enum) {
            self: Self,
            diag: Diagnostic,
        };

        /// Parse command-line process arguments.
        pub fn parse(
            allocator: std.mem.Allocator,
            args: std.process.Args,
            writer: *std.Io.Writer,
            opts: ParseOptions,
        ) Error!Self {
            var arg_str_iter = try args.iterateAllocator(allocator);
            defer arg_str_iter.deinit();

            // Skip executable path
            _ = arg_str_iter.skip();

            // Parse command-line arguments, exit process successfully on help.
            return switch (try parseCommand(allocator, &arg_str_iter, writer, opts)) {
                .self => |self| self,
                .diag => |diag| switch (diag) {
                    inline else => |payload, tag| {
                        if (tag != .Help) try writer.print("error.{t}: ", .{tag});
                        switch (tag) {
                            .Help => {
                                try writeHelp(writer, .{});
                                try writer.flush();
                                std.process.exit(0);
                            },
                            .NoArgumentValue,
                            .UnexpectedArgument,
                            => try writer.writeAll(payload),
                            .UnexpectedSubcommand => try writer.writeAll(payload),
                            .UnexpectedArgumentValue => try writer.print("--{s} cannot be equal to {s}", .{ payload[0], payload[1] }),
                            .PresentNamedArgumentExclude => try writer.print("--{s} excludes --{s} {s}", .{ payload[0], payload[1], payload[2] }),
                            .MissingNamedArgumentDependencies => try writer.print("--{s}", .{payload}),
                        }
                        try writer.writeAll("\n\n");
                        try writeUsage(writer);
                        try writer.flush();
                        std.process.exit(2);
                    },
                },
            };
        }

        /// Free command-line process arguments that were accumulated.
        pub fn free(self: *Self, allocator: std.mem.Allocator) void {
            if (HAS_OPTIONS) {
                inline for (cli.options) |param| {
                    if (@hasField(@TypeOf(param), "capacity")) {
                        @field(self.options, param.long).deinit(allocator);
                    }
                }
            }
            if (HAS_POSITIONALS) {
                inline for (cli.positionals) |param| {
                    if (@hasField(@TypeOf(param), "capacity")) {
                        @field(self.positionals, @tagName(param.meta)).deinit(allocator);
                    }
                }
            }
            if (HAS_SUBCOMMANDS) {
                if (self.subcommands_opt) |*subcommands| {
                    switch (subcommands.*) {
                        inline else => |*sc| sc.free(allocator),
                    }
                }
            }
        }

        /// Parse arguments from slice for testing.
        fn parseFromSlice(
            allocator: std.mem.Allocator,
            arg_strs: []const [:0]const u8,
            writer: *std.Io.Writer,
            opts: ParseOptions,
        ) Error!ParseCommandResult {
            var arg_str_iter: ArgIterator = .{ .arg_strs = arg_strs };
            return parseCommand(allocator, &arg_str_iter, writer, opts);
        }

        /// Parse command arguments.
        fn parseCommand(
            allocator: std.mem.Allocator,
            arg_str_iter: anytype,
            writer: *std.Io.Writer,
            opts: ParseOptions,
        ) Error!ParseCommandResult {
            // Initialize default values
            var self: Self = undefined;
            if (HAS_OPTIONS) {
                inline for (cli.options) |param| {
                    const Param = @TypeOf(param);
                    if (@hasField(Param, "capacity")) {
                        @field(self.options, param.long) = try .initCapacity(allocator, param.capacity);
                    } else if (@hasField(Param, "default")) {
                        @field(self.options, param.long) = param.default;
                    } else if (param.type[0] == '?') {
                        @field(self.options, param.long) = null;
                    }
                }
            }
            if (HAS_FLAGS) {
                inline for (cli.flags) |param| {
                    if (@hasField(@TypeOf(param), "capacity")) {
                        @field(self.flags, param.long) = 0;
                    } else {
                        @field(self.flags, param.long) = false;
                    }
                }
            }
            if (HAS_POSITIONALS) {
                inline for (cli.positionals) |param| {
                    const Param = @TypeOf(param);
                    if (@hasField(Param, "capacity")) {
                        @field(self.positionals, @tagName(param.meta)) = try .initCapacity(allocator, param.capacity);
                    } else if (@hasField(Param, "default")) {
                        @field(self.positionals, @tagName(param.meta)) = param.default;
                    }
                }
            }
            self.subcommands_opt = null;

            // Store peeked argument
            var peeked_opt: ?[:0]const u8 = null;

            // Parse named arguments
            if (Long != void) {
                // Track parsed long name enum literals with possible enum value strings
                // in order to check against dependencies and excludes later
                var arg_map: std.AutoArrayHashMapUnmanaged(Long, [:0]const u8) = .empty;
                defer if (opts.is_gpa) arg_map.deinit(allocator);
                if (DEPENDENCY_MAP.kvs.len > 0 or EXCLUDE_MAP.kvs.len > 0) {
                    try arg_map.ensureTotalCapacity(allocator, @typeInfo(Long).@"enum".fields.len);
                }

                while (arg_str_iter.next()) |arg_str| {
                    // Break on positional argument or single-character
                    if (arg_str[0] != '-' or arg_str.len == 1) {
                        peeked_opt = arg_str;
                        break;
                    }

                    // Check for help argument
                    if (checkHelp(arg_str)) {
                        return .{ .diag = .Help };
                    }

                    // Parse name
                    const arg_name = if (arg_str.len == 2) arg_str[1..] else arg_str[2..];
                    const is_negated = std.mem.startsWith(u8, arg_name, "no-");
                    const name = if (is_negated) arg_name[3..] else arg_name;

                    // Look for short or long name
                    const long = blk: {
                        break :blk if (name.len == 1) SHORT_LONG_MAP.get(name) else std.meta.stringToEnum(Long, name);
                    } orelse return .{ .diag = .{ .UnexpectedArgument = arg_name } };

                    // Parse value
                    switch (long) {
                        inline else => |long_tag| {
                            const option_idx = @backingInt(long_tag);
                            const long_str = @tagName(long_tag);
                            const T = if (HAS_OPTIONS and option_idx < cli.options.len)
                                StringToType(cli.options[option_idx].type)
                            else
                                bool;
                            const Base = switch (@typeInfo(T)) {
                                .optional => |optional| optional.child,
                                else => T,
                            };
                            const flag_idx = if (T == bool)
                                if (HAS_OPTIONS) option_idx - cli.options.len else option_idx
                            else
                                option_idx;
                            if (is_negated) {
                                if (!@hasField(@TypeOf(if (T == bool) cli.flags[flag_idx] else cli.options[option_idx]), "with_no")) {
                                    return .{ .diag = .{ .UnexpectedArgument = arg_name } };
                                } else if (T == bool) {
                                    if (@hasField(@TypeOf(cli.flags[flag_idx]), "capacity")) {
                                        @field(self.flags, long_str) = 0;
                                    } else {
                                        @field(self.flags, long_str) = false;
                                    }
                                } else if (@typeInfo(T) == .optional) {
                                    @field(self.options, long_str) = null;
                                } else if (@hasField(@TypeOf(cli.options[option_idx]), "capacity")) {
                                    @field(self.options, long_str).clearRetainingCapacity();
                                }
                            } else if (T == bool) {
                                if (@hasField(@TypeOf(cli.flags[flag_idx]), "capacity")) {
                                    @field(self.flags, long_str) += 1;
                                } else {
                                    @field(self.flags, long_str) = true;
                                }
                                if ((DEPENDENCY_MAP.kvs.len > 0 or EXCLUDE_MAP.kvs.len > 0) and
                                    !arg_map.contains(long))
                                {
                                    arg_map.putAssumeCapacity(long, "");
                                }
                            } else {
                                const value_str = arg_str_iter.next();
                                const value = switch (try parseValue(T, long_str, value_str)) {
                                    .value => |value| value,
                                    .diag => |diag| return .{ .diag = diag },
                                };
                                if (@hasField(@TypeOf(cli.options[option_idx]), "capacity")) {
                                    @field(self.options, long_str).appendAssumeCapacity(value);
                                } else {
                                    @field(self.options, long_str) = value;
                                }
                                if ((DEPENDENCY_MAP.kvs.len > 0 or EXCLUDE_MAP.kvs.len > 0) and
                                    (!arg_map.contains(long) or @typeInfo(Base) == .@"enum"))
                                {
                                    arg_map.putAssumeCapacity(long, if (@typeInfo(Base) == .@"enum") value_str.? else "");
                                }
                            }
                        },
                    }
                }

                // Check parsed long names with possible enum value strings against dependencies
                var prev_dependent_opt: ?[:0]const u8 = null;
                var is_prev_dependency_present = false;
                outer: for (DEPENDENCY_MAP.keys(), DEPENDENCY_MAP.values()) |key, value| {
                    const dependent_long_str: [:0]const u8 = @ptrCast(key);
                    if (prev_dependent_opt) |prev_dependent| {
                        if (prev_dependent.ptr != dependent_long_str.ptr) {
                            if (!is_prev_dependency_present) {
                                return .{ .diag = .{ .MissingNamedArgumentDependencies = prev_dependent } };
                            }
                            is_prev_dependency_present = false;
                        } else if (is_prev_dependency_present) continue;
                    }
                    const dependency_long = value.long;
                    const dependency_values_str = value.values_str;
                    if (arg_map.contains(std.meta.stringToEnum(Long, dependent_long_str).?)) {
                        prev_dependent_opt = dependent_long_str;
                        if (arg_map.get(dependency_long)) |arg_value_str| {
                            if (dependency_values_str.len > 0) {
                                var dependency_value_str_iter = std.mem.tokenizeScalar(u8, dependency_values_str, ' ');
                                while (dependency_value_str_iter.next()) |dependency_value_str| {
                                    if (std.mem.eql(u8, arg_value_str, dependency_value_str)) {
                                        is_prev_dependency_present = true;
                                        continue :outer;
                                    }
                                }
                                is_prev_dependency_present = false;
                            } else is_prev_dependency_present = true;
                        } else is_prev_dependency_present = false;
                    } else is_prev_dependency_present = true;
                }
                if (prev_dependent_opt) |prev_dependent| {
                    if (!is_prev_dependency_present) {
                        return .{ .diag = .{ .MissingNamedArgumentDependencies = prev_dependent } };
                    }
                }

                // Check parsed long names with possible enum value strings against excludes
                inline for (comptime EXCLUDE_MAP.keys(), comptime EXCLUDE_MAP.values()) |key, value| {
                    const excluding_long_str: [:0]const u8 = @ptrCast(key);
                    const excluded_long = value.long;
                    const excluded_values_str = value.values_str;
                    if (arg_map.contains(std.meta.stringToEnum(Long, excluding_long_str).?)) {
                        if (arg_map.get(excluded_long)) |arg_value_str| {
                            if (excluded_values_str.len > 0) {
                                var excluded_value_str_iter = std.mem.tokenizeScalar(u8, excluded_values_str, ' ');
                                while (excluded_value_str_iter.next()) |excluded_value_str| {
                                    if (std.mem.eql(u8, arg_value_str, excluded_value_str)) {
                                        return .{ .diag = .{ .PresentNamedArgumentExclude = .{
                                            excluding_long_str,
                                            @tagName(excluded_long),
                                            excluded_values_str,
                                        } } };
                                    }
                                }
                            } else return .{ .diag = .{ .PresentNamedArgumentExclude = .{
                                excluding_long_str,
                                @tagName(excluded_long),
                                "",
                            } } };
                        }
                    }
                }

                // Append default option values if none were accumulated
                if (HAS_OPTIONS) {
                    inline for (cli.options) |param| {
                        const Param = @TypeOf(param);
                        if (@hasField(Param, "capacity") and
                            @hasField(Param, "default") and
                            @field(self.options, param.long).items.len == 0)
                        {
                            @field(self.options, param.long).appendAssumeCapacity(param.default);
                        }
                    }
                }
            }

            // Parse positional arguments
            if (Positionals != void) blk: {
                comptime var i: usize = 0;
                inline while (i < cli.positionals.len) : (i += 1) {
                    const param = cli.positionals[i];
                    const Param = @TypeOf(param);
                    var value = switch (try parseValue(
                        StringToType(param.type),
                        @tagName(param.meta),
                        peeked_opt orelse arg_str_iter.next(),
                    )) {
                        .value => |value| value,
                        .diag => |diag| switch (diag) {
                            .NoArgumentValue => if (@hasField(Param, "default")) param.default else return .{ .diag = diag },
                            else => return .{ .diag = diag },
                        },
                    };
                    peeked_opt = arg_str_iter.next();
                    if (@hasField(Param, "capacity")) {
                        @field(self.positionals, @tagName(param.meta)).appendAssumeCapacity(value);
                        while (peeked_opt) |peeked| : (peeked_opt = arg_str_iter.next()) {
                            if (peeked[0] == '-') {
                                if (peeked[1] == '-' and peeked.len == 2) {
                                    peeked_opt = arg_str_iter.next();
                                    break;
                                } else break :blk;
                            }
                            value = switch (try parseValue(StringToType(param.type), @tagName(param.meta), peeked)) {
                                .value => |next_value| next_value,
                                .diag => |diag| return .{ .diag = diag },
                            };
                            @field(self.positionals, @tagName(param.meta)).appendAssumeCapacity(value);
                        }
                    } else {
                        @field(self.positionals, @tagName(param.meta)) = value;
                    }
                }
            }

            // Parse subcommand
            if (peeked_opt orelse arg_str_iter.next()) |arg_str| blk: {
                if (checkHelp(arg_str)) {
                    return .{ .diag = .Help };
                }
                if (Subcommands != void) {
                    if (std.meta.stringToEnum(std.meta.FieldEnum(Subcommands), arg_str)) |sc_arg| {
                        switch (sc_arg) {
                            inline else => |sc| {
                                const Args = CommandArgs(cli.subcommands[@backingInt(sc)], cli_opts);
                                const command = switch (try Args.parseCommand(allocator, arg_str_iter, writer, opts)) {
                                    .self => |command| command,
                                    .diag => |diag| return .{ .diag = diag },
                                };
                                self.subcommands_opt = @unionInit(Subcommands, @tagName(sc), command);
                                break :blk;
                            },
                        }
                    }
                    return .{ .diag = .{ .UnexpectedSubcommand = arg_str } };
                }
            }

            return .{ .self = self };
        }

        fn parseValue(
            comptime T: type,
            comptime arg_name: [:0]const u8,
            peeked_opt: ?[:0]const u8,
        ) Error!union(enum) {
            value: T,
            diag: Diagnostic,
        } {
            const Base = switch (@typeInfo(T)) {
                .optional => |optional| optional.child,
                else => T,
            };
            const value_str = switch (@typeInfo(Base)) {
                .@"enum", .int, .float, .pointer => blk: {
                    const value_str = peeked_opt orelse return .{ .diag = .{ .NoArgumentValue = arg_name } };
                    if (value_str[0] == '-') {
                        if (checkHelp(value_str)) {
                            return .{ .diag = .Help };
                        }
                        return .{ .diag = .{ .NoArgumentValue = arg_name } };
                    }
                    break :blk value_str;
                },
                else => unexpectedType(@typeName(T)),
            };
            return .{ .value = switch (@typeInfo(Base)) {
                .@"enum" => std.meta.stringToEnum(Base, value_str) orelse
                    return .{ .diag = .{ .UnexpectedArgumentValue = .{ arg_name, value_str } } },
                .int => try std.fmt.parseInt(Base, value_str, 0),
                .float => try std.fmt.parseFloat(Base, value_str),
                .pointer => value_str,
                else => unexpectedType(@typeName(T)),
            } };
        }

        fn checkHelp(arg_str: [:0]const u8) bool {
            return std.mem.eql(u8, arg_str, "-h") or std.mem.eql(u8, arg_str, "--help");
        }

        /// Write usage.
        pub fn writeUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("usage: {s}", .{cli.name});
            try writeUsageCommand(cli, "       ", writer);
            try writer.writeAll("\n-h, --help for more info\n");
        }

        fn writeUsageCommand(comptime command: anytype, comptime prefix: [:0]const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (@hasField(@TypeOf(command), "options")) {
                inline for (command.options) |param| {
                    const Param = @TypeOf(param);
                    const fmt = if (@hasField(Param, "short"))
                        " [-{c} <{s}>" ++ if (@hasField(Param, "capacity")) "...]" else "]"
                    else
                        " [--{s} <{s}>" ++ if (@hasField(Param, "capacity")) "...]" else "]";
                    const args = if (@hasField(Param, "short"))
                        .{ param.short, param.type }
                    else
                        .{ param.long, param.type };
                    try writer.print(fmt, args);
                }
            }
            if (@hasField(@TypeOf(command), "flags")) {
                inline for (command.flags) |param| {
                    const Param = @TypeOf(param);
                    const fmt = if (@hasField(Param, "short")) " [-{c}]" else " [--{s}]";
                    const args = if (@hasField(Param, "short")) .{param.short} else .{param.long};
                    try writer.print(fmt, args);
                }
            }
            if (@hasField(@TypeOf(command), "positionals")) {
                inline for (command.positionals) |param| {
                    const Param = @TypeOf(param);
                    const fmt = " <{s}" ++ if (@hasField(Param, "capacity")) "...>" else ">";
                    const args = .{param.type};
                    try writer.print(fmt, args);
                }
            }
            if (@hasField(@TypeOf(command), "subcommands")) {
                inline for (command.subcommands, 1..) |sc, i| {
                    try writer.writeByte('\n');
                    try writer.writeAll(prefix);
                    const is_last = i == command.subcommands.len;
                    const new_prefix = prefix ++ if (is_last) "    " else "│   ";
                    try writer.print((if (is_last) "└──" else "├──") ++ " {s}", .{sc.name});
                    try writeUsageCommand(sc, new_prefix, writer);
                }
            }
        }

        /// Write help.
        pub fn writeHelp(writer: *std.Io.Writer, opts: HelpOptions) std.Io.Writer.Error!void {
            // Write header
            try writer.print("Usage: {s}", .{cli.name});
            if (HAS_OPTIONS) {
                try writer.writeAll(" [options]");
            }
            if (HAS_FLAGS) {
                try writer.writeAll(" [flags]");
            }
            if (HAS_POSITIONALS) {
                try writer.writeAll(" [positionals]");
            }
            if (HAS_SUBCOMMANDS) {
                try writer.writeAll(" [subcommands]");
            }
            try writer.writeByte('\n');

            // Write version
            try writer.print("\nVersion: {f}\n", .{cli_opts.version});

            // Write description
            if (@hasField(Cli, "description")) {
                try writer.print("\n{s}\n", .{addDot(cli.description)});
            }

            try writeHelpCommand(cli, writer, opts);
        }

        fn writeHelpCommand(comptime command: anytype, writer: *std.Io.Writer, opts: HelpOptions) std.Io.Writer.Error!void {
            const Command = @TypeOf(command);
            var is_empty = true;

            // Write note
            if (@hasField(Command, "note")) {
                try writer.writeByte('\n');
                var note_line_iter = std.mem.tokenizeScalar(u8, command.note, '\n');
                while (note_line_iter.next()) |note_line| {
                    try writer.splatByteAll(' ', opts.padding);
                    try writer.print("{s}\n", .{note_line});
                }
            }

            // Write options
            if (@hasField(Command, "options") and command.options.len > 0) {
                is_empty = false;
                try writer.writeByte('\n');
                try writer.splatByteAll(' ', opts.padding);
                try writer.writeAll("Options:\n");
                try writeHelpCommandParams(command.options, writer, opts);
            }

            // Write flags
            if (@hasField(Command, "flags") and command.flags.len > 0) {
                is_empty = false;
                try writer.writeByte('\n');
                try writer.splatByteAll(' ', opts.padding);
                try writer.writeAll("Flags:\n");
                try writeHelpCommandParams(command.flags, writer, opts);
            }

            // Write positionals
            if (@hasField(Command, "positionals") and command.positionals.len > 0) {
                is_empty = false;
                try writer.writeByte('\n');
                try writer.splatByteAll(' ', opts.padding);
                try writer.writeAll("Positionals:\n");
                try writeHelpCommandParams(command.positionals, writer, opts);
            }

            // Write subcommands
            if (@hasField(Command, "subcommands") and command.subcommands.len > 0) {
                is_empty = false;
                try writer.writeByte('\n');
                try writer.splatByteAll(' ', opts.padding);
                try writer.writeAll("Subcommands:");
                inline for (command.subcommands) |sc| {
                    try writer.writeByte('\n');
                    try writer.splatByteAll(' ', opts.padding);
                    const sc_fmt = "  {s}";
                    const sc_args = .{sc.name};
                    try writer.print(sc_fmt, sc_args);
                    if (@hasField(@TypeOf(sc), "description")) {
                        const count = std.fmt.count(sc_fmt, sc_args);
                        try writer.splatByteAll(' ', opts.desc_start_idx -| opts.padding -| count);
                        try writer.print("{s}", .{addDot(sc.description)});
                    }
                    try writeHelpCommand(sc, writer, .{
                        .desc_start_idx = opts.desc_start_idx,
                        .padding = opts.padding + 4,
                    });
                }
            }

            // Write next line if command is empty
            if (is_empty) try writer.writeByte('\n');
        }

        fn writeHelpCommandParams(comptime params: anytype, writer: *std.Io.Writer, opts: HelpOptions) std.Io.Writer.Error!void {
            inline for (params) |param| {
                const Param = @TypeOf(param);
                const is_positional = @hasField(Param, "meta");
                const T = if (@hasField(Param, "type")) StringToType(param.type) else bool;
                const Base = switch (@typeInfo(T)) {
                    .optional => |optional| optional.child,
                    else => T,
                };

                // Keep character count to determine description start
                var count: u64 = 0;

                // Write name
                if (@hasField(Param, "short")) {
                    const fmt = "  -{c}, --{s}" ++ if (T == bool) "{s}" else " <{s}>";
                    const args = .{ param.short, param.long, if (T == bool) "" else param.type };
                    try writer.splatByteAll(' ', opts.padding);
                    try writer.print(fmt, args);
                    count += std.fmt.count(fmt, args);
                } else {
                    const fmt = if (is_positional) "  {s} <{s}>" else if (T == bool) "  --{s}{s}" else "  --{s} <{s}>";
                    const args = .{ if (is_positional) @tagName(param.meta) else param.long, if (T == bool) "" else param.type };
                    try writer.splatByteAll(' ', opts.padding);
                    try writer.print(fmt, args);
                    count += std.fmt.count(fmt, args);
                }

                // Write capacity
                if (@hasField(Param, "capacity")) {
                    const fmt = "...[{d}]";
                    const args = .{param.capacity};
                    count += std.fmt.count(fmt, args);
                    try writer.print(fmt, args);
                }

                // Write default value
                if (@hasField(Param, "default")) {
                    const fmt = switch (@typeInfo(Base)) {
                        .int, .float => " (={d})",
                        .pointer, .@"enum" => " (={s})",
                        else => unexpectedType(param.type),
                    };
                    const args = .{if (@typeInfo(Base) == .@"enum") @tagName(param.default) else param.default};
                    count += std.fmt.count(fmt, args);
                    try writer.print(fmt, args);
                }

                // Write description
                if (@hasField(Param, "description")) {
                    try writer.splatByteAll(' ', opts.desc_start_idx -| opts.padding -| count);
                    try writer.writeAll(addDot(param.description));
                }
                try writer.writeByte('\n');

                // Write note
                if (@hasField(Param, "note")) {
                    var note_line_iter = std.mem.tokenizeScalar(u8, param.note, '\n');
                    while (note_line_iter.next()) |note_line| {
                        try writer.splatByteAll(' ', opts.padding + 4);
                        try writer.print("{s}\n", .{note_line});
                    }
                }

                // Write enum literals
                if (@typeInfo(Base) == .@"enum") {
                    try writer.splatByteAll(' ', opts.padding + 4);
                    try writer.writeAll("Values:\n");
                    for (std.meta.fieldNames(Base)) |name| {
                        try writer.splatByteAll(' ', opts.padding + 6);
                        try writer.print("{s}\n", .{name});
                    }
                }

                // Write dependencies
                if (@hasField(Param, "dependencies")) {
                    try writer.splatByteAll(' ', opts.padding + 4);
                    try writer.writeAll("Dependencies:\n");
                    inline for (param.dependencies) |dep| {
                        try writer.splatByteAll(' ', opts.padding + 6);
                        try writer.print("--{s}\n", .{dep});
                    }
                }

                // Write excludes
                if (@hasField(Param, "excludes")) {
                    try writer.splatByteAll(' ', opts.padding + 4);
                    try writer.writeAll("Excludes:\n");
                    inline for (param.excludes) |exclude| {
                        try writer.splatByteAll(' ', opts.padding + 6);
                        try writer.print("--{s}\n", .{exclude});
                    }
                }

                // Write opposite long name
                if (@hasField(Param, "with_no")) {
                    count = 0;
                    const fmt = "  --no-{s}";
                    const args = .{param.long};
                    count += std.fmt.count(fmt, args);
                    try writer.splatByteAll(' ', opts.padding);
                    try writer.print(fmt, args);

                    // Write opposite description
                    if (@hasField(Param, "description")) {
                        try writer.splatByteAll(' ', opts.desc_start_idx -| opts.padding -| count);
                        // Write "with_no" string
                        try writer.writeAll(param.with_no);
                        // Skip possible parenthesis block at the beginning
                        const start_idx = blk: {
                            var start_idx: usize = 0;
                            if (param.description[0] == '(') {
                                if (std.mem.indexOfPos(u8, param.description, 1, ") ")) |idx| {
                                    start_idx = idx + 2;
                                }
                            }
                            break :blk start_idx;
                        };
                        // Find description's second word
                        if (std.mem.indexOfScalarPos(u8, param.description, start_idx, ' ')) |space_idx| {
                            try writer.writeByte(' ');
                            // Write description's second word's first byte as lowercase
                            const word2_byte1 = param.description[space_idx + 1];
                            try writer.writeByte(if (param.description[0] == '(') std.ascii.toLower(word2_byte1) else word2_byte1);
                            // Skip possible parenthesis block at the end
                            const end_idx = blk: {
                                var end_idx: usize = param.description.len;
                                if (param.description[param.description.len - 1] == ')') {
                                    if (std.mem.lastIndexOf(u8, param.description, " (")) |idx| {
                                        end_idx = idx;
                                    }
                                }
                                break :blk end_idx;
                            };
                            // Write description after second word's first byte but before possible parenthesis block at the end
                            try writer.writeAll(param.description[space_idx + 2 .. end_idx]);
                            if (cli_opts.add_desc_dot) try writer.writeByte('.');
                        } else {
                            try writer.writeAll(addDot(""));
                        }
                    }
                    try writer.writeByte('\n');
                }
            }
        }

        /// Format arguments for testing (all values must be initialized).
        pub fn format(self: Self, padding_opt: ?u8) std.fmt.Alt(Formatter, Formatter.format) {
            return .{ .data = .{ .command = self, .padding = padding_opt orelse 0 } };
        }

        const Formatter = struct {
            command: Self,
            padding: u8,

            fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                if (self.padding == 0) {
                    try writer.print("Arguments ({s} v{f}):\n", .{ cli.name, cli_opts.version });
                }
                var is_empty = true;

                // Write options
                if (Self.Options != void) {
                    is_empty = false;
                    try writer.writeByte('\n');
                    try writer.splatByteAll(' ', self.padding);
                    try writer.writeAll("Options:\n");
                    try formatArgs(self.command.options, self.padding, writer);
                }

                // Write flags
                if (Self.Flags != void) {
                    is_empty = false;
                    try writer.writeByte('\n');
                    try writer.splatByteAll(' ', self.padding);
                    try writer.writeAll("Flags:\n");
                    try formatArgs(self.command.flags, self.padding, writer);
                }

                // Write positionals
                if (Self.Positionals != void) {
                    is_empty = false;
                    try writer.writeByte('\n');
                    try writer.splatByteAll(' ', self.padding);
                    try writer.writeAll("Positionals:\n");
                    try formatArgs(self.command.positionals, self.padding, writer);
                }

                // Write subcommands
                if (Self.Subcommands != void) {
                    is_empty = false;
                    if (self.command.subcommands_opt) |subcommands| {
                        switch (subcommands) {
                            inline else => |sc, name| {
                                try writer.writeByte('\n');
                                try writer.splatByteAll(' ', self.padding);
                                try writer.print("Subcommand {t}:", .{name});
                                try writer.print("{f}", .{sc.format(self.padding + 2)});
                            },
                        }
                    }
                }

                // Write next line if command is empty
                if (is_empty) try writer.writeByte('\n');
            }
        };

        fn formatArgs(args: anytype, padding: u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |Arg| {
                try writer.splatByteAll(' ', padding);
                if (comptime std.mem.startsWith(u8, @typeName(Arg.type), "array_list")) {
                    const array = @field(args, Arg.name);
                    try writer.print("  {s}: [{d}]{s} = .{{", .{
                        Arg.name,
                        array.items.len,
                        @typeName(@typeInfo(@TypeOf(array.items)).pointer.child),
                    });
                    for (array.items, 0..) |value, i| {
                        try formatValue(value, i, writer);
                    }
                    if (array.items.len > 0) {
                        try writer.writeByte(' ');
                    }
                    try writer.writeByte('}');
                } else {
                    try writer.print("  {s}: {s} =", .{ Arg.name, @typeName(Arg.type) });
                    try formatValue(@as(Arg.type, @field(args, Arg.name)), 0, writer);
                }
                try writer.writeByte('\n');
            }
        }

        fn formatValue(value: anytype, i: usize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const T = @TypeOf(value);
            try writer.writeAll(if (i == 0) " " else ", ");
            try writer.print(switch (@typeInfo(T)) {
                .bool => "{}",
                .int, .float => "{d}",
                .@"enum" => ".{t}",
                .pointer => "\"{s}\"",
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .@"enum" => "{?}",
                    .int, .float => "{?d}",
                    .pointer => "{?s}",
                    else => unexpectedType(@typeName(T)),
                },
                else => unexpectedType(@typeName(T)),
            }, .{value});
        }

        fn addDot(comptime description: [:0]const u8) [:0]const u8 {
            return description ++ if (cli_opts.add_desc_dot) "." else "";
        }

        fn NamedArgs(comptime params: anytype) type {
            if (params.len == 0) {
                return void;
            }
            const num_fields = params.len;

            var field_names: [num_fields][]const u8 = undefined;
            var field_types: [num_fields]type = undefined;
            var field_attrs: [num_fields]Type.Struct.FieldAttributes = undefined;
            for (params, 0..) |param, i| {
                const Param = @TypeOf(param);
                validateLong(param.long);
                if (@hasField(Param, "short")) {
                    validateShort(param.short);
                }
                const T = if (@hasField(Param, "type")) blk: {
                    if (param.type[0] == 'b' or param.type[0] == '?' and param.type[1] == 'b') {
                        @compileError("Option must not be boolean: " ++ param.long);
                    }
                    if (@hasField(Param, "capacity")) {
                        if (param.type[0] == '?') {
                            @compileError("Accumulated option must not be nullable: " ++ param.long);
                        }
                    } else if (param.type[0] != '?' and @hasField(Param, "with_no")) {
                        @compileError("Non-accumulated opposite option must be nullable: " ++ param.long);
                    }
                    const Base = StringToType(param.type);
                    if (@hasField(Param, "default")) {
                        _ = @as(Base, param.default);
                    }
                    break :blk if (@hasField(Param, "capacity"))
                        std.ArrayList(Base)
                    else
                        Base;
                } else if (@hasField(Param, "capacity"))
                    std.math.IntFittingRange(0, param.capacity)
                else
                    bool;
                if (@hasField(Param, "default") and @typeInfo(T) == .optional and @as(T, param.default) == null) {
                    @compileError("Nullable option's default value must not be explicitly \"null\", since it is already \"null\" implicitly: " ++ param.long);
                }
                field_names[i] = param.long;
                field_types[i] = T;
                field_attrs[i] = .{
                    .@"comptime" = false,
                    .default_value_ptr = null,
                    .@"align" = @alignOf(T),
                };
            }
            return @Struct(
                .auto,
                null,
                &field_names,
                &field_types,
                &field_attrs,
            );
        }

        fn PositionalArgs(comptime params: anytype) type {
            if (params.len == 0) {
                return void;
            }
            const num_fields = params.len;

            var field_names: [num_fields][]const u8 = undefined;
            var field_types: [num_fields]type = undefined;
            var field_attrs: [num_fields]Type.Struct.FieldAttributes = undefined;
            for (params, 0..) |param, i| {
                const Param = @TypeOf(param);
                const meta_str = @tagName(param.meta);
                for (meta_str) |char| {
                    if (!std.ascii.isUpper(char) and !std.ascii.isDigit(char) and char != '_') {
                        @compileError("Meta name tag must be SCREAMING_SNAKE_CASE: " ++ meta_str);
                    }
                }
                if (param.type[0] == '?') {
                    @compileError("Positional must not be nullable: " ++ meta_str);
                }
                if (param.type[0] == 'b') {
                    @compileError("Positional must not be boolean: " ++ meta_str);
                }
                const T = blk: {
                    const Base = StringToType(param.type);
                    if (@hasField(Param, "default")) {
                        _ = @as(Base, param.default);
                    }
                    break :blk if (@hasField(Param, "capacity"))
                        std.ArrayList(Base)
                    else
                        Base;
                };
                field_names[i] = meta_str;
                field_types[i] = T;
                field_attrs[i] = .{
                    .@"comptime" = false,
                    .default_value_ptr = null,
                    .@"align" = @alignOf(T),
                };
            }
            return @Struct(
                .auto,
                null,
                &field_names,
                &field_types,
                &field_attrs,
            );
        }

        fn SubcommandArgs(comptime subcommands: anytype) type {
            if (subcommands.len == 0) {
                return void;
            }
            const num_fields = subcommands.len;

            var field_names: [num_fields][]const u8 = undefined;
            var field_types: [num_fields]type = undefined;
            var field_attrs: [num_fields]Type.UnionField.Attributes = undefined;
            for (subcommands, 0..) |sc, i| {
                const T = CommandArgs(sc, cli_opts);
                field_names[i] = sc.name;
                field_types[i] = T;
                field_attrs[i] = .{
                    .@"align" = @alignOf(T),
                };
            }
            return @Union(
                .auto,
                SubcommandArg(subcommands),
                &field_names,
                &field_types,
                &field_attrs,
            );
        }

        fn SubcommandArg(comptime subcommands: anytype) type {
            if (subcommands.len == 0) {
                return void;
            }
            const num_fields = subcommands.len;

            var field_names: [num_fields][]const u8 = undefined;
            for (subcommands, 0..num_fields) |sc, i| {
                field_names[i] = sc.name;
            }

            const TagInt: type = std.math.IntFittingRange(0, field_names.len - 1);
            return @Enum(
                TagInt,
                .exhaustive,
                &field_names,
                &std.simd.iota(TagInt, field_names.len),
            );
        }

        fn StringToType(comptime str: [:0]const u8) type {
            return switch (str[0]) {
                'b' => bool,
                'i' => if (str.ptr == "isize".ptr) isize else std.meta.Int(.signed, std.fmt.parseUnsigned(u8, str[1..], 10) catch unexpectedType(str)),
                'u' => if (str.ptr == "usize".ptr) usize else std.meta.Int(.unsigned, std.fmt.parseUnsigned(u8, str[1..], 10) catch unexpectedType(str)),
                'f' => std.meta.Float(std.fmt.parseUnsigned(u8, str[1..], 10) catch unexpectedType(str)),
                's' => [:0]const u8,
                '?' => switch (str[1]) {
                    'i' => if (str.ptr == "?isize".ptr) ?isize else ?@Int(.signed, std.fmt.parseUnsigned(
                        u8,
                        str[2..],
                        10,
                    ) catch unexpectedType(str)),
                    'u' => if (str.ptr == "?usize".ptr) ?usize else ?@Int(.unsigned, std.fmt.parseUnsigned(
                        u8,
                        str[2..],
                        10,
                    ) catch unexpectedType(str)),
                    'f' => ?std.meta.Float(std.fmt.parseUnsigned(
                        u8,
                        str[2..],
                        10,
                    ) catch unexpectedType(str)),
                    's' => ?[:0]const u8,
                    else => blk: {
                        for (cli_opts.enums) |E| {
                            if (std.mem.endsWith(u8, @typeName(E), str[1..])) {
                                break :blk ?E;
                            }
                        }
                        unexpectedType(str);
                    },
                },
                else => blk: {
                    for (cli_opts.enums) |E| {
                        if (std.mem.endsWith(u8, @typeName(E), str)) {
                            break :blk E;
                        }
                    }
                    unexpectedType(str);
                },
            };
        }
    };
}

const ArgIterator = struct {
    arg_strs: []const [:0]const u8,

    fn next(iter: *ArgIterator) ?[:0]const u8 {
        if (iter.arg_strs.len == 0) return null;
        defer iter.arg_strs = iter.arg_strs[1..];
        return iter.arg_strs[0];
    }
};

fn validateLong(comptime long: [:0]const u8) void {
    @setEvalBranchQuota(EVAL_BRANCH_QUOTA);
    if (long.len < 2) {
        @compileError("Long must consist of at least two characters: " ++ long);
    }
    if (long[0] == '-') {
        @compileError("Long must not start with '-': " ++ long);
    }
    if (std.mem.startsWith(u8, long, "no-")) {
        @compileError("Reserved long prefix \"no-\": " ++ long);
    }
    if (long.ptr == "help".ptr) {
        @compileError("Reserved long: " ++ long);
    }
    for (long) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') {
            @compileError("Long contains unsupported character: " ++ @as([1]u8, .{char}));
        }
    }
}

fn validateShort(comptime short: u8) void {
    @setEvalBranchQuota(EVAL_BRANCH_QUOTA);
    if (short == 'h') {
        @compileError("Reserved short: " ++ @as([1]u8, .{short}));
    }
    if (!std.ascii.isAlphanumeric(short)) {
        @compileError("Unsupported short: " ++ @as([1]u8, .{short}));
    }
}

fn unexpectedType(comptime str: [:0]const u8) noreturn {
    @compileError("Unexpected type: " ++ str);
}

test "all types nullable required" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
                .with_no = "no",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .with_no = "no",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .default = .foo,
                .with_no = "no",
            },
            .{
                .long = "string",
                .type = "?string",
                .with_no = "no",
            },
            .{
                .long = "f32",
                .type = "?f32",
                .with_no = "no",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(?u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(?Enum, @TypeOf(cli_args.options.@"enum"));
    try std.testing.expectEqual(?[:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(?f32, @TypeOf(cli_args.options.f32));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // All null
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--no-u32", "--no-string", "--no-bool", "--no-f32", "1", "hello", "foo", "10.1" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = null,
                .@"enum" = .foo,
                .string = null,
                .f32 = null,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 10.1,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "all types defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "u32",
                .default = 123,
            },
            .{
                .long = "enum",
                .type = "Enum",
                .default = .bar,
            },
            .{
                .long = "string",
                .type = "string",
                .default = "default",
            },
            .{
                .long = "f32",
                .type = "f32",
                .default = 123.456,
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.options.@"enum"));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.options.f32));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // All skipped
    {
        var args = try Args.parseFromSlice(gpa, &.{ "1", "hello", "foo", "5.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "default",
                .f32 = 123.456,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 5.5,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "all types defaults and nullable but not null" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
                .with_no = "no",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .default = 123,
                .with_no = "no",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .default = .foo,
                .with_no = "no",
            },
            .{
                .long = "string",
                .type = "?string",
                .default = "default",
                .with_no = "no",
            },
            .{
                .long = "f32",
                .type = "?f32",
                .default = 123.456,
                .with_no = "no",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(?u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(?Enum, @TypeOf(cli_args.options.@"enum"));
    try std.testing.expectEqual(?[:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(?f32, @TypeOf(cli_args.options.f32));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // All skipped
    {
        var args = try Args.parseFromSlice(gpa, &.{ "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .foo,
                .string = "default",
                .f32 = 123.456,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // All null
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--no-u32", "--no-string", "--no-bool", "--no-f32", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = null,
                .@"enum" = .foo,
                .string = null,
                .f32 = null,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "all types defaults and nullable and null" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
            },
            .{
                .long = "string",
                .type = "?string",
            },
            .{
                .long = "f32",
                .type = "?f32",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(3, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(?u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(?[:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(?f32, @TypeOf(cli_args.options.f32));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--string", "world", "--bool", "--f32", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // All skipped
    {
        var args = try Args.parseFromSlice(gpa, &.{ "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = null,
                .string = null,
                .f32 = null,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "all types required" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
                .short = 'b',
                .with_no = "no",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "u32",
                .short = 'u',
            },
            .{
                .long = "enum",
                .type = "Enum",
                .short = 'e',
            },
            .{
                .long = "string",
                .type = "string",
                .short = 's',
            },
            .{
                .long = "f32",
                .type = "f32",
                .short = 'f',
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.options.@"enum"));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.options.f32));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // Repeated args
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5", "--u32", "321", "--enum", "foo", "--string", "updated", "--no-bool", "--f32", "3.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = false,
            },
            .options = .{
                .u32 = 321,
                .@"enum" = .foo,
                .string = "updated",
                .f32 = 3.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // Short names args
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u", "321", "-e", "foo", "-s", "updated", "-b", "-f", "1.5", "1", "hello", "foo", "2.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 321,
                .@"enum" = .foo,
                .string = "updated",
                .f32 = 1.5,
            },
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 2.5,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "no args" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const cli = .{ .name = "command" };
    const Args = CommandArgs(cli, .{});
    try std.testing.expectEqual(Args.Options, void);
    try std.testing.expectEqual(Args.Positionals, void);
    try std.testing.expectEqual(Args.Subcommands, void);

    var args = try Args.parseFromSlice(gpa, &.{}, writer, .{});
    defer args.self.free(gpa);
    try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
        .flags = {},
        .options = {},
        .positionals = {},
        .subcommands_opt = null,
    } }, args);
}

test "only positional" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(Args.Options, void);
    try std.testing.expectEqual(4, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.U8));
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.positionals.STRING));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.positionals.ENUM));
    try std.testing.expectEqual(f32, @TypeOf(cli_args.positionals.F32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "1", "hello", "foo", "1.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = {},
            .options = {},
            .positionals = .{
                .U8 = 1,
                .STRING = "hello",
                .ENUM = .foo,
                .F32 = 1.5,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "only named" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const Enum = enum { foo, bar };
    const cli = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
            },
            .{
                .long = "enum",
                .type = "Enum",
            },
            .{
                .long = "string",
                .type = "?string",
            },
            .{
                .long = "f32",
                .type = "?f32",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{Enum} });
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Flags).@"struct".fields.len);
    try std.testing.expectEqual(4, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(Args.Positionals, void);
    try std.testing.expectEqual(Args.Subcommands, void);
    try std.testing.expectEqual(bool, @TypeOf(cli_args.flags.bool));
    try std.testing.expectEqual(?u32, @TypeOf(cli_args.options.u32));
    try std.testing.expectEqual(Enum, @TypeOf(cli_args.options.@"enum"));
    try std.testing.expectEqual(?[:0]const u8, @TypeOf(cli_args.options.string));
    try std.testing.expectEqual(?f32, @TypeOf(cli_args.options.f32));

    // All set
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--u32", "123", "--enum", "bar", "--string", "world", "--bool", "--f32", "1.5" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .bool = true,
            },
            .options = .{
                .u32 = 123,
                .@"enum" = .bar,
                .string = "world",
                .f32 = 1.5,
            },
            .positionals = {},
            .subcommands_opt = null,
        } }, args);
    }
}

test "help menu" {
    const Enum = enum { foo, bar };
    const no_help = .{
        .name = "command",
        .flags = .{
            .{
                .long = "bool",
                .with_no = "no",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .with_no = "no",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .with_no = "no",
            },
            .{
                .long = "string",
                .type = "?string",
                .with_no = "no",
            },
            .{
                .long = "float",
                .type = "?f32",
                .with_no = "no",
            },
            .{
                .long = "list",
                .type = "string",
                .capacity = 2,
                .with_no = "no",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
            },
            .{
                .meta = .STRING,
                .type = "string",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
            },
            .{
                .meta = .F32,
                .type = "f32",
            },
        },
    };

    const with_help = .{
        .name = "command",
        .description = "command help",
        .flags = .{
            .{
                .long = "bool",
                .description = "bool help",
                .with_no = "no bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .description = "u32 help",
                .with_no = "no u32",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .description = "enum help",
                .with_no = "no enum",
            },
            .{
                .long = "string",
                .type = "?string",
                .description = "string help",
                .with_no = "no string",
            },
            .{
                .long = "float",
                .type = "?f32",
                .description = "float help",
                .with_no = "no float",
            },
            .{
                .long = "list",
                .type = "string",
                .description = "string list help",
                .capacity = 2,
                .with_no = "no string",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
                .description = "u8 help",
            },
            .{
                .meta = .STRING,
                .type = "string",
                .description = "string help",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
                .description = "enum help",
            },
            .{
                .meta = .F32,
                .type = "f32",
                .description = "f32 help",
            },
        },
    };

    const with_help_with_defaults_optional = .{
        .name = "command",
        .description = "command help",
        .flags = .{
            .{
                .long = "bool",
                .description = "bool help",
                .with_no = "no bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .description = "u32 help",
                .default = 10,
                .with_no = "no u32",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .description = "enum help",
                .default = .foo,
                .with_no = "no enum",
            },
            .{
                .long = "string",
                .type = "?string",
                .description = "string help",
                .default = "foo",
                .with_no = "no string",
            },
            .{
                .long = "float",
                .type = "?f32",
                .description = "float help",
                .default = 1.5,
                .with_no = "no float",
            },
            .{
                .long = "list",
                .type = "string",
                .description = "string list help",
                .capacity = 2,
                .with_no = "no string",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
                .description = "u8 help",
            },
            .{
                .meta = .STRING,
                .type = "string",
                .description = "string help",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
                .description = "enum help",
            },
            .{
                .meta = .F32,
                .type = "f32",
                .description = "f32 help",
            },
        },
    };

    const with_help_with_defaults_optional_null = .{
        .name = "command",
        .description = "command help",
        .flags = .{
            .{
                .long = "bool",
                .description = "bool help",
                .with_no = "no bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .description = "u32 help",
                .with_no = "no u32",
            },
            .{
                .long = "string",
                .type = "?string",
                .description = "string help",
                .with_no = "no string",
            },
            .{
                .long = "float",
                .type = "?f32",
                .description = "float help",
                .with_no = "no float",
            },
            .{
                .long = "list",
                .type = "string",
                .description = "string list help",
                .capacity = 2,
                .with_no = "no string",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
                .description = "u8 help",
            },
            .{
                .meta = .STRING,
                .type = "string",
                .description = "string help",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
                .description = "enum help",
            },
            .{
                .meta = .F32,
                .type = "f32",
                .description = "f32 help",
            },
        },
    };

    const with_help_with_defaults = .{
        .name = "command",
        .description = "command help",
        .flags = .{
            .{
                .long = "bool",
                .description = "bool help",
                .with_no = "no bool",
            },
        },
        .options = .{
            .{
                .long = "u32",
                .type = "?u32",
                .description = "u32 help",
                .default = 10,
                .with_no = "no u32",
            },
            .{
                .long = "enum",
                .type = "?Enum",
                .description = "enum help",
                .default = .foo,
                .with_no = "no enum",
            },
            .{
                .long = "string",
                .type = "?string",
                .description = "string help",
                .default = "foo",
                .with_no = "no string",
            },
            .{
                .long = "float",
                .type = "?f32",
                .description = "float help",
                .default = 1.5,
                .with_no = "no float",
            },
            .{
                .long = "list",
                .type = "string",
                .description = "string list help",
                .capacity = 2,
                .with_no = "no string",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
                .description = "u8 help",
            },
            .{
                .meta = .STRING,
                .type = "string",
                .description = "string help",
            },
            .{
                .meta = .ENUM,
                .type = "Enum",
                .description = "enum help",
            },
            .{
                .meta = .F32,
                .type = "f32",
                .description = "f32 help",
            },
        },
    };

    const with_subcommand = .{
        .name = "command",
        .description = "command help",
        .flags = .{
            .{
                .long = "bool",
                .description = "bool help",
                .with_no = "no bool",
            },
        },
        .positionals = .{
            .{
                .meta = .U8,
                .type = "u8",
                .description = "u8 help",
            },
        },
        .subcommands = .{
            .{
                .name = "subcommand1",
                .description = "subcommand1 help",
                .flags = .{
                    .{
                        .long = "bool2",
                        .description = "bool2 help",
                        .with_no = "no bool2",
                    },
                },
                .subcommands = .{
                    .{
                        .name = "subcommand11",
                        .description = "subcommand11 help",
                        .flags = .{
                            .{
                                .long = "bool3",
                                .description = "bool3 help",
                                .with_no = "no bool3",
                            },
                        },
                        .subcommands = .{
                            .{
                                .name = "subcommand111",
                                .description = "subcommand111 help",
                                .flags = .{
                                    .{
                                        .long = "bool4",
                                        .description = "bool4 help",
                                        .with_no = "no bool4",
                                    },
                                },
                            },
                        },
                    },
                    .{
                        .name = "subcommand12",
                        .description = "subcommand12 help",
                        .flags = .{
                            .{
                                .long = "bool5",
                                .description = "bool5 help",
                                .with_no = "no bool5",
                            },
                        },
                    },
                },
            },
            .{
                .name = "subcommand2",
                .description = "subcommand2 help",
                .positionals = .{
                    .{
                        .meta = .U16,
                        .type = "u16",
                        .description = "u16 help",
                    },
                },
                .subcommands = .{
                    .{
                        .name = "subcommand21",
                        .description = "subcommand21 help",
                        .positionals = .{
                            .{
                                .meta = .U32,
                                .type = "u32",
                                .description = "u32 help",
                            },
                        },
                    },
                },
            },
        },
    };

    var buf: [MAX_BUF_SIZE]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try CommandArgs(no_help, .{ .enums = &.{Enum} }).writeUsage(&writer);
    try std.testing.expectEqualStrings(
        \\usage: command [--u32 <?u32>] [--enum <?Enum>] [--string <?string>] [--float <?f32>] [--list <string>...] [--bool] <u8> <string> <Enum> <f32>
        \\-h, --help for more info
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_help, .{ .enums = &.{Enum} }).writeUsage(&writer);
    try std.testing.expectEqualStrings(
        \\usage: command [--u32 <?u32>] [--enum <?Enum>] [--string <?string>] [--float <?f32>] [--list <string>...] [--bool] <u8> <string> <Enum> <f32>
        \\-h, --help for more info
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_subcommand, .{ .enums = &.{Enum} }).writeUsage(&writer);
    try std.testing.expectEqualStrings(
        \\usage: command [--bool] <u8>
        \\       ├── subcommand1 [--bool2]
        \\       │   ├── subcommand11 [--bool3]
        \\       │   │   └── subcommand111 [--bool4]
        \\       │   └── subcommand12 [--bool5]
        \\       └── subcommand2 <u16>
        \\           └── subcommand21 <u32>
        \\-h, --help for more info
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(no_help, .{ .enums = &.{Enum} }).writeHelp(&writer, .{});
    try std.testing.expectEqualStrings(
        \\Usage: command [options] [flags] [positionals]
        \\
        \\Version: 0.0.0
        \\
        \\Options:
        \\  --u32 <?u32>
        \\  --no-u32
        \\  --enum <?Enum>
        \\    Values:
        \\      foo
        \\      bar
        \\  --no-enum
        \\  --string <?string>
        \\  --no-string
        \\  --float <?f32>
        \\  --no-float
        \\  --list <string>...[2]
        \\  --no-list
        \\
        \\Flags:
        \\  --bool
        \\  --no-bool
        \\
        \\Positionals:
        \\  U8 <u8>
        \\  STRING <string>
        \\  ENUM <Enum>
        \\    Values:
        \\      foo
        \\      bar
        \\  F32 <f32>
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_help, .{ .enums = &.{Enum} }).writeHelp(&writer, .{ .desc_start_idx = 50 });
    try std.testing.expectEqualStrings(
        \\Usage: command [options] [flags] [positionals]
        \\
        \\Version: 0.0.0
        \\
        \\command help.
        \\
        \\Options:
        \\  --u32 <?u32>                                    u32 help.
        \\  --no-u32                                        no u32 help.
        \\  --enum <?Enum>                                  enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  --no-enum                                       no enum help.
        \\  --string <?string>                              string help.
        \\  --no-string                                     no string help.
        \\  --float <?f32>                                  float help.
        \\  --no-float                                      no float help.
        \\  --list <string>...[2]                           string list help.
        \\  --no-list                                       no string list help.
        \\
        \\Flags:
        \\  --bool                                          bool help.
        \\  --no-bool                                       no bool help.
        \\
        \\Positionals:
        \\  U8 <u8>                                         u8 help.
        \\  STRING <string>                                 string help.
        \\  ENUM <Enum>                                     enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  F32 <f32>                                       f32 help.
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_help_with_defaults_optional, .{ .enums = &.{Enum} }).writeHelp(&writer, .{ .desc_start_idx = 50 });
    try std.testing.expectEqualStrings(
        \\Usage: command [options] [flags] [positionals]
        \\
        \\Version: 0.0.0
        \\
        \\command help.
        \\
        \\Options:
        \\  --u32 <?u32> (=10)                              u32 help.
        \\  --no-u32                                        no u32 help.
        \\  --enum <?Enum> (=foo)                           enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  --no-enum                                       no enum help.
        \\  --string <?string> (=foo)                       string help.
        \\  --no-string                                     no string help.
        \\  --float <?f32> (=1.5)                           float help.
        \\  --no-float                                      no float help.
        \\  --list <string>...[2]                           string list help.
        \\  --no-list                                       no string list help.
        \\
        \\Flags:
        \\  --bool                                          bool help.
        \\  --no-bool                                       no bool help.
        \\
        \\Positionals:
        \\  U8 <u8>                                         u8 help.
        \\  STRING <string>                                 string help.
        \\  ENUM <Enum>                                     enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  F32 <f32>                                       f32 help.
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_help_with_defaults_optional_null, .{ .enums = &.{Enum} }).writeHelp(&writer, .{ .desc_start_idx = 50 });
    try std.testing.expectEqualStrings(
        \\Usage: command [options] [flags] [positionals]
        \\
        \\Version: 0.0.0
        \\
        \\command help.
        \\
        \\Options:
        \\  --u32 <?u32>                                    u32 help.
        \\  --no-u32                                        no u32 help.
        \\  --string <?string>                              string help.
        \\  --no-string                                     no string help.
        \\  --float <?f32>                                  float help.
        \\  --no-float                                      no float help.
        \\  --list <string>...[2]                           string list help.
        \\  --no-list                                       no string list help.
        \\
        \\Flags:
        \\  --bool                                          bool help.
        \\  --no-bool                                       no bool help.
        \\
        \\Positionals:
        \\  U8 <u8>                                         u8 help.
        \\  STRING <string>                                 string help.
        \\  ENUM <Enum>                                     enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  F32 <f32>                                       f32 help.
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_help_with_defaults, .{ .enums = &.{Enum} }).writeHelp(&writer, .{ .desc_start_idx = 50 });
    try std.testing.expectEqualStrings(
        \\Usage: command [options] [flags] [positionals]
        \\
        \\Version: 0.0.0
        \\
        \\command help.
        \\
        \\Options:
        \\  --u32 <?u32> (=10)                              u32 help.
        \\  --no-u32                                        no u32 help.
        \\  --enum <?Enum> (=foo)                           enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  --no-enum                                       no enum help.
        \\  --string <?string> (=foo)                       string help.
        \\  --no-string                                     no string help.
        \\  --float <?f32> (=1.5)                           float help.
        \\  --no-float                                      no float help.
        \\  --list <string>...[2]                           string list help.
        \\  --no-list                                       no string list help.
        \\
        \\Flags:
        \\  --bool                                          bool help.
        \\  --no-bool                                       no bool help.
        \\
        \\Positionals:
        \\  U8 <u8>                                         u8 help.
        \\  STRING <string>                                 string help.
        \\  ENUM <Enum>                                     enum help.
        \\    Values:
        \\      foo
        \\      bar
        \\  F32 <f32>                                       f32 help.
        \\
    , writer.buffered());
    _ = writer.consumeAll();

    try CommandArgs(with_subcommand, .{ .enums = &.{Enum} }).writeHelp(&writer, .{ .desc_start_idx = 50 });
    try std.testing.expectEqualStrings(
        \\Usage: command [flags] [positionals] [subcommands]
        \\
        \\Version: 0.0.0
        \\
        \\command help.
        \\
        \\Flags:
        \\  --bool                                          bool help.
        \\  --no-bool                                       no bool help.
        \\
        \\Positionals:
        \\  U8 <u8>                                         u8 help.
        \\
        \\Subcommands:
        \\  subcommand1                                     subcommand1 help.
        \\    Flags:
        \\      --bool2                                     bool2 help.
        \\      --no-bool2                                  no bool2 help.
        \\
        \\    Subcommands:
        \\      subcommand11                                subcommand11 help.
        \\        Flags:
        \\          --bool3                                 bool3 help.
        \\          --no-bool3                              no bool3 help.
        \\
        \\        Subcommands:
        \\          subcommand111                           subcommand111 help.
        \\            Flags:
        \\              --bool4                             bool4 help.
        \\              --no-bool4                          no bool4 help.
        \\
        \\      subcommand12                                subcommand12 help.
        \\        Flags:
        \\          --bool5                                 bool5 help.
        \\          --no-bool5                              no bool5 help.
        \\
        \\  subcommand2                                     subcommand2 help.
        \\    Positionals:
        \\      U16 <u16>                                   u16 help.
        \\
        \\    Subcommands:
        \\      subcommand21                                subcommand21 help.
        \\        Positionals:
        \\          U32 <u32>                               u32 help.
        \\
    , writer.buffered());
    _ = writer.consumeAll();
}

test "help and argument errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const cli = .{
        .name = "command",
        .options = .{
            .{
                .long = "named-1",
                .type = "?u8",
                .excludes = .{
                    "named-3 zon",
                },
            },
            .{
                .long = "named-2",
                .type = "?string",
                .excludes = .{
                    "flag",
                },
            },
            .{
                .long = "named-3",
                .type = "Mode",
            },
            .{
                .long = "named-4",
                .type = "string",
                .dependencies = .{
                    "named-3 zon",
                    "flag",
                },
            },
        },
        .flags = .{
            .{
                .long = "flag",
                .dependencies = .{
                    "named-3 zig",
                },
            },
        },
        .positionals = .{
            .{
                .meta = .POS1,
                .type = "string",
            },
            .{
                .meta = .POS2,
                .type = "f64",
            },
        },
    };

    const Args = CommandArgs(cli, .{ .enums = &.{std.zig.Ast.Mode} });

    // Help
    {
        const args = try Args.parseFromSlice(gpa, &.{"--help"}, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{"-h"}, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "--help" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "-h" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "--help" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "-h" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "--help" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "-h" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "baz", "--help" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "baz", "-h" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "baz", "3.14", "--help" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "baz", "3.14", "-h" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .Help }, args);
    }

    // NoArgumentValue
    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "--named-2", "bar", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .NoArgumentValue = "named-1" } }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "baz" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .NoArgumentValue = "POS2" } }, args);
    }

    // UnexpectedArgument
    const unexp_arg = "-f";
    {
        const args = try Args.parseFromSlice(gpa, &.{ unexp_arg, "--named-1", "42", "--named-2", "bar", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .UnexpectedArgument = unexp_arg[1..] } }, args);
    }

    // PresentNamedArgumentExclude
    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "--named-3", "zig", "--flag", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .PresentNamedArgumentExclude = .{ "named-2", "flag", "" } } }, args);
    }

    const exclude = "named-3 zon";
    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-3", "zon", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .PresentNamedArgumentExclude = .{ "named-1", "named-3", exclude[8..] } } }, args);
    }

    // MissingNamedArgumentDependencies
    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-2", "bar", "--named-4", "str", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .MissingNamedArgumentDependencies = "named-4" } }, args);
    }

    {
        const args = try Args.parseFromSlice(gpa, &.{ "--named-3", "zon", "--flag", "baz", "3.14" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .MissingNamedArgumentDependencies = "flag" } }, args);
    }

    // First dependency is present
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--named-2", "bar", "--named-3", "zon", "--named-4", "str", "baz", "3.14" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .flag = false,
            },
            .options = .{
                .@"named-1" = null,
                .@"named-2" = "bar",
                .@"named-3" = .zon,
                .@"named-4" = "str",
            },
            .positionals = .{
                .POS1 = "baz",
                .POS2 = 3.14,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // Second dependency present
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--named-1", "42", "--named-3", "zig", "--named-4", "str", "--flag", "baz", "3.14" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = .{
                .flag = true,
            },
            .options = .{
                .@"named-1" = 42,
                .@"named-2" = null,
                .@"named-3" = .zig,
                .@"named-4" = "str",
            },
            .positionals = .{
                .POS1 = "baz",
                .POS2 = 3.14,
            },
            .subcommands_opt = null,
        } }, args);
    }
}

test "lists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const cli = .{
        .name = "command",
        .options = .{
            .{
                .long = "list",
                .type = "string",
                .capacity = 2,
                .with_no = "no",
            },
        },
        .positionals = .{
            .{
                .meta = .LIST1,
                .type = "string",
                .capacity = 2,
            },
            .{
                .meta = .LIST2,
                .type = "u8",
                .capacity = 2,
            },
        },
        .subcommands = .{
            .{
                .name = "sub",
            },
        },
    };

    const Args = CommandArgs(cli, .{});
    {
        var args = (try Args.parseFromSlice(gpa, &.{ "foo", "bar", "--", "12", "34" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqualSlices([]const u8, &.{}, args.options.list.items);
        try std.testing.expectEqualSlices([]const u8, &.{ "foo", "bar" }, args.positionals.LIST1.items);
        try std.testing.expectEqualSlices(u8, &.{ 12, 34 }, args.positionals.LIST2.items);
    }

    {
        var args = (try Args.parseFromSlice(gpa, &.{ "--list", "foo", "--list", "bar", "foo", "bar", "--", "12", "34" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqualSlices([]const u8, &.{ "foo", "bar" }, args.options.list.items);
        try std.testing.expectEqualSlices([]const u8, &.{ "foo", "bar" }, args.positionals.LIST1.items);
        try std.testing.expectEqualSlices(u8, &.{ 12, 34 }, args.positionals.LIST2.items);
    }

    {
        var args = (try Args.parseFromSlice(gpa, &.{ "--list", "foo", "--list", "bar", "--no-list", "foo", "bar", "--", "12", "34" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqualSlices([]const u8, &.{}, args.options.list.items);
        try std.testing.expectEqualSlices([]const u8, &.{ "foo", "bar" }, args.positionals.LIST1.items);
        try std.testing.expectEqualSlices(u8, &.{ 12, 34 }, args.positionals.LIST2.items);
    }

    {
        var args = (try Args.parseFromSlice(gpa, &.{ "--list", "foo", "--list", "bar", "--no-list", "--list", "baz", "baz", "--", "123", "--", "sub" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqualSlices([]const u8, &.{"baz"}, args.options.list.items);
        try std.testing.expectEqualSlices([]const u8, &.{"baz"}, args.positionals.LIST1.items);
        try std.testing.expectEqualSlices(u8, &.{123}, args.positionals.LIST2.items);
        try std.testing.expect(args.subcommands_opt.? == .sub);
    }
}

test "subcommands and subcommand error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var stderr_buf: [MAX_BUF_SIZE]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const writer = &stderr_file_writer.interface;

    const cli = .{
        .name = "command",
        .options = .{
            .{
                .long = "foo",
                .type = "string",
            },
        },
        .positionals = .{
            .{
                .meta = .BAR,
                .type = "u8",
            },
        },
        .subcommands = .{
            .{
                .name = "sub1",
                .options = .{
                    .{
                        .long = "sub1a",
                        .type = "string",
                    },
                },
                .positionals = .{
                    .{
                        .meta = .SUB1B,
                        .type = "u8",
                    },
                },
                .subcommands = .{
                    .{
                        .name = "sub11",
                        .options = .{
                            .{
                                .long = "sub11a",
                                .type = "string",
                            },
                        },
                        .positionals = .{
                            .{
                                .meta = .SUB11B,
                                .type = "u8",
                            },
                        },
                    },
                },
            },
            .{
                .name = "sub2",
                .options = .{
                    .{
                        .long = "sub2a",
                        .type = "string",
                    },
                },
                .subcommands = .{
                    .{
                        .name = "sub21",
                        .options = .{
                            .{
                                .long = "sub21a",
                                .type = "string",
                            },
                        },
                    },
                },
            },
        },
    };

    const Args = CommandArgs(cli, .{});
    const cli_args: Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(1, @typeInfo(Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(2, @typeInfo(Args.Subcommands).@"union".fields.len);
    try std.testing.expectEqual([:0]const u8, @TypeOf(cli_args.options.foo));
    try std.testing.expectEqual(u8, @TypeOf(cli_args.positionals.BAR));

    const Sub1Args = CommandArgs(cli.subcommands[0], .{});
    const sub1_args: Sub1Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Sub1Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(1, @typeInfo(Sub1Args.Positionals).@"struct".fields.len);
    try std.testing.expectEqual(1, @typeInfo(Sub1Args.Subcommands).@"union".fields.len);
    try std.testing.expectEqual([:0]const u8, @TypeOf(sub1_args.options.sub1a));
    try std.testing.expectEqual(u8, @TypeOf(sub1_args.positionals.SUB1B));

    const Sub2Args = CommandArgs(cli.subcommands[1], .{});
    const sub2_args: Sub2Args = undefined;
    try std.testing.expectEqual(1, @typeInfo(Sub2Args.Options).@"struct".fields.len);
    try std.testing.expectEqual(Sub2Args.Positionals, void);
    try std.testing.expectEqual(1, @typeInfo(Sub2Args.Subcommands).@"union".fields.len);
    try std.testing.expectEqual([:0]const u8, @TypeOf(sub2_args.options.sub2a));

    // No subcommand
    {
        var args = try Args.parseFromSlice(gpa, &.{ "--foo", "foo", "10" }, writer, .{});
        defer args.self.free(gpa);
        try std.testing.expectEqual(Args.ParseCommandResult{ .self = .{
            .flags = {},
            .options = .{
                .foo = "foo",
            },
            .positionals = .{
                .BAR = 10,
            },
            .subcommands_opt = null,
        } }, args);
    }

    // Unexpected subcommand
    {
        const args = try Args.parseFromSlice(gpa, &.{ "--foo", "foo", "10", "non-sub" }, writer, .{});
        try std.testing.expectEqual(Args.ParseCommandResult{ .diag = .{ .UnexpectedSubcommand = "non-sub" } }, args);
    }

    // First subcommand
    {
        var args = (try Args.parseFromSlice(gpa, &.{ "--foo", "foo", "10", "sub1", "--sub1a", "nested", "24", "sub11", "--sub11a", "double nested", "42" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqual(Args{
            .flags = {},
            .options = .{
                .foo = "foo",
            },
            .positionals = .{
                .BAR = 10,
            },
            .subcommands_opt = .{
                .sub1 = .{
                    .flags = {},
                    .options = .{
                        .sub1a = "nested",
                    },
                    .positionals = .{
                        .SUB1B = 24,
                    },
                    .subcommands_opt = .{
                        .sub11 = .{
                            .flags = {},
                            .options = .{
                                .sub11a = "double nested",
                            },
                            .positionals = .{
                                .SUB11B = 42,
                            },
                            .subcommands_opt = null,
                        },
                    },
                },
            },
        }, args);
        try std.testing.expectFmt(
            \\Arguments (command v0.0.0):
            \\
            \\Options:
            \\  foo: [:0]const u8 = "foo"
            \\
            \\Positionals:
            \\  BAR: u8 = 10
            \\
            \\Subcommand sub1:
            \\  Options:
            \\    sub1a: [:0]const u8 = "nested"
            \\
            \\  Positionals:
            \\    SUB1B: u8 = 24
            \\
            \\  Subcommand sub11:
            \\    Options:
            \\      sub11a: [:0]const u8 = "double nested"
            \\
            \\    Positionals:
            \\      SUB11B: u8 = 42
            \\
        , "{f}", .{args.format(null)});
    }

    // Second subcommand
    {
        var args = (try Args.parseFromSlice(gpa, &.{ "--foo", "foo", "10", "sub2", "--sub2a", "nested2", "sub21", "--sub21a", "double nested2" }, writer, .{})).self;
        defer args.free(gpa);
        try std.testing.expectEqual(Args{
            .flags = {},
            .options = .{
                .foo = "foo",
            },
            .positionals = .{
                .BAR = 10,
            },
            .subcommands_opt = .{
                .sub2 = .{
                    .flags = {},
                    .options = .{
                        .sub2a = "nested2",
                    },
                    .positionals = {},
                    .subcommands_opt = .{
                        .sub21 = .{
                            .flags = {},
                            .options = .{
                                .sub21a = "double nested2",
                            },
                            .positionals = {},
                            .subcommands_opt = null,
                        },
                    },
                },
            },
        }, args);
        try std.testing.expectFmt(
            \\Arguments (command v0.0.0):
            \\
            \\Options:
            \\  foo: [:0]const u8 = "foo"
            \\
            \\Positionals:
            \\  BAR: u8 = 10
            \\
            \\Subcommand sub2:
            \\  Options:
            \\    sub2a: [:0]const u8 = "nested2"
            \\
            \\  Subcommand sub21:
            \\    Options:
            \\      sub21a: [:0]const u8 = "double nested2"
            \\
        , "{f}", .{args.format(null)});
    }
}
