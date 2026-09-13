/*
 * Copyright © 2019 Valve Corporation.
 * Copyright © 2016 Red Hat.
 * Copyright © 2016 Bas Nieuwenhuizen
 *
 * based in part on anv driver which is:
 * Copyright © 2015 Intel Corporation
 *
 * SPDX-License-Identifier: MIT
 */

#include "gnm_shader_args.h"
#include "gnm_shader.h"

#include "util/memstream.h"

struct user_sgpr_info {
  uint64_t inline_push_constant_mask;
  bool inlined_all_push_consts;
  bool indirect_all_descriptor_sets;
  uint8_t remaining_sgprs;
};

static void allocate_inline_push_consts(const struct gnm_shader_info *info,
                                        struct user_sgpr_info *user_sgpr_info) {
  uint8_t remaining_sgprs = user_sgpr_info->remaining_sgprs;

  if (!info->inline_push_constant_mask)
    return;

  uint64_t mask = info->inline_push_constant_mask;
  uint8_t num_push_consts = util_bitcount64(mask);

  /* Disable the default push constants path if all constants can be inlined. */
  if (num_push_consts <= MIN2(remaining_sgprs + 1, AC_MAX_INLINE_PUSH_CONSTS) &&
      info->can_inline_all_push_constants) {
    user_sgpr_info->inlined_all_push_consts = true;
    remaining_sgprs++;
  } else {
    /* Clamp to the maximum number of allowed inlined push constants. */
    while (num_push_consts >
           MIN2(remaining_sgprs, AC_MAX_INLINE_PUSH_CONSTS_WITH_INDIRECT)) {
      num_push_consts--;
      mask &= ~BITFIELD64_BIT(util_last_bit64(mask) - 1);
    }
  }

  user_sgpr_info->remaining_sgprs = remaining_sgprs - util_bitcount64(mask);
  user_sgpr_info->inline_push_constant_mask = mask;
}

struct gnm_shader_args_state {
  struct gnm_shader_args *args;
  bool gather_debug_info;
  void *ctx;
  const char *arg_names[AC_MAX_ARGS];
  BITSET_DECLARE(user_data, AC_MAX_ARGS);
};

static void add_ud_arg(struct gnm_shader_args_state *state, unsigned size,
                       enum ac_arg_type type, struct ac_arg *arg,
                       enum gnm_ud_index ud) {
  ac_add_arg(&state->args->ac, AC_ARG_SGPR, size, type, arg);

  struct gnm_userdata_info *ud_info =
      &state->args->user_sgprs_locs.shader_data[ud];

  if (ud_info->sgpr_idx == -1)
    ud_info->sgpr_idx = state->args->num_user_sgprs;

  ud_info->num_sgprs += size;

  state->args->num_user_sgprs += size;

  if (state->gather_debug_info)
    BITSET_SET(state->user_data, arg->arg_index);
}

#define GNM_ADD_UD_ARG(state, size, type, arg, ud_index)                       \
  do {                                                                         \
    add_ud_arg(state, size, type, &(state)->args->arg, ud_index);              \
    if ((state)->gather_debug_info) {                                          \
      (state)->arg_names[(state)->args->arg.arg_index] = #arg;                 \
    }                                                                          \
  } while (false)

