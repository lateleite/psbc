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

#include "gnm_shader.h"

#include "ac_nir.h"
#include "amdgfxregs.h"
#include "gnm_shader_args.h"
#include "nir/gnm_nir.h"
#include "spirv/nir_spirv.h"
#include "spirv_info.h"

static uint8_t vectorize_vec2_16bit(const nir_instr *instr, const void *_) {
  if (instr->type != nir_instr_type_alu)
    return 0;

  const nir_alu_instr *alu = nir_instr_as_alu(instr);
  const unsigned bit_size = alu->def.bit_size;
  if (bit_size == 16)
    return 2;
  else
    return 1;
}

nir_function_impl *gnm_get_rt_shader_entrypoint(nir_shader *shader) {
  nir_foreach_function_impl(
      impl, shader) if (impl->function->is_entrypoint ||
                        impl->function->is_exported) return impl;
  return NULL;
}

void gnm_optimize_nir(struct nir_shader *shader, bool optimize_conservatively) {
  bool progress;

  NIR_PASS(_, shader, nir_lower_alu_width, vectorize_vec2_16bit, NULL);
  NIR_PASS(_, shader, nir_opt_fp_math_ctrl);

  struct set *skip = _mesa_pointer_set_create(NULL);
  do {
    progress = false;

    NIR_LOOP_PASS(progress, skip, shader, nir_split_array_vars,
                  nir_var_function_temp);
    NIR_LOOP_PASS(progress, skip, shader, nir_shrink_vec_array_vars,
                  nir_var_function_temp | nir_var_mem_shared);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_copy_prop_vars);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_dead_write_vars);

    NIR_LOOP_PASS(_, skip, shader, nir_lower_phis_to_scalar,
                  ac_nir_lower_phis_to_scalar_cb, NULL);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_copy_prop);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_remove_phis);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_dce);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_dead_cf);
    bool opt_loop_progress = false;
    NIR_LOOP_PASS_NOT_IDEMPOTENT(opt_loop_progress, skip, shader, nir_opt_loop);
    if (opt_loop_progress) {
      progress = true;
      NIR_LOOP_PASS(progress, skip, shader, nir_opt_copy_prop);
      NIR_LOOP_PASS(progress, skip, shader, nir_opt_remove_phis);
      NIR_LOOP_PASS(progress, skip, shader, nir_opt_dce);
    }
    NIR_LOOP_PASS_NOT_IDEMPOTENT(progress, skip, shader, nir_opt_if,
                                 nir_opt_if_optimize_phi_true_false);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_cse);

    nir_opt_peephole_select_options peephole_select_options = {
        .limit = 8,
        .indirect_load_ok = true,
        .expensive_alu_ok = true,
        .discard_ok = true,
    };
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_peephole_select,
                  &peephole_select_options);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_constant_folding);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_intrinsics);
    NIR_LOOP_PASS_NOT_IDEMPOTENT(progress, skip, shader, nir_opt_algebraic);
    NIR_LOOP_PASS(progress, skip, shader, nir_opt_phi_to_bool);

    NIR_LOOP_PASS(progress, skip, shader, nir_opt_undef);

    if (shader->options->max_unroll_iterations) {
      bool unroll_progess = false;
      NIR_LOOP_PASS_NOT_IDEMPOTENT(unroll_progess, skip, shader,
                                   nir_opt_loop_unroll);
      /* Loop unrolling can add trivial phis for constants defined in the loop,
       * which can break all kinds of validation if they aren't removed
       * immediately.
       */
      if (unroll_progess) {
        progress = true;
        NIR_LOOP_PASS(progress, skip, shader, nir_opt_remove_phis);
      }
    }
  } while (progress && !optimize_conservatively);
  _mesa_set_destroy(skip, NULL);

  NIR_PASS(progress, shader, nir_opt_shrink_vectors, true);
  NIR_PASS(progress, shader, nir_remove_dead_variables,
           nir_var_function_temp | nir_var_shader_in | nir_var_shader_out |
               nir_var_mem_shared,
           NULL);

  if (shader->info.stage == MESA_SHADER_FRAGMENT &&
      shader->info.fs.uses_discard)
    NIR_PASS(progress, shader, nir_opt_move_discards_to_top);

  NIR_PASS(progress, shader, nir_opt_move, nir_move_load_ubo);

  /* gnm_get_rt_shader_entrypoint returns the entrypoint for non-RT shaders too.
   */
  nir_function_impl *entrypoint = gnm_get_rt_shader_entrypoint(shader);
  nir_shader_gather_info(shader, entrypoint);
}

void gnm_optimize_nir_algebraic_early(nir_shader *nir) {
  bool more_algebraic = true;
  bool had_opt_fp_math_ctrl = false;
  while (more_algebraic) {
    more_algebraic = false;
    NIR_PASS(_, nir, nir_opt_copy_prop);
    NIR_PASS(_, nir, nir_opt_dce);
    NIR_PASS(_, nir, nir_opt_constant_folding);
    NIR_PASS(_, nir, nir_opt_cse);

    nir_opt_peephole_select_options peephole_select_options = {
        .limit = 8,
        .indirect_load_ok = true,
        .expensive_alu_ok = true,
        .discard_ok = true,
    };
    NIR_PASS(_, nir, nir_opt_peephole_select, &peephole_select_options);
    NIR_PASS(_, nir, nir_opt_undef);
    NIR_PASS(_, nir, nir_opt_phi_to_bool);
    NIR_PASS(more_algebraic, nir, nir_opt_algebraic);
    NIR_PASS(_, nir, nir_opt_generate_bfi);
    NIR_PASS(_, nir, nir_opt_remove_phis);
    NIR_PASS(_, nir, nir_opt_dead_cf);

    if (!had_opt_fp_math_ctrl) {
      NIR_PASS(more_algebraic, nir, nir_opt_fp_math_ctrl);
      had_opt_fp_math_ctrl = true;
    }
  }
}

