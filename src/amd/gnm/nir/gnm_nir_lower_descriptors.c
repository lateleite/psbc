/*
 * Copyright © 2020 Valve Corporation
 *
 * SPDX-License-Identifier: MIT
 */
#include "ac_shader_util.h"
#include "amdgfxregs.h"
#include "gnm_nir.h"
#include "gnm_shader.h"
#include "gnm_shader_args.h"
#include "nir.h"
#include "nir_builder.h"

typedef struct {
  enum ac_descriptor_type desc_type;
  uint32_t index;
  uint32_t desc_set;
  uint32_t byte_offset;
} layout_info_entry;

typedef struct {
  layout_info_entry entries[128];
  uint32_t next_desc_set_offsets[16];
  uint8_t num_entries;
} layout_info_state;

typedef struct {
  enum amd_gfx_level gfx_level;
  bool has_image_load_dcc_bug;

  const struct gnm_shader_args *args;
  const struct gnm_shader_info *info;

  layout_info_state layout_info;
} lower_descriptors_state;

static nir_def *get_scalar_arg(nir_builder *b, unsigned size,
                               struct ac_arg arg) {
  assert(arg.used);
  return nir_load_scalar_arg_amd(b, size, .base = arg.arg_index);
}

static nir_def *get_binding_table_addr(nir_builder *b,
                                       lower_descriptors_state *state,
                                       unsigned binding) {
  const struct gnm_userdata_locations *user_sgprs_locs =
      &state->info->user_sgprs_locs;
  assert(user_sgprs_locs->shader_data[AC_UD_INDIRECT_DESCRIPTORS].sgpr_idx !=
         -1);

  return get_scalar_arg(b, 2, state->args->descriptors[0]);
}

static const unsigned RESOURCE_STRIDE = 16;

static void visit_vulkan_resource_index(nir_builder *b,
                                        lower_descriptors_state *state,
                                        nir_intrinsic_instr *intrin) {
  const unsigned desc_set = nir_intrinsic_desc_set(intrin);
  const unsigned binding = nir_intrinsic_binding(intrin);

  assert(desc_set == 0); // TODO: support for non-zero descriptor set indices

  nir_def *array_index = intrin->src[0].ssa;
  nir_def *desc_addr = get_binding_table_addr(b, state, binding);

  nir_def *target_index = nir_imm_int(b, binding * 4);
  if (array_index != NULL)
    target_index = nir_iadd(b, target_index, array_index);

  nir_def_rewrite_uses(&intrin->def,
                       nir_vec3(b, nir_channel(b, desc_addr, 0),
                                nir_channel(b, desc_addr, 1), target_index));
  nir_instr_remove(&intrin->instr);
}

static void visit_vulkan_resource_reindex(nir_builder *b,
                                          nir_intrinsic_instr *intrin) {
  UNREACHABLE("TODO");
  nir_descriptor_type desc_type = nir_intrinsic_desc_type(intrin);
  assert(desc_type == nir_descriptor_type_uniform_buffer ||
         desc_type == nir_descriptor_type_storage_buffer ||
         desc_type == nir_descriptor_type_acceleration_structure);

  nir_def *binding_ptr = nir_channel(b, intrin->src[0].ssa, 2);
  nir_def *stride = nir_imm_int(b, RESOURCE_STRIDE);

  nir_def *index = nir_imul_nuw(b, intrin->src[1].ssa, stride);
  binding_ptr = nir_iadd_nuw(b, binding_ptr, index);

  nir_def_replace(&intrin->def,
                  nir_vector_insert_imm(b, intrin->src[0].ssa, binding_ptr, 1));
}

