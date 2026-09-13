/*
 * Copyright © 2016 Red Hat.
 * Copyright © 2016 Bas Nieuwenhuizen
 *
 * based in part on anv driver which is:
 * Copyright © 2015 Intel Corporation
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef GNM_ACO_SHADER_INFO_H
#define GNM_ACO_SHADER_INFO_H

/* this will convert from gnm shader info to the ACO one. */

#include "aco_shader_info.h"
#include "gnm_private.h"
#include "gnm_shader_args.h"

#define ASSIGN_FIELD(x) aco_info->x = gnm->x
#define ASSIGN_FIELD_CP(x) memcpy(&aco_info->x, &gnm->x, sizeof(gnm->x))

static inline void
gnm_aco_convert_ps_epilog_key(struct aco_ps_epilog_info *aco_info,
                              const struct gnm_ps_epilog_key *gnm,
                              const struct gnm_shader_args *gnm_args);

static inline unsigned
gnm_calculate_lds_size(const struct gnm_shader_info *gnm,
                       const enum amd_gfx_level gfx_level) {
  unsigned lds_size = 0;

  if (gfx_level >= GFX9 && gnm->stage == MESA_SHADER_GEOMETRY)
    lds_size = gnm->legacy_gs_info.lds_size;
  else if (gnm->stage == MESA_SHADER_TESS_CTRL)
    lds_size = gnm->tcs.lds_size; /* only used by stats */
  else
    lds_size = gnm->nir_shared_size;

  return lds_size;
}

static inline void
gnm_aco_convert_shader_info(struct aco_shader_info *aco_info,
                            const struct gnm_shader_info *gnm,
                            const struct gnm_shader_args *gnm_args,
                            const struct gnm_pipeline_key *gnm_key,
                            const enum amd_gfx_level gfx_level) {
  ASSIGN_FIELD(wave_size);
  ASSIGN_FIELD(workgroup_size);
  ASSIGN_FIELD(ps.has_epilog);
  ASSIGN_FIELD(vs.tcs_in_out_eq);
  ASSIGN_FIELD(vs.has_prolog);
  ASSIGN_FIELD(ps.num_inputs);
  ASSIGN_FIELD(cs.uses_full_subgroups);
  ASSIGN_FIELD(descriptor_heap);
  aco_info->vs.any_tcs_inputs_via_lds = gnm->vs.tcs_inputs_via_lds != 0;
  /* S2 must not be modified for correct hang recovery when NGG_WAVE_ID_EN=1. */
  aco_info->ps.spi_ps_input_ena = gnm->ps.spi_ps_input_ena;
  aco_info->ps.spi_ps_input_addr = gnm->ps.spi_ps_input_addr;
  aco_info->ps.has_prolog = false;
  aco_info->image_2d_view_of_3d = gnm_key->image_2d_view_of_3d;
  aco_info->epilog_pc = gnm_args->epilog_pc;
  aco_info->hw_stage = gnm_select_hw_stage(gnm, gfx_level);
  aco_info->lds_size = gnm_calculate_lds_size(gnm, gfx_level);
}

#define ASSIGN_VS_STATE_FIELD(x) aco_info->x = gnm->state->x
#define ASSIGN_VS_STATE_FIELD_CP(x)                                            \
  memcpy(&aco_info->x, &gnm->state->x, sizeof(gnm->state->x))
static inline void
gnm_aco_convert_vs_prolog_key(struct aco_vs_prolog_info *aco_info,
                              const struct gnm_vs_prolog_key *gnm,
                              const struct gnm_shader_args *gnm_args) {
  ASSIGN_FIELD(instance_rate_inputs);
  ASSIGN_FIELD(nontrivial_divisors);
  ASSIGN_FIELD(zero_divisors);
  ASSIGN_FIELD(post_shuffle);
  ASSIGN_FIELD(alpha_adjust_lo);
  ASSIGN_FIELD(alpha_adjust_hi);
  ASSIGN_FIELD_CP(formats);
  ASSIGN_FIELD(num_attributes);
  ASSIGN_FIELD(misaligned_mask);
  ASSIGN_FIELD(unaligned_mask);
  ASSIGN_FIELD(next_stage);

  aco_info->inputs = gnm_args->prolog_inputs;
}

static inline void
gnm_aco_convert_ps_epilog_key(struct aco_ps_epilog_info *aco_info,
                              const struct gnm_ps_epilog_key *gnm,
                              const struct gnm_shader_args *gnm_args) {
  ASSIGN_FIELD(spi_shader_col_format);
  ASSIGN_FIELD(color_is_int8);
  ASSIGN_FIELD(color_is_int10);
  ASSIGN_FIELD(mrt0_is_dual_src);
  ASSIGN_FIELD(alpha_to_coverage_via_mrtz);
  ASSIGN_FIELD(alpha_to_one);

  memcpy(aco_info->colors, gnm_args->colors, sizeof(aco_info->colors));
  memcpy(aco_info->color_map, gnm->color_map, sizeof(aco_info->color_map));
  aco_info->depth = gnm_args->depth;
  aco_info->stencil = gnm_args->stencil;
  aco_info->samplemask = gnm_args->sample_mask;

  aco_info->alpha_func = COMPARE_FUNC_ALWAYS;
}

static inline void
gnm_aco_convert_opts(struct aco_compiler_options *aco_info,
                     const struct gnm_nir_compiler_options *gnm,
                     const struct gnm_shader_args *gnm_args) {
  ASSIGN_FIELD(dump_ir);
  ASSIGN_FIELD(dump_preoptir);
  ASSIGN_FIELD(record_asm);
  ASSIGN_FIELD(record_ir);
  ASSIGN_FIELD(record_stats);
  ASSIGN_FIELD(enable_mrt_output_nan_fixup);
  ASSIGN_FIELD(wgp_mode);
  ASSIGN_FIELD(family);
  ASSIGN_FIELD(gfx_level);
  ASSIGN_FIELD(address32_hi);
  // aco_info->compiler_info = gnm->compiler_info;
  aco_info->is_opengl = false;
  aco_info->optimisations_disabled = gnm->key.optimisations_disabled;
  aco_info->gfx_level = gnm->gfx_level;
  aco_info->family = gnm->family;
  aco_info->address32_hi = gnm->address32_hi;
}
#undef ASSIGN_VS_STATE_FIELD
#undef ASSIGN_VS_STATE_FIELD_CP
#undef ASSIGN_FIELD
#undef ASSIGN_FIELD_CP

#endif