#define GNM_ADD_UD_ARRAY_ARG(state, size, type, arg, array_index, ud_index)    \
  do {                                                                         \
    add_ud_arg(state, size, type, &(state)->args->arg[array_index], ud_index); \
    if ((state)->gather_debug_info) {                                          \
      (state)->arg_names[(state)->args->arg[array_index].arg_index] =          \
          ralloc_asprintf((state)->ctx, "%s[%u]", #arg, array_index);          \
    }                                                                          \
  } while (false)

#define GNM_ADD_ARG(state, regfile, size, type, arg)                           \
  do {                                                                         \
    ac_add_arg(&(state)->args->ac, regfile, size, type, &(state)->args->arg);  \
    if ((state)->gather_debug_info) {                                          \
      (state)->arg_names[(state)->args->arg.arg_index] = #arg;                 \
    }                                                                          \
  } while (false)

#define GNM_ADD_ARRAY_ARG(state, regfile, size, type, arg, array_index)        \
  do {                                                                         \
    ac_add_arg(&(state)->args->ac, regfile, size, type,                        \
               &(state)->args->arg[array_index]);                              \
    if ((state)->gather_debug_info) {                                          \
      (state)->arg_names[(state)->args->arg[array_index].arg_index] =          \
          ralloc_asprintf((state)->ctx, "%s[%u]", #arg, array_index);          \
    }                                                                          \
  } while (false)

#define GNM_ADD_NULL_ARG(state, regfile, size, type)                           \
  ac_add_arg(&(state)->args->ac, regfile, size, type, NULL)

static void add_descriptor_set(struct gnm_shader_args_state *state,
                               uint32_t set) {
  GNM_ADD_ARRAY_ARG(state, AC_ARG_SGPR, 2, AC_ARG_CONST_ADDR, descriptors, set);

  struct gnm_userdata_info *ud_info =
      &state->args->user_sgprs_locs.descriptor_sets[set];
  ud_info->sgpr_idx = state->args->num_user_sgprs;
  ud_info->num_sgprs = 1;

  state->args->user_sgprs_locs.descriptor_sets_enabled |= 1u << set;
  state->args->num_user_sgprs++;
}

static void add_descriptor_heap(struct gnm_shader_args_state *state,
                                uint32_t heap) {
  GNM_ADD_ARRAY_ARG(state, AC_ARG_SGPR, 2, AC_ARG_CONST_ADDR, descriptors,
                    heap);

  struct gnm_userdata_info *ud_info =
      &state->args->user_sgprs_locs.descriptor_heaps[heap];
  ud_info->sgpr_idx = state->args->num_user_sgprs;
  ud_info->num_sgprs = 1;

  state->args->user_sgprs_locs.descriptor_heaps_enabled |= 1u << heap;
  state->args->num_user_sgprs++;
}

static void
declare_global_input_sgprs(struct gnm_shader_args_state *state,
                           const enum amd_gfx_level gfx_level,
                           const struct gnm_shader_info *info,
                           const struct user_sgpr_info *user_sgpr_info) {
  if (user_sgpr_info) {
    if (info->descriptor_heap) {
      add_descriptor_heap(state, GNM_HEAP_RESOURCE);
      add_descriptor_heap(state, GNM_HEAP_SAMPLER);
    } else {
      /* 1 for each descriptor set */
      if (!user_sgpr_info->indirect_all_descriptor_sets) {
        uint32_t mask = info->desc_set_used_mask;

        while (mask) {
          int i = u_bit_scan(&mask);

          add_descriptor_set(state, i);
        }
      } else {
        GNM_ADD_UD_ARRAY_ARG(state, 2, AC_ARG_CONST_ADDR, descriptors, 0,
                             AC_UD_INDIRECT_DESCRIPTORS);
      }
    }

    if (info->loads_push_constants &&
        !user_sgpr_info->inlined_all_push_consts) {
      GNM_ADD_UD_ARG(state, 2, AC_ARG_CONST_ADDR, ac.push_constants,
                     AC_UD_PUSH_CONSTANTS);
    }

    if (info->loads_dynamic_offsets) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_CONST_ADDR, ac.dynamic_descriptors,
                     AC_UD_DYNAMIC_DESCRIPTORS);

      if (info->loads_dynamic_descriptors_offset_addr) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_CONST_ADDR,
                       ac.dynamic_descriptors_offset_addr,
                       AC_UD_DYNAMIC_DESCRIPTORS_OFFSET_ADDR);
      }
    }

    for (unsigned i = 0;
         i < util_bitcount64(user_sgpr_info->inline_push_constant_mask); i++) {
      GNM_ADD_UD_ARRAY_ARG(state, 1, AC_ARG_VALUE, ac.inline_push_consts, i,
                           AC_UD_INLINE_PUSH_CONSTANTS);
    }
    state->args->ac.inline_push_const_mask =
        user_sgpr_info->inline_push_constant_mask;
  }

  const bool needs_streamout_buffers =
      info->so.enabled_stream_buffers_mask ||
      ((info->stage == MESA_SHADER_VERTEX && info->vs.as_es) ||
       (info->stage == MESA_SHADER_TESS_EVAL && info->tes.as_es) ||
       info->stage == MESA_SHADER_GEOMETRY);

  if (needs_streamout_buffers) {
    GNM_ADD_UD_ARG(state, 1, AC_ARG_CONST_ADDR, streamout_buffers,
                   AC_UD_STREAMOUT_BUFFERS);
  }
}

