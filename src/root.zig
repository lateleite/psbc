const std = @import("std");
const debug = std.debug;
const hash = std.hash;
const Io = std.Io;
const math = std.math;
const mem = std.mem;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const gnm = @import("gnm");
const psb = gnm.psb;

// const c = @import("c_mesa");
const c = @import("c_generated.zig");

pub fn globalInit() void {
    c.glsl_type_singleton_init_or_ref();
}

pub fn globalDeinit() void {
    c.glsl_type_singleton_decref();
}

pub const SystemOptions = packed struct {
    is_neo: bool,
};

pub fn getGfxLevel(options: SystemOptions) c_uint {
    return if (options.is_neo)
        c.GFX8 // Volcanic Islands/Polaris, used in NEO PS4
    else
        c.GFX7; // Sea Islands family, used in base PS4 model
}

pub fn getChipFamily(options: SystemOptions) c_uint {
    // these family values are guesses,
    // and shouldn't alter the resulting assembly at all
    return if (options.is_neo)
        c.CHIP_TONGA
    else
        c.CHIP_KAVERI;
}

pub fn getDefaultNirOptions(gfx_level: c_uint, chip_family: c_uint) c.nir_shader_compiler_options {
    const has_accelerated_dot_product =
        chip_family == c.CHIP_VEGA20 or
        (chip_family >= c.CHIP_MI100 and chip_family != c.CHIP_NAVI10);
    const io_options = c.nir_io_has_flexible_input_interpolation_except_flat |
        (if (gfx_level >= c.GFX8) c.nir_io_16bit_input_output_support else 0) |
        c.nir_io_prefer_scalar_fs_inputs |
        c.nir_io_mix_convergent_flat_with_interpolated |
        c.nir_io_vectorizer_ignores_types |
        c.nir_io_compaction_rotates_color_channels |
        c.nir_io_assign_color_input_bases_after_all_other_inputs |
        c.nir_io_use_frag_result_dual_src_blend |
        c.nir_io_compact_to_higher_16;

    return c.nir_shader_compiler_options{
        .vertex_id_zero_based = true,
        .lower_scmp = true,
        .lower_flrp16 = true,
        .lower_flrp32 = true,
        .lower_flrp64 = true,
        .lower_device_index_to_zero = true,
        .lower_fdiv = true,
        .lower_fmod = true,
        .lower_ineg = true,
        .lower_bitfield_insert = true,
        .lower_bitfield_extract = true,
        .lower_bitfield_extract16 = false,
        .lower_bitfield_extract8 = false,
        .lower_pack_snorm_4x8 = true,
        .lower_pack_unorm_4x8 = true,
        .lower_pack_half_2x16 = true,
        .lower_pack_64_2x32 = true,
        .lower_pack_64_4x16 = true,
        .lower_pack_32_2x16 = true,
        .lower_unpack_snorm_2x16 = true,
        .lower_unpack_snorm_4x8 = true,
        .lower_unpack_unorm_2x16 = true,
        .lower_unpack_unorm_4x8 = true,
        .lower_unpack_half_2x16 = true,
        .lower_fpow = true,
        .lower_mul_high16 = true,
        .lower_mul_2x32_64 = true,
        .lower_iadd_sat = gfx_level <= c.GFX8,
        .lower_hadd = true,
        .lower_mul_32x16 = true,
        .lower_bfloat16_conversions = true,
        .has_ldexp = true,
        .has_bfe = true,
        .has_bfm = true,
        .has_bitfield_select = true,
        .has_fneo_fcmpu = true,
        .has_ford_funord = true,
        .has_fsub = true,
        .has_isub = true,
        .has_sdot_4x8 = has_accelerated_dot_product,
        .has_sudot_4x8 = has_accelerated_dot_product and gfx_level >= c.GFX11,
        .has_udot_4x8 = has_accelerated_dot_product,
        .has_sdot_4x8_sat = has_accelerated_dot_product,
        .has_sudot_4x8_sat = has_accelerated_dot_product and gfx_level >= c.GFX11,
        .has_udot_4x8_sat = has_accelerated_dot_product,
        .has_dot_2x16 = has_accelerated_dot_product and gfx_level < c.GFX11,
        .has_bfdot2_bfadd = gfx_level >= c.GFX12,
        .has_find_msb_rev = true,
        .has_pack_32_4x8 = true,
        .has_pack_half_2x16_rtz = true,
        .has_bit_test = true,
        .has_fmulz = true,
        .has_msad = true,
        .has_shfr32 = true,
        .has_mul24_relaxed = true,
        .has_f2e4m3fn_satfn = gfx_level >= c.GFX12,
        .has_atomic_isub = true,
        .has_atomic_load_store = true,
        .lower_int64_options = c.nir_lower_imul64 | c.nir_lower_imul_high64 | c.nir_lower_imul_2x32_64 | c.nir_lower_divmod64 |
            c.nir_lower_minmax64 | c.nir_lower_iabs64 | c.nir_lower_iadd_sat64 | c.nir_lower_conv64 |
            c.nir_lower_bitfield_extract64,
        .divergence_analysis_options = c.nir_divergence_view_index_uniform,
        .support_indirect_inputs = c.BITFIELD_BIT(c.MESA_SHADER_TESS_CTRL) |
            c.BITFIELD_BIT(c.MESA_SHADER_TESS_EVAL),
        .support_indirect_outputs = c.BITFIELD_BIT(c.MESA_SHADER_TESS_CTRL) |
            c.BITFIELD_BIT(c.MESA_SHADER_MESH),
        .optimize_quad_vote_to_reduce = true,
        .lower_fisnormal = true,
        .support_16bit_alu = gfx_level >= c.GFX8,
        .vectorize_vec2_16bit = true,
        .discard_is_demote = true,
        .optimize_sample_mask_in = true,
        .optimize_load_front_face_fsign = true,
        .io_options = @bitCast(io_options),
        .lower_layer_fs_input_to_sysval = true,
        .scalarize_ddx = true,
        .coarse_ddx = true,
        .skip_lower_packing_ops = c.BITFIELD_BIT(c.nir_lower_packing_op_unpack_64_2x32) |
            c.BITFIELD_BIT(c.nir_lower_packing_op_unpack_64_4x16) |
            c.BITFIELD_BIT(c.nir_lower_packing_op_unpack_32_2x16) |
            c.BITFIELD_BIT(c.nir_lower_packing_op_pack_32_4x8) |
            c.BITFIELD_BIT(c.nir_lower_packing_op_unpack_32_4x8),
        .max_workgroup_invocations = 1024,
        .max_workgroup_count = @splat(math.maxInt(u32)),
        .max_samples = 8,
    };
}