static void visit_load_vulkan_descriptor(nir_builder *b,
                                         nir_intrinsic_instr *intrin) {
  nir_def *rsrc = intrin->src[0].ssa;
  nir_descriptor_type desc_type = nir_intrinsic_desc_type(intrin);

  uint8_t desc_dwords;
  switch (desc_type) {
  case nir_descriptor_type_uniform_buffer:
  case nir_descriptor_type_storage_buffer:
    desc_dwords = 4;
    break;
  default:
    UNREACHABLE("Unexpected descriptor type");
  }

  nir_def *desc_table = nir_pack_64_2x32(b, nir_trim_vector(b, rsrc, 2));
  nir_def *offset = nir_channel(b, rsrc, 2);

  nir_def *desc = ac_nir_load_smem(b, desc_dwords, desc_table, offset, 16, 0);

  nir_def_rewrite_uses(&intrin->def, desc);
  nir_instr_remove(&intrin->instr);
}

static void visit_get_ssbo_size(nir_builder *b, lower_descriptors_state *state,
                                nir_intrinsic_instr *intrin) {
  nir_def *rsrc = intrin->src[0].ssa;

  nir_def *size;
  if (nir_intrinsic_access(intrin) & ACCESS_NON_UNIFORM) {
    nir_def *ptr =
        nir_iadd(b, nir_channel(b, rsrc, 0), nir_channel(b, rsrc, 1));
    ptr = nir_iadd_imm(b, ptr, 8);
    size = nir_build_load_global(
        b, 4, 32, ptr, .access = ACCESS_NON_WRITEABLE | ACCESS_CAN_REORDER,
        .align_mul = 16, .align_offset = 4);
  } else {
    /* load the entire descriptor so it can be CSE'd */
    nir_def *ptr = nir_channel(b, rsrc, 0);
    nir_def *desc = ac_nir_load_smem(b, 4, ptr, nir_channel(b, rsrc, 1), 4, 0);
    size = nir_channel(b, desc, 2);
  }

  nir_def_rewrite_uses(&intrin->def, size);
  nir_instr_remove(&intrin->instr);
}

static inline unsigned get_desc_size(enum ac_descriptor_type desc_type) {
  switch (desc_type) {
  case AC_DESC_IMAGE:
  case AC_DESC_PLANE_0:
  case AC_DESC_FMASK:
  case AC_DESC_PLANE_1:
    return 8;
  case AC_DESC_SAMPLER:
  case AC_DESC_BUFFER:
  case AC_DESC_PLANE_2:
    return 4;
  default:
    UNREACHABLE("Unexpected desc_type");
  }
}

static inline layout_info_entry *
find_layout_entry(lower_descriptors_state *state, uint32_t index,
                  uint32_t desc_set, enum ac_descriptor_type desc_type) {
  for (uint8_t i = 0; i < state->layout_info.num_entries; i += 1) {
    layout_info_entry *cur_entry = &state->layout_info.entries[i];
    if (cur_entry->index == index && cur_entry->desc_set == desc_set &&
        cur_entry->desc_type == desc_type) {
      return cur_entry;
    }
  }
  return NULL;
}