static void
declare_vs_specific_input_sgprs(struct gnm_shader_args_state *state,
                                const struct gnm_shader_info *info) {
  if (info->vs.has_prolog)
    GNM_ADD_UD_ARG(state, 2, AC_ARG_VALUE, prolog_inputs,
                   AC_UD_VS_PROLOG_INPUTS);

  if (info->type != GNM_SHADER_TYPE_GS_COPY) {
    if (info->vs.vb_desc_usage_mask) {
      GNM_ADD_UD_ARG(state, 2, AC_ARG_CONST_ADDR, ac.vertex_buffers,
                     AC_UD_VS_VERTEX_BUFFERS);
    }

    GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.base_vertex,
                   AC_UD_VS_BASE_VERTEX_START_INSTANCE);
    if (info->vs.needs_draw_id) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.draw_id,
                     AC_UD_VS_BASE_VERTEX_START_INSTANCE);
    }
    if (info->vs.needs_base_instance) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.start_instance,
                     AC_UD_VS_BASE_VERTEX_START_INSTANCE);
    }
  }
}

static void declare_vs_input_vgprs(struct gnm_shader_args_state *state,
                                   enum amd_gfx_level gfx_level,
                                   const struct gnm_shader_info *info,
                                   bool merged_vs_tcs) {
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.vertex_id);
  if (info->vs.as_ls || merged_vs_tcs) {
    if (gfx_level >= GFX11) {
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* user VGPR */
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* user VGPR */
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.instance_id);
    } else if (gfx_level >= GFX10) {
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.vs_rel_patch_id);
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* user vgpr */
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.instance_id);
    } else {
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.vs_rel_patch_id);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.instance_id);
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* unused */
    }
  } else {
    if (gfx_level >= GFX10) {
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* unused */
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.vs_prim_id);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.instance_id);
    } else {
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.instance_id);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.vs_prim_id);
      GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* unused */
    }
  }

  if (info->vs.dynamic_inputs) {
    assert(info->vs.use_per_attribute_vb_descs);
    unsigned num_attributes = util_last_bit(info->vs.input_slot_usage_mask);
    for (unsigned i = 0; i < num_attributes; i++) {
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 4, AC_ARG_VALUE, vs_inputs, i);

      /* The vertex shader isn't required to consume all components that are
       * loaded by the prolog and it's possible that more VGPRs are written.
       * This specific case is handled at the end of the prolog which waits for
       * all pending VMEM loads if needed.
       */
      state->args->ac.args[state->args->vs_inputs[i].arg_index].pending_vmem =
          true;
    }
  }
}

static void declare_streamout_sgprs(struct gnm_shader_args_state *state,
                                    const struct gnm_shader_info *info,
                                    mesa_shader_stage stage) {
  int i;

  /* Streamout SGPRs. */
  if (info->so.enabled_stream_buffers_mask) {
    assert(stage == MESA_SHADER_VERTEX || stage == MESA_SHADER_TESS_EVAL);

    GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.streamout_config);
    GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.streamout_write_index);
  } else if (stage == MESA_SHADER_TESS_EVAL) {
    GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);
  }

  /* A streamout buffer offset is loaded if the stride is non-zero. */
  for (i = 0; i < 4; i++) {
    if (!info->so.strides[i])
      continue;

    GNM_ADD_ARRAY_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.streamout_offset,
                      i);
  }
}

static void declare_tes_input_vgprs(struct gnm_shader_args_state *state) {
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tes_u);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tes_v);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tes_rel_patch_id);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tes_patch_id);
}

static void declare_ps_input_vgprs(struct gnm_shader_args_state *state,
                                   const struct gnm_shader_info *info) {
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.persp_sample);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.persp_center);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.persp_centroid);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 3, AC_ARG_VALUE, ac.pull_model);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.linear_sample);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.linear_center);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 2, AC_ARG_VALUE, ac.linear_centroid);
  GNM_ADD_NULL_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE); /* line stipple tex */
  GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.frag_pos, 0);
  GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.frag_pos, 1);
  GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.frag_pos, 2);
  GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.frag_pos, 3);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.front_face);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.ancillary);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.sample_coverage);
  GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.pos_fixed_pt);

  if (state->args->remap_spi_ps_input)
    ac_compact_ps_vgpr_args(&state->args->ac, info->ps.spi_ps_input_ena);
}

static void gnm_init_shader_args(struct gnm_shader_args_state *state) {
  memset(state->args, 0, sizeof(*state->args));

  state->args->explicit_scratch_args = true;
  state->args->remap_spi_ps_input = true;

  for (int i = 0; i < MAX_SETS; i++)
    state->args->user_sgprs_locs.descriptor_sets[i].sgpr_idx = -1;
  for (int i = 0; i < GNM_MAX_HEAPS; i++)
    state->args->user_sgprs_locs.descriptor_heaps[i].sgpr_idx = -1;
  for (int i = 0; i < AC_UD_MAX_UD; i++)
    state->args->user_sgprs_locs.shader_data[i].sgpr_idx = -1;
}