pub const SpirvToNirError = error{
    NirCompilationFailed,
};

pub const SpirvToNirOptions = struct {
    entry_point: [:0]const u8,
    stage: MesaShaderStage,
    is_neo: bool = false,
    should_optimize: bool = false,
};

pub fn spirvToNir(
    input_spirv: []const u32,
    nir_options: *const c.nir_shader_compiler_options,
    options: SpirvToNirOptions,
) SpirvToNirError!*c.nir_shader {
    const gfx_level = getGfxLevel(.{ .is_neo = options.is_neo });
    return gnm_shader_spirv_to_nir(
        gfx_level,
        input_spirv.ptr,
        input_spirv.len * @sizeOf(u32),
        options.stage,
        nir_options,
        options.entry_point.ptr,
        !options.should_optimize,
    ) orelse error.NirCompilationFailed;
}

pub const OptimizeOptions = struct {
    should_optimize: bool = false,
};

pub fn optimize(
    nir: *c.nir_shader,
    options: OptimizeOptions,
) void {
    c.gnm_link_shader(nir);

    c.gnm_optimize_nir(nir, !options.should_optimize);

    // Gather info again, information such as outputs_read can be out-of-date.
    c.nir_shader_gather_info(nir, c.nir_shader_get_entrypoint(nir));
    c.gnm_nir_lower_io(nir);
}

pub const NirToGcnError = error{
    CodeLengthOverflow,
    HeaderLengthOverflow,
    UnimplementedShaderType,

    PixelInterpOverflow,
    PixelInputOverflow,
    VertexInputOverflow,
    VertexExportOverflow,
} || Io.Writer.Error;

pub const NirToGcnOptions = struct {
    stage: MesaShaderStage,
    is_neo: bool = false,
    should_optimize: bool = false,
    verbose: bool = false,
};

pub fn nirToGcn(
    nir: *c.nir_shader,
    writer: *Io.Writer,
    options: NirToGcnOptions,
) NirToGcnError!void {
    const gfx_level = getGfxLevel(.{ .is_neo = options.is_neo });
    const chip_family = getChipFamily(.{ .is_neo = options.is_neo });

    const compiler_info = fillCompilerInfo(gfx_level, chip_family);
    const compiler_opts: c.aco_compiler_options = .{
        .compiler_info = &compiler_info,
        .dump_preoptir = options.verbose,
        .optimisations_disabled = !options.should_optimize,
        .family = chip_family,
        .gfx_level = gfx_level,
    };

    var shader_info: c.gnm_shader_info = .{};
    c.gnm_nir_shader_info_init(@backingInt(options.stage), c.MESA_SHADER_NONE, &shader_info);

    c.gnm_nir_shader_info_pass(gfx_level, chip_family, nir, c.MESA_SHADER_NONE, false, &shader_info);

    var shader_args: c.gnm_shader_args = .{};
    gnm_declare_shader_args(gfx_level, &shader_info, options.stage, .none, &shader_args, null);

    shader_info.user_sgprs_locs = shader_args.user_sgprs_locs;
    shader_info.inline_push_constant_mask = shader_args.ac.inline_push_const_mask;

    const pipe_key: c.gnm_pipeline_key = .{
        .ps = .{
            .epilog = .{
                // TODO: user option for mrt format
                .spi_shader_col_format = c.V_028714_SPI_SHADER_FP16_ABGR,
                // TODO: another option to select between 8 and 10
                // bit colors?
                // is that even supported by the PS Quadruple?
                .color_is_int8 = 0xff,
            },
            .has_epilog = false,
        },
    };
    var aco_info: c.aco_shader_info = .{};
    c.gnm_aco_convert_shader_info(&aco_info, &shader_info, &shader_args, &pipe_key, gfx_level);

    c.gnm_postprocess_nir(
        gfx_level,
        chip_family,
        nir,
        &shader_args,
        &shader_info,
        &aco_info,
        &pipe_key,
        !options.should_optimize,
    );

    var build_ctx = BuildContext{
        .last_error = null,
        .writer = writer,
        .nir = nir,
        .shader_info = &shader_info,
        .shader_args = &shader_args,
        .shader_info_aco = &aco_info,
        .pipe_key = &pipe_key,
        .gfx_level = gfx_level,
        .family = chip_family,
        .stage = options.stage,
        .is_neo = options.is_neo,
    };
    aco_compile_shader(&compiler_opts, &aco_info, 1, &.{nir}, &shader_args.ac, &buildBinaryCallback, &build_ctx);

    if (build_ctx.last_error) |err|
        return err;
}

