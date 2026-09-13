const std = @import("std");

const Translator = @import("translate_c").Translator;
const zcc = @import("compile_commands");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //
    // dependencies
    //
    const upstream = b.dependency("mesa", .{});

    const translate_c = b.dependency("translate_c", .{});
    const dep_argzon = b.dependency("argzon", .{});
    const mod_argzon = dep_argzon.module("argzon");
    const dep_freegnm = b.dependency("freegnm", .{});
    const mod_gnm = dep_freegnm.module("gnm");

    //
    // C includes Zig module
    //
    const INCLUDES_LITTLE =
        \\#define UTIL_ARCH_LITTLE_ENDIAN 1
        \\#define UTIL_ARCH_BIG_ENDIAN 0
        \\
        \\#define HAVE_STRUCT_TIMESPEC 1
        \\#define HAVE_PTHREAD 1
        \\#include "aco_interface.h"
        \\#include "common/amdgfxregs.h"
        \\#include "nir/gnm_nir.h"
        \\#include "gnm_aco_shader_info.h"
        \\#include "gnm_private.h"
        \\
    ;
    const INCLUDES_BIG =
        \\#define UTIL_ARCH_LITTLE_ENDIAN 0
        \\#define UTIL_ARCH_BIG_ENDIAN 1
        \\
        \\#define HAVE_STRUCT_TIMESPEC 1
        \\#define HAVE_PTHREAD 1
        \\#include "aco_interface.h"
        \\#include "common/amdgfxregs.h"
        \\#include "nir/gnm_nir.h"
        \\#include "gnm_aco_shader_info.h"
        \\#include "gnm_private.h"
        \\
    ;
    const target_endian = target.result.cpu.arch.endian();

    //
    // WARNING:
    // unfortunately translate-c was mistranslating two bitset functions,
    // so I put the generated file into the source tree in `src/c_generate.zig`
    // and removed those two functions from it.
    //

    // const c_mesa: Translator = .init(translate_c, .{
    //     .c_source_file = b.addWriteFiles().add("c_mesa.h", switch (target_endian) {
    //         .little => INCLUDES_LITTLE,
    //         .big => INCLUDES_BIG,
    //     }),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,

    // });
    // for (LOCAL_INCLUDE_PATHS) |inc_path| {
    //     c_mesa.addIncludePath(b.path(inc_path));
    // }
    // for (INCLUDE_PATHS) |inc_path| {
    //     c_mesa.addIncludePath(upstream.path(inc_path));
    // }
    _ = translate_c;
    _ = INCLUDES_LITTLE;
    _ = INCLUDES_BIG;
    _ = target_endian;

    //
    // setup the library itself
    //
    const mod_psbc = b.addModule("psbc", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            // .{ .name = "c_mesa", .module = c_mesa.mod },
            .{ .name = "gnm", .module = mod_gnm },
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const BASE_C_FLAGS = [_][]const u8{
        "-std=gnu11",
        "-Wall",
    };
    const BASE_CXX_FLAGS = [_][]const u8{
        "-std=gnu++17",
        "-Wall",
    };

    var c_flag_list = try getPlatformFlags(b.allocator, target.result, &BASE_C_FLAGS);
    defer c_flag_list.deinit(b.allocator);
    var cxx_flag_list = try getPlatformFlags(b.allocator, target.result, &BASE_CXX_FLAGS);
    defer cxx_flag_list.deinit(b.allocator);

    for (LOCAL_INCLUDE_PATHS) |inc_path| {
        mod_psbc.addIncludePath(b.path(inc_path));
    }
    for (INCLUDE_PATHS) |inc_path| {
        mod_psbc.addIncludePath(upstream.path(inc_path));
    }
    mod_psbc.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &C_SOURCES,
        .flags = c_flag_list.items,
        .language = .c,
    });
    mod_psbc.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &CXX_SOURCES,
        .flags = cxx_flag_list.items,
        .language = .cpp,
    });
    mod_psbc.addCSourceFiles(.{
        .root = b.path("generated/src"),
        .files = &.{
            "builtin_types.c",
            "format_srgb.c",
            "gfx10_format_table.c",
            "nir_constant_expressions.c",
            "nir_intrinsics.c",
            "nir_opcodes.c",
            "nir_opt_algebraic.c",
            "spirv_info.c",
            "u_format_table.c",
            "vtn_gather_types.c",
        },
        .flags = c_flag_list.items,
        .language = .c,
    });
    mod_psbc.addCSourceFiles(.{
        .root = b.path("src/amd/gnm"),
        .files = &.{
            "nir/gnm_nir_fix_buffer_access_chains.c",
            "nir/gnm_nir_lower_cooperative_matrix.c",
            "nir/gnm_nir_lower_descriptors.c",
            "nir/gnm_nir_lower_io.c",
            "nir/gnm_nir_lower_intrinsics_early.c",
            "nir/gnm_nir_lower_primitive_shading_rate.c",
            "nir/gnm_nir_lower_vs_inputs.c",
            "gnm_pipeline.c",
            "gnm_pipeline_graphics.c",
            "gnm_shader_args.c",
            "gnm_shader_info.c",
            "gnm_shader.c",
        },
        .flags = c_flag_list.items,
        .language = .c,
    });
    mod_psbc.addCSourceFiles(.{
        .root = b.path("overlay/src"),
        .files = &.{
            "amd/common/ac_shader_args.c",
            "compiler/spirv/spirv_to_nir.c",
        },
        .flags = c_flag_list.items,
        .language = .c,
    });
    mod_psbc.addCSourceFile(.{
        .file = b.path("generated/src/aco_opcodes.cpp"),
        .flags = cxx_flag_list.items,
        .language = .cpp,
    });

    switch (target.result.cpu.arch) {
        .x86_64 => {
            if (target.result.os.tag == .windows) {
                mod_psbc.addCSourceFiles(.{
                    .root = upstream.path("src"),
                    .files = &.{
                        "util/blake3/blake3_sse2_x86-64_windows_gnu.S",
                        "util/blake3/blake3_sse41_x86-64_windows_gnu.S",
                        "util/blake3/blake3_avx2_x86-64_windows_gnu.S",
                        "util/blake3/blake3_avx512_x86-64_windows_gnu.S",
                    },
                    .flags = c_flag_list.items,
                    .language = .assembly_with_preprocessor,
                });
            } else {
                mod_psbc.addCSourceFiles(.{
                    .root = upstream.path("src"),
                    .files = &.{
                        "util/blake3/blake3_sse2_x86-64_unix.S",
                        "util/blake3/blake3_sse41_x86-64_unix.S",
                        "util/blake3/blake3_avx2_x86-64_unix.S",
                        "util/blake3/blake3_avx512_x86-64_unix.S",
                    },
                    .flags = c_flag_list.items,
                    .language = .assembly_with_preprocessor,
                });
            }
        },
        .arm => {
            mod_psbc.addCSourceFiles(.{
                .root = upstream.path("src"),
                .files = &.{
                    "src/util/blake3/blake3_neon.c",
                },
                .flags = c_flag_list.items,
                .language = .c,
            });
        },
        else => {},
    }

    //
    // tools
    //
    const exe_psbc = b.addExecutable(.{
        .name = "psbc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/psbc/main.zig"),
            .imports = &.{
                .{ .name = "argzon", .module = mod_argzon },
                .{ .name = "gnm", .module = mod_gnm },
                .{ .name = "psbc", .module = mod_psbc },
            },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for (LOCAL_INCLUDE_PATHS) |inc_path| {
        exe_psbc.root_module.addIncludePath(b.path(inc_path));
    }
    for (INCLUDE_PATHS) |inc_path| {
        exe_psbc.root_module.addIncludePath(upstream.path(inc_path));
    }

    b.installArtifact(exe_psbc);

    //
    // check stages for ZLS
    //
    const step_check = b.step("check", "Check if the project compiles");

    const check_psbc = b.addLibrary(.{
        .name = "psbc",
        .root_module = mod_psbc,
    });
    const check_exe_psbc = b.addExecutable(.{
        .name = "psbc",
        .root_module = exe_psbc.root_module,
    });

    step_check.dependOn(&check_psbc.step);
    step_check.dependOn(&check_exe_psbc.step);
}