void gnm_optimize_nir_algebraic_late(nir_shader *nir) {
  /* Do late algebraic optimization to turn add(a,
   * neg(b)) back into subs, then the mandatory cleanup
   * after algebraic.  Note that it may produce fnegs,
   * and if so then we need to keep running to squash
   * fneg(fneg(a)).
   */
  bool more_late_algebraic = true;
  struct set *skip = _mesa_pointer_set_create(NULL);
  while (more_late_algebraic) {
    more_late_algebraic = false;
    NIR_LOOP_PASS_NOT_IDEMPOTENT(more_late_algebraic, skip, nir,
                                 nir_opt_algebraic_late);
    NIR_LOOP_PASS(_, skip, nir, nir_opt_constant_folding);
    NIR_LOOP_PASS(_, skip, nir, nir_opt_copy_prop);
    NIR_LOOP_PASS(_, skip, nir, nir_opt_dce);
    NIR_LOOP_PASS(_, skip, nir, nir_opt_cse);
  }
  _mesa_set_destroy(skip, NULL);
}

void gnm_optimize_nir_algebraic(nir_shader *nir, bool opt_offsets,
                                bool opt_mqsad, enum amd_gfx_level gfx_level) {
  gnm_optimize_nir_algebraic_early(nir);

  if (opt_offsets) {
    const nir_opt_offsets_options offset_options = {
        .uniform_max = 0,
        .buffer_max = ~0,
        .shared_max = UINT16_MAX,
        .shared_atomic_max = UINT16_MAX,
        .allow_offset_wrap_cb = ac_nir_allow_offset_wrap_cb,
        .cb_data = &gfx_level,
    };
    NIR_PASS(_, nir, nir_opt_offsets, &offset_options);
  }
  if (opt_mqsad)
    NIR_PASS(_, nir, nir_opt_mqsad);

  gnm_optimize_nir_algebraic_late(nir);
}

static void shared_var_info(const struct glsl_type *type, unsigned *size,
                            unsigned *align) {
  assert(glsl_type_is_vector_or_scalar(type));

  uint32_t comp_size =
      glsl_type_is_boolean(type) ? 4 : glsl_get_bit_size(type) / 8;
  unsigned length = glsl_get_vector_elements(type);
  *size = comp_size * length, *align = comp_size;
}

static void gnm_shader_choose_subgroup_size(enum amd_gfx_level gfx_level,
                                            nir_shader *nir) {
  nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));

  unsigned wave_size;

  if (nir->info.min_subgroup_size == nir->info.max_subgroup_size) {
    wave_size = nir->info.min_subgroup_size;
  } else if (mesa_shader_stage_uses_workgroup(nir->info.stage)) {
    const unsigned local_size = nir->info.workgroup_size[0] *
                                nir->info.workgroup_size[1] *
                                nir->info.workgroup_size[2];

    unsigned default_wave_size = 64;

    /* Games don't always request full subgroups when they should, which can
     * cause bugs if cswave32 is enabled. Furthermore, if cooperative matrices
     * or subgroup info are used, we can't transparently change the subgroup
     * size.
     */
    const bool require_full_subgroups =
        (default_wave_size == 32 &&
         (nir->info.uses_wide_subgroup_intrinsics ||
          (nir->info.stage == MESA_SHADER_COMPUTE &&
           nir->info.cs.has_cooperative_matrix)) &&
         local_size % GNM_SUBGROUP_SIZE == 0);

    /* Use wave32 for small workgroups. */
    if (local_size <= 32)
      wave_size = 32;
    else if (require_full_subgroups)
      wave_size = 64;
    else
      wave_size = default_wave_size;
  } else if (nir->info.stage == MESA_SHADER_GEOMETRY &&
             (gfx_level >= GFX10 && gfx_level <= GFX10_3)) {
    /* Legacy GS doesn't support wave32. */
    wave_size = 64;
  } else if (nir->info.stage == MESA_SHADER_FRAGMENT) {
    wave_size = 64;
  } else {
    wave_size = 64;
  }

  if (nir->info.api_subgroup_size == 0) {
    /* Report real wave_size for allow_varying. */
    nir->info.api_subgroup_size = wave_size;
  }

  nir->info.max_subgroup_size = wave_size;

  /* We might still decide to use ngg later. */
  if (nir->info.stage == MESA_SHADER_GEOMETRY)
    nir->info.min_subgroup_size = 64;
  else
    nir->info.min_subgroup_size = wave_size;
}

