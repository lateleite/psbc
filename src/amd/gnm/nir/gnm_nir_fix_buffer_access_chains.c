#include "gnm_nir.h"
#include "gnm_shader.h"
#include "nir_builder.h"

static nir_def *fix_buffer_load(nir_builder *b, nir_def *rsrc) {
  nir_alu_instr *mov_alu = nir_def_as_alu(rsrc); // %20 = mov %19.xy
  nir_def *vec3_def = mov_alu->src[0].src.ssa;
  nir_alu_instr *vec3_alu =
      nir_def_as_alu(vec3_def); // %19 = vec3 %14.x, %14.y, %18

  nir_def *found_desc = vec3_alu->src[0].src.ssa;

  while (nir_def_is_alu(found_desc)) {
    // %59 = vec3 %12.x, %12.y, %58
    nir_alu_instr *next_vec3_alu = nir_def_as_alu(found_desc);
    found_desc = next_vec3_alu->src[0].src.ssa;
  }

  nir_intrinsic_instr *intrin = nir_def_as_intrinsic(found_desc);
  assert(intrin->intrinsic == nir_intrinsic_load_vulkan_descriptor);
  // we're at the vulkan descriptor already, use it
  return found_desc;
}

static bool process_instruction_for_descs(nir_builder *b, nir_instr *instr,
                                          void *_state) {

  if (instr->type == nir_instr_type_intrinsic) {
    nir_intrinsic_instr *intrin = nir_instr_as_intrinsic(instr);
    b->cursor = nir_before_instr(&intrin->instr);

    nir_def *rsrc;
    switch (intrin->intrinsic) {
    case nir_intrinsic_load_ubo:
    case nir_intrinsic_load_ssbo:
    case nir_intrinsic_ssbo_atomic:
    case nir_intrinsic_ssbo_atomic_swap:
      rsrc = fix_buffer_load(b, intrin->src[0].ssa);
      nir_src_rewrite(&intrin->src[0], rsrc);
      return true;
    case nir_intrinsic_store_ssbo:
      rsrc = fix_buffer_load(b, intrin->src[1].ssa);
      nir_src_rewrite(&intrin->src[1], rsrc);
      return true;
    default:
      break;
    }
  }

  return false;
}

static bool process_instruction_for_offsets(nir_builder *b, nir_instr *instr,
                                            void *_state) {

  if (instr->type == nir_instr_type_alu) {
    nir_alu_instr *alu = nir_instr_as_alu(instr);
    b->cursor = nir_before_instr(&alu->instr);

    if (alu->op == nir_op_mov) {
      nir_def *src = alu->src[0].src.ssa;
      if (nir_def_is_intrinsic(src) && alu->src[0].swizzle[0] == 2) {
        nir_intrinsic_instr *intrin = nir_def_as_intrinsic(src);
        if (intrin->intrinsic == nir_intrinsic_load_vulkan_descriptor) {
          nir_def_replace(&alu->def, nir_imm_int(b, 0));
          return true;
        }
      }
    }
  }

  return false;
}

//
// After the SPIRV to NIR translation, load_ubo instructions take their buffer
// descriptor and offset through an access chain that requires a specific layout
// to come from load_vulkan_descriptor. On mainstream Mesa, that layout only
// supports storing 32 bits of address for a descriptor set/binding, but on psbc
// we need 64 bits. So in order to accomplish that, we must adjust the access
// chains, or else compilation will fail.
//
bool gnm_nir_fix_buffer_access_chains(nir_shader *shader) {
  bool progress = false;
  progress |= nir_shader_instructions_pass(
      shader, process_instruction_for_descs, nir_metadata_control_flow, NULL);
  progress |= nir_shader_instructions_pass(
      shader, process_instruction_for_offsets, nir_metadata_control_flow, NULL);
  return progress;
}
