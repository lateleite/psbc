/*
 * Copyright © 2019 Valve Corporation.
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

#ifndef GNM_SHADER_ARGS_H
#define GNM_SHADER_ARGS_H

#include "ac_shader_args.h"
#include "amd_family.h"
#include "compiler/shader_enums.h"
#include "gnm_shader.h"

struct gnm_shader_args {
  struct ac_shader_args ac;

  struct ac_arg descriptors[MAX_SETS]; /* sets or heaps */

  /* Streamout */
  struct ac_arg streamout_buffers;

  /* Fragment shaders */
  struct ac_arg ps_state;

  struct ac_arg prolog_inputs;
  struct ac_arg vs_inputs[MAX_VERTEX_ATTRIBS];

  /* PS epilogs */
  struct ac_arg colors[MAX_RTS];
  struct ac_arg depth;
  struct ac_arg stencil;
  struct ac_arg sample_mask;

  /* GS */
  struct ac_arg vgt_esgs_ring_itemsize;

  /* PS/TCS epilogs PC. */
  struct ac_arg epilog_pc;

  struct gnm_userdata_locations user_sgprs_locs;
  unsigned num_user_sgprs;

  bool explicit_scratch_args;
  bool remap_spi_ps_input;
};

void gnm_declare_shader_args(enum amd_gfx_level gfx_level,
                             const struct gnm_shader_info *info,
                             mesa_shader_stage stage,
                             mesa_shader_stage previous_stage,
                             struct gnm_shader_args *args,
                             struct gnm_shader_debug_info *debug);

#endif