const BuildContext = struct {
    // outputs
    last_error: ?NirToGcnError,

    // inputs
    writer: *Io.Writer,
    nir: *const c.nir_shader,
    shader_info: *const c.gnm_shader_info,
    shader_args: *const c.gnm_shader_args,
    shader_info_aco: *const c.aco_shader_info,
    pipe_key: *const c.gnm_pipeline_key,
    gfx_level: c.amd_gfx_level,
    family: c.radeon_family,
    stage: MesaShaderStage,
    is_neo: bool,
};

fn buildBinaryCallback(
    private: ?*anyopaque,
    config: *const c.ac_shader_config,
    llvm_ir_str: [*:0]const u8,
    llvm_ir_size: c_uint,
    disasm_str: [*:0]const u8,
    disasm_size: c_uint,
    statistics: ?*c.amd_stats,
    exec_size: u32,
    code: [*]const u32,
    code_num_dwords: u32,
    symbols: [*]const c.aco_symbol,
    num_symbols: u32,
    debug_info: [*]const c.ac_shader_debug_info,
    debug_info_count: u32,
) callconv(.c) void {
    _ = llvm_ir_str; // autofix
    _ = llvm_ir_size; // autofix
    _ = disasm_str; // autofix
    _ = disasm_size; // autofix
    _ = statistics; // autofix
    _ = exec_size; // autofix
    _ = symbols; // autofix
    _ = num_symbols; // autofix
    _ = debug_info; // autofix
    _ = debug_info_count; // autofix

    var ctx: *BuildContext = @ptrCast(@alignCast(private.?));

    const writer = ctx.writer;

    var actual_config = config.*;
    gnm_postprocess_binary_config(
        ctx.gfx_level,
        ctx.shader_info,
        ctx.shader_args,
        ctx.stage,
        &actual_config,
    );

    // calculate byte sizes and counts ahead of time since some structs need them
    const needs_fetch_shader = ctx.nir.info.stage == c.MESA_SHADER_VERTEX and ctx.shader_info_aco.vs.has_prolog;
    const num_inputs_slots = res: {
        var count: u8 = 0;
        if (ctx.shader_args.prolog_inputs.used)
            count += 1;
        if (ctx.shader_args.ac.vertex_buffers.used)
            count += 1;
        if (ctx.shader_args.descriptors[0].used)
            count += 1;
        break :res count;
    };
    const num_inputs: u8 = @popCount(ctx.nir.info.inputs_read);
    // exclude position as it doesn't count as an export semantic in PSB
    const num_outputs: u8 = @popCount(ctx.nir.info.outputs_written & ~c.VARYING_BIT_POS);
    const code_byte_len = math.cast(u24, code_num_dwords * @sizeOf(u32)) orelse {
        ctx.last_error = error.CodeLengthOverflow;
        return;
    };
    const new_code_byte_len: u24 = res: {
        var len = code_byte_len;
        if (needs_fetch_shader)
            len += @sizeOf(u32);
        break :res len;
    };
    const aligned_new_code_byte_len = mem.alignForward(u24, new_code_byte_len, 8);

    const header_data_byte_len, const aligned_header_data_byte_len = res: {
        var length: u32 = @sizeOf(gnm.ShaderCommonData);

        switch (ctx.stage) {
            .vertex => length += @sizeOf(gnm.VsShader),
            .fragment => length += @sizeOf(gnm.PsShader),
            else => {
                ctx.last_error = error.UnimplementedShaderType;
                return;
            },
        }

        length += num_inputs_slots * @sizeOf(gnm.InputUsageSlot);

        switch (ctx.stage) {
            .vertex => length += @popCount(ctx.nir.info.inputs_read) * @sizeOf(gnm.VertexInputSemantic) +
                num_outputs * @sizeOf(gnm.VertexExportSemantic),
            .fragment => length += @popCount(ctx.nir.info.inputs_read) * @sizeOf(gnm.PixelInputSemantic),
            else => unreachable,
        }

        const aligned_len = mem.alignForward(u32, length, 4);
        break :res .{ length, aligned_len };
    };
    const header_bytes_to_align = aligned_header_data_byte_len - header_data_byte_len;

    //
    // PSB header
    //
    const psb_header: psb.BinaryHeader = .{
        .version = .{
            .major = 0,
            .minor = 4,
            .compiler = 0,
        },
        .association_hash = .{ 0, 0 },
        .type = switch (ctx.stage) {
            .vertex => .vertex,
            .fragment => .fragment,
            else => unreachable,
        },
        .source_code_type = .isa,
        .uses_shader_resource_table = false,
        .compiler = .{ .type = .unspecified },
        .code_byte_length = @sizeOf(gnm.ShaderFileHeader) + aligned_header_data_byte_len + new_code_byte_len,
        .variant = .{},
        .attributes = .{ .none = .{} },
    };
    writer.writeStruct(psb_header, .little) catch |err| {
        ctx.last_error = err;
        return;
    };

    //
    // GNM shader headers
    //
    const file_header = gnm.ShaderFileHeader{
        .version_major = 7,
        .version_minor = 2,
        .type = switch (ctx.stage) {
            .vertex => .vertex,
            .fragment => .pixel,
            else => unreachable,
        },
        .shader_header_len_dwords = math.cast(u8, aligned_header_data_byte_len / @sizeOf(u32)) orelse {
            ctx.last_error = error.HeaderLengthOverflow;
            return;
        },
        .has_shader_aux_data = 0,
        .target_gpu_modes = .{
            .base = !ctx.is_neo,
            .neo = ctx.is_neo,
        },
    };
    writer.writeStruct(file_header, .little) catch |err| {
        ctx.last_error = err;
        return;
    };

    const common_data: gnm.ShaderCommonData = .{
        .shader_len = math.cast(u23, aligned_new_code_byte_len + @sizeOf(gnm.ShaderBinaryInfo)) orelse {
            ctx.last_error = error.CodeLengthOverflow;
            return;
        },
        .num_input_usage_slots = num_inputs_slots,
        .constant_buffer_len_dqwords = 0,
        .scratch_size = 0,
    };
    writer.writeInt(u64, @bitCast(common_data), .little) catch |err| {
        ctx.last_error = err;
        return;
    };

    switch (ctx.stage) {
        .vertex => {
            const output_info = calcVertexOutputInfo(ctx.shader_info.*);
            const num_vs_exports = @max(1, math.cast(u5, ctx.shader_info.outinfo.param_exports) orelse {
                ctx.last_error = error.VertexExportOverflow;
                return;
            });
            const num_pos_exports = output_info.num_pos_exports;
            const clip_dist_mask = output_info.clip_dist_mask;
            const cull_dist_mask = output_info.cull_dist_mask;
            const total_mask = clip_dist_mask | cull_dist_mask;
            const enable_misc_vec =
                ctx.shader_info.outinfo.writes_pointsize or
                ctx.shader_info.outinfo.writes_layer or
                ctx.shader_info.outinfo.writes_viewport_index or
                ctx.shader_info.outinfo.writes_primitive_shading_rate;
            const vs_data: gnm.VsShader = .{
                .registers = .{
                    .spi_shader_pgm_lo_vs = aligned_header_data_byte_len,
                    .spi_shader_pgm_hi_vs = 0xffffffff,
                    .spi_shader_pgm_rsrc1_vs = @bitCast(actual_config.rsrc1),
                    .spi_shader_pgm_rsrc2_vs = @bitCast(actual_config.rsrc2),
                    .spi_vs_out_config = .{
                        .vs_export_count = num_vs_exports,
                        .vs_half_pack = false,
                    },
                    .spi_shader_pos_format = .{
                        .pos0_export_format = .@"4comp",
                        .pos1_export_format = if (num_pos_exports > 1) .@"4comp" else .none,
                        .pos2_export_format = if (num_pos_exports > 2) .@"4comp" else .none,
                        .pos3_export_format = if (num_pos_exports > 3) .@"4comp" else .none,
                    },
                    .pa_cl_vs_out_cntl = .{
                        .clip_dist_ena_0 = (clip_dist_mask & 0x1) != 0,
                        .clip_dist_ena_1 = (clip_dist_mask & 0x2) != 0,
                        .clip_dist_ena_2 = (clip_dist_mask & 0x4) != 0,
                        .clip_dist_ena_3 = (clip_dist_mask & 0x8) != 0,
                        .clip_dist_ena_4 = (clip_dist_mask & 0x10) != 0,
                        .clip_dist_ena_5 = (clip_dist_mask & 0x20) != 0,
                        .clip_dist_ena_6 = (clip_dist_mask & 0x40) != 0,
                        .clip_dist_ena_7 = (clip_dist_mask & 0x80) != 0,
                        .cull_dist_ena_0 = (cull_dist_mask & 0x1) != 0,
                        .cull_dist_ena_1 = (cull_dist_mask & 0x2) != 0,
                        .cull_dist_ena_2 = (cull_dist_mask & 0x4) != 0,
                        .cull_dist_ena_3 = (cull_dist_mask & 0x8) != 0,
                        .cull_dist_ena_4 = (cull_dist_mask & 0x10) != 0,
                        .cull_dist_ena_5 = (cull_dist_mask & 0x20) != 0,
                        .cull_dist_ena_6 = (cull_dist_mask & 0x40) != 0,
                        .cull_dist_ena_7 = (cull_dist_mask & 0x80) != 0,
                        .use_vtx_point_size = ctx.shader_info.outinfo.writes_pointsize,
                        .use_vtx_render_target_indx = ctx.shader_info.outinfo.writes_layer,
                        .use_vtx_viewport_indx = ctx.shader_info.outinfo.writes_viewport_index,
                        .vs_out_misc_vec_ena = enable_misc_vec,
                        .vs_out_ccdist0_vec_ena = (total_mask & 0x0f) != 0,
                        .vs_out_ccdist1_vec_ena = (total_mask & 0xf0) != 0,
                        .vs_out_misc_side_bus_ena = enable_misc_vec or
                            (ctx.gfx_level >= c.GFX10_3 and num_pos_exports > 1),
                    },
                },
                .num_input_semantics = @popCount(ctx.nir.info.inputs_read),
                .num_export_semantics = num_outputs,
                .gs_mode_or_num_input_semantics_cs = 0,
                .fetch_control = 0,
            };
            writer.writeStruct(vs_data, .little) catch |err| {
                ctx.last_error = err;
                return;
            };
        },
        .fragment => {
            const ps_data: gnm.PsShader = .{
                .registers = .{
                    .spi_shader_pgm_lo_ps = aligned_header_data_byte_len,
                    .spi_shader_pgm_hi_ps = 0xffffffff,
                    .spi_shader_pgm_rsrc1_ps = @bitCast(actual_config.rsrc1),
                    .spi_shader_pgm_rsrc2_ps = @bitCast(actual_config.rsrc2),
                    .spi_shader_z_format = @bitCast(c.ac_get_spi_shader_z_format(
                        ctx.shader_info.ps.writes_z,
                        ctx.shader_info.ps.writes_stencil,
                        ctx.shader_info.ps.writes_sample_mask,
                        ctx.shader_info.ps.writes_mrt0_alpha,
                    )),
                    .spi_shader_col_format = @bitCast(ctx.pipe_key.ps.epilog.spi_shader_col_format),
                    .spi_ps_input_ena = @bitCast(actual_config.spi_ps_input_ena),
                    .spi_ps_input_addr = @bitCast(actual_config.spi_ps_input_addr),
                    .spi_ps_in_control = .{
                        .num_interp = math.cast(u6, ctx.shader_info.ps.num_inputs) orelse
                            {
                                ctx.last_error = error.PixelInterpOverflow;
                                return;
                            },
                        .param_gen = ctx.gfx_level >= c.GFX11 and
                            ctx.shader_info.ps.num_inputs == 0 and
                            actual_config.lds_size > 0,
                        .bc_optimize_disable = false,
                    },
                    .spi_baryc_cntl = .{
                        .persp_center_cntl = false,
                        .persp_centroid_cntl = false,
                        .linear_center_cntl = false,
                        .linear_centroid_cntl = false,
                        .pos_float_location = 0,
                        .pos_float_ulc = false,
                        .front_face_all_bits = true,
                    },
                    .db_shader_control = @bitCast(c.gnm_compute_db_shader_control(
                        ctx.gfx_level,
                        ctx.family,
                        ctx.shader_info,
                    )),
                    .cb_shader_mask = @bitCast(c.ac_get_cb_shader_mask(
                        ctx.pipe_key.ps.epilog.spi_shader_col_format,
                    )),
                },
                .num_input_semantics = @popCount(ctx.nir.info.inputs_read),
            };
            writer.writeStruct(ps_data, .little) catch |err| {
                ctx.last_error = err;
                return;
            };
        },
        else => unreachable,
    }

    // input slots/resources
    if (ctx.shader_args.prolog_inputs.used) {
        const slot: gnm.InputUsageSlot = .{
            .usage_type = .sub_ptr_fetch_shader,
            .api_slot = 0,
            .start_register = ctx.shader_args.ac.args[ctx.shader_args.prolog_inputs.arg_index].offset,
            .register_info = .{ .default = .{} },
        };
        writer.writeStruct(slot, .little) catch |err| {
            ctx.last_error = err;
            return;
        };
    }
    if (ctx.shader_args.ac.vertex_buffers.used) {
        const slot: gnm.InputUsageSlot = .{
            .usage_type = .ptr_vertex_buffer_table,
            .api_slot = 0,
            .start_register = ctx.shader_args.ac.args[ctx.shader_args.ac.vertex_buffers.arg_index].offset,
            .register_info = .{ .default = .{} },
        };
        writer.writeStruct(slot, .little) catch |err| {
            ctx.last_error = err;
            return;
        };
    }
    // TODO: have this work with multiple sets
    if (ctx.shader_args.descriptors[0].used) {
        const slot: gnm.InputUsageSlot = .{
            .usage_type = .ptr_indirect_resource_table,
            .api_slot = 0,
            .start_register = ctx.shader_args.ac.args[ctx.shader_args.descriptors[0].arg_index].offset,
            .register_info = .{ .default = .{} },
        };
        writer.writeStruct(slot, .little) catch |err| {
            ctx.last_error = err;
            return;
        };
    }

    // inputs and outputs
    switch (ctx.stage) {
        .vertex => {
            for (0..num_inputs) |i| {
                const arg = ctx.shader_args.ac.args[ctx.shader_args.vs_inputs[i].arg_index];
                const input: gnm.VertexInputSemantic = .{
                    .semantic = math.cast(u8, i) orelse {
                        ctx.last_error = error.VertexInputOverflow;
                        return;
                    },
                    .vgpr = arg.offset,
                    .size_in_elements = arg.size,
                };
                writer.writeStruct(input, .little) catch |err| {
                    ctx.last_error = err;
                    return;
                };
            }
            for (0..num_outputs) |i| {
                // VS exports/PS inputs semantic index seems to start at 15.
                // this is to be compatible with official SDK shaders
                // TODO: make sure this is the case
                const output: gnm.VertexExportSemantic = .{
                    .semantic = math.cast(u8, 15 + i) orelse {
                        ctx.last_error = error.VertexExportOverflow;
                        return;
                    },
                    .out_index = math.cast(u5, i) orelse {
                        ctx.last_error = error.VertexExportOverflow;
                        return;
                    },
                    .type = .{},
                };
                writer.writeInt(u16, @bitCast(output), .little) catch |err| {
                    ctx.last_error = err;
                    return;
                };
            }
        },
        .fragment => {
            for (0..num_inputs) |i| {
                // VS exports/PS inputs semantic index seems to start at 15.
                // this is to be compatible with official SDK shaders
                // TODO: make sure this is the case
                const input: gnm.PixelInputSemantic = .{
                    .semantic = math.cast(u8, 15 + i) orelse {
                        ctx.last_error = error.PixelInputOverflow;
                        return;
                    },
                    .default_value = .@"0_0_0_0",
                    .flat_shade = false,
                    .sel_linear = false,
                    .hw = .{ .base = .{ .custom = false } },
                };
                writer.writeInt(u16, @bitCast(input), .little) catch |err| {
                    ctx.last_error = err;
                    return;
                };
            }
        },
        else => unreachable,
    }

    // alignment padding
    if (header_bytes_to_align > 0) {
        writer.splatByteAll(0, header_bytes_to_align) catch |err| {
            ctx.last_error = err;
            return;
        };
    }

    //
    // GCN bytecode
    //

    // prepend vertex shaders that use vertex input with essentialy is a
    // jump instruction to a fetch "shader"
    // TODO: add option to disable this
    // TODO: mesa mentions a prolog, is that equivalent to a fetch shader?
    //
    // s_swappc_b64 s[0:1], s[0:1]
    // TODO: get an assembler in freegnm
    const FETCH_SHADER_SWAP_INSTR: u32 = 0xbe802100;
    if (needs_fetch_shader) {
        writer.writeInt(u32, FETCH_SHADER_SWAP_INSTR, .little) catch |err| {
            ctx.last_error = err;
            return;
        };
    }
    const code_slice = code[0..code_num_dwords];
    const code_slice_u8: []const u8 = @ptrCast(@alignCast(code_slice));

    for (code_slice) |cur_word| {
        writer.writeInt(u32, cur_word, .little) catch |err| {
            ctx.last_error = err;
            return;
        };
    }

    // more alignment padding
    const zero_bytes = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const num_hash_zero_bytes = aligned_new_code_byte_len - new_code_byte_len;
    if (num_hash_zero_bytes > 0) {
        writer.splatByteAll(0, num_hash_zero_bytes) catch |err| {
            ctx.last_error = err;
            return;
        };
    }

    // embedded metadata in GCN code, likely used by official SDK tools
    var bin_info: gnm.ShaderBinaryInfo = .{
        .info = .{
            .is_pssl_or_cg = true,
            .is_source_cached = false,
            .type = switch (ctx.stage) {
                .vertex => .vs_vs,
                .fragment => .ps,
                else => unreachable,
            },
            .length = new_code_byte_len,
        },
        .chunk_usage_base_offset_dwords = 0,
        .num_input_usage_slots = 0, // TODO: can't set count without breaking CRC
        .srt = .{},
        .footer_version = 0,
        .association_hash = .{ 0, 0 },
        .crc32 = 0,
    };

    const BIN_INFO_HASHABLE_LEN = 0x18;
    comptime debug.assert(BIN_INFO_HASHABLE_LEN <= @sizeOf(@TypeOf(bin_info)));
    const bin_info_without_crc = @as([*]const u8, @ptrCast(@alignCast(&bin_info)))[0..BIN_INFO_HASHABLE_LEN];

    var hasher = Crc32Sb.init();
    if (needs_fetch_shader)
        hash.autoHash(&hasher, FETCH_SHADER_SWAP_INSTR);
    hasher.update(code_slice_u8);
    hasher.update(zero_bytes[0..num_hash_zero_bytes]);
    hasher.update(bin_info_without_crc);
    bin_info.crc32 = hasher.final();

    writer.writeStruct(bin_info, .little) catch |err| {
        ctx.last_error = err;
        return;
    };

    //
    // PSB shader metadata
    //
    // TODO: implement writing this data
    const param_info: psb.ParamInfo = .{
        .num_buffer_resources = 0,
        .num_constants = 0,
        .num_variables = 0,
        .num_sampler_resources = 0,
        .num_input_attributes = 0,
        .num_output_attributes = 0,
        .num_stream_outs = 0,
        .value_table_byte_len = 0,
        .string_table_byte_len = 0,
    };
    writer.writeStruct(param_info, .little) catch |err| {
        ctx.last_error = err;
        return;
    };
}

