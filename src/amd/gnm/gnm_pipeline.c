/*
 * Copyright © 2016 Red Hat.
 * Copyright © 2016 Bas Nieuwenhuizen
 *
 * based in part on anv driver which is:
 * Copyright © 2015 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

#include "gnm_private.h"
#include "gnm_shader_args.h"
#include "nir/gnm_nir.h"
#include "nir/nir.h"
#include "nir/nir_builder.h"
#include "nir/nir_serialize.h"
#include "spirv/nir_spirv.h"

#include "ac_binary.h"
#include "ac_nir.h"
#include "ac_shader_util.h"
#include "aco_interface.h"
#include "sid.h"
#include "util/u_debug.h"

static nir_component_mask_t non_uniform_access_callback(const nir_src *src,
                                                        void *_) {
  if (src->ssa->num_components == 1)
    return 0x1;
  return nir_chase_binding(*src).success ? 0x2 : 0x3;
}

void gnm_postprocess_nir(enum amd_gfx_level gfx_level,
                         enum radeon_family family, struct nir_shader *nir,
                         const struct gnm_shader_args *args,
                         struct gnm_shader_info *info,
                         const struct aco_shader_info *aco_info,
                         const struct gnm_pipeline_key *pipe_key,
                         bool optimisations_disabled) {
  const bool use_llvm = false;
  bool progress;

  /* Wave and workgroup size should already be filled. */
  assert(info->wave_size && info->workgroup_size);

  if (nir->info.stage == MESA_SHADER_FRAGMENT) {
    if (!optimisations_disabled) {
      NIR_PASS(_, nir, nir_opt_cse);
    }
    // NIR_PASS(_, nir, gnm_nir_lower_fs_intrinsics, stage, pipe_key);
  }

  /* LLVM could support more of these in theory. */
  // radv_nir_opt_tid_function_options tid_options = {
  //    .use_masked_swizzle_amd = true,
  //    .use_dpp16_shift_amd = !use_llvm && gfx_level >= GFX8,
  //    .use_clustered_rotate = !use_llvm,
  //    .hw_subgroup_size = stage->info.wave_size,
  //    .hw_ballot_bit_size = stage->info.wave_size,
  //    .hw_ballot_num_comp = 1,
  // };
  // NIR_PASS(_, nir, radv_nir_opt_tid_function, &tid_options);

  NIR_PASS(_, nir, ac_nir_flag_smem_for_loads, gfx_level, use_llvm);

  NIR_PASS(_, nir, nir_lower_memory_model);

  enum nir_lower_non_uniform_access_type lower_non_uniform_access_types =
      nir_lower_non_uniform_ubo_access | nir_lower_non_uniform_ssbo_access |
      nir_lower_non_uniform_texture_access | nir_lower_non_uniform_image_access;

  nir_load_store_vectorize_options vectorize_opts = {
      .modes = nir_var_mem_ssbo | nir_var_mem_ubo | nir_var_mem_push_const |
               nir_var_mem_shared | nir_var_mem_global | nir_var_shader_temp,
      .callback = ac_nir_mem_vectorize_callback,
      .cb_data = &(struct ac_nir_config){gfx_level, !use_llvm},
      .robust_modes = 0,
      .bounds_checked_modes =
          nir_var_mem_ssbo | nir_var_mem_ubo | nir_var_mem_shared,
      /* Only vectorize shared2 during late optimizations. */
      .has_shared2_amd = false,
  };

  // TODO: psbc: add runtime options of these
  // if (stage->key.uniform_robustness2)
  //    vectorize_opts.robust_modes |= nir_var_mem_ubo;

  // if (stage->key.storage_robustness2)
  //    vectorize_opts.robust_modes |= nir_var_mem_ssbo;

  bool constant_fold_for_push_const = false;
  if (!optimisations_disabled) {
    progress = false;
    NIR_PASS(progress, nir, nir_opt_load_store_vectorize, &vectorize_opts);
    if (progress) {
      NIR_PASS(_, nir, nir_opt_copy_prop);
      NIR_PASS(_, nir, nir_opt_shrink_stores, true);

      constant_fold_for_push_const = true;
    }
  }

  /* In practice, most shaders do not have non-uniform-qualified
   * accesses (see
   * https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/17558#note_1475069)
   * thus a cheaper and likely to fail check is run first.
   */
  if (nir_has_non_uniform_access(nir, lower_non_uniform_access_types)) {
    if (!optimisations_disabled) {
      NIR_PASS(_, nir, nir_opt_non_uniform_access);
    }

    if (!use_llvm) {
      nir_lower_non_uniform_access_options options = {
          .types = lower_non_uniform_access_types,
          .callback = &non_uniform_access_callback,
          .callback_data = NULL,
      };
      NIR_PASS(_, nir, nir_lower_non_uniform_access, &options);
    }
  }

  progress = false;
  NIR_PASS(progress, nir, ac_nir_lower_mem_access_bit_sizes, gfx_level,
           use_llvm);
  if (progress)
    constant_fold_for_push_const = true;

  NIR_PASS(_, nir, ac_nir_lower_image_tex,
           &(ac_nir_lower_image_tex_options){
               .gfx_level = gfx_level,
               .lower_array_layer_round_even = false,
               .fix_derivs_in_divergent_cf =
                   nir->info.stage == MESA_SHADER_FRAGMENT && !use_llvm,
               .max_wqm_vgprs =
                   64, // TODO: improve spiller and RA support for linear VGPRs
           });

  if (nir->info.uses_resource_info_query)
    NIR_PASS(_, nir, ac_nir_lower_resinfo, gfx_level);

  NIR_PASS(_, nir, gnm_nir_lower_descriptors, gfx_level, family, info, args);

  NIR_PASS(_, nir, nir_lower_alu_width, ac_nir_opt_vectorize_cb, &gfx_level);

  nir_move_options sink_opts =
      nir_move_const_undef | nir_move_copies | nir_dont_move_byte_word_vecs;

  if (!optimisations_disabled) {
    NIR_PASS(_, nir, nir_opt_licm);

    if (nir->info.stage == MESA_SHADER_VERTEX) {
      /* Always load all VS inputs at the top to eliminate needless
       * VMEM->s_wait->VMEM sequences. Each s_wait can cost 1000 cycles, so make
       * sure all VS input loads are grouped.
       */
      NIR_PASS(_, nir, nir_opt_move_to_top, nir_move_to_top_input_loads);
      NIR_PASS(_, nir, nir_opt_sink, sink_opts);
      NIR_PASS(_, nir, nir_opt_move, sink_opts);
    } else {
      if (nir->info.stage != MESA_SHADER_FRAGMENT)
        sink_opts |= nir_move_load_input | nir_move_load_frag_coord;

      NIR_PASS(_, nir, nir_opt_sink, sink_opts);
      NIR_PASS(_, nir, nir_opt_move,
               sink_opts | nir_move_load_input | nir_move_load_frag_coord);
    }
  }

  /* Lower VS inputs. We need to do this after nir_opt_sink, because
   * load_input can be reordered, but buffer loads can't.
   */
  if (nir->info.stage == MESA_SHADER_VERTEX) {
    NIR_PASS(_, nir, gnm_nir_lower_vs_inputs, args, info);
  }

  /* Lower I/O intrinsics to memory instructions. */
  bool io_to_mem = gnm_nir_lower_io_to_mem(gfx_level, nir, info);
  bool is_last_vgt_stage = gnm_is_last_vgt_stage(nir);

  if (is_last_vgt_stage) {
    if (nir->info.stage != MESA_SHADER_GEOMETRY) {
      NIR_PASS(_, nir, ac_nir_lower_legacy_vs, gfx_level,
               info->outinfo.clip_dist_mask | info->outinfo.cull_dist_mask,
               false, info->outinfo.vs_output_param_offset,
               info->outinfo.param_exports, info->outinfo.export_prim_id, false,
               info->force_vrs_per_vertex);

    } else {
      ac_nir_lower_legacy_gs_options options = {
          .has_gen_prim_query = false,
          .has_pipeline_stats_query = false,
          .gfx_level = gfx_level,
          .export_clipdist_mask =
              info->outinfo.clip_dist_mask | info->outinfo.cull_dist_mask,
          .param_offsets = info->outinfo.vs_output_param_offset,
          .has_param_exports = info->outinfo.param_exports,
          .force_vrs = info->force_vrs_per_vertex,
      };
      ac_nir_legacy_gs_info gs_info = {0};

      nir_shader *gs_copy_shader;
      NIR_PASS(_, nir, ac_nir_lower_legacy_gs, &options, &gs_copy_shader,
               &gs_info);

      for (unsigned i = 0; i < 4; i++)
        info->gs.num_components_per_stream[i] =
            gs_info.num_components_per_stream[i];
    }
  } else if (nir->info.stage == MESA_SHADER_FRAGMENT) {
    ac_nir_lower_ps_late_options late_options = {
        .gfx_level = gfx_level,
        .use_aco = !use_llvm,
        .bc_optimize_for_persp =
            G_0286CC_PERSP_CENTER_ENA(info->ps.spi_ps_input_ena) &&
            G_0286CC_PERSP_CENTROID_ENA(info->ps.spi_ps_input_ena),
        .bc_optimize_for_linear =
            G_0286CC_LINEAR_CENTER_ENA(info->ps.spi_ps_input_ena) &&
            G_0286CC_LINEAR_CENTROID_ENA(info->ps.spi_ps_input_ena),
        .uses_discard = info->ps.can_discard,
        .dcc_decompress_gfx11 = false,
        .no_color_export = info->ps.has_epilog,
        .no_depth_export = info->ps.exports_mrtz_via_epilog,
    };

    if (!late_options.no_color_export) {
      late_options.dual_src_blend = info->ps.mrt0_is_dual_src;
      late_options.color_is_int8 = pipe_key->ps.epilog.color_is_int8;
      late_options.color_is_int10 = pipe_key->ps.epilog.color_is_int10;
      late_options.enable_mrt_output_nan_fixup =
          pipe_key->ps.epilog.enable_mrt_output_nan_fixup;
      /* Need to filter out unwritten color slots. */
      late_options.spi_shader_col_format =
          pipe_key->ps.epilog.spi_shader_col_format & info->ps.colors_written;
      late_options.alpha_to_one = false;
    }

    if (!late_options.no_depth_export) {
      /* Compared to gfx_state.ps.alpha_to_coverage_via_mrtz,
       * radv_shader_info.ps.writes_mrt0_alpha need any
       * depth/stencil/sample_mask exist. ac_nir_lower_ps() require this field
       * to reflect whether alpha via mrtz is really present.
       */
      late_options.alpha_to_coverage_via_mrtz = info->ps.writes_mrt0_alpha;
    }

    NIR_PASS(_, nir, ac_nir_lower_ps_late, &late_options);
  }

  /* This must be after lowering resources to descriptor loads and before
   * lowering intrinsics to args and lowering int64.
   */
  if (!use_llvm)
    ac_nir_optimize_uniform_atomics(nir);

  NIR_PASS(_, nir, nir_opt_uniform_subgroup,
           &(struct nir_lower_subgroups_options){
               .subgroup_size = info->wave_size,
               .ballot_bit_size = info->wave_size,
               .ballot_components = 1,
               .lower_ballot_bit_count_to_mbcnt_amd = true,
           });

  NIR_PASS(_, nir, nir_opt_idiv_const, 8);

  NIR_PASS(_, nir, nir_lower_idiv,
           &(nir_lower_idiv_options){
               .allow_fp16 = gfx_level >= GFX9,
           });

  NIR_PASS(_, nir, ac_nir_lower_intrinsics_to_args, &args->ac,
           &(ac_nir_lower_intrinsics_to_args_options){
               .gfx_level = gfx_level,
               .has_ls_vgpr_init_bug = false,
               .hw_stage = gnm_select_hw_stage(info, gfx_level),
               .wave_size = info->wave_size,
               .workgroup_size = info->workgroup_size,
               .use_llvm = use_llvm,
               .load_grid_size_from_user_sgpr = gfx_level >= GFX10_3,
           });
  // NIR_PASS(_, nir, gnm_nir_lower_abi, gfx_level, stage, gfx_state,
  // pdev->info.address32_hi);

  if (!optimisations_disabled) {
    NIR_PASS(_, nir, nir_opt_dce);

    NIR_PASS(_, nir, nir_opt_copy_prop);
    NIR_PASS(_, nir, nir_opt_constant_folding);
    NIR_PASS(_, nir, nir_opt_cse);
    NIR_PASS(_, nir, nir_opt_if, nir_opt_if_optimize_phi_true_false);
    NIR_PASS(_, nir, nir_opt_shrink_vectors, true);

    NIR_PASS(_, nir, ac_nir_flag_smem_for_loads, gfx_level, use_llvm);
    NIR_PASS(_, nir, ac_nir_lower_mem_access_bit_sizes, gfx_level, use_llvm);

    nir_load_store_vectorize_options late_vectorize_opts = {
        .modes = nir_var_mem_global | nir_var_mem_shared | nir_var_shader_out |
                 nir_var_mem_task_payload | nir_var_shader_in,
        .callback = ac_nir_mem_vectorize_callback,
        .cb_data = &(struct ac_nir_config){gfx_level, !use_llvm},
        .robust_modes = 0,
        .bounds_checked_modes =
            nir_var_mem_ssbo | nir_var_mem_ubo | nir_var_mem_shared,
        .has_shared2_amd = true,
    };
    NIR_PASS(_, nir, nir_opt_load_store_vectorize, &late_vectorize_opts);
  }

  NIR_PASS(_, nir, ac_nir_lower_mem_access_bit_sizes, gfx_level, use_llvm);
  NIR_PASS(_, nir, ac_nir_lower_global_access);
  NIR_PASS(_, nir, nir_lower_int64);

  bool opt_intrinsics = false;
  if (gfx_level >= GFX11)
    NIR_PASS(opt_intrinsics, nir, ac_nir_opt_flip_if_for_mem_loads);
  if (opt_intrinsics) /* optimize inot(inverse_ballot) */
    NIR_PASS(_, nir, nir_opt_intrinsics);

  gnm_optimize_nir_algebraic(nir,
                             io_to_mem ||
                                 nir->info.stage == MESA_SHADER_COMPUTE ||
                                 nir->info.stage == MESA_SHADER_TASK,
                             gfx_level >= GFX8, gfx_level);

  NIR_PASS(_, nir, nir_lower_fp16_casts, nir_lower_fp16_split_fp64);

  if (ac_nir_might_lower_bit_size(nir)) {
    if (gfx_level >= GFX8)
      nir_divergence_analysis(nir);

    if (nir_lower_bit_size(nir, ac_nir_lower_bit_size_callback, &gfx_level)) {
      NIR_PASS(_, nir, nir_opt_constant_folding);
    }
  }
  if (gfx_level >= GFX9) {
    bool separate_g16 = gfx_level >= GFX10;
    struct nir_opt_tex_srcs_options opt_srcs_options[] = {
        {
            .sampler_dims = ~(BITFIELD_BIT(GLSL_SAMPLER_DIM_CUBE) |
                              BITFIELD_BIT(GLSL_SAMPLER_DIM_BUF)),
            .src_types = (1 << nir_tex_src_coord) | (1 << nir_tex_src_lod) |
                         (1 << nir_tex_src_bias) | (1 << nir_tex_src_min_lod) |
                         (1 << nir_tex_src_ms_index) |
                         (separate_g16 ? 0
                                       : (1 << nir_tex_src_ddx) |
                                             (1 << nir_tex_src_ddy)),
        },
        {
            .sampler_dims = ~BITFIELD_BIT(GLSL_SAMPLER_DIM_CUBE),
            .src_types = (1 << nir_tex_src_ddx) | (1 << nir_tex_src_ddy),
        },
    };
    struct nir_opt_16bit_tex_image_options opt_16bit_options = {
        .rounding_mode = nir_rounding_mode_undef,
        .opt_tex_dest_types = nir_type_float | nir_type_int | nir_type_uint,
        .opt_image_dest_types = nir_type_float | nir_type_int | nir_type_uint,
        .integer_dest_saturates = true,
        .opt_image_store_data = true,
        .opt_image_srcs = true,
        .opt_srcs_options_count = separate_g16 ? 2 : 1,
        .opt_srcs_options = opt_srcs_options,
    };
    bool run_copy_prop = false;
    NIR_PASS(run_copy_prop, nir, nir_opt_16bit_tex_image, &opt_16bit_options);

    /* Optimizing 16bit texture/image dests leaves scalar moves that need to be
     * removed before the next alu nir_lower_alu_width, otherwise we might end
     * up with invalid swizzles in the backend. It also allows nir_opt_vectorize
     * to make more progress.
     */
    if (run_copy_prop) {
      NIR_PASS(_, nir, nir_opt_copy_prop);
      NIR_PASS(_, nir, nir_opt_dce);
    }

    if (!optimisations_disabled) {
      NIR_PASS(_, nir, nir_opt_vectorize, ac_nir_opt_vectorize_cb, &gfx_level);
    }
  }

  /* cleanup passes */
  NIR_PASS(_, nir, nir_lower_alu_width, ac_nir_opt_vectorize_cb, &gfx_level);

  NIR_PASS(_, nir, nir_lower_load_const_to_scalar);
  NIR_PASS(_, nir, nir_opt_copy_prop);
  NIR_PASS(_, nir, nir_opt_dce);

  if (!optimisations_disabled) {
    sink_opts |= nir_move_comparisons | nir_move_load_ubo | nir_move_load_ssbo |
                 nir_move_alu;
    NIR_PASS(_, nir, nir_opt_sink, sink_opts);

    nir_move_options move_opts =
        nir_move_const_undef | nir_move_load_ubo | nir_move_load_input |
        nir_move_load_frag_coord | nir_move_comparisons | nir_move_copies |
        nir_dont_move_byte_word_vecs | nir_move_alu;
    NIR_PASS(_, nir, nir_opt_move, move_opts);

    /* Run nir_opt_move again to make sure that comparision are as close as
     * possible to the first use to prevent SCC spilling.
     */
    NIR_PASS(_, nir, nir_opt_move, nir_move_comparisons);
  }

  info->nir_shared_size = nir->info.shared_size;
}
