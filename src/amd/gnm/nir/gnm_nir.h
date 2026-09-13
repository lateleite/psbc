/*
 * Copyright © 2023 Valve Corporation
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

#ifndef RADV_NIR_H
#define RADV_NIR_H

#include "amd_family.h"
#include "nir.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nir_shader nir_shader;
struct radeon_info;
struct gnm_pipeline_layout;
struct gnm_pipeline_key;
struct gnm_pipeline_stage;
struct gnm_shader_info;
struct gnm_shader_args;
struct gnm_device;

bool gnm_nir_lower_descriptors(nir_shader *shader, enum amd_gfx_level gfx_level,
                               enum radeon_family family,
                               const struct gnm_shader_info *info,
                               const struct gnm_shader_args *args);

void gnm_nir_lower_abi(nir_shader *shader, enum amd_gfx_level gfx_level,
                       const struct gnm_shader_info *info,
                       const struct gnm_shader_args *args,
                       const struct gnm_pipeline_key *pl_key,
                       uint32_t address32_hi);

bool gnm_nir_lower_ray_queries(struct nir_shader *shader,
                               struct gnm_device *device);

bool gnm_nir_lower_vs_inputs(nir_shader *shader,
                             const struct gnm_shader_args *args,
                             const struct gnm_shader_info *info);

bool gnm_nir_lower_primitive_shading_rate(nir_shader *nir,
                                          enum amd_gfx_level gfx_level);

bool gnm_nir_lower_fs_intrinsics(nir_shader *nir,
                                 const struct gnm_pipeline_stage *fs_stage,
                                 const struct gnm_pipeline_key *key);

bool gnm_nir_lower_intrinsics_early(nir_shader *nir,
                                    bool lower_view_index_to_zero);

bool gnm_nir_lower_view_index(nir_shader *nir, bool per_primitive);

bool gnm_nir_lower_viewport_to_zero(nir_shader *nir);

bool gnm_nir_export_multiview(nir_shader *nir);

void gnm_nir_lower_io(nir_shader *nir);

unsigned gnm_map_io_driver_location(unsigned semantic);

bool gnm_nir_lower_io_to_mem(enum amd_gfx_level gfx_level, nir_shader *nir,
                             const struct gnm_shader_info *info);

bool gnm_nir_lower_cooperative_matrix(nir_shader *shader,
                                      enum amd_gfx_level gfx_level,
                                      unsigned wave_size);

bool gnm_nir_fix_buffer_access_chains(nir_shader *shader);

#ifdef __cplusplus
}
#endif

#endif /* RADV_NIR_H */