const VertexOutputInfo = struct {
    num_pos_exports: u32,
    clip_dist_mask: u32,
    cull_dist_mask: u32,
};

fn calcVertexOutputInfo(info: c.gnm_shader_info) VertexOutputInfo {
    var out_info: VertexOutputInfo = .{
        .num_pos_exports = 1,
        .clip_dist_mask = 0,
        .cull_dist_mask = 0,
    };
    if (info.outinfo.writes_pointsize or
        info.outinfo.writes_viewport_index or
        info.outinfo.writes_layer or
        info.outinfo.writes_primitive_shading_rate)
    {
        out_info.num_pos_exports += 1;
    }

    // Clip and cull distances are packed by ac_nir_export_position.
    const num_clip_dist_comps = @popCount(info.outinfo.clip_dist_mask);
    // Cull distances are not exported if the shader culls against them.
    const num_cull_dist_comps = @popCount(info.outinfo.cull_dist_mask);
    const clip_cull_mask = BITFIELD_MASK(num_clip_dist_comps + num_cull_dist_comps);

    if ((clip_cull_mask & 0x0f) != 0) {
        out_info.num_pos_exports += 1;
    }
    if ((clip_cull_mask & 0xf0) != 0) {
        out_info.num_pos_exports += 1;
    }

    out_info.clip_dist_mask = BITFIELD_MASK(num_clip_dist_comps);
    out_info.cull_dist_mask = BITFIELD_RANGE(num_clip_dist_comps, num_cull_dist_comps);
    return out_info;
}