static bool gnm_tcs_needs_state_sgpr(const struct gnm_shader_info *info) {
  /* Some values are loaded from a SGPR when dynamic states are used or when the
   * shader is unlinked. */
  return !info->num_tess_patches;
}

static bool gnm_tes_needs_state_sgpr(const struct gnm_shader_info *info) {
  /* Some values are loaded from a SGPR when dynamic states are used or when the
   * shader is unlinked. */
  return !info->num_tess_patches || !info->tes.tcs_vertices_out;
}

static bool gnm_ps_needs_state_sgpr(const struct gnm_shader_info *info) {
  if (info->ps.needs_sample_positions)
    return true;

  if (info->ps.reads_sample_mask_in && info->ps.uses_sample_shading)
    return true;

  /* For computing barycentrics when the primitive topology is unknown at
   * compile time (GPL). */
  if (info->ps.load_rasterization_prim)
    return true;

  return false;
}

static void declare_shader_args(struct gnm_shader_args_state *state,
                                enum amd_gfx_level gfx_level,
                                const struct gnm_shader_info *info,
                                mesa_shader_stage stage,
                                mesa_shader_stage previous_stage,
                                struct user_sgpr_info *user_sgpr_info) {
  gnm_init_shader_args(state);

  if (mesa_shader_stage_is_rt(stage)) {
    return;
  }

  GNM_ADD_UD_ARG(state, 2, AC_ARG_CONST_ADDR, ac.ring_offsets,
                 AC_UD_SCRATCH_RING_OFFSETS);

  /* For merged shaders the user SGPRs start at 8, with 8 system SGPRs in front
   * (including the rw_buffers at s0/s1. With user SGPR0 = s8, lets restart the
   * count from 0.
   */
  if (previous_stage != MESA_SHADER_NONE)
    state->args->num_user_sgprs = 0;

  /* To ensure prologs match the main VS, VS specific input SGPRs have to be
   * placed before other sgprs.
   */

  switch (stage) {
  case MESA_SHADER_COMPUTE:
  case MESA_SHADER_TASK:
    declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

    if (info->cs.uses_grid_size) {
      GNM_ADD_UD_ARG(state, 2, AC_ARG_CONST_ADDR, ac.num_work_groups,
                     AC_UD_CS_GRID_SIZE);
    }

    if (info->vs.needs_draw_id) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.draw_id, AC_UD_CS_TASK_DRAW_ID);
    }

    if (stage == MESA_SHADER_TASK) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.task_ring_entry,
                     AC_UD_TASK_RING_ENTRY);
    }

    for (int i = 0; i < 3; i++) {
      if (info->cs.uses_block_id[i]) {
        GNM_ADD_ARRAY_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.workgroup_ids,
                          i);
      }
    }

    if (info->cs.uses_local_invocation_idx) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tg_size);
    }

    if (state->args->explicit_scratch_args && gfx_level < GFX11) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
    }

    if (gfx_level >= GFX11) {
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                  ac.local_invocation_ids_packed);
    } else {
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                  ac.local_invocation_id_x);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                  ac.local_invocation_id_y);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                  ac.local_invocation_id_z);
    }
    break;
  case MESA_SHADER_VERTEX:
    /* To ensure prologs match the main VS, VS specific input SGPRs have to be
     * placed before other sgprs.
     */
    declare_vs_specific_input_sgprs(state, info);

    declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

    if (info->uses_view_index) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);
    }

    if (info->force_vrs_per_vertex) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.force_vrs_rates,
                     AC_UD_FORCE_VRS_RATES);
    }

    if (info->vs.as_es) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.es2gs_offset);
    } else if (info->vs.as_ls) {
      /* no extra parameters */
    } else {
      declare_streamout_sgprs(state, info, stage);
    }

    if (state->args->explicit_scratch_args) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
    }

    declare_vs_input_vgprs(state, gfx_level, info, false);
    break;
  case MESA_SHADER_TESS_CTRL:
    if (previous_stage != MESA_SHADER_NONE) {
      /* First 6 system regs */
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tess_offchip_offset);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.merged_wave_info);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tcs_factor_offset);

      if (gfx_level >= GFX11) {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tcs_wave_id);
      } else {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
      }

      GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);
      GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);

      declare_vs_specific_input_sgprs(state, info);

      declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

      if (info->uses_view_index) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);
      }

      if (gnm_tcs_needs_state_sgpr(info)) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.tcs_offchip_layout,
                       AC_UD_TCS_OFFCHIP_LAYOUT);
      }

      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tcs_patch_id);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tcs_rel_ids);

      declare_vs_input_vgprs(state, gfx_level, info, true);
    } else {
      declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

      if (info->uses_view_index) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);
      }

      if (gnm_tcs_needs_state_sgpr(info)) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.tcs_offchip_layout,
                       AC_UD_TCS_OFFCHIP_LAYOUT);
      }

      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tess_offchip_offset);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tcs_factor_offset);
      if (state->args->explicit_scratch_args) {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
      }
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tcs_patch_id);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.tcs_rel_ids);
    }
    break;
  case MESA_SHADER_TESS_EVAL:
    declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

    if (info->uses_view_index)
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);

    if (gnm_tes_needs_state_sgpr(info))
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.tcs_offchip_layout,
                     AC_UD_TCS_OFFCHIP_LAYOUT);

    if (info->tes.as_es) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tess_offchip_offset);
      GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.es2gs_offset);
    } else {
      declare_streamout_sgprs(state, info, stage);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tess_offchip_offset);
    }
    if (state->args->explicit_scratch_args) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
    }
    declare_tes_input_vgprs(state);
    break;
  case MESA_SHADER_GEOMETRY:
    if (previous_stage != MESA_SHADER_NONE) {
      /* First 6 system regs */
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.gs2vs_offset);

      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.merged_wave_info);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.tess_offchip_offset);

      if (gfx_level >= GFX11) {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.gs_attr_offset);
      } else {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
      }

      GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);
      GNM_ADD_NULL_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE);

      if (previous_stage == MESA_SHADER_VERTEX) {
        declare_vs_specific_input_sgprs(state, info);
      }

      declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

      if (info->uses_view_index) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);
      }

      if (previous_stage == MESA_SHADER_TESS_EVAL &&
          gnm_tes_needs_state_sgpr(info))
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.tcs_offchip_layout,
                       AC_UD_TCS_OFFCHIP_LAYOUT);

      if (previous_stage != MESA_SHADER_MESH) {
        if (gfx_level >= GFX12) {
          GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                            ac.gs_vtx_offset, 0);
          GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_prim_id);
          GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                            ac.gs_vtx_offset, 1);
        } else {
          GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                            ac.gs_vtx_offset, 0);
          GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                            ac.gs_vtx_offset, 1);
          GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_prim_id);
          GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_invocation_id);
          GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE,
                            ac.gs_vtx_offset, 2);
        }
      }

      if (previous_stage == MESA_SHADER_VERTEX) {
        declare_vs_input_vgprs(state, gfx_level, info, false);
      } else if (previous_stage == MESA_SHADER_TESS_EVAL) {
        declare_tes_input_vgprs(state);
      }
    } else {
      declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

      if (info->uses_view_index) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.view_index, AC_UD_VIEW_INDEX);
      }

      if (info->force_vrs_per_vertex) {
        GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ac.force_vrs_rates,
                       AC_UD_FORCE_VRS_RATES);
      }

      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.gs2vs_offset);
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.gs_wave_id);
      if (state->args->explicit_scratch_args) {
        GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
      }
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        0);
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        1);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_prim_id);
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        2);
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        3);
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        4);
      GNM_ADD_ARRAY_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_vtx_offset,
                        5);
      GNM_ADD_ARG(state, AC_ARG_VGPR, 1, AC_ARG_VALUE, ac.gs_invocation_id);
    }
    break;
  case MESA_SHADER_FRAGMENT:
    declare_global_input_sgprs(state, gfx_level, info, user_sgpr_info);

    if (info->ps.has_epilog) {
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, epilog_pc, AC_UD_EPILOG_PC);
    }

    if (gnm_ps_needs_state_sgpr(info))
      GNM_ADD_UD_ARG(state, 1, AC_ARG_VALUE, ps_state, AC_UD_PS_STATE);

    GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.prim_mask);

    if (info->ps.pops && gfx_level < GFX11) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE,
                  ac.pops_collision_wave_id);
    }

    if (info->ps.load_provoking_vtx) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.load_provoking_vtx);
    }

    if (state->args->explicit_scratch_args && gfx_level < GFX11) {
      GNM_ADD_ARG(state, AC_ARG_SGPR, 1, AC_ARG_VALUE, ac.scratch_offset);
    }

    declare_ps_input_vgprs(state, info);
    break;
  default:
    UNREACHABLE("Shader stage not implemented");
  }
}