nir_shader *
gnm_shader_spirv_to_nir(enum amd_gfx_level gfx_level, const uint32_t *spirv,
                        size_t spirv_size, mesa_shader_stage shader_stage,
                        const nir_shader_compiler_options *nir_options,
                        const char *entrypoint, bool optimisations_disabled) {
  // unsigned subgroup_size = 64, ballot_bit_size = 64;

  nir_shader *nir;

  assert(spirv_size % 4 == 0);

  const struct spirv_capabilities spirv_caps = {
      .FragmentMaskAMD = true,
      .ImageGatherBiasLodAMD = true,
      .ImageReadWriteLodAMD = true,
      .DemoteToHelperInvocation = true,
      .ComputeDerivativeGroupQuadsKHR = true,
      .DeviceGroup = true,
      .DrawParameters = true,
      .FloatControls2 = true,
      .Float16 = gfx_level >= GFX9,
      .AtomicFloat32AddEXT = true,
      .AtomicFloat32MinMaxEXT = true,
      .Float64 = true,
      .AtomicFloat64AddEXT = true,
      .FragmentFullyCoveredEXT = true,
      .GeometryStreams = true,
      .Groups = true,
      .ImageMSArray = true,
      .StorageImageReadWithoutFormat = true,
      .StorageImageWriteWithoutFormat = true,
      .Int8 = true,
      .Int16 = true,
      .Int64 = true,
      .Int64Atomics = true,
      .MeshShadingNV = true,
      .MinLod = true,
      .MultiViewport = true,
      .PhysicalStorageBufferAddresses = true,
      .SampleMaskPostDepthCoverage = true,
      .RayCullMaskKHR = true,
      .RayQueryKHR = true,
      .RayTracingKHR = true,
      .RayTraversalPrimitiveCullingKHR = true,
      .RuntimeDescriptorArray = true,
      .Shader = true,
      .ShaderClockKHR = true,
      .ShaderViewportIndexLayerEXT = true,
      .SparseResidency = true,
      .StencilExportEXT = true,
      .StorageBuffer8BitAccess = true,
      .StorageBuffer16BitAccess = true,
      .StorageImageMultisample = true,
      .SubgroupBallotKHR = true,
      .SubgroupShuffleINTEL = true,
      .SubgroupVoteKHR = true,
      .Tessellation = true,
      .TransformFeedback = true,
      .VariablePointers = true,
      .VulkanMemoryModel = true,
      .VulkanMemoryModelDeviceScope = true,
      .FragmentShadingRateKHR = gfx_level >= GFX10_3,
      .WorkgroupMemoryExplicitLayoutKHR = true,
  };
  const struct spirv_to_nir_options spirv_options = {
      .amd_gcn_shader = true,
      .amd_shader_ballot = true,
      .amd_shader_explicit_vertex_parameter = true,
      .amd_trinary_minmax = true,
      .capabilities = &spirv_caps,
      .ubo_addr_format = nir_address_format_vec2_index_32bit_offset,
      .ssbo_addr_format = nir_address_format_vec2_index_32bit_offset,
      .phys_ssbo_addr_format = nir_address_format_64bit_global,
      .push_const_addr_format = nir_address_format_logical,
      .shared_addr_format = nir_address_format_32bit_offset,
      .constant_addr_format = nir_address_format_64bit_global,
  };
  nir = spirv_to_nir(spirv, spirv_size / 4, NULL, 0, shader_stage, entrypoint,
                     &spirv_options, nir_options);
  if (!nir) {
    return NULL;
  }
  assert(nir->info.stage == shader_stage);
  nir_validate_shader(nir, "after spirv_to_nir");

  const struct nir_lower_sysvals_to_varyings_options sysvals_to_varyings = {
      .point_coord = true,
      .primitive_id = nir->info.stage == MESA_SHADER_FRAGMENT,
  };
  NIR_PASS(_, nir, nir_lower_sysvals_to_varyings, &sysvals_to_varyings);

  /* We have to lower away local constant initializers right before we
   * inline functions.  That way they get properly initialized at the top
   * of the function and not at the top of its caller.
   */
  NIR_PASS(_, nir, nir_lower_variable_initializers, nir_var_function_temp);
  NIR_PASS(_, nir, nir_lower_returns);

  bool progress = false;
  NIR_PASS(progress, nir, nir_inline_functions);
  if (progress) {
    NIR_PASS(_, nir, nir_opt_copy_prop_vars);
    NIR_PASS(_, nir, nir_opt_copy_prop);
  }
  NIR_PASS(_, nir, nir_opt_deref);

  /* Pick off the single entrypoint that we want - leave cmat call functions */
  nir_remove_non_cmat_call_entrypoints(nir);

  /* Make sure we lower constant initializers on output variables so that
   * nir_remove_dead_variables below sees the corresponding stores
   */
  NIR_PASS(_, nir, nir_lower_variable_initializers, nir_var_shader_out);

  /* Now that we've deleted all but the main function, we can go ahead and
   * lower the rest of the constant initializers.
   */
  NIR_PASS(_, nir, nir_lower_variable_initializers, ~0);

  gnm_shader_choose_subgroup_size(gfx_level, nir);

  progress = false;
  NIR_PASS(progress, nir, nir_lower_cooperative_matrix_flexible_dimensions, 16,
           16, 16);
  if (progress) {
    NIR_PASS(_, nir, nir_opt_deref);
    NIR_PASS(_, nir, nir_opt_dce);
    NIR_PASS(_, nir, nir_remove_dead_variables,
             nir_var_function_temp | nir_var_shader_temp, NULL);
  }

  NIR_PASS(progress, nir, gnm_nir_lower_cooperative_matrix, gfx_level,
           nir->info.max_subgroup_size);
  if (progress) {
    NIR_PASS(_, nir, nir_opt_dce);
    NIR_PASS(progress, nir, nir_inline_functions);
    nir_remove_non_entrypoints(nir); /* remove the late inlined functions */
    if (progress) {
      NIR_PASS(_, nir, nir_opt_copy_prop_vars);
      NIR_PASS(_, nir, nir_opt_copy_prop);
    }
    NIR_PASS(_, nir, nir_opt_deref);
    NIR_PASS(_, nir, nir_opt_dce);
  }

  /* Split member structs.  We do this before lower_io_to_temporaries so that
   * it doesn't lower system values to temporaries by accident.
   */
  NIR_PASS(_, nir, nir_split_var_copies);
  NIR_PASS(_, nir, nir_split_per_member_structs);

  if (nir->info.stage == MESA_SHADER_FRAGMENT)
    NIR_PASS(_, nir, nir_lower_input_attachments,
             &(nir_input_attachment_options){
                 .use_ia_coord_intrin = true,
             });

  nir_remove_dead_variables_options dead_vars_opts = {};
  NIR_PASS(_, nir, nir_remove_dead_variables,
           nir_var_shader_in | nir_var_shader_out | nir_var_system_value |
               nir_var_mem_shared,
           &dead_vars_opts);

  /* Variables can make nir_propagate_invariant more conservative
   * than it needs to be.
   */
  NIR_PASS(_, nir, nir_lower_global_vars_to_local);

  NIR_PASS(_, nir, nir_lower_vars_to_ssa);

  NIR_PASS(_, nir, nir_propagate_invariant, false);

  nir_gather_clip_cull_distance_sizes_from_vars(nir);
  NIR_PASS(_, nir, nir_merge_clip_cull_distance_vars);

  nir_lower_doubles_options lower_doubles = nir->options->lower_doubles_options;

  if (gfx_level == GFX6) {
    /* GFX6 doesn't support v_floor_f64 and the precision
     * of v_fract_f64 which is used to implement 64-bit
     * floor is less than what Vulkan requires.
     */
    lower_doubles |= nir_lower_dfloor;
  }

  NIR_PASS(_, nir, nir_lower_doubles, NULL, lower_doubles);

  NIR_PASS(_, nir, nir_normalize_sin_cos);

  NIR_PASS(_, nir, nir_lower_system_values);

  if (gfx_level < GFX12 &&
      nir->info.derivative_group == DERIVATIVE_GROUP_QUADS) {
    nir_lower_compute_system_values_options csv_options = {
        .shuffle_local_ids_for_quad_derivatives = true,
        .lower_local_invocation_index = true,
    };

    NIR_PASS(_, nir, nir_opt_cse); /* CSE load_local_invocation_id */
    NIR_PASS(_, nir, nir_lower_compute_system_values, &csv_options);
  }

  bool lower_local_invocation_index = false;

  if (nir->info.stage == MESA_SHADER_COMPUTE ||
      nir->info.stage == MESA_SHADER_TASK ||
      nir->info.stage == MESA_SHADER_MESH) {
    lower_local_invocation_index =
        nir->info.derivative_group == DERIVATIVE_GROUP_QUADS ||
        (((nir->info.workgroup_size[0] == 1) +
          (nir->info.workgroup_size[1] == 1) +
          (nir->info.workgroup_size[2] == 1)) == 2);
  }

  nir_lower_compute_system_values_options csv_options = {
      /* Mesh shaders run as NGG which can implement local_invocation_index from
       * the wave ID in merged_wave_info, but they don't have
       * local_invocation_ids on GFX10.3.
       */
      .lower_cs_local_id_to_index = false,
      .lower_local_invocation_index = lower_local_invocation_index,
  };
  NIR_PASS(_, nir, nir_lower_compute_system_values, &csv_options);

  nir_shader_gather_info(nir, nir_shader_get_entrypoint(nir));

  nir_lower_tex_options tex_options = {
      .lower_txp = ~0,
      .lower_txf_offset = true,
      .lower_tg4_offsets = true,
      .lower_txs_cube_array = true,
      .lower_to_fragment_fetch_amd = gfx_level <= GFX11,
      .lower_lod_zero_width = true,
      .lower_invalid_implicit_lod = true,
      .lower_1d = gfx_level == GFX9,
      .optimize_txd = true,
  };

  NIR_PASS(_, nir, nir_lower_tex, &tex_options);

  static const nir_lower_image_options image_options = {
      .lower_cube_size = true,
  };

  NIR_PASS(_, nir, nir_lower_image, &image_options);

  if (nir->info.stage == MESA_SHADER_VERTEX ||
      nir->info.stage == MESA_SHADER_GEOMETRY ||
      nir->info.stage == MESA_SHADER_FRAGMENT) {
    NIR_PASS(_, nir, nir_lower_io_vars_to_temporaries,
             nir_shader_get_entrypoint(nir),
             nir_var_shader_in | nir_var_shader_out);
  } else if (nir->info.stage == MESA_SHADER_TESS_EVAL) {
    NIR_PASS(_, nir, nir_lower_io_vars_to_temporaries,
             nir_shader_get_entrypoint(nir), nir_var_shader_out);
  }

  NIR_PASS(_, nir, nir_split_var_copies);

  NIR_PASS(_, nir, nir_lower_global_vars_to_local);
  NIR_PASS(_, nir, nir_remove_dead_variables, nir_var_function_temp, NULL);

  bool gfx7minus = gfx_level <= GFX7;
  bool use_llvm = false;

  NIR_PASS(_, nir, nir_lower_subgroups,
           &(struct nir_lower_subgroups_options){
               .subgroup_size = nir->info.api_subgroup_size,
               .ballot_bit_size = nir->info.api_subgroup_size,
               .ballot_components = 1,
               .lower_to_scalar = 1,
               .lower_subgroup_masks = 1,
               .lower_relative_shuffle = 1,
               .lower_rotate_to_shuffle = use_llvm,
               .lower_shuffle_to_32bit = 1,
               .lower_vote_feq = 1,
               .lower_vote_ieq = 1,
               .lower_vote_bool_eq = 1,
               .lower_quad_broadcast_dynamic = 1,
               .lower_quad_broadcast_dynamic_to_const = gfx7minus,
               .lower_shuffle_to_swizzle_amd = 1,
               .lower_ballot_bit_count_to_mbcnt_amd = 1,
               .lower_boolean_reduce = !use_llvm,
               .lower_boolean_shuffle = true,
           });

  NIR_PASS(_, nir, nir_lower_load_const_to_scalar);
  NIR_PASS(_, nir, nir_opt_shrink_stores, true);
  if (nir->info.stage == MESA_SHADER_FRAGMENT && nir->info.fs.uses_discard)
    NIR_PASS(_, nir, nir_lower_discard_if, nir_move_terminate_out_of_loops);

  const nir_opt_access_options opt_access_options = {
      .is_vulkan = true,
  };
  NIR_PASS(_, nir, nir_opt_access, &opt_access_options);

  if (!optimisations_disabled) {
    /* Only run this pass once before nir_lower_var_copies is called,
     * so that we don't introduce any new copy_deref instructions later.
     */
    NIR_PASS(_, nir, nir_opt_find_array_copies);
    NIR_PASS(_, nir, nir_lower_vars_to_ssa);

    gnm_optimize_nir(nir, false);

    NIR_PASS(_, nir, nir_opt_memcpy);
    NIR_PASS(_, nir, nir_opt_deref);
  }

  /* We call nir_lower_var_copies() after the first gnm_optimize_nir()
   * to remove any copies introduced by nir_opt_find_array_copies().
   */
  NIR_PASS(_, nir, nir_lower_var_copies);

  NIR_PASS(_, nir, nir_lower_memcpy);

  unsigned lower_flrp = (nir->options->lower_flrp16 ? 16 : 0) |
                        (nir->options->lower_flrp32 ? 32 : 0) |
                        (nir->options->lower_flrp64 ? 64 : 0);
  if (lower_flrp != 0)
    NIR_PASS(progress, nir, nir_lower_flrp, lower_flrp,
             false /* always precise */);

  NIR_PASS(_, nir, nir_lower_explicit_io, nir_var_mem_push_const,
           nir_address_format_32bit_offset);

  NIR_PASS(_, nir, nir_lower_explicit_io, nir_var_mem_ubo | nir_var_mem_ssbo,
           nir_address_format_vec2_index_32bit_offset);

  NIR_PASS(_, nir, gnm_nir_lower_intrinsics_early, true);

  /* Lower deref operations for compute shared memory. */
  if (nir->info.stage == MESA_SHADER_COMPUTE ||
      nir->info.stage == MESA_SHADER_TASK ||
      nir->info.stage == MESA_SHADER_MESH) {
    nir_variable_mode var_modes = nir_var_mem_shared;

    if (nir->info.stage == MESA_SHADER_TASK ||
        nir->info.stage == MESA_SHADER_MESH)
      var_modes |= nir_var_mem_task_payload;

    NIR_PASS(_, nir, nir_lower_vars_to_explicit_types, var_modes,
             shared_var_info);
    NIR_PASS(_, nir, nir_lower_explicit_io, var_modes,
             nir_address_format_32bit_offset);

    if (nir->info.zero_initialize_shared_memory && nir->info.shared_size > 0) {
      const unsigned chunk_size = 16; /* max single store size */
      const unsigned shared_size = align(nir->info.shared_size, chunk_size);
      NIR_PASS(_, nir, nir_zero_initialize_shared_memory, shared_size,
               chunk_size);
    }
  }

  NIR_PASS(_, nir, nir_lower_explicit_io,
           nir_var_mem_global | nir_var_mem_constant,
           nir_address_format_64bit_global);

  NIR_PASS(_, nir, gnm_nir_fix_buffer_access_chains);

  /* Lower large variables that are always constant with load_constant
   * intrinsics, which get turned into PC-relative loads from a data
   * section next to the shader.
   */
  NIR_PASS(_, nir, nir_opt_large_constants, glsl_get_natural_size_align_bytes,
           16);

  /* Lower primitive shading rate to match HW requirements. */
  if ((nir->info.stage == MESA_SHADER_VERTEX ||
       nir->info.stage == MESA_SHADER_GEOMETRY ||
       nir->info.stage == MESA_SHADER_MESH) &&
      nir->info.outputs_written & VARYING_BIT_PRIMITIVE_SHADING_RATE) {
    /* Lower primitive shading rate to match HW requirements. */
    NIR_PASS(_, nir, gnm_nir_lower_primitive_shading_rate, gfx_level);
  }

  /* Indirect lowering must be called after the gnm_optimize_nir() loop
   * has been called at least once. Otherwise indirect lowering can
   * bloat the instruction count of the loop and cause it to be
   * considered too large for unrolling.
   */
  bool indirect_derefs_lowered = false;
  NIR_PASS(indirect_derefs_lowered, nir, ac_nir_lower_indirect_derefs);
  NIR_PASS(_, nir, nir_lower_vars_to_ssa);

  if (indirect_derefs_lowered && !optimisations_disabled &&
      nir->info.stage != MESA_SHADER_COMPUTE) {
    /* Optimize the lowered code before the linking optimizations. */
    gnm_optimize_nir(nir, false);
  }

  return nir;
}