fn BITFIELD_MASK(b: u5) u32 {
    return if (b == 32)
        ~@as(u32, 0)
    else
        (@as(u32, 1) << (b & 31)) - 1;
}

fn BITFIELD_RANGE(b: u5, count: u5) u32 {
    return BITFIELD_MASK(b + count) & ~BITFIELD_MASK(b);
}

// based off ac_fill_compiler_info
fn fillCompilerInfo(gfx_level: c.amd_gfx_level, family: c.radeon_family) c.ac_compiler_info {
    const max_se: u8 = if (gfx_level == c.GFX8) 4 else 2;
    const has_distributed_tess = gfx_level >= c.GFX10 or (gfx_level >= c.GFX8 and max_se >= 2);

    var out: c.ac_compiler_info = .{};

    out.gfx_level = gfx_level;

    out.max_waves_per_simd = if (gfx_level >= c.GFX10_3)
        16
    else if (gfx_level == c.GFX10)
        20
    else if (family >= c.CHIP_POLARIS10 and family <= c.CHIP_VEGAM)
        8
    else
        10;

    if (gfx_level >= c.GFX10) {
        out.num_physical_sgprs_per_simd = 108 * out.max_waves_per_simd;
        out.min_sgpr_alloc = 108;
        out.max_sgpr_alloc = 108;
        out.sgpr_alloc_granularity = 108;
    } else if (family == c.CHIP_TONGA or family == c.CHIP_ICELAND) {
        out.num_physical_sgprs_per_simd = 800;
        out.min_sgpr_alloc = 96;
        out.max_sgpr_alloc = 96;
        out.sgpr_alloc_granularity = 96;
    } else if (gfx_level >= c.GFX8) {
        out.num_physical_sgprs_per_simd = 800;
        out.min_sgpr_alloc = 16;
        out.max_sgpr_alloc = 102;
        out.sgpr_alloc_granularity = 16;
    } else {
        out.num_physical_sgprs_per_simd = 512;
        out.min_sgpr_alloc = 8;
        out.max_sgpr_alloc = 104;
        out.sgpr_alloc_granularity = 8;
    }

    if (family == c.CHIP_NAVI31 or family == c.CHIP_NAVI32 or
        family == c.CHIP_STRIX_HALO or gfx_level == c.GFX12)
    {
        out.num_physical_wave64_vgprs_per_simd = 768;
    } else if (gfx_level >= c.GFX10) {
        out.num_physical_wave64_vgprs_per_simd = 512;
    } else {
        out.num_physical_wave64_vgprs_per_simd = 256;
    }

    if (gfx_level >= c.GFX10_3) {
        out.wave64_vgpr_alloc_granularity = out.num_physical_wave64_vgprs_per_simd / 64;
        out.wave64_vgpr_encode_granularity = 4;
    } else if (gfx_level == c.GFX9 and family >= c.CHIP_MI200) {
        out.wave64_vgpr_alloc_granularity = 8;
        out.wave64_vgpr_encode_granularity = 8;
    } else {
        out.wave64_vgpr_alloc_granularity = 4;
        out.wave64_vgpr_encode_granularity = 4;
    }
    out.min_wave64_vgpr_alloc = out.wave64_vgpr_alloc_granularity;
    out.max_vgpr_alloc = 256;

    out.num_simd_per_compute_unit = if (gfx_level >= c.GFX10) 2 else 4;

    out.hs_offchip_workgroup_dw_size = if (family == c.CHIP_HAWAII) 4096 else 8192;

    out.has_lds_bank_count_16 = family == c.CHIP_KABINI or family == c.CHIP_STONEY;
    out.has_sram_ecc_enabled = family == c.CHIP_VEGA20 or family == c.CHIP_MI100 or
        family == c.CHIP_MI200 or family == c.CHIP_GFX940;
    out.has_point_sample_accel = family == c.CHIP_STRIX1 or family == c.CHIP_STRIX_HALO or
        family == c.CHIP_KRACKAN1;
    out.has_fast_fma32 = gfx_level >= c.GFX9 or family == c.CHIP_TAHITI or
        family == c.CHIP_HAWAII or family == c.CHIP_CARRIZO;
    out.has_fma_mix = gfx_level >= c.GFX10 or family == c.CHIP_VEGA12 or
        family == c.CHIP_VEGA20 or family == c.CHIP_MI100 or
        family == c.CHIP_MI200 or family == c.CHIP_GFX940;
    out.has_mad32 =
        (gfx_level == c.GFX9 and family <= c.CHIP_MI200) or gfx_level < c.GFX10_3;
    out.has_packed_math_16bit = gfx_level >= c.GFX9;
    out.has_accelerated_dot_product =
        family == c.CHIP_VEGA20 or
        (family >= c.CHIP_MI100 and family != c.CHIP_NAVI10 and family != c.CHIP_GFX1013);
    out.has_image_bvh_intersect_ray = gfx_level >= c.GFX10_3 or family == c.CHIP_GFX1013;

    out.has_ngg_passthru_no_msg = family >= c.CHIP_NAVI23;

    out.local_invocation_ids_packed = gfx_level >= c.GFX11;
    out.has_fmask = gfx_level <= c.GFX10_3;

    out.has_3d_cube_border_color_mipmap = family == c.CHIP_MI100;

    out.conformant_trunc_coord = false;

    out.has_attr_ring = gfx_level >= c.GFX11;

    out.mesh_fast_launch_2 = false;

    out.smaller_tcs_workgroups = !has_distributed_tess and max_se > 1;

    out.has_gfx6_mrt_export_bug =
        family == c.CHIP_TAHITI or family == c.CHIP_PITCAIRN or family == c.CHIP_VERDE;
    out.has_vtx_format_alpha_adjust_bug = gfx_level <= c.GFX8 and family != c.CHIP_STONEY;

    out.has_smem_oob_access_bug = gfx_level <= c.GFX7;

    out.has_image_load_dcc_bug =
        family == c.CHIP_NAVI23 or family == c.CHIP_VANGOGH or family == c.CHIP_REMBRANDT;

    out.has_ls_vgpr_init_bug = family == c.CHIP_VEGA10 or family == c.CHIP_RAVEN;

    out.has_cb_lt16bit_int_clamp_bug = gfx_level <= c.GFX7 and family != c.CHIP_HAWAII;

    out.has_vrs_frag_pos_z_bug =
        family == c.CHIP_NAVI21 or family == c.CHIP_NAVI22 or family == c.CHIP_VANGOGH;

    out.has_ngg_fully_culled_bug = gfx_level == c.GFX10;

    out.has_attr_ring_wait_bug = gfx_level == c.GFX11 or gfx_level == c.GFX11_5;

    out.has_primid_instancing_bug = gfx_level == c.GFX6 and max_se == 1;

    return out;
}

