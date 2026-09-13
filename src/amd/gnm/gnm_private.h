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

#ifndef GNM_PRIVATE_H
#define GNM_PRIVATE_H

#include "gnm_shader.h"

#ifdef __cplusplus
extern "C" {
#endif

/* gnm_shader_info.h */
struct gnm_shader_info;

void gnm_nir_shader_info_pass(enum amd_gfx_level gfx_level,
                              enum radeon_family family,
                              const struct nir_shader *nir,
                              mesa_shader_stage next_stage,
                              bool consider_force_vrs,
                              struct gnm_shader_info *info);

void gnm_nir_shader_info_init(mesa_shader_stage stage,
                              mesa_shader_stage next_stage,
                              struct gnm_shader_info *info);

enum ac_hw_stage gnm_select_hw_stage(const struct gnm_shader_info *const info,
                                     const enum amd_gfx_level gfx_level);

#ifdef __cplusplus
}
#endif

#endif /* GNM_PRIVATE_H */
