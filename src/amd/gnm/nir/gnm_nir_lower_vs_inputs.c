/*
 * Copyright © 2023 Valve Corporation
 *
 * SPDX-License-Identifier: MIT
 */

#include "ac_nir.h"
#include "gnm_constants.h"
#include "gnm_nir.h"
#include "gnm_shader.h"
#include "gnm_shader_args.h"
#include "nir.h"
#include "nir_builder.h"

typedef struct {
  const struct gnm_shader_args *args;
  const struct gnm_shader_info *info;
} lower_vs_inputs_state;

static nir_def *lower_load_vs_input_from_prolog(nir_builder *b,
                                                nir_intrinsic_instr *intrin,
                                                lower_vs_inputs_state *s) {
  nir_src *offset_src = nir_get_io_offset_src(intrin);
  assert(nir_src_is_const(*offset_src));

  const nir_io_semantics io_sem = nir_intrinsic_io_semantics(intrin);
  const unsigned base_offset = nir_src_as_uint(*offset_src);
  const unsigned location =
      io_sem.location + base_offset - VERT_ATTRIB_GENERIC0;
  const unsigned component = nir_intrinsic_component(intrin);
  const unsigned bit_size = intrin->def.bit_size;
  const unsigned num_components = intrin->def.num_components;

  /* 64-bit inputs: they occupy twice as many 32-bit components.
   * 16-bit inputs: they occupy a 32-bit component (not packed).
   */
  const unsigned arg_bit_size = MAX2(bit_size, 32);

  unsigned num_input_args = 1;
  nir_def *input_args[2] = {
      ac_nir_load_arg(b, &s->args->ac, s->args->vs_inputs[location]), NULL};
  if (component * 32 + arg_bit_size * num_components > 128) {
    assert(bit_size == 64);

    num_input_args++;
    input_args[1] =
        ac_nir_load_arg(b, &s->args->ac, s->args->vs_inputs[location + 1]);
  }

  nir_def *extracted =
      nir_extract_bits(b, input_args, num_input_args, component * 32,
                       num_components, arg_bit_size);

  if (bit_size < arg_bit_size) {
    assert(bit_size == 16);

    if (nir_alu_type_get_base_type(nir_intrinsic_dest_type(intrin)) ==
        nir_type_float)
      return nir_f2f16(b, extracted);
    else
      return nir_u2u16(b, extracted);
  }

  return extracted;
}

static bool lower_vs_input_instr(nir_builder *b, nir_intrinsic_instr *intrin,
                                 void *state) {
  if (intrin->intrinsic != nir_intrinsic_load_input)
    return false;

  lower_vs_inputs_state *s = (lower_vs_inputs_state *)state;

  b->cursor = nir_before_instr(&intrin->instr);

  nir_def *replacement = NULL;

  if (s->info->vs.dynamic_inputs) {
    replacement = lower_load_vs_input_from_prolog(b, intrin, s);
  } else {
    UNREACHABLE("psbc: Static inputs in VS are unsupported");
  }

  nir_def_replace(&intrin->def, replacement);
  nir_instr_free(&intrin->instr);

  return true;
}

bool gnm_nir_lower_vs_inputs(nir_shader *shader,
                             const struct gnm_shader_args *args,
                             const struct gnm_shader_info *info) {
  assert(shader->info.stage == MESA_SHADER_VERTEX);

  lower_vs_inputs_state state = {
      .info = info,
      .args = args,
  };

  return nir_shader_intrinsics_pass(shader, lower_vs_input_instr,
                                    nir_metadata_control_flow, &state);
}
