/*
 * Copyright © 2016 Red Hat.
 * Copyright © 2016 Bas Nieuwenhuizen
 * Copyright © 2023 Valve Corporation
 *
 * SPDX-License-Identifier: MIT
 */

#include "ac_nir.h"
#include "gnm_nir.h"
#include "gnm_shader.h"
#include "nir.h"
#include "nir_builder.h"
#include "nir_tcs_info.h"

static int type_size_vec4(const struct glsl_type *type, bool bindless) {
  return glsl_count_attribute_slots(type, false);
}

void gnm_nir_lower_io(nir_shader *nir) {
  // psbc: assign location values for fragment shader inputs
  if (nir->info.stage == MESA_SHADER_FRAGMENT) {
    nir_assign_io_var_locations(nir, nir_var_shader_in);
  }

  /* The nir_lower_io pass currently cannot handle array deref of vectors.
   * Call this here to make sure there are no such derefs left in the shader.
   */
  NIR_PASS(_, nir, nir_lower_array_deref_of_vec,
           nir_var_shader_in | nir_var_shader_out, NULL,
           nir_lower_direct_array_deref_of_vec_load |
               nir_lower_indirect_array_deref_of_vec_load |
               nir_lower_direct_array_deref_of_vec_store |
               nir_lower_indirect_array_deref_of_vec_store);

  if (nir->info.stage == MESA_SHADER_TESS_CTRL) {
    NIR_PASS(_, nir, nir_lower_tess_level_array_vars_to_vec);
  }

  NIR_PASS(_, nir, nir_lower_io, nir_var_shader_in | nir_var_shader_out,
           type_size_vec4,
           nir_lower_io_lower_64bit_to_32 |
               nir_lower_io_use_interpolated_input_intrinsics);

  /* Fold constant offset srcs for IO. */
  NIR_PASS(_, nir, nir_opt_constant_folding);

  if (nir->info.stage == MESA_SHADER_FRAGMENT) {
    /* Lower explicit input load intrinsics to sysvals for the layer ID. */
    NIR_PASS(_, nir, nir_lower_system_values);
  }

  NIR_PASS(_, nir, nir_opt_dce);
  NIR_PASS(_, nir, nir_remove_dead_variables,
           nir_var_shader_in | nir_var_shader_out, NULL);
}

/* IO slot layout for stages that aren't linked. */
enum {
  GNM_IO_SLOT_POS = 0,
  GNM_IO_SLOT_CLIP_DIST0,
  GNM_IO_SLOT_CLIP_DIST1,
  GNM_IO_SLOT_PSIZ,
  GNM_IO_SLOT_VAR0, /* 0..31 */
};

unsigned gnm_map_io_driver_location(unsigned semantic) {
  if ((semantic >= VARYING_SLOT_PATCH0 && semantic < VARYING_SLOT_TESS_MAX) ||
      semantic == VARYING_SLOT_TESS_LEVEL_INNER ||
      semantic == VARYING_SLOT_TESS_LEVEL_OUTER)
    return ac_shader_io_get_unique_index_patch(semantic);

  switch (semantic) {
  case VARYING_SLOT_POS:
    return GNM_IO_SLOT_POS;
  case VARYING_SLOT_CLIP_DIST0:
    return GNM_IO_SLOT_CLIP_DIST0;
  case VARYING_SLOT_CLIP_DIST1:
    return GNM_IO_SLOT_CLIP_DIST1;
  case VARYING_SLOT_PSIZ:
    return GNM_IO_SLOT_PSIZ;
  default:
    assert(semantic >= VARYING_SLOT_VAR0 && semantic <= VARYING_SLOT_VAR31);
    return GNM_IO_SLOT_VAR0 + (semantic - VARYING_SLOT_VAR0);
  }
}

bool gnm_nir_lower_io_to_mem(enum amd_gfx_level gfx_level, nir_shader *nir,
                             const struct gnm_shader_info *info) {
  ac_nir_map_io_driver_location map_input = gnm_map_io_driver_location;
  ac_nir_map_io_driver_location map_output = gnm_map_io_driver_location;

  if (nir->info.stage == MESA_SHADER_VERTEX) {
    if (info->vs.as_ls) {
      NIR_PASS(_, nir, ac_nir_lower_ls_outputs_to_mem, map_output, gfx_level,
               info->vs.tcs_in_out_eq, info->vs.tcs_inputs_via_temp,
               info->vs.tcs_inputs_via_lds);
      return true;
    } else if (info->vs.as_es) {
      NIR_PASS(_, nir, ac_nir_lower_es_outputs_to_mem, map_output, gfx_level,
               info->esgs_itemsize, info->gs_inputs_read);
      return true;
    }
  } else if (nir->info.stage == MESA_SHADER_TESS_CTRL) {
    NIR_PASS(_, nir, ac_nir_lower_hs_inputs_to_mem, map_input, gfx_level,
             info->vs.tcs_in_out_eq, info->vs.tcs_inputs_via_temp,
             info->vs.tcs_inputs_via_lds);

    nir_tcs_info tcs_info;
    nir_gather_tcs_info(nir, &tcs_info, nir->info.tess._primitive_mode,
                        nir->info.tess.spacing);
    ac_nir_tess_io_info tess_io_info;
    ac_nir_get_tess_io_info(nir, &tcs_info, info->tcs.tes_inputs_read,
                            info->tcs.tes_patch_inputs_read, map_output, true,
                            &tess_io_info);

    NIR_PASS(_, nir, ac_nir_lower_hs_outputs_to_mem, &tcs_info, &tess_io_info,
             map_output, gfx_level, info->wave_size);

    return true;
  } else if (nir->info.stage == MESA_SHADER_TESS_EVAL) {
    NIR_PASS(_, nir, ac_nir_lower_tes_inputs_to_mem, map_input);

    if (info->tes.as_es) {
      NIR_PASS(_, nir, ac_nir_lower_es_outputs_to_mem, map_output, gfx_level,
               info->esgs_itemsize, info->gs_inputs_read);
    }

    return true;
  } else if (nir->info.stage == MESA_SHADER_GEOMETRY) {
    NIR_PASS(_, nir, ac_nir_lower_gs_inputs_to_mem, map_input, gfx_level,
             false);
    return true;
  }

  return false;
}