pub fn printNirToStdout(nir: *c.nir_shader) void {
    c.nir_print_shader(nir, c.stdout);
}

pub const MesaShaderStage = enum(c_int) {
    none = -1,
    vertex = 0,
    tess_ctrl = 1,
    tess_eval = 2,
    geometry = 3,
    fragment = 4,
    compute = 5,
    task = 6,
    mesh = 7,
    raygen = 8,
    any_hit = 9,
    closest_hit = 10,
    miss = 11,
    intersection = 12,
    callable = 13,
    kernel = 14,
};

extern fn gnm_declare_shader_args(
    gfx_level: c.enum_amd_gfx_level,
    info: *const c.gnm_shader_info,
    stage: MesaShaderStage,
    previous_stage: MesaShaderStage,
    args: *c.gnm_shader_args,
    debug: ?*c.gnm_shader_debug_info,
) void;
extern fn gnm_shader_spirv_to_nir(
    gfx_level: c.amd_gfx_level,
    spirv: [*]const u32,
    spirv_byte_size: usize,
    shader_stage: MesaShaderStage,
    nir_options: *const c.nir_shader_compiler_options,
    entrypoint: [*]const u8,
    optimisations_disabled: bool,
) ?*c.nir_shader;
const aco_callback = fn (
    private: ?*anyopaque,
    conifg: *const c.ac_shader_config,
    llvm_ir_str: [*:0]const u8,
    llvm_ir_size: c_uint,
    disasm_str: [*:0]const u8,
    disasm_size: c_uint,
    statistics: ?*c.amd_stats,
    exec_size: u32,
    code: [*]const u32,
    code_num_dwords: u32,
    symbols: [*]const c.aco_symbol,
    num_symbols: u32,
    debug_info: [*]const c.ac_shader_debug_info,
    debug_info_count: u32,
) callconv(.c) void;
extern fn gnm_postprocess_binary_config(
    gfx_level: c.amd_gfx_level,
    info: *const c.gnm_shader_info,
    args: *const c.gnm_shader_args,
    stage: MesaShaderStage,
    config: *c.ac_shader_config,
) void;
extern fn aco_compile_shader(
    options: *const c.aco_compiler_options,
    info: *const c.aco_shader_info,
    shader_count: c_uint,
    shaders: [*]const *c.nir_shader,
    args: *const c.ac_shader_args,
    build_binary: *const aco_callback,
    build_user_data: ?*anyopaque,
) void;