static bool gnm_mem_ordered(enum amd_gfx_level gfx_level) {
  return gfx_level >= GFX10 && gfx_level < GFX12;
}

void gnm_postprocess_binary_config(enum amd_gfx_level gfx_level,
                                   const struct gnm_shader_info *info,
                                   const struct gnm_shader_args *args,
                                   mesa_shader_stage stage,
                                   struct ac_shader_config *config) {
  bool scratch_enabled = config->scratch_bytes_per_wave > 0;
  bool trap_enabled = false;
  unsigned vgpr_comp_cnt = 0;
  unsigned num_input_vgprs = args->ac.num_vgprs_used;

  if (stage == MESA_SHADER_FRAGMENT) {
    num_input_vgprs = ac_get_fs_input_vgpr_cnt(config);
  }

  unsigned num_vgprs = MAX2(config->num_vgprs, num_input_vgprs);
  /* +2 for the ring offsets, +3 for scratch wave offset and VCC */
  unsigned num_sgprs = MAX2(config->num_sgprs, args->ac.num_sgprs_used + 2 + 3);
  unsigned num_shared_vgprs = config->num_shared_vgprs;
  /* shared VGPRs are introduced in Navi and are allocated in blocks of 8 (RDNA
   * ref 3.6.5) */
  assert((gfx_level >= GFX10 && num_shared_vgprs % 8 == 0) ||
         (gfx_level < GFX10 && num_shared_vgprs == 0));
  unsigned num_shared_vgpr_blocks = num_shared_vgprs / 8;
  unsigned excp_en = 0, excp_en_msb = 0;
  bool dx10_clamp = gfx_level < GFX12;

  config->num_vgprs = num_vgprs;
  config->num_sgprs = num_sgprs;
  config->num_shared_vgprs = num_shared_vgprs;

  config->rsrc2 = S_00B12C_USER_SGPR(args->num_user_sgprs) |
                  S_00B12C_SCRATCH_EN(scratch_enabled) |
                  S_00B12C_TRAP_PRESENT(trap_enabled);

  if (trap_enabled) {
    /* Configure the shader exceptions like memory violation, etc.
     * TODO: Enable (and validate) more exceptions.
     */
    excp_en = 1 << 8; /* mem_viol */
  }

  if (gfx_level <= GFX10_3) {
    config->rsrc2 |= S_00B12C_SO_BASE0_EN(!!info->so.strides[0]) |
                     S_00B12C_SO_BASE1_EN(!!info->so.strides[1]) |
                     S_00B12C_SO_BASE2_EN(!!info->so.strides[2]) |
                     S_00B12C_SO_BASE3_EN(!!info->so.strides[3]) |
                     S_00B12C_SO_EN(!!info->so.enabled_stream_buffers_mask);
  }

  config->rsrc1 =
      S_00B848_VGPRS((num_vgprs - 1) / (info->wave_size == 32 ? 8 : 4)) |
      S_00B848_DX10_CLAMP(dx10_clamp) | S_00B848_FLOAT_MODE(config->float_mode);

  if (gfx_level >= GFX10) {
    config->rsrc2 |= S_00B22C_USER_SGPR_MSB_GFX10(args->num_user_sgprs >> 5);
  } else {
    config->rsrc1 |= S_00B228_SGPRS((num_sgprs - 1) / 8);
    config->rsrc2 |= S_00B22C_USER_SGPR_MSB_GFX9(args->num_user_sgprs >> 5);
  }

  mesa_shader_stage es_stage = MESA_SHADER_NONE;
  if (gfx_level >= GFX9) {
    es_stage = stage == MESA_SHADER_GEOMETRY ? info->gs.es_type : stage;
  }

  // assert(config->lds_size <= lds_size_per_workgroup);
  unsigned lds_alloc =
      ac_shader_encode_lds_size(config->lds_size, gfx_level, stage);

  switch (stage) {
  case MESA_SHADER_TESS_EVAL:
    if (info->tes.as_es) {
      assert(gfx_level <= GFX8);
      vgpr_comp_cnt = info->uses_prim_id ? 3 : 2;

      config->rsrc2 |= S_00B12C_OC_LDS_EN(1) | S_00B12C_EXCP_EN(excp_en);
    } else {
      bool enable_prim_id = info->outinfo.export_prim_id || info->uses_prim_id;
      vgpr_comp_cnt = enable_prim_id ? 3 : 2;

      config->rsrc1 |= S_00B128_MEM_ORDERED(gfx_level >= GFX10);
      if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
        config->rsrc1 |= S_00B128_MEM_ORDERED(gnm_mem_ordered(gfx_level));
      config->rsrc2 |= S_00B12C_OC_LDS_EN(1) | S_00B12C_EXCP_EN(excp_en);
    }
    config->rsrc2 |= S_00B22C_SHARED_VGPR_CNT(num_shared_vgpr_blocks);
    break;
  case MESA_SHADER_TESS_CTRL:
    if (gfx_level >= GFX9) {
      /* We need at least 2 components for LS.
       * VGPR0-3: (VertexID, RelAutoindex, InstanceID / StepRate0, InstanceID).
       * StepRate0 is set to 1. so that VGPR3 doesn't have to be loaded.
       */
      if (gfx_level >= GFX10) {
        if (info->vs.needs_instance_id) {
          vgpr_comp_cnt = gfx_level >= GFX12 ? 1 : 3;
        } else if (gfx_level <= GFX10_3) {
          vgpr_comp_cnt = 1;
        }
        config->rsrc2 |= S_00B42C_EXCP_EN_GFX6(excp_en);
      } else {
        vgpr_comp_cnt = info->vs.needs_instance_id ? 2 : 1;
        config->rsrc2 |= S_00B42C_EXCP_EN_GFX9(excp_en);
      }
    } else {
      config->rsrc2 |= S_00B12C_OC_LDS_EN(1) | S_00B12C_EXCP_EN(excp_en);
    }
    if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
      config->rsrc1 |= S_00B428_MEM_ORDERED(gnm_mem_ordered(gfx_level));
    config->rsrc1 |= S_00B428_WGP_MODE(config->wgp_mode);
    config->rsrc2 |= S_00B42C_SHARED_VGPR_CNT(num_shared_vgpr_blocks);
    break;
  case MESA_SHADER_VERTEX:
    if (info->vs.as_ls) {
      assert(gfx_level <= GFX8);
      /* We need at least 2 components for LS.
       * VGPR0-3: (VertexID, RelAutoindex, InstanceID / StepRate0, InstanceID).
       * StepRate0 is set to 1. so that VGPR3 doesn't have to be loaded.
       */
      vgpr_comp_cnt = info->vs.needs_instance_id ? 2 : 1;
    } else if (info->vs.as_es) {
      assert(gfx_level <= GFX8);
      /* VGPR0-3: (VertexID, InstanceID / StepRate0, ...) */
      vgpr_comp_cnt = info->vs.needs_instance_id ? 1 : 0;
    } else {
      /* VGPR0-3: (VertexID, InstanceID / StepRate0, PrimID, InstanceID)
       * If PrimID is disabled. InstanceID / StepRate1 is loaded instead.
       * StepRate0 is set to 1. so that VGPR3 doesn't have to be loaded.
       */
      if (info->vs.needs_instance_id && gfx_level >= GFX10) {
        vgpr_comp_cnt = 3;
      } else if (info->outinfo.export_prim_id) {
        vgpr_comp_cnt = 2;
      } else if (info->vs.needs_instance_id) {
        vgpr_comp_cnt = 1;
      } else {
        vgpr_comp_cnt = 0;
      }

      if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
        config->rsrc1 |= S_00B128_MEM_ORDERED(gnm_mem_ordered(gfx_level));
    }
    config->rsrc2 |= S_00B12C_SHARED_VGPR_CNT(num_shared_vgpr_blocks) |
                     S_00B12C_EXCP_EN(excp_en);
    break;
  case MESA_SHADER_MESH:
    UNREACHABLE("Mesh shaders are unsupported");
  case MESA_SHADER_FRAGMENT:
    if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
      config->rsrc1 |= S_00B028_MEM_ORDERED(gnm_mem_ordered(gfx_level));
    config->rsrc1 |= S_00B028_LOAD_PROVOKING_VTX(info->ps.load_provoking_vtx);
    config->rsrc2 |=
        S_00B02C_SHARED_VGPR_CNT(num_shared_vgpr_blocks) |
        S_00B02C_EXCP_EN(excp_en) |
        S_00B02C_LOAD_COLLISION_WAVEID(info->ps.pops && gfx_level < GFX11);
    break;
  case MESA_SHADER_GEOMETRY:
    if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
      config->rsrc1 |= S_00B228_MEM_ORDERED(gnm_mem_ordered(gfx_level));
    config->rsrc2 |= S_00B22C_SHARED_VGPR_CNT(num_shared_vgpr_blocks) |
                     S_00B22C_EXCP_EN(excp_en);
    break;
  case MESA_SHADER_RAYGEN:
  case MESA_SHADER_CLOSEST_HIT:
  case MESA_SHADER_MISS:
  case MESA_SHADER_CALLABLE:
  case MESA_SHADER_INTERSECTION:
  case MESA_SHADER_ANY_HIT:
    UNREACHABLE("Raytracing shaders are unsupported");
  case MESA_SHADER_COMPUTE:
  case MESA_SHADER_TASK:
    if (gfx_level >= GFX10 && gfx_level <= GFX11_5)
      config->rsrc1 |= S_00B848_MEM_ORDERED(gnm_mem_ordered(gfx_level));
    config->rsrc1 |= S_00B848_WGP_MODE(config->wgp_mode);
    config->rsrc2 |= S_00B84C_TGID_X_EN(info->cs.uses_block_id[0]) |
                     S_00B84C_TGID_Y_EN(info->cs.uses_block_id[1]) |
                     S_00B84C_TGID_Z_EN(info->cs.uses_block_id[2]) |
                     S_00B84C_TIDIG_COMP_CNT(info->cs.uses_thread_id[2]   ? 2
                                             : info->cs.uses_thread_id[1] ? 1
                                                                          : 0) |
                     S_00B84C_TG_SIZE_EN(info->cs.uses_local_invocation_idx) |
                     S_00B84C_LDS_SIZE(lds_alloc) | S_00B84C_EXCP_EN(excp_en) |
                     S_00B84C_EXCP_EN_MSB(excp_en_msb);
    config->rsrc3 |= S_00B8A0_SHARED_VGPR_CNT(num_shared_vgpr_blocks);

    break;
  default:
    UNREACHABLE("unsupported shader type");
    break;
  }

  if (gfx_level >= GFX9 && stage == MESA_SHADER_GEOMETRY) {
    unsigned gs_vgpr_comp_cnt, es_vgpr_comp_cnt;

    if (es_stage == MESA_SHADER_VERTEX) {
      /* VGPR0-3: (VertexID, InstanceID / StepRate0, ...) */
      if (info->vs.needs_instance_id) {
        es_vgpr_comp_cnt = gfx_level >= GFX10 ? 3 : 1;
      } else {
        es_vgpr_comp_cnt = 0;
      }
    } else if (es_stage == MESA_SHADER_TESS_EVAL) {
      es_vgpr_comp_cnt = info->uses_prim_id ? 3 : 2;
    } else {
      UNREACHABLE("invalid shader ES type");
    }

    /* If offsets 4, 5 are used, GS_VGPR_COMP_CNT is ignored and
     * VGPR[0:4] are always loaded.
     */
    if (info->uses_invocation_id) {
      gs_vgpr_comp_cnt = 3; /* VGPR3 contains InvocationID. */
    } else if (info->uses_prim_id) {
      gs_vgpr_comp_cnt = 2; /* VGPR2 contains PrimitiveID. */
    } else if (info->gs.vertices_in >= 3) {
      gs_vgpr_comp_cnt = 1; /* VGPR1 contains offsets 2, 3 */
    } else {
      gs_vgpr_comp_cnt = 0; /* VGPR0 contains offsets 0, 1 */
    }

    config->rsrc1 |= S_00B228_GS_VGPR_COMP_CNT(gs_vgpr_comp_cnt) |
                     S_00B228_WGP_MODE(config->wgp_mode);
    config->rsrc2 |= S_00B22C_ES_VGPR_COMP_CNT(es_vgpr_comp_cnt) |
                     S_00B22C_OC_LDS_EN(es_stage == MESA_SHADER_TESS_EVAL);
  } else if (gfx_level >= GFX9 && stage == MESA_SHADER_TESS_CTRL) {
    config->rsrc1 |= S_00B428_LS_VGPR_COMP_CNT(vgpr_comp_cnt);
  } else {
    config->rsrc1 |= S_00B128_VGPR_COMP_CNT(vgpr_comp_cnt);
  }
}