static nir_def *get_sampler_desc(nir_builder *b, lower_descriptors_state *state,
                                 nir_deref_instr *deref,
                                 enum ac_descriptor_type desc_type,
                                 bool non_uniform, nir_tex_instr *tex,
                                 bool write) {
  nir_variable *var = nir_deref_instr_get_variable(deref);
  assert(var);
  unsigned desc_set = var->data.descriptor_set;

  layout_info_entry *entry =
      find_layout_entry(state, var->index, desc_set, desc_type);
  assert(entry);

  unsigned size = get_desc_size(desc_type);
  unsigned offset = entry->byte_offset;
  switch (desc_type) {
  case AC_DESC_FMASK:
  case AC_DESC_PLANE_1:
    offset += 32;
    break;
  case AC_DESC_PLANE_2:
    offset += 64;
    break;
  default:
    break;
  }

  nir_def *index = NULL;
  while (deref->deref_type != nir_deref_type_var) {
    assert(deref->deref_type == nir_deref_type_array);
    unsigned array_size = MAX2(glsl_get_aoa_size(deref->type), 1);
    array_size *= size;

    nir_def *tmp = nir_imul_imm(b, deref->arr.index.ssa, array_size);
    if (tmp != deref->arr.index.ssa)
      nir_def_as_alu(tmp)->no_unsigned_wrap = true;

    if (index) {
      index = nir_iadd(b, tmp, index);
      nir_def_as_alu(index)->no_unsigned_wrap = true;
    } else {
      index = tmp;
    }

    deref = nir_deref_instr_parent(deref);
  }

  nir_def *index_offset =
      index ? nir_iadd_imm(b, index, offset) : nir_imm_int(b, offset);
  if (index && index_offset != index)
    nir_def_as_alu(index_offset)->no_unsigned_wrap = true;

  assert(desc_set == 0); // TODO: support for non-zero descriptor set indices
  nir_def *desc_addr_table = nir_pack_64_2x32(b, get_binding_table_addr(b, state, desc_set));

  if (non_uniform)
    return nir_iadd(b, desc_addr_table, index_offset);

  nir_def *desc =
      ac_nir_load_smem(b, size, desc_addr_table, index_offset, size * 4u, 0);

  /* 3 plane formats always have same size and format for plane 1 & 2, so
   * use the tail from plane 1 so that we can store only the first 16 bytes
   * of the last plane. */
  if (desc_type == AC_DESC_PLANE_2) {
    nir_def *desc2 = get_sampler_desc(b, state, deref, AC_DESC_PLANE_1,
                                      non_uniform, tex, write);

    nir_def *comp[8];
    for (unsigned i = 0; i < 4; i++)
      comp[i] = nir_channel(b, desc, i);
    for (unsigned i = 4; i < 8; i++)
      comp[i] = nir_channel(b, desc2, i);

    return nir_vec(b, comp, 8);
  } else if (desc_type == AC_DESC_IMAGE && state->has_image_load_dcc_bug &&
             !tex && !write) {
    nir_def *comp[8];
    for (unsigned i = 0; i < 8; i++)
      comp[i] = nir_channel(b, desc, i);

    /* WRITE_COMPRESS_ENABLE must be 0 for all image loads to workaround a
     * hardware bug.
     */
    comp[6] = nir_iand_imm(b, comp[6], C_00A018_WRITE_COMPRESS_ENABLE);

    return nir_vec(b, comp, 8);
  } else if (desc_type == AC_DESC_SAMPLER && tex->op == nir_texop_tg4) {
    nir_def *comp[4];
    for (unsigned i = 0; i < 4; i++)
      comp[i] = nir_channel(b, desc, i);

    /* We want to always use the linear filtering truncation behaviour for
     * nir_texop_tg4, even if the sampler uses nearest/point filtering.
     */
    comp[0] = nir_iand_imm(b, comp[0], C_008F30_TRUNC_COORD);

    return nir_vec(b, comp, 4);
  }

  return desc;
}

static void update_image_intrinsic(nir_builder *b,
                                   lower_descriptors_state *state,
                                   nir_intrinsic_instr *intrin) {
  nir_deref_instr *deref = nir_src_as_deref(intrin->src[0]);
  const enum glsl_sampler_dim dim = glsl_get_sampler_dim(deref->type);
  bool is_load = intrin->intrinsic == nir_intrinsic_image_deref_load ||
                 intrin->intrinsic == nir_intrinsic_image_deref_sparse_load;

  nir_def *desc = get_sampler_desc(
      b, state, deref,
      dim == GLSL_SAMPLER_DIM_BUF ? AC_DESC_BUFFER : AC_DESC_IMAGE,
      nir_intrinsic_access(intrin) & ACCESS_NON_UNIFORM, NULL, !is_load);

  if (intrin->intrinsic == nir_intrinsic_image_deref_descriptor_amd) {
    nir_def_rewrite_uses(&intrin->def, desc);
    nir_instr_remove(&intrin->instr);
  } else {
    nir_rewrite_image_intrinsic(intrin, desc, true);
  }
}

