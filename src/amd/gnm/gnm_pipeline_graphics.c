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
#include "gnm_shader_args.h"
#include "nir/gnm_nir.h"
#include "nir/nir.h"
#include "nir/nir_builder.h"
#include "nir/nir_serialize.h"
#include "spirv/nir_spirv.h"
#include "util/disk_cache.h"
#include "util/os_time.h"
#include "util/u_atomic.h"

#include "ac_binary.h"
#include "ac_nir.h"
#include "ac_shader_util.h"
#include "aco_interface.h"
#include "sid.h"
#include "util/u_debug.h"

uint32_t gnm_compute_db_shader_control(enum amd_gfx_level gfx_level,
                                       enum radeon_family family,
                                       const struct gnm_shader_info *info) {
  unsigned conservative_z_export = V_02880C_EXPORT_ANY_Z;
  unsigned z_order = V_02880C_EARLY_Z_THEN_LATE_Z;

  if (info->ps.depth_layout == FRAG_DEPTH_LAYOUT_GREATER)
    conservative_z_export = V_02880C_EXPORT_GREATER_THAN_Z;
  else if (info->ps.depth_layout == FRAG_DEPTH_LAYOUT_LESS)
    conservative_z_export = V_02880C_EXPORT_LESS_THAN_Z;

  bool has_rbplus = family == CHIP_STONEY || gfx_level >= GFX9;
  bool rbplus_allowed =
      has_rbplus &&
      (family == CHIP_STONEY || family == CHIP_VEGA12 || family == CHIP_RAVEN ||
       family == CHIP_RAVEN2 || family == CHIP_RENOIR || gfx_level >= GFX10_3);

  bool disable_rbplus = has_rbplus && !rbplus_allowed;

  /* It shouldn't be needed to export gl_SampleMask when MSAA is disabled
   * but this appears to break Project Cars (DXVK). See
   * https://bugs.freedesktop.org/show_bug.cgi?id=109401
   */
  bool mask_export_enable = info->ps.writes_sample_mask;

  bool export_conflict_wa = false;

  return S_02880C_Z_EXPORT_ENABLE(info->ps.writes_z) |
         S_02880C_STENCIL_TEST_VAL_EXPORT_ENABLE(info->ps.writes_stencil) |
         S_02880C_KILL_ENABLE(!!info->ps.can_discard) |
         S_02880C_MASK_EXPORT_ENABLE(mask_export_enable) |
         S_02880C_CONSERVATIVE_Z_EXPORT(conservative_z_export) |
         S_02880C_Z_ORDER(z_order) |
         S_02880C_DEPTH_BEFORE_SHADER(info->ps.early_fragment_test) |
         S_02880C_PRE_SHADER_DEPTH_COVERAGE_ENABLE(
             info->ps.post_depth_coverage) |
         S_02880C_EXEC_ON_HIER_FAIL(info->ps.writes_memory) |
         S_02880C_EXEC_ON_NOOP(info->ps.writes_memory) |
         S_02880C_DUAL_QUAD_DISABLE(disable_rbplus) |
         S_02880C_OVERRIDE_INTRINSIC_RATE_ENABLE(export_conflict_wa) |
         S_02880C_OVERRIDE_INTRINSIC_RATE(export_conflict_wa ? 2 : 0);
}

static void gnm_pipeline_link_vs(nir_shader *vs_nir) {
  assert(vs_nir->info.stage == MESA_SHADER_VERTEX);

  nir_foreach_shader_in_variable(var, vs_nir) {
    var->data.driver_location = var->data.location;
  }

  nir_foreach_shader_out_variable(var, vs_nir) {
    var->data.driver_location = var->data.location;
  }
}

static void gnm_pipeline_link_tes(nir_shader *tes_nir) {
  assert(tes_nir->info.stage == MESA_SHADER_TESS_EVAL);

  nir_foreach_shader_out_variable(var, tes_nir) {
    var->data.driver_location = var->data.location;
  }
}

static void gnm_pipeline_link_gs(nir_shader *gs_nir) {
  assert(gs_nir->info.stage == MESA_SHADER_GEOMETRY);

  nir_foreach_shader_out_variable(var, gs_nir) {
    var->data.driver_location = var->data.location;
  }
}

static void gnm_pipeline_link_mesh(nir_shader *mesh_nir) {
  assert(mesh_nir->info.stage == MESA_SHADER_MESH);

  /* ac_nir_lower_ngg ignores driver locations for mesh shaders, but set them to
   * all zero just to be on the safe side.
   */
  nir_foreach_shader_out_variable(var, mesh_nir) {
    var->data.driver_location = 0;
  }
}

static void gnm_pipeline_link_fs(nir_shader *fs_nir) {
  assert(fs_nir->info.stage == MESA_SHADER_FRAGMENT);

  nir_foreach_shader_out_variable(var, fs_nir) {
    var->data.driver_location = var->data.location + var->data.index;
  }
}

void gnm_link_shader(nir_shader *nir) {
  switch (nir->info.stage) {
  case MESA_SHADER_VERTEX:
    gnm_pipeline_link_vs(nir);
    break;
  case MESA_SHADER_TESS_EVAL:
    gnm_pipeline_link_tes(nir);
    break;
  case MESA_SHADER_GEOMETRY:
    gnm_pipeline_link_gs(nir);
    break;
  case MESA_SHADER_MESH:
    gnm_pipeline_link_mesh(nir);
    break;
  case MESA_SHADER_FRAGMENT:
    gnm_pipeline_link_fs(nir);
    break;
  default:
    UNREACHABLE("Invalid graphics shader stage");
  }
}