const LOCAL_INCLUDE_PATHS = [_][]const u8{
    "overlay/src",
    "overlay/src/amd",
    "overlay/src/amd/common",
    "overlay/src/compiler",
    "generated/include",
    "generated/include/common",
    "src/amd/gnm",
};

const INCLUDE_PATHS = [_][]const u8{
    "include/",
    "src/",
    "src/amd",
    "src/amd/common",
    "src/amd/common/nir",
    "src/amd/compiler",
    "src/compiler",
    "src/compiler/nir",
    "src/compiler/spirv",
    "src/gallium/include",
    "src/mesa",
    "src/util",
    "src/util/format",
};

fn getPlatformFlags(
    alloc: std.mem.Allocator,
    target: std.Target,
    other_defines: []const []const u8,
) !std.ArrayList([]const u8) {
    var flag_list: std.ArrayList([]const u8) = .empty;
    errdefer flag_list.deinit(alloc);

    switch (target.os.tag) {
        else => try flag_list.append(alloc, "-DHAVE_SYSCONF=1"),
        .freebsd, .netbsd, .openbsd, .haiku, .macos, .windows => {},
    }

    switch (target.cpu.arch.endian()) {
        .big => try flag_list.appendSlice(alloc, &.{
            "-DUTIL_ARCH_LITTLE_ENDIAN=0",
            "-DUTIL_ARCH_BIG_ENDIAN=1",
        }),
        .little => try flag_list.appendSlice(alloc, &.{
            "-DUTIL_ARCH_LITTLE_ENDIAN=1",
            "-DUTIL_ARCH_BIG_ENDIAN=0",
        }),
    }

    try flag_list.appendSlice(alloc, &.{
        "-D_GNU_SOURCE",
        "-DHAVE_STRUCT_TIMESPEC",
        "-DHAVE_PTHREAD",
        "-DHAVE_SECURE_GETENV",
        "-DHAVE_FUNC_ATTRIBUTE_UNUSED",
    });
    try flag_list.appendSlice(alloc, other_defines);

    return flag_list;
}