unsigned gnm_compute_spi_ps_input(enum amd_gfx_level gfx_level,
                                  const struct gnm_shader_info *info) {
  unsigned spi_ps_input;

  spi_ps_input =
      S_0286CC_PERSP_CENTER_ENA(info->ps.reads_persp_center) |
      S_0286CC_PERSP_CENTROID_ENA(info->ps.reads_persp_centroid) |
      S_0286CC_PERSP_SAMPLE_ENA(info->ps.reads_persp_sample) |
      S_0286CC_LINEAR_CENTER_ENA(info->ps.reads_linear_center) |
      S_0286CC_LINEAR_CENTROID_ENA(info->ps.reads_linear_centroid) |
      S_0286CC_LINEAR_SAMPLE_ENA(info->ps.reads_linear_sample) |
      S_0286CC_PERSP_PULL_MODEL_ENA(info->ps.reads_barycentric_model) |
      S_0286CC_FRONT_FACE_ENA(info->ps.reads_front_face) |
      S_0286CC_POS_FIXED_PT_ENA(info->ps.reads_pixel_coord);

  if (info->ps.reads_frag_coord_mask || info->ps.reads_sample_pos_mask) {
    uint8_t mask =
        info->ps.reads_frag_coord_mask | info->ps.reads_sample_pos_mask;

    for (unsigned i = 0; i < 4; i++) {
      if (mask & (1 << i))
        spi_ps_input |= S_0286CC_POS_X_FLOAT_ENA(1) << i;
    }

    if (info->ps.reads_frag_coord_mask & (1 << 2)) {
      spi_ps_input |= S_0286CC_ANCILLARY_ENA(1);
    }
  }

  if (info->ps.reads_sample_id || info->ps.reads_frag_shading_rate ||
      info->ps.reads_sample_mask_in || info->ps.reads_layer) {
    spi_ps_input |= S_0286CC_ANCILLARY_ENA(1);
  }

  if (info->ps.reads_sample_mask_in || info->ps.reads_fully_covered) {
    spi_ps_input |= S_0286CC_SAMPLE_COVERAGE_ENA(1) |
                    S_02865C_COVERAGE_TO_SHADER_SELECT(
                        gfx_level >= GFX12 && info->ps.reads_fully_covered);
  }

  if (G_0286CC_POS_W_FLOAT_ENA(spi_ps_input)) {
    /* If POS_W_FLOAT (11) is enabled, at least one of PERSP_* must be enabled
     * too */
    spi_ps_input |= S_0286CC_PERSP_CENTER_ENA(1);
  }

  if (!(spi_ps_input & 0x7F) && !G_0286CC_LINE_STIPPLE_TEX_ENA(spi_ps_input)) {
    /* At least one of PERSP_* (0xF) or LINEAR_* (0x70) or LINE_STIPPLE_TEX must
     * be enabled. LINE_STIPPLE_TEX uses the least number of initialized VGPRs,
     * so let's use it because pixel throughput is limited by the number of
     * initialized VGPRs.
     *
     * We can't set LINE_STIPPLE_TEX on GFX12 because it reduces primitive
     * throughput to only 1 SE. Other gens are fine (tested on Navi10, Navi21,
     * Navi31).
     * TODO: Test Strix Halo.
     */
    if (gfx_level == GFX12)
      spi_ps_input |= S_0286CC_PERSP_SAMPLE_ENA(1);
    else
      spi_ps_input |= S_0286CC_LINE_STIPPLE_TEX_ENA(1);
  }

  return spi_ps_input;
}