const Crc32Sb_bad = hash.Crc(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0xffffffff,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0,
});

const Crc32Sb = struct {
    const lookup_table = [256]u32{
        0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f,
        0xe963a535, 0x9e6495a3, 0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988,
        0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91, 0x1db71064, 0x6ab020f2,
        0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
        0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9,
        0xfa0f3d63, 0x8d080df5, 0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172,
        0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b, 0x35b5a8fa, 0x42b2986c,
        0xdbbbc9d6, 0xacbcf940, 0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59,
        0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423,
        0xcfba9599, 0xb8bda50f, 0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924,
        0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d, 0x76dc4190, 0x01db7106,
        0x98d220bc, 0xefd5102a, 0x71b18589, 0x06b6b51f, 0x9fbfe4a5, 0xe8b8d433,
        0x7807c9a2, 0x0f00f934, 0x9609a88e, 0xe10e9818, 0x7f6a0dbb, 0x086d3d2d,
        0x91646c97, 0xe6635c01, 0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e,
        0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457, 0x65b0d9c6, 0x12b7e950,
        0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65,
        0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2, 0x4adfa541, 0x3dd895d7,
        0xa4d1c46d, 0xd3d6f4fb, 0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0,
        0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9, 0x5005713c, 0x270241aa,
        0xbe0b1010, 0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
        0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17, 0x2eb40d81,
        0xb7bd5c3b, 0xc0ba6cad, 0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a,
        0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683, 0xe3630b12, 0x94643b84,
        0x0d6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
        0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb,
        0x196c3671, 0x6e6b06e7, 0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc,
        0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5, 0xd6d6a3e8, 0xa1d1937e,
        0x38d8c2c4, 0x4fdff252, 0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b,
        0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55,
        0x316e8eef, 0x4669be79, 0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236,
        0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f, 0xc5ba3bbe, 0xb2bd0b28,
        0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d,
        0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x026d930a, 0x9c0906a9, 0xeb0e363f,
        0x72076785, 0x05005713, 0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38,
        0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21, 0x86d3d2d4, 0xf1d4e242,
        0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777,
        0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c, 0x8f659eff, 0xf862ae69,
        0x616bffd3, 0x166ccf45, 0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2,
        0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db, 0xaed16a4a, 0xd9d65adc,
        0x40df0b66, 0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
        0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605, 0xcdd70693,
        0x54de5729, 0x23d967bf, 0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94,
        0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d,
    };
    const Self = @This();

    crc: u32,

    pub fn init() Self {
        return Self{ .crc = 0xffffffff };
    }

    inline fn tableEntry(index: u32) u32 {
        const actual_index: u8 = res: {
            var i: u32 = @intCast(index & 0xFF);
            if (i < 0xe0) {
                i = i +% ((((i - i / 7) >> 1) + i / 7) >> 2) *% 0xfffffffa;
            } else {
                i = 0;
            }
            break :res @truncate(i);
        };
        return lookup_table[actual_index];
    }

    pub fn update(self: *Self, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const table_index = self.crc ^ bytes[i];
            self.crc = tableEntry(table_index) ^ (self.crc >> 8);
        }
    }

    pub fn final(self: Self) u32 {
        return ~self.crc;
    }

    pub fn hash(bytes: []const u8) u32 {
        var cur_c = Self.init();
        cur_c.update(bytes);
        return cur_c.final();
    }
};