const C_SOURCES = [_][]const u8{
    "amd/common/nir/ac_nir.c",
    "amd/common/nir/ac_nir_create_gs_copy_shader.c",
    "amd/common/nir/ac_nir_lower_esgs_io_to_mem.c",
    "amd/common/nir/ac_nir_lower_global_access.c",
    "amd/common/nir/ac_nir_lower_image_tex.c",
    "amd/common/nir/ac_nir_lower_intrinsics_to_args.c",
    "amd/common/nir/ac_nir_lower_legacy_gs.c",
    "amd/common/nir/ac_nir_lower_legacy_vs.c",
    "amd/common/nir/ac_nir_lower_mem_access_bit_sizes.c",
    "amd/common/nir/ac_nir_lower_ps_late.c",
    "amd/common/nir/ac_nir_lower_resinfo.c",
    "amd/common/nir/ac_nir_lower_tess_io_to_mem.c",
    "amd/common/nir/ac_nir_opt_shared_append.c",
    "amd/common/nir/ac_nir_opt_flip_if_for_mem_loads.c",
    "amd/common/nir/ac_nir_prerast_utils.c",
    "amd/common/ac_descriptors.c",
    "amd/common/ac_formats.c",
    "amd/common/ac_shader_util.c",
    "compiler/nir/nir.c",
    "compiler/nir/nir_builder.c",
    "compiler/nir/nir_builtin_builder.c",
    "compiler/nir/nir_clip_cull_distance_io_utils.c",
    "compiler/nir/nir_clone.c",
    "compiler/nir/nir_control_flow.c",
    "compiler/nir/nir_deref.c",
    "compiler/nir/nir_divergence_analysis.c",
    "compiler/nir/nir_dominance.c",
    "compiler/nir/nir_dominance_lca.c",
    "compiler/nir/nir_downgrade_pls_vars.c",
    "compiler/nir/nir_fixup_is_exported.c",
    "compiler/nir/nir_format_convert.c",
    "compiler/nir/nir_from_ssa.c",
    "compiler/nir/nir_functions.c",
    "compiler/nir/nir_gather_info.c",
    "compiler/nir/nir_gather_output_deps.c",
    "compiler/nir/nir_gather_tcs_info.c",
    "compiler/nir/nir_gather_types.c",
    "compiler/nir/nir_gather_xfb_info.c",
    "compiler/nir/nir_opt_group_loads.c",
    "compiler/nir/nir_gs_count_vertices.c",
    "compiler/nir/nir_inline_sysval.c",
    "compiler/nir/nir_inline_uniforms.c",
    "compiler/nir/nir_instr_set.c",
    "compiler/nir/nir_io_add_xfb_info.c",
    "compiler/nir/nir_legacy.c",
    "compiler/nir/nir_linking_helpers.c",
    "compiler/nir/nir_liveness.c",
    "compiler/nir/nir_loop_analyze.c",
    "compiler/nir/nir_lower_alu.c",
    "compiler/nir/nir_lower_alu_width.c",
    "compiler/nir/nir_lower_alpha.c",
    "compiler/nir/nir_lower_amul.c",
    "compiler/nir/nir_lower_array_deref_of_vec.c",
    "compiler/nir/nir_lower_atomics.c",
    "compiler/nir/nir_lower_atomics_to_ssbo.c",
    "compiler/nir/nir_lower_bitmap.c",
    "compiler/nir/nir_lower_blend.c",
    "compiler/nir/nir_lower_bool_to_float.c",
    "compiler/nir/nir_lower_bool_to_int32.c",
    "compiler/nir/nir_lower_calls_to_builtins.c",
    "compiler/nir/nir_lower_cl_images.c",
    "compiler/nir/nir_lower_clamp_color_outputs.c",
    "compiler/nir/nir_lower_clip.c",
    "compiler/nir/nir_lower_clip_disable.c",
    "compiler/nir/nir_lower_clip_halfz.c",
    "compiler/nir/nir_lower_const_arrays_to_uniforms.c",
    "compiler/nir/nir_lower_continue_constructs.c",
    "compiler/nir/nir_lower_convert_alu_types.c",
    "compiler/nir/nir_lower_cooperative_matrix.c",
    "compiler/nir/nir_lower_variable_initializers.c",
    "compiler/nir/nir_lower_discard_if.c",
    "compiler/nir/nir_lower_double_ops.c",
    "compiler/nir/nir_lower_explicit_io.c",
    "compiler/nir/nir_lower_fb_read.c",
    "compiler/nir/nir_lower_flatshade.c",
    "compiler/nir/nir_lower_floats.c",
    "compiler/nir/nir_lower_flrp.c",
    "compiler/nir/nir_lower_fp16_conv.c",
    "compiler/nir/nir_lower_fragcoord_wtrans.c",
    "compiler/nir/nir_lower_frag_coord_to_pixel_coord.c",
    "compiler/nir/nir_lower_fragcolor.c",
    "compiler/nir/nir_lower_frexp.c",
    "compiler/nir/nir_lower_global_vars_to_local.c",
    "compiler/nir/nir_lower_goto_ifs.c",
    "compiler/nir/nir_lower_gs_intrinsics.c",
    "compiler/nir/nir_lower_halt_to_return.c",
    "compiler/nir/nir_lower_helper_writes.c",
    "compiler/nir/nir_lower_load_const_to_scalar.c",
    "compiler/nir/nir_lower_locals_to_regs.c",
    "compiler/nir/nir_lower_idiv.c",
    "compiler/nir/nir_lower_image.c",
    "compiler/nir/nir_lower_image_atomics_to_global.c",
    "compiler/nir/nir_lower_indirect_derefs_to_if_else_trees.c",
    "compiler/nir/nir_lower_input_attachments.c",
    "compiler/nir/nir_lower_int64.c",
    "compiler/nir/nir_lower_interpolation.c",
    "compiler/nir/nir_lower_int_to_float.c",
    "compiler/nir/nir_lower_io.c",
    "compiler/nir/nir_lower_io_array_vars_to_elements.c",
    "compiler/nir/nir_lower_io_indirect_loads.c",
    "compiler/nir/nir_lower_io_vars_to_temporaries.c",
    "compiler/nir/nir_lower_io_to_scalar.c",
    "compiler/nir/nir_lower_io_vars_to_scalar.c",
    "compiler/nir/nir_lower_is_helper_invocation.c",
    "compiler/nir/nir_lower_multiview.c",
    "compiler/nir/nir_lower_mediump.c",
    "compiler/nir/nir_lower_mem_access_bit_sizes.c",
    "compiler/nir/nir_lower_memcpy.c",
    "compiler/nir/nir_lower_memory_model.c",
    "compiler/nir/nir_lower_non_uniform_access.c",
    "compiler/nir/nir_lower_packing.c",
    "compiler/nir/nir_lower_passthrough_edgeflags.c",
    "compiler/nir/nir_lower_patch_vertices.c",
    "compiler/nir/nir_lower_phis_to_scalar.c",
    "compiler/nir/nir_lower_pntc_ytransform.c",
    "compiler/nir/nir_lower_point_size.c",
    "compiler/nir/nir_lower_point_smooth.c",
    "compiler/nir/nir_lower_poly_line_smooth.c",
    "compiler/nir/nir_lower_printf.c",
    "compiler/nir/nir_lower_reg_intrinsics_to_ssa.c",
    "compiler/nir/nir_lower_readonly_images_to_tex.c",
    "compiler/nir/nir_lower_returns.c",
    "compiler/nir/nir_lower_robust_access.c",
    "compiler/nir/nir_lower_samplers.c",
    "compiler/nir/nir_lower_sample_shading.c",
    "compiler/nir/nir_lower_scratch.c",
    "compiler/nir/nir_lower_scratch_to_var.c",
    "compiler/nir/nir_lower_shader_calls.c",
    "compiler/nir/nir_lower_single_sampled.c",
    "compiler/nir/nir_lower_ssbo.c",
    "compiler/nir/nir_lower_subgroups.c",
    "compiler/nir/nir_lower_system_values.c",
    "compiler/nir/nir_lower_task_shader.c",
    "compiler/nir/nir_lower_terminate_to_demote.c",
    "compiler/nir/nir_lower_tess_coord_z.c",
    "compiler/nir/nir_lower_tex_shadow.c",
    "compiler/nir/nir_lower_tex.c",
    "compiler/nir/nir_lower_texcoord_replace.c",
    "compiler/nir/nir_lower_texcoord_replace_late.c",
    "compiler/nir/nir_lower_two_sided_color.c",
    "compiler/nir/nir_lower_undef_to_zero.c",
    "compiler/nir/nir_lower_vars_to_ssa.c",
    "compiler/nir/nir_lower_var_copies.c",
    "compiler/nir/nir_lower_vec_to_regs.c",
    "compiler/nir/nir_lower_vec3_to_vec4.c",
    "compiler/nir/nir_lower_view_index_to_device_index.c",
    "compiler/nir/nir_lower_viewport_transform.c",
    "compiler/nir/nir_lower_wpos_center.c",
    "compiler/nir/nir_lower_wpos_ytransform.c",
    "compiler/nir/nir_lower_wrmasks.c",
    "compiler/nir/nir_lower_bit_size.c",
    "compiler/nir/nir_lower_ubo_vec4.c",
    "compiler/nir/nir_lower_uniforms_to_ubo.c",
    "compiler/nir/nir_lower_workgroup_size.c",
    "compiler/nir/nir_lower_sysvals_to_varyings.c",
    "compiler/nir/nir_metadata.c",
    "compiler/nir/nir_mod_analysis.c",
    "compiler/nir/nir_move_output_stores_to_end.c",
    "compiler/nir/nir_move_vec_src_uses_to_dest.c",
    "compiler/nir/nir_normalize_cubemap_coords.c",
    "compiler/nir/nir_normalize_sin_cos.c",
    "compiler/nir/nir_opt_access.c",
    "compiler/nir/nir_opt_barriers.c",
    "compiler/nir/nir_opt_barycentric.c",
    "compiler/nir/nir_opt_call.c",
    "compiler/nir/nir_opt_clip_cull_const.c",
    "compiler/nir/nir_opt_combine_stores.c",
    "compiler/nir/nir_opt_comparison_pre.c",
    "compiler/nir/nir_opt_constant_folding.c",
    "compiler/nir/nir_opt_copy_prop_vars.c",
    "compiler/nir/nir_opt_copy_propagate.c",
    "compiler/nir/nir_opt_cse.c",
    "compiler/nir/nir_opt_dce.c",
    "compiler/nir/nir_opt_dead_cf.c",
    "compiler/nir/nir_opt_dead_write_vars.c",
    "compiler/nir/nir_opt_find_array_copies.c",
    "compiler/nir/nir_opt_fp_math_ctrl.c",
    "compiler/nir/nir_opt_frag_coord_to_pixel_coord.c",
    "compiler/nir/nir_opt_fragdepth.c",
    "compiler/nir/nir_opt_gcm.c",
    "compiler/nir/nir_opt_generate_bfi.c",
    "compiler/nir/nir_opt_idiv_const.c",
    "compiler/nir/nir_opt_if.c",
    "compiler/nir/nir_opt_intrinsics.c",
    "compiler/nir/nir_opt_large_constants.c",
    "compiler/nir/nir_opt_licm.c",
    "compiler/nir/nir_opt_load_skip_helpers.c",
    "compiler/nir/nir_opt_load_store_vectorize.c",
    "compiler/nir/nir_opt_loop.c",
    "compiler/nir/nir_opt_loop_unroll.c",
    "compiler/nir/nir_opt_memcpy.c",
    "compiler/nir/nir_opt_move.c",
    "compiler/nir/nir_opt_move_discards_to_top.c",
    "compiler/nir/nir_opt_move_to_top.c",
    "compiler/nir/nir_opt_mqsad.c",
    "compiler/nir/nir_opt_non_uniform_access.c",
    "compiler/nir/nir_opt_offsets.c",
    "compiler/nir/nir_opt_peephole_select.c",
    "compiler/nir/nir_opt_phi_precision.c",
    "compiler/nir/nir_opt_phi_to_bool.c",
    "compiler/nir/nir_opt_preamble.c",
    "compiler/nir/nir_opt_ray_queries.c",
    "compiler/nir/nir_opt_reassociate.c",
    "compiler/nir/nir_opt_reassociate_bfi.c",
    "compiler/nir/nir_opt_rematerialize_compares.c",
    "compiler/nir/nir_opt_remove_phis.c",
    "compiler/nir/nir_opt_shrink_stores.c",
    "compiler/nir/nir_opt_shrink_vectors.c",
    "compiler/nir/nir_opt_sink.c",
    "compiler/nir/nir_opt_undef.c",
    "compiler/nir/nir_opt_uniform_atomics.c",
    "compiler/nir/nir_opt_uniform_subgroup.c",
    "compiler/nir/nir_opt_uub.c",
    "compiler/nir/nir_opt_varyings.c",
    "compiler/nir/nir_opt_vectorize.c",
    "compiler/nir/nir_opt_vectorize_io.c",
    "compiler/nir/nir_opt_vectorize_io_vars.c",
    "compiler/nir/nir_passthrough_gs.c",
    "compiler/nir/nir_passthrough_tcs.c",
    "compiler/nir/nir_phi_builder.c",
    "compiler/nir/nir_print.c",
    "compiler/nir/nir_propagate_invariant.c",
    "compiler/nir/nir_range_analysis.c",
    "compiler/nir/nir_recompute_io_bases.c",
    "compiler/nir/nir_remove_dead_variables.c",
    "compiler/nir/nir_remove_outputs.c",
    "compiler/nir/nir_remove_tex_shadow.c",
    "compiler/nir/nir_repair_ssa.c",
    "compiler/nir/nir_scale_fdiv.c",
    "compiler/nir/nir_schedule.c",
    "compiler/nir/nir_search.c",
    "compiler/nir/nir_separate_merged_clip_cull_io.c",
    "compiler/nir/nir_serialize.c",
    "compiler/nir/nir_shader_bisect.c",
    "compiler/nir/nir_split_64bit_vec3_and_vec4.c",
    "compiler/nir/nir_split_conversions.c",
    "compiler/nir/nir_split_per_member_structs.c",
    "compiler/nir/nir_split_var_copies.c",
    "compiler/nir/nir_split_vars.c",
    "compiler/nir/nir_sweep.c",
    "compiler/nir/nir_to_lcssa.c",
    "compiler/nir/nir_trivialize_registers.c",
    "compiler/nir/nir_unlower_io_to_vars.c",
    "compiler/nir/nir_use_dominance.c",
    "compiler/nir/nir_validate.c",
    "compiler/nir/nir_worklist.c",
    "compiler/spirv/vtn_alu.c",
    "compiler/spirv/vtn_amd.c",
    "compiler/spirv/vtn_cfg.c",
    "compiler/spirv/vtn_cmat.c",
    "compiler/spirv/vtn_debug.c",
    "compiler/spirv/vtn_glsl450.c",
    "compiler/spirv/vtn_opencl.c",
    "compiler/spirv/vtn_structured_cfg.c",
    "compiler/spirv/vtn_subgroup.c",
    "compiler/spirv/vtn_variables.c",
    "compiler/glsl_types.c",
    "compiler/shader_enums.c",
    "util/blake3/blake3.c",
    "util/blake3/blake3_dispatch.c",
    "util/blake3/blake3_portable.c",
    "util/format/u_format_bptc.c",
    "util/format/u_format_etc.c",
    "util/format/u_format_fxt1.c",
    "util/format/u_format_latc.c",
    "util/format/u_format_other.c",
    "util/format/u_format_rgtc.c",
    "util/format/u_format_s3tc.c",
    "util/format/u_format_yuv.c",
    "util/format/u_format_zs.c",
    "util/format/u_format.c",
    "util/blob.c",
    "util/crc32.c",
    "util/dag.c",
    "util/double.c",
    "util/fast_idiv_by_const.c",
    "util/float8.c",
    "util/half_float.c",
    "util/hash_table.c",
    "util/log.c",
    "util/memstream.c",
    "util/mesa-blake3.c",
    "util/os_file.c",
    "util/os_misc.c",
    "util/ralloc.c",
    "util/range_minimum_query.c",
    "util/rb_tree.c",
    "util/rgtc.c",
    "util/set.c",
    "util/simple_mtx.c",
    "util/softfloat.c",
    "util/u_call_once.c",
    "util/u_cpu_detect.c",
    "util/u_debug.c",
    "util/u_dynarray.c",
    "util/u_printf.c",
    "util/u_process.c",
    "util/u_thread.c",
    "util/u_vector.c",
    "util/u_worklist.c",
};