static bool apply_layout_to_intrin(nir_builder *b,
                                   lower_descriptors_state *state,
                                   nir_intrinsic_instr *intrin) {
  b->cursor = nir_before_instr(&intrin->instr);

  switch (intrin->intrinsic) {
  case nir_intrinsic_vulkan_resource_index:
    visit_vulkan_resource_index(b, state, intrin);
    break;
  case nir_intrinsic_vulkan_resource_reindex:
    visit_vulkan_resource_reindex(b, intrin);
    break;
  case nir_intrinsic_load_vulkan_descriptor:
    visit_load_vulkan_descriptor(b, intrin);
    break;
  case nir_intrinsic_get_ssbo_size:
    visit_get_ssbo_size(b, state, intrin);
    break;
  case nir_intrinsic_image_deref_load:
  case nir_intrinsic_image_deref_sparse_load:
  case nir_intrinsic_image_deref_store:
  case nir_intrinsic_image_deref_atomic:
  case nir_intrinsic_image_deref_atomic_swap:
  case nir_intrinsic_image_deref_size:
  case nir_intrinsic_image_deref_samples:
  case nir_intrinsic_image_deref_descriptor_amd:
    update_image_intrinsic(b, state, intrin);
    break;
  default:
    return false;
  }

  return true;
}

static bool apply_layout_to_tex(nir_builder *b, lower_descriptors_state *state,
                                nir_tex_instr *tex) {
  b->cursor = nir_before_instr(&tex->instr);

  nir_deref_instr *texture_deref_instr = NULL;
  nir_deref_instr *sampler_deref_instr = NULL;
  int plane = -1;

  nir_def *image = NULL;
  nir_def *sampler = NULL;

  for (unsigned i = 0; i < tex->num_srcs; i++) {
    switch (tex->src[i].src_type) {
    case nir_tex_src_texture_deref:
      texture_deref_instr = nir_src_as_deref(tex->src[i].src);
      break;
    case nir_tex_src_sampler_deref:
      sampler_deref_instr = nir_src_as_deref(tex->src[i].src);
      break;
    case nir_tex_src_plane:
      plane = nir_src_as_int(tex->src[i].src);
      break;
    default:
      break;
    }
  }

  if (plane >= 0) {
    assert(tex->op != nir_texop_txf_ms &&
           tex->op != nir_texop_samples_identical);
    assert(tex->sampler_dim != GLSL_SAMPLER_DIM_BUF);
    image =
        get_sampler_desc(b, state, texture_deref_instr, AC_DESC_PLANE_0 + plane,
                         tex->texture_non_uniform, tex, false);
  } else if (tex->sampler_dim == GLSL_SAMPLER_DIM_BUF) {
    image = get_sampler_desc(b, state, texture_deref_instr, AC_DESC_BUFFER,
                             tex->texture_non_uniform, tex, false);
  } else if (tex->op == nir_texop_fragment_mask_fetch_amd) {
    image = get_sampler_desc(b, state, texture_deref_instr, AC_DESC_FMASK,
                             tex->texture_non_uniform, tex, false);
  } else {
    image = get_sampler_desc(b, state, texture_deref_instr, AC_DESC_IMAGE,
                             tex->texture_non_uniform, tex, false);
  }

  if (sampler_deref_instr) {
    sampler = get_sampler_desc(b, state, sampler_deref_instr, AC_DESC_SAMPLER,
                               tex->sampler_non_uniform, tex, false);
  }

  for (unsigned i = 0; i < tex->num_srcs; i++) {
    switch (tex->src[i].src_type) {
    case nir_tex_src_texture_deref:
      tex->src[i].src_type = nir_tex_src_texture_handle;
      nir_src_rewrite(&tex->src[i].src, image);
      break;
    case nir_tex_src_sampler_deref:
      tex->src[i].src_type = nir_tex_src_sampler_handle;
      nir_src_rewrite(&tex->src[i].src, sampler);
      break;
    default:
      break;
    }
  }

  return true;
}