static void
gnm_gather_shader_args_debug_info(struct gnm_shader_args_state *state,
                                  struct gnm_shader_debug_info *debug) {
  char *data = NULL;
  size_t size = 0;
  struct u_memstream mem;
  if (u_memstream_open(&mem, &data, &size)) {
    FILE *const memf = u_memstream_get(&mem);

    for (uint32_t i = 0; i < state->args->ac.arg_count; i++) {
      fprintf(memf, "   %u.", i);
      switch (state->args->ac.args[i].file) {
      case AC_ARG_SGPR:
        fprintf(memf, " sgpr");
        break;
      case AC_ARG_VGPR:
        fprintf(memf, " vgpr");
        break;
      }
      switch (state->args->ac.args[i].type) {
      case AC_ARG_VALUE:
        fprintf(memf, " value");
        break;
      case AC_ARG_CONST_ADDR:
        fprintf(memf, " const_addr");
        break;
      }
      if (state->args->ac.args[i].skip)
        fprintf(memf, " skip");
      if (state->args->ac.args[i].pending_vmem)
        fprintf(memf, " pending_vmem");
      if (state->args->ac.args[i].preserved)
        fprintf(memf, " preserved");
      if (BITSET_TEST(state->user_data, i))
        fprintf(memf, " user_data");
      fprintf(memf, " offset=%u size=%u name=%s\n",
              state->args->ac.args[i].offset, state->args->ac.args[i].size,
              state->arg_names[i] ? state->arg_names[i] : "(null)");
    }

    u_memstream_close(&mem);
  }

  debug->args_string = malloc(size + 1);
  if (debug->args_string) {
    memcpy(debug->args_string, data, size);
    debug->args_string[size] = 0;
  }
  free(data);
}