const CXX_SOURCES = [_][]const u8{
    "amd/compiler/instruction_selection/aco_isel_cfg.cpp",
    "amd/compiler/instruction_selection/aco_isel_helpers.cpp",
    "amd/compiler/instruction_selection/aco_isel_setup.cpp",
    "amd/compiler/instruction_selection/aco_select_nir_alu.cpp",
    "amd/compiler/instruction_selection/aco_select_nir_intrinsics.cpp",
    "amd/compiler/instruction_selection/aco_select_nir.cpp",
    "amd/compiler/instruction_selection/aco_select_ps_epilog.cpp",
    "amd/compiler/instruction_selection/aco_select_ps_prolog.cpp",
    "amd/compiler/instruction_selection/aco_select_trap_handler.cpp",
    "amd/compiler/instruction_selection/aco_select_vs_prolog.cpp",
    "amd/compiler/aco_dead_code_analysis.cpp",
    "amd/compiler/aco_dominance.cpp",
    "amd/compiler/aco_interface.cpp",
    "amd/compiler/aco_ir.cpp",
    "amd/compiler/aco_assembler.cpp",
    "amd/compiler/aco_form_hard_clauses.cpp",
    "amd/compiler/aco_insert_delay_alu.cpp",
    "amd/compiler/aco_insert_exec_mask.cpp",
    "amd/compiler/aco_insert_fp_mode.cpp",
    "amd/compiler/aco_insert_NOPs.cpp",
    "amd/compiler/aco_insert_waitcnt.cpp",
    "amd/compiler/aco_reduce_assign.cpp",
    "amd/compiler/aco_register_allocation.cpp",
    "amd/compiler/aco_live_var_analysis.cpp",
    "amd/compiler/aco_lower_branches.cpp",
    "amd/compiler/aco_lower_phis.cpp",
    "amd/compiler/aco_lower_subdword.cpp",
    "amd/compiler/aco_lower_to_cssa.cpp",
    "amd/compiler/aco_lower_to_hw_instr.cpp",
    "amd/compiler/aco_optimizer.cpp",
    "amd/compiler/aco_optimizer_postRA.cpp",
    "amd/compiler/aco_opt_value_numbering.cpp",
    "amd/compiler/aco_print_asm.cpp",
    "amd/compiler/aco_print_ir.cpp",
    "amd/compiler/aco_reindex_ssa.cpp",
    "amd/compiler/aco_repair_ssa.cpp",
    "amd/compiler/aco_scheduler.cpp",
    "amd/compiler/aco_scheduler_ilp.cpp",
    "amd/compiler/aco_spill.cpp",
    "amd/compiler/aco_spill_preserved.cpp",
    "amd/compiler/aco_ssa_elimination.cpp",
    "amd/compiler/aco_statistics.cpp",
    "amd/compiler/aco_validate.cpp",
    "util/u_qsort.cpp",
};