static void layout_add_resource(lower_descriptors_state *state,
                                nir_deref_instr *deref,
                                enum ac_descriptor_type desc_type) {
  nir_variable *var = nir_deref_instr_get_variable(deref);

  unsigned desc_set = var->data.descriptor_set;
  unsigned desc_size = get_desc_size(desc_type);

  // TODO: the entries array dimension is arbitrary, expand it if needed.
  // or better, just make it a dynamic array
  assert(state->layout_info.num_entries <
         ARRAY_SIZE(state->layout_info.entries));
  // TODO: the offsets array dimension is also arbitrary,
  // so the above also applies here
  assert(desc_set < ARRAY_SIZE(state->layout_info.next_desc_set_offsets));

  layout_info_entry *new_entry =
      &state->layout_info.entries[state->layout_info.num_entries];
  new_entry->desc_type = desc_type;
  new_entry->desc_set = desc_set;
  new_entry->index = var->index;
  new_entry->byte_offset = state->layout_info.next_desc_set_offsets[desc_set];

  state->layout_info.num_entries += 1;
  state->layout_info.next_desc_set_offsets[desc_set] += desc_size * 4u;
}

static void layout_process_tex(lower_descriptors_state *state,
                               nir_tex_instr *tex) {
  nir_deref_instr *texture_deref_instr = NULL;
  nir_deref_instr *sampler_deref_instr = NULL;
  int plane = -1;
  for (unsigned i = 0; i < tex->num_srcs; i++) {
    switch (tex->src[i].src_type) {
    case nir_tex_src_texture_deref:
      texture_deref_instr = nir_src_as_deref(tex->src[i].src);
      break;
    case nir_tex_src_sampler_deref:
      sampler_deref_instr = nir_src_as_deref(tex->src[i].src);
      break;
    case nir_tex_src_plane:
      plane = nir_src_as_int(tex->src[i].src);
      break;
    default:
      break;
    }
  }
  nir_variable *var = nir_deref_instr_get_variable(
      sampler_deref_instr ? sampler_deref_instr : texture_deref_instr);
  assert(var);
  if (plane >= 0) {
    layout_add_resource(state, texture_deref_instr, AC_DESC_PLANE_0 + plane);
  } else if (tex->sampler_dim == GLSL_SAMPLER_DIM_BUF) {
    layout_add_resource(state, texture_deref_instr, AC_DESC_BUFFER);
  } else if (tex->op == nir_texop_fragment_mask_fetch_amd) {
    layout_add_resource(state, texture_deref_instr, AC_DESC_FMASK);
  } else {
    layout_add_resource(state, texture_deref_instr, AC_DESC_IMAGE);
  }
  if (sampler_deref_instr) {
    layout_add_resource(state, sampler_deref_instr, AC_DESC_SAMPLER);
  }
}

static bool lower_descriptors_instr(nir_builder *b, nir_instr *instr,
                                    void *_state) {
  lower_descriptors_state *state = _state;

  if (instr->type == nir_instr_type_tex)
    return apply_layout_to_tex(b, state, nir_instr_as_tex(instr));
  else if (instr->type == nir_instr_type_intrinsic)
    return apply_layout_to_intrin(b, state, nir_instr_as_intrinsic(instr));

  return false;
}

bool gnm_nir_lower_descriptors(nir_shader *shader, enum amd_gfx_level gfx_level,
                               enum radeon_family family,
                               const struct gnm_shader_info *info,
                               const struct gnm_shader_args *args) {
  bool progress = false;

  lower_descriptors_state state = {
      .gfx_level = gfx_level,
      .has_image_load_dcc_bug = family == CHIP_NAVI23 ||
                                family == CHIP_VANGOGH ||
                                family == CHIP_REMBRANDT,
      .args = args,
      .info = info,
  };

  /* generate resource offset table for caller */
  nir_foreach_function_impl(impl, shader) {
    nir_foreach_block(block, impl) {
      nir_foreach_instr_safe(instr, block) {
        if (instr->type == nir_instr_type_tex) {
          layout_process_tex(&state, nir_instr_as_tex(instr));
        }
      }
    }
  }

  progress |= nir_shader_instructions_pass(shader, lower_descriptors_instr,
                                           nir_metadata_control_flow, &state);

  return progress;
}