void gnm_declare_shader_args(enum amd_gfx_level gfx_level,
                             const struct gnm_shader_info *info,
                             mesa_shader_stage stage,
                             mesa_shader_stage previous_stage,
                             struct gnm_shader_args *args,
                             struct gnm_shader_debug_info *debug) {
  struct gnm_shader_args_state state = {
      .args = args,
  };

  struct user_sgpr_info user_sgpr_info = {0};

  if (mesa_shader_stage_is_rt(stage))
    UNREACHABLE("psbc: Raytracing shaders are unsupported");

  declare_shader_args(&state, gfx_level, info, stage, previous_stage, NULL);

  uint32_t num_user_sgprs = args->num_user_sgprs;
  if (info->loads_push_constants)
    num_user_sgprs++;
  if (info->loads_dynamic_offsets) {
    num_user_sgprs++;
    if (info->loads_dynamic_descriptors_offset_addr)
      num_user_sgprs++;
  }

  uint32_t available_sgprs = gfx_level >= GFX9 &&
                                     stage != MESA_SHADER_COMPUTE &&
                                     stage != MESA_SHADER_TASK
                                 ? 32
                                 : 16;
  uint32_t remaining_sgprs = available_sgprs - num_user_sgprs;

  user_sgpr_info.remaining_sgprs = remaining_sgprs;

  if (info->descriptor_heap) {
    assert(user_sgpr_info.remaining_sgprs >= GNM_MAX_HEAPS);
    user_sgpr_info.remaining_sgprs -= GNM_MAX_HEAPS;
  } else {
    const uint32_t num_desc_set = util_bitcount(info->desc_set_used_mask);

    if (info->force_indirect_descriptors || remaining_sgprs < num_desc_set) {
      user_sgpr_info.indirect_all_descriptor_sets = true;
      user_sgpr_info.remaining_sgprs--;
    } else {
      user_sgpr_info.remaining_sgprs -= num_desc_set;
    }
  }

  allocate_inline_push_consts(info, &user_sgpr_info);

  state.gather_debug_info = debug != NULL;
  if (state.gather_debug_info) {
    state.ctx = ralloc_context(NULL);
    state.gather_debug_info &= !!state.ctx;
  }

  declare_shader_args(&state, gfx_level, info, stage, previous_stage,
                      &user_sgpr_info);

  if (state.gather_debug_info)
    gnm_gather_shader_args_debug_info(&state, debug);

  ralloc_free(state.ctx);
}
