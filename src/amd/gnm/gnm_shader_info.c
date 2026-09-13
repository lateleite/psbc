/*
 * Copyright © 2017 Red Hat
 *
 * SPDX-License-Identifier: MIT
 */
#include "ac_shader_util.h"
#include "gnm_shader.h"
#include "nir/gnm_nir.h"
#include "nir/nir.h"
#include "nir/nir_xfb_info.h"
#include "nir_tcs_info.h"
#include <stdbool.h>

#include "ac_nir.h"
#include "amdgfxregs.h"

static void mark_sampler_desc(const nir_variable *var,
                              struct gnm_shader_info *info) {
  info->desc_set_used_mask |= (1u << var->data.descriptor_set);
}

static bool gnm_use_vs_prolog(const nir_shader *nir) {
  return nir->info.inputs_read > 0;
}

static bool gnm_use_per_attribute_vb_descs(const nir_shader *nir) {
  return gnm_use_vs_prolog(nir);
}

static void gather_load_vs_input_info(const nir_shader *nir,
                                      const nir_intrinsic_instr *intrin,
                                      struct gnm_shader_info *info) {
  const nir_io_semantics io_sem = nir_intrinsic_io_semantics(intrin);
  const unsigned location = io_sem.location;
  const unsigned component = nir_intrinsic_component(intrin);
  unsigned mask = nir_def_components_read(&intrin->def);
  mask = (intrin->def.bit_size == 64 ? util_widen_mask(mask, 2) : mask)
         << component;

  if (location >= VERT_ATTRIB_GENERIC0) {
    const unsigned generic_loc = location - VERT_ATTRIB_GENERIC0;

    if (gnm_use_per_attribute_vb_descs(nir))
      info->vs.vb_desc_usage_mask |= BITFIELD_BIT(generic_loc);

    info->vs.input_slot_usage_mask |=
        BITFIELD_RANGE(generic_loc, io_sem.num_slots);
  }
}

static void gather_load_fs_input_info(const nir_shader *nir,
                                      const nir_intrinsic_instr *intrin,
                                      struct gnm_shader_info *info) {
  const nir_io_semantics io_sem = nir_intrinsic_io_semantics(intrin);
  const unsigned location = io_sem.location;
  const unsigned mapped_location = nir_intrinsic_base(intrin);
  const unsigned attrib_count = io_sem.num_slots;
  const unsigned component = nir_intrinsic_component(intrin);

  switch (location) {
  case VARYING_SLOT_CLIP_DIST0:
    info->ps.input_clips_culls_mask |=
        BITFIELD_RANGE(component, intrin->num_components);
    break;
  case VARYING_SLOT_CLIP_DIST1:
    info->ps.input_clips_culls_mask |=
        BITFIELD_RANGE(component, intrin->num_components) << 4;
    break;
  default:
    break;
  }

  const uint32_t mapped_mask = BITFIELD_RANGE(mapped_location, attrib_count);
  const bool per_primitive =
      nir->info.per_primitive_inputs & BITFIELD64_BIT(location);

  if (!per_primitive) {
    if (intrin->intrinsic == nir_intrinsic_load_input_vertex) {
      if (io_sem.interp_explicit_strict)
        info->ps.explicit_strict_shaded_mask |= mapped_mask;
      else
        info->ps.explicit_shaded_mask |= mapped_mask;
    } else if (intrin->intrinsic == nir_intrinsic_load_interpolated_input &&
               intrin->def.bit_size == 16) {
      if (io_sem.high_16bits)
        info->ps.float16_hi_shaded_mask |= mapped_mask;
      else
        info->ps.float16_shaded_mask |= mapped_mask;
    } else if (intrin->intrinsic == nir_intrinsic_load_interpolated_input) {
      info->ps.float32_shaded_mask |= mapped_mask;
    }
  }

  if (location >= VARYING_SLOT_VAR0) {
    const uint32_t var_mask =
        BITFIELD_RANGE(location - VARYING_SLOT_VAR0, attrib_count);

    if (per_primitive)
      info->ps.input_per_primitive_mask |= var_mask;
    else
      info->ps.input_mask |= var_mask;
  }
}

static void gather_intrinsic_load_input_info(const nir_shader *nir,
                                             const nir_intrinsic_instr *instr,
                                             struct gnm_shader_info *info) {
  switch (nir->info.stage) {
  case MESA_SHADER_VERTEX:
    gather_load_vs_input_info(nir, instr, info);
    break;
  case MESA_SHADER_FRAGMENT:
    gather_load_fs_input_info(nir, instr, info);
    break;
  default:
    break;
  }
}

static void gather_intrinsic_store_output_info(const nir_shader *nir,
                                               const nir_intrinsic_instr *instr,
                                               struct gnm_shader_info *info,
                                               bool consider_force_vrs) {
  const nir_io_semantics io_sem = nir_intrinsic_io_semantics(instr);
  const unsigned location = io_sem.location;
  const unsigned component = nir_intrinsic_component(instr);
  const unsigned write_mask = nir_intrinsic_write_mask(instr);

  switch (nir->info.stage) {
  case MESA_SHADER_FRAGMENT:
    if (location >= FRAG_RESULT_DATA0) {
      int index = mesa_frag_result_get_color_index(location);

      info->ps.colors_written |= 0xfu << (4 * index);

      if (location == FRAG_RESULT_DATA0)
        info->ps.color0_written |= write_mask << component;
    }
    break;
  default:
    break;
  }

  if (consider_force_vrs && location == VARYING_SLOT_POS) {
    unsigned pos_w_chan = 3 - component;

    if (write_mask & BITFIELD_BIT(pos_w_chan)) {
      nir_scalar pos_w = nir_scalar_resolved(instr->src[0].ssa, pos_w_chan);
      /* Use coarse shading if the value of Pos.W can't be determined or if its
       * value is != 1 (typical for non-GUI elements).
       */
      if (!nir_scalar_is_const(pos_w) ||
          nir_scalar_as_uint(pos_w) != 0x3f800000u)
        info->force_vrs_per_vertex = true;
    }
  }

  if ((location == VARYING_SLOT_CLIP_DIST0 ||
       location == VARYING_SLOT_CLIP_DIST1) &&
      !io_sem.no_sysval_output) {
    unsigned base = (location == VARYING_SLOT_CLIP_DIST1 ? 4 : 0) + component;
    unsigned clip_array_mask =
        BITFIELD_MASK(nir->info.clip_distance_array_size);
    info->outinfo.clip_dist_mask |= (write_mask << base) & clip_array_mask;
    info->outinfo.cull_dist_mask |= (write_mask << base) & ~clip_array_mask;
  }
}

static void gather_push_constant_info(const nir_shader *nir,
                                      const nir_intrinsic_instr *instr,
                                      struct gnm_shader_info *info) {
  uint32_t offset, size;

  if (nir_src_is_const(instr->src[0])) {
    offset = nir_intrinsic_base(instr) + nir_src_as_uint(instr->src[0]);
    size = instr->num_components * (instr->def.bit_size / 8u);
  } else {
    offset = nir_intrinsic_base(instr);
    size = nir_intrinsic_range(instr);
  }

  info->loads_push_constants = true;
  info->push_constant_size = MAX2(info->push_constant_size, offset + size);

  if (nir_src_is_const(instr->src[0]) && instr->def.bit_size >= 32) {
    const uint32_t start_dw = offset / 4;
    const uint32_t size_dw = size / 4;

    if (start_dw + size_dw <= (MAX_PUSH_CONSTANTS_SIZE / 4u)) {
      info->inline_push_constant_mask |= BITFIELD64_RANGE(start_dw, size_dw);
      return;
    }
  }

  info->can_inline_all_push_constants = false;
}

static void gather_intrinsic_info(const nir_shader *nir,
                                  const nir_intrinsic_instr *instr,
                                  struct gnm_shader_info *info,
                                  bool consider_force_vrs) {
  switch (instr->intrinsic) {
  case nir_intrinsic_load_barycentric_sample:
  case nir_intrinsic_load_barycentric_pixel:
  case nir_intrinsic_load_barycentric_centroid:
  case nir_intrinsic_load_barycentric_at_sample:
  case nir_intrinsic_load_barycentric_at_offset: {
    enum glsl_interp_mode mode = nir_intrinsic_interp_mode(instr);
    switch (mode) {
    case INTERP_MODE_SMOOTH:
    case INTERP_MODE_NONE:
      if (instr->intrinsic == nir_intrinsic_load_barycentric_pixel ||
          instr->intrinsic == nir_intrinsic_load_barycentric_at_sample ||
          instr->intrinsic == nir_intrinsic_load_barycentric_at_offset)
        info->ps.reads_persp_center = true;
      else if (instr->intrinsic == nir_intrinsic_load_barycentric_centroid)
        info->ps.reads_persp_centroid = true;
      else if (instr->intrinsic == nir_intrinsic_load_barycentric_sample)
        info->ps.reads_persp_sample = true;
      break;
    case INTERP_MODE_NOPERSPECTIVE:
      if (instr->intrinsic == nir_intrinsic_load_barycentric_pixel ||
          instr->intrinsic == nir_intrinsic_load_barycentric_at_sample ||
          instr->intrinsic == nir_intrinsic_load_barycentric_at_offset)
        info->ps.reads_linear_center = true;
      else if (instr->intrinsic == nir_intrinsic_load_barycentric_centroid)
        info->ps.reads_linear_centroid = true;
      else if (instr->intrinsic == nir_intrinsic_load_barycentric_sample)
        info->ps.reads_linear_sample = true;
      break;
    default:
      break;
    }
    if (instr->intrinsic == nir_intrinsic_load_barycentric_at_sample)
      info->ps.needs_sample_positions = true;
    break;
  }
  case nir_intrinsic_load_provoking_vtx_amd:
    info->ps.load_provoking_vtx = true;
    break;
  case nir_intrinsic_load_sample_positions_amd:
    info->ps.needs_sample_positions = true;
    break;
  case nir_intrinsic_load_rasterization_primitive_amd:
    info->ps.load_rasterization_prim = true;
    break;
  case nir_intrinsic_load_local_invocation_id:
  case nir_intrinsic_load_workgroup_id: {
    unsigned mask = nir_def_components_read(&instr->def);
    while (mask) {
      unsigned i = u_bit_scan(&mask);

      if (instr->intrinsic == nir_intrinsic_load_workgroup_id)
        info->cs.uses_block_id[i] = true;
      else
        info->cs.uses_thread_id[i] = true;
    }
    break;
  }
  case nir_intrinsic_load_pixel_coord:
    info->ps.reads_pixel_coord = true;
    break;
  case nir_intrinsic_load_frag_coord:
    info->ps.reads_frag_coord_mask |= nir_def_components_read(&instr->def);
    break;
  case nir_intrinsic_load_sample_pos:
    info->ps.reads_sample_pos_mask |= nir_def_components_read(&instr->def);
    break;
  case nir_intrinsic_load_push_constant:
    gather_push_constant_info(nir, instr, info);
    break;
  case nir_intrinsic_vulkan_resource_index:
    info->desc_set_used_mask |= (1u << nir_intrinsic_desc_set(instr));
    break;
  case nir_intrinsic_image_deref_load:
  case nir_intrinsic_image_deref_sparse_load:
  case nir_intrinsic_image_deref_store:
  case nir_intrinsic_image_deref_atomic:
  case nir_intrinsic_image_deref_atomic_swap:
  case nir_intrinsic_image_deref_size:
  case nir_intrinsic_image_deref_samples: {
    nir_variable *var =
        nir_deref_instr_get_variable(nir_def_as_deref(instr->src[0].ssa));
    mark_sampler_desc(var, info);
    break;
  }
  case nir_intrinsic_load_input:
  case nir_intrinsic_load_per_primitive_input:
  case nir_intrinsic_load_interpolated_input:
  case nir_intrinsic_load_input_vertex:
    gather_intrinsic_load_input_info(nir, instr, info);
    break;
  case nir_intrinsic_store_output:
  case nir_intrinsic_store_per_vertex_output:
    gather_intrinsic_store_output_info(nir, instr, info, consider_force_vrs);
    break;
  case nir_intrinsic_load_poly_line_smooth_enabled:
    info->ps.needs_poly_line_smooth = true;
    break;
  case nir_intrinsic_begin_invocation_interlock:
    info->ps.pops = true;
    break;
  default:
    break;
  }
}

static void gather_tex_info(const nir_tex_instr *instr,
                            struct gnm_shader_info *info) {
  for (unsigned i = 0; i < instr->num_srcs; i++) {
    switch (instr->src[i].src_type) {
    case nir_tex_src_texture_deref:
      mark_sampler_desc(
          nir_deref_instr_get_variable(nir_src_as_deref(instr->src[i].src)),
          info);
      break;
    case nir_tex_src_sampler_deref:
      mark_sampler_desc(
          nir_deref_instr_get_variable(nir_src_as_deref(instr->src[i].src)),
          info);
      break;
    default:
      break;
    }
  }
}

static void gather_info_block(const nir_shader *nir, const nir_block *block,
                              struct gnm_shader_info *info,
                              bool consider_force_vrs) {
  nir_foreach_instr(instr, block) {
    switch (instr->type) {
    case nir_instr_type_intrinsic:
      gather_intrinsic_info(nir, nir_instr_as_intrinsic(instr), info,
                            consider_force_vrs);
      break;
    case nir_instr_type_tex:
      gather_tex_info(nir_instr_as_tex(instr), info);
      break;
    default:
      break;
    }
  }
}

static void mark_16bit_ps_input(struct gnm_shader_info *info,
                                const struct glsl_type *type, int location) {
  if (glsl_type_is_scalar(type) || glsl_type_is_vector(type) ||
      glsl_type_is_matrix(type)) {
    unsigned attrib_count = glsl_count_attribute_slots(type, false);
    if (glsl_type_is_16bit(type)) {
      info->ps.float16_shaded_mask |= ((1ull << attrib_count) - 1) << location;
    }
  } else if (glsl_type_is_array(type)) {
    unsigned stride =
        glsl_count_attribute_slots(glsl_get_array_element(type), false);
    for (unsigned i = 0; i < glsl_get_length(type); ++i) {
      mark_16bit_ps_input(info, glsl_get_array_element(type),
                          location + i * stride);
    }
  } else {
    assert(glsl_type_is_struct_or_ifc(type));
    for (unsigned i = 0; i < glsl_get_length(type); i++) {
      mark_16bit_ps_input(info, glsl_get_struct_field(type, i), location);
      location +=
          glsl_count_attribute_slots(glsl_get_struct_field(type, i), false);
    }
  }
}

static void gather_xfb_info(const nir_shader *nir,
                            struct gnm_shader_info *info) {
  struct gnm_streamout_info *so = &info->so;

  if (!nir->xfb_info)
    return;

  const nir_xfb_info *xfb = nir->xfb_info;
  assert(xfb->output_count <= MAX_SO_OUTPUTS);
  so->num_outputs = xfb->output_count;

  for (unsigned i = 0; i < xfb->output_count; i++) {
    unsigned output_buffer = xfb->outputs[i].buffer;
    unsigned stream = xfb->buffer_to_stream[xfb->outputs[i].buffer];
    so->enabled_stream_buffers_mask |= (1 << output_buffer) << (stream * 4);
  }

  for (unsigned i = 0; i < NIR_MAX_XFB_BUFFERS; i++) {
    so->strides[i] = xfb->buffers[i].stride / 4;
  }
}

static void assign_outinfo_param(struct gnm_vs_output_info *outinfo,
                                 gl_varying_slot idx,
                                 unsigned *total_param_exports,
                                 unsigned extra_offset) {
  if (outinfo->vs_output_param_offset[idx] == AC_EXP_PARAM_UNDEFINED)
    outinfo->vs_output_param_offset[idx] =
        extra_offset + (*total_param_exports)++;
}

static void assign_outinfo_params(struct gnm_vs_output_info *outinfo,
                                  uint64_t mask, unsigned *total_param_exports,
                                  unsigned extra_offset) {
  u_foreach_bit64(idx, mask) {
    if (idx >= VARYING_SLOT_VAR0 || idx == VARYING_SLOT_LAYER ||
        idx == VARYING_SLOT_PRIMITIVE_ID || idx == VARYING_SLOT_VIEWPORT)
      assign_outinfo_param(outinfo, idx, total_param_exports, extra_offset);
  }
}

static void gnm_get_output_masks(const struct nir_shader *nir,
                                 uint64_t *per_vtx_mask,
                                 uint64_t *per_prim_mask) {
  /* These are not compiled into neither output param nor position exports. */
  const uint64_t special_mask = VARYING_BIT_PRIMITIVE_COUNT |
                                VARYING_BIT_PRIMITIVE_INDICES |
                                VARYING_BIT_CULL_PRIMITIVE;

  *per_prim_mask = nir->info.outputs_written & nir->info.per_primitive_outputs &
                   ~special_mask;
  *per_vtx_mask = nir->info.outputs_written & ~nir->info.per_primitive_outputs &
                  ~special_mask;
}

static uint32_t gnm_compute_esgs_itemsize(enum amd_gfx_level gfx_level,
                                          uint32_t num_varyings) {
  uint32_t esgs_itemsize;

  esgs_itemsize = num_varyings * 16;

  /* For the ESGS ring in LDS, add 1 dword to reduce LDS bank
   * conflicts, i.e. each vertex will start on a different bank.
   */
  if (gfx_level >= GFX9 && esgs_itemsize)
    esgs_itemsize += 4;

  return esgs_itemsize;
}

uint64_t gnm_gather_unlinked_io_mask(const uint64_t nir_io_mask) {
  /* Create a mask of driver locations mapped from NIR semantics. */
  uint64_t gnm_io_mask = 0;
  u_foreach_bit64(semantic, nir_io_mask) {
    /* These outputs are not used when fixed output slots are needed. */
    if (semantic == VARYING_SLOT_LAYER || semantic == VARYING_SLOT_VIEWPORT ||
        semantic == VARYING_SLOT_PRIMITIVE_ID ||
        semantic == VARYING_SLOT_PRIMITIVE_SHADING_RATE)
      continue;

    gnm_io_mask |= BITFIELD64_BIT(gnm_map_io_driver_location(semantic));
  }

  return gnm_io_mask;
}

uint64_t gnm_gather_unlinked_patch_io_mask(const uint64_t nir_io_mask,
                                           const uint32_t nir_patch_io_mask) {
  uint64_t gnm_io_mask = 0;
  u_foreach_bit64(semantic, nir_patch_io_mask) {
    gnm_io_mask |= BITFIELD64_BIT(
        gnm_map_io_driver_location(semantic + VARYING_SLOT_PATCH0));
  }

  /* Tess levels need to be handled separately because they are not part of
   * patch_outputs_written. */
  if (nir_io_mask & VARYING_BIT_TESS_LEVEL_OUTER)
    gnm_io_mask |= BITFIELD64_BIT(
        gnm_map_io_driver_location(VARYING_SLOT_TESS_LEVEL_OUTER));
  if (nir_io_mask & VARYING_BIT_TESS_LEVEL_INNER)
    gnm_io_mask |= BITFIELD64_BIT(
        gnm_map_io_driver_location(VARYING_SLOT_TESS_LEVEL_INNER));

  return gnm_io_mask;
}

static void gather_shader_info_vs(enum amd_gfx_level gfx_level,
                                  const nir_shader *nir,
                                  struct gnm_shader_info *info) {
  if (gnm_use_vs_prolog(nir)) {
    info->vs.has_prolog = true;
    info->vs.dynamic_inputs = true;
  }

  info->gs_inputs_read = ~0ULL;
  info->vs.tcs_inputs_via_lds = ~0ULL;

  /* Use per-attribute vertex descriptors to prevent faults and for correct
   * bounds checking. */
  info->vs.use_per_attribute_vb_descs = gnm_use_per_attribute_vb_descs(nir);

  /* We have to ensure consistent input register assignments between the main
   * shader and the prolog.
   */
  info->vs.needs_instance_id |= info->vs.has_prolog;
  info->vs.needs_base_instance |= info->vs.has_prolog;
  info->vs.needs_draw_id |= info->vs.has_prolog;

  if (info->vs.dynamic_inputs) {
    info->vs.num_attributes = util_last_bit(info->vs.vb_desc_usage_mask);
    info->vs.vb_desc_usage_mask = BITFIELD_MASK(info->vs.num_attributes);
  }

  /* When the topology is unknown (with GPL), the number of vertices per
   * primitive needs be passed through a user SGPR for NGG streamout with VS.
   * Otherwise, the XFB offset is incorrectly computed because using the maximum
   * number of vertices can't work.
   */
  info->vs.dynamic_num_verts_per_prim = false;

  info->vs.num_linked_outputs =
      util_last_bit64(gnm_gather_unlinked_io_mask(nir->info.outputs_written));

  if (info->next_stage == MESA_SHADER_TESS_CTRL) {
    info->vs.as_ls = true;
  } else if (info->next_stage == MESA_SHADER_GEOMETRY) {
    info->vs.as_es = true;
    info->esgs_itemsize =
        gnm_compute_esgs_itemsize(gfx_level, info->vs.num_linked_outputs);
  }
}

static void gather_shader_info_gs(enum amd_gfx_level gfx_level,
                                  const nir_shader *nir,
                                  struct gnm_shader_info *info) {
  info->gs.vertices_in = nir->info.gs.vertices_in;
  info->gs.vertices_out = nir->info.gs.vertices_out;
  info->gs.input_prim = nir->info.gs.input_primitive;
  info->gs.output_prim = nir->info.gs.output_primitive;
  info->gs.invocations = nir->info.gs.invocations;

  info->gs.num_linked_inputs =
      util_last_bit64(gnm_gather_unlinked_io_mask(nir->info.inputs_read));

  info->legacy_gs_info.esgs_itemsize =
      gnm_compute_esgs_itemsize(gfx_level, info->gs.num_linked_inputs);
}

static void gather_shader_info_fs(enum amd_gfx_level gfx_level,
                                  const nir_shader *nir,
                                  struct gnm_shader_info *info) {
  info->ps.num_inputs = util_bitcount64(nir->info.inputs_read);
  info->ps.can_discard = nir->info.fs.uses_discard;
  info->ps.early_fragment_test =
      nir->info.fs.early_fragment_tests ||
      (nir->info.fs.early_and_late_fragment_tests &&
       nir->info.fs.depth_layout == FRAG_DEPTH_LAYOUT_NONE &&
       nir->info.fs.stencil_front_layout == FRAG_STENCIL_LAYOUT_NONE &&
       nir->info.fs.stencil_back_layout == FRAG_STENCIL_LAYOUT_NONE);
  info->ps.post_depth_coverage = nir->info.fs.post_depth_coverage;
  info->ps.depth_layout = nir->info.fs.depth_layout;
  info->ps.uses_sample_shading = nir->info.fs.uses_sample_shading;
  info->ps.writes_memory = nir->info.writes_memory;
  info->ps.uses_fbfetch_output = nir->info.fs.uses_fbfetch_output;
  info->ps.has_pcoord = nir->info.inputs_read & VARYING_BIT_PNTC;
  info->ps.prim_id_input = nir->info.inputs_read & VARYING_BIT_PRIMITIVE_ID;
  info->ps.reads_layer =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_LAYER_ID);
  info->ps.viewport_index_input = nir->info.inputs_read & VARYING_BIT_VIEWPORT;
  info->ps.writes_z =
      nir->info.outputs_written & BITFIELD64_BIT(FRAG_RESULT_DEPTH);
  info->ps.writes_stencil =
      nir->info.outputs_written & BITFIELD64_BIT(FRAG_RESULT_STENCIL);
  info->ps.writes_sample_mask =
      nir->info.outputs_written & BITFIELD64_BIT(FRAG_RESULT_SAMPLE_MASK);
  info->ps.reads_sample_mask_in =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SAMPLE_MASK_IN);
  info->ps.reads_sample_id =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SAMPLE_ID);
  info->ps.reads_frag_shading_rate =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_FRAG_SHADING_RATE);
  info->ps.reads_front_face =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_FRONT_FACE) |
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_FRONT_FACE_FSIGN);
  info->ps.reads_barycentric_model = BITSET_TEST(
      nir->info.system_values_read, SYSTEM_VALUE_BARYCENTRIC_PULL_MODEL);
  info->ps.reads_fully_covered =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_FULLY_COVERED);

  bool uses_persp_or_linear_interp =
      info->ps.reads_persp_center || info->ps.reads_persp_centroid ||
      info->ps.reads_persp_sample || info->ps.reads_linear_center ||
      info->ps.reads_linear_centroid || info->ps.reads_linear_sample;

  info->ps.allow_flat_shading = !(
      uses_persp_or_linear_interp || info->ps.needs_sample_positions ||
      info->ps.reads_frag_shading_rate || info->ps.writes_memory ||
      nir->info.fs.needs_coarse_quad_helper_invocations ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_FRAG_COORD) ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_PIXEL_COORD) ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_POINT_COORD) ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SAMPLE_ID) ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SAMPLE_POS) ||
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SAMPLE_MASK_IN) ||
      BITSET_TEST(nir->info.system_values_read,
                  SYSTEM_VALUE_HELPER_INVOCATION) ||
      BITSET_TEST(nir->info.system_values_read,
                  SYSTEM_VALUE_SUBGROUP_INVOCATION));

  info->ps.pops_is_per_sample =
      info->ps.pops && (nir->info.fs.sample_interlock_ordered ||
                        nir->info.fs.sample_interlock_unordered);

  info->ps.spi_ps_input_ena = gnm_compute_spi_ps_input(gfx_level, info);
  info->ps.spi_ps_input_addr = info->ps.spi_ps_input_ena;

  info->ps.has_epilog = false;

  const bool export_alpha = (info->ps.color0_written & 0x8) &&
                            (info->ps.writes_z || info->ps.writes_stencil ||
                             info->ps.writes_sample_mask);

  if (info->ps.has_epilog) {
    info->ps.exports_mrtz_via_epilog = export_alpha;
  } else {
    // TODO: psbc: add user overrides for these
    // info->ps.mrt0_is_dual_src = gfx_state->ps.epilog.mrt0_is_dual_src;
    // info->ps.spi_shader_col_format =
    // gfx_state->ps.epilog.spi_shader_col_format;
    info->ps.mrt0_is_dual_src = 0;
    info->ps.spi_shader_col_format = 0;

    /* Clear color attachments that aren't exported by the FS to match IO shader
     * arguments. */
    if (!info->ps.mrt0_is_dual_src)
      info->ps.spi_shader_col_format &= info->ps.colors_written;

    info->ps.cb_shader_mask =
        ac_get_cb_shader_mask(info->ps.spi_shader_col_format);
  }

  if (!info->ps.exports_mrtz_via_epilog) {
    info->ps.writes_mrt0_alpha = export_alpha;
  }

  /* Disable VRS and use the rates from PS_ITER_SAMPLES if:
   *
   * - The fragment shader reads gl_SampleMaskIn because the 16-bit sample
   * coverage mask isn't enough for MSAA8x and 2x2 coarse shading.
   * - On GFX10.3, if the fragment shader requests a fragment interlock
   * execution mode even if the ordered section was optimized out, to
   * consistently implement fragmentShadingRateWithFragmentShaderInterlock =
   * VK_FALSE.
   */
  info->ps.force_sample_iter_shading_rate =
      (info->ps.reads_sample_mask_in && !info->ps.needs_poly_line_smooth) ||
      (gfx_level == GFX10_3 && (nir->info.fs.sample_interlock_ordered ||
                                nir->info.fs.sample_interlock_unordered ||
                                nir->info.fs.pixel_interlock_ordered ||
                                nir->info.fs.pixel_interlock_unordered));
}

static uint32_t gnm_get_user_data_0(enum amd_gfx_level gfx_level,
                                    struct gnm_shader_info *info) {
  switch (info->stage) {
  case MESA_SHADER_VERTEX:
  case MESA_SHADER_TESS_EVAL:
  case MESA_SHADER_MESH:
    if (info->next_stage == MESA_SHADER_TESS_CTRL) {
      assert(info->stage == MESA_SHADER_VERTEX);

      if (gfx_level >= GFX10) {
        return R_00B430_SPI_SHADER_USER_DATA_HS_0;
      } else if (gfx_level == GFX9) {
        return R_00B430_SPI_SHADER_USER_DATA_LS_0;
      } else {
        return R_00B530_SPI_SHADER_USER_DATA_LS_0;
      }
    }

    if (info->next_stage == MESA_SHADER_GEOMETRY) {
      assert(info->stage == MESA_SHADER_VERTEX ||
             info->stage == MESA_SHADER_TESS_EVAL);

      if (gfx_level >= GFX10) {
        return R_00B230_SPI_SHADER_USER_DATA_GS_0;
      } else {
        return R_00B330_SPI_SHADER_USER_DATA_ES_0;
      }
    }

    assert(info->stage != MESA_SHADER_MESH);
    return R_00B130_SPI_SHADER_USER_DATA_VS_0;
  case MESA_SHADER_TESS_CTRL:
    return gfx_level == GFX9 ? R_00B430_SPI_SHADER_USER_DATA_LS_0
                             : R_00B430_SPI_SHADER_USER_DATA_HS_0;
  case MESA_SHADER_GEOMETRY:
    return gfx_level == GFX9 ? R_00B330_SPI_SHADER_USER_DATA_ES_0
                             : R_00B230_SPI_SHADER_USER_DATA_GS_0;
  case MESA_SHADER_FRAGMENT:
    return R_00B030_SPI_SHADER_USER_DATA_PS_0;
  case MESA_SHADER_COMPUTE:
  case MESA_SHADER_TASK:
  case MESA_SHADER_RAYGEN:
  case MESA_SHADER_CALLABLE:
  case MESA_SHADER_CLOSEST_HIT:
  case MESA_SHADER_MISS:
  case MESA_SHADER_INTERSECTION:
  case MESA_SHADER_ANY_HIT:
    return R_00B900_COMPUTE_USER_DATA_0;
  default:
    UNREACHABLE("invalid shader stage");
  }
}

void gnm_nir_shader_info_init(mesa_shader_stage stage,
                              mesa_shader_stage next_stage,
                              struct gnm_shader_info *info) {
  memset(info, 0, sizeof(*info));

  /* Assume that shaders can inline all push constants by default. */
  info->can_inline_all_push_constants = true;

  info->stage = stage;
  info->next_stage = next_stage;
}

static void gnm_set_vs_output_param(enum amd_gfx_level gfx_level,
                                    const struct nir_shader *nir,
                                    struct gnm_shader_info *info,
                                    bool export_prim_id,
                                    bool export_clip_cull_dists) {
  struct gnm_vs_output_info *outinfo = &info->outinfo;
  uint64_t per_vtx_mask, per_prim_mask;

  gnm_get_output_masks(nir, &per_vtx_mask, &per_prim_mask);

  memset(outinfo->vs_output_param_offset, AC_EXP_PARAM_UNDEFINED,
         sizeof(outinfo->vs_output_param_offset));

  /* Implicit primitive ID for VS and TES is added by ac_nir_lower_legacy_vs /
   * ac_nir_lower_ngg, it can be configured as either a per-vertex or
   * per-primitive output depending on the GPU.
   */
  const bool implicit_prim_id_per_prim = false;
  const bool implicit_prim_id_per_vertex =
      export_prim_id && !implicit_prim_id_per_prim &&
      (nir->info.stage == MESA_SHADER_VERTEX ||
       nir->info.stage == MESA_SHADER_TESS_EVAL);

  unsigned total_param_exports = 0;

  /* Per-vertex outputs */
  assign_outinfo_params(outinfo, per_vtx_mask, &total_param_exports, 0);

  if (implicit_prim_id_per_vertex) {
    /* Mark the primitive ID as output when it's implicitly exported by VS or
     * TES. */
    if (outinfo->vs_output_param_offset[VARYING_SLOT_PRIMITIVE_ID] ==
        AC_EXP_PARAM_UNDEFINED)
      outinfo->vs_output_param_offset[VARYING_SLOT_PRIMITIVE_ID] =
          total_param_exports++;

    outinfo->export_prim_id = true;
  }

  if (export_clip_cull_dists) {
    if (nir->info.outputs_written & VARYING_BIT_CLIP_DIST0)
      outinfo->vs_output_param_offset[VARYING_SLOT_CLIP_DIST0] =
          total_param_exports++;
    if (nir->info.outputs_written & VARYING_BIT_CLIP_DIST1)
      outinfo->vs_output_param_offset[VARYING_SLOT_CLIP_DIST1] =
          total_param_exports++;
  }

  outinfo->param_exports = total_param_exports;

  /* The HW always assumes that there is at least 1 per-vertex param.
   * so if there aren't any, we have to offset per-primitive params by 1.
   */
  const unsigned extra_offset =
      !!(total_param_exports == 0 && gfx_level >= GFX11);

  if (implicit_prim_id_per_prim) {
    /* Mark the primitive ID as output when it's implicitly exported by VS. */
    if (outinfo->vs_output_param_offset[VARYING_SLOT_PRIMITIVE_ID] ==
        AC_EXP_PARAM_UNDEFINED)
      outinfo->vs_output_param_offset[VARYING_SLOT_PRIMITIVE_ID] =
          extra_offset + total_param_exports++;

    outinfo->export_prim_id_per_primitive = true;
  }

  /* Per-primitive outputs: the HW needs these to be last. */
  assign_outinfo_params(outinfo, per_prim_mask, &total_param_exports,
                        extra_offset);

  outinfo->prim_param_exports = total_param_exports - outinfo->param_exports;
}

void gnm_nir_shader_info_pass(enum amd_gfx_level gfx_level,
                              enum radeon_family family,
                              const struct nir_shader *nir,
                              mesa_shader_stage next_stage,
                              bool consider_force_vrs,
                              struct gnm_shader_info *info) {
  struct nir_function *func =
      (struct nir_function *)exec_list_get_head_const(&nir->functions);

  nir_foreach_block(block, func->impl) {
    gather_info_block(nir, block, info, consider_force_vrs);
  }

  if (nir->info.stage == MESA_SHADER_VERTEX ||
      nir->info.stage == MESA_SHADER_TESS_EVAL ||
      nir->info.stage == MESA_SHADER_GEOMETRY) {
    gather_xfb_info(nir, info);
  }

  if (nir->info.stage == MESA_SHADER_VERTEX ||
      nir->info.stage == MESA_SHADER_TESS_EVAL ||
      nir->info.stage == MESA_SHADER_GEOMETRY ||
      nir->info.stage == MESA_SHADER_MESH) {
    struct gnm_vs_output_info *outinfo = &info->outinfo;
    uint64_t per_vtx_mask, per_prim_mask;

    gnm_get_output_masks(nir, &per_vtx_mask, &per_prim_mask);

    /* Per vertex outputs. */
    outinfo->writes_pointsize = per_vtx_mask & VARYING_BIT_PSIZ;
    outinfo->writes_viewport_index = per_vtx_mask & VARYING_BIT_VIEWPORT;
    outinfo->writes_layer = per_vtx_mask & VARYING_BIT_LAYER;
    outinfo->writes_primitive_shading_rate =
        (per_vtx_mask & VARYING_BIT_PRIMITIVE_SHADING_RATE) ||
        info->force_vrs_per_vertex;

    /* Per primitive outputs. */
    outinfo->writes_viewport_index_per_primitive =
        per_prim_mask & VARYING_BIT_VIEWPORT;
    outinfo->writes_layer_per_primitive = per_prim_mask & VARYING_BIT_LAYER;
    outinfo->writes_primitive_shading_rate_per_primitive =
        per_prim_mask & VARYING_BIT_PRIMITIVE_SHADING_RATE;
    outinfo->export_prim_id_per_primitive =
        per_prim_mask & VARYING_BIT_PRIMITIVE_ID;
  }

  info->vs.needs_draw_id |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_DRAW_ID);
  info->vs.needs_base_instance |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_BASE_INSTANCE);
  info->vs.needs_instance_id |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_INSTANCE_ID);
  info->uses_view_index |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_VIEW_INDEX);
  info->uses_invocation_id |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_INVOCATION_ID);
  info->uses_prim_id |=
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_PRIMITIVE_ID);

  /* Used by compute and mesh shaders. */
  info->cs.uses_grid_size =
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_NUM_WORKGROUPS);
  info->cs.uses_local_invocation_idx =
      BITSET_TEST(nir->info.system_values_read,
                  SYSTEM_VALUE_LOCAL_INVOCATION_INDEX) |
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_SUBGROUP_ID) |
      BITSET_TEST(nir->info.system_values_read, SYSTEM_VALUE_NUM_SUBGROUPS);

  if (nir->info.stage == MESA_SHADER_COMPUTE ||
      nir->info.stage == MESA_SHADER_TASK ||
      nir->info.stage == MESA_SHADER_MESH) {
    for (int i = 0; i < 3; ++i)
      info->cs.block_size[i] = nir->info.workgroup_size[i];
  }

  info->user_data_0 = gnm_get_user_data_0(gfx_level, info);
  // TODO: psbc: allow user to override these?
  info->force_indirect_descriptors = true;
  info->descriptor_heap = false;

  switch (nir->info.stage) {
  case MESA_SHADER_COMPUTE:
    break;
  case MESA_SHADER_TASK:
    UNREACHABLE("Task shaders are unavailable on psbc");
  case MESA_SHADER_FRAGMENT:
    gather_shader_info_fs(gfx_level, nir, info);
    break;
  case MESA_SHADER_GEOMETRY:
    gather_shader_info_gs(gfx_level, nir, info);
    break;
  case MESA_SHADER_TESS_EVAL:
  case MESA_SHADER_TESS_CTRL:
    UNREACHABLE("TODO: psbc Tesselation");
  case MESA_SHADER_VERTEX:
    gather_shader_info_vs(gfx_level, nir, info);
    break;
  case MESA_SHADER_MESH:
    UNREACHABLE("Mesh shaders are unavailable on psbc");
  default:
    if (mesa_shader_stage_is_rt(nir->info.stage))
      UNREACHABLE("Raytrace shaders are unavailable on psbc");
    break;
  }

  info->wave_size = nir->info.min_subgroup_size;
  assert(info->wave_size == nir->info.max_subgroup_size);
  assert(info->wave_size == 32 || info->wave_size == 64);
  assert(gfx_level >= GFX10 || info->wave_size == 64);
  assert(nir->info.stage != MESA_SHADER_GEOMETRY || info->wave_size == 64);

  switch (nir->info.stage) {
  case MESA_SHADER_COMPUTE:
  case MESA_SHADER_TASK:
    info->workgroup_size = ac_compute_cs_workgroup_size(
        nir->info.workgroup_size, false, UINT32_MAX);

    /* Allow the compiler to assume that the shader always has full subgroups,
     * meaning that the initial EXEC mask is -1 in all waves (all lanes
     * enabled). This assumption is incorrect for ray tracing and internal
     * (meta) shaders because they can use unaligned dispatch.
     */
    info->cs.uses_full_subgroups =
        !nir->info.internal && (info->workgroup_size % info->wave_size) == 0;
    break;
  case MESA_SHADER_VERTEX:
    if (info->vs.as_ls || info->vs.as_es) {
      /* Set the maximum possible value by default, this will be optimized
       * during linking if possible.
       */
      info->workgroup_size = 256;
    } else {
      info->workgroup_size = info->wave_size;
      // TODO: psbc add user facing options for exporting primitive ID and clip
      // cull distances
      gnm_set_vs_output_param(gfx_level, nir, info, false, false);
    }
    break;
  case MESA_SHADER_TESS_CTRL:
    /* Set the maximum possible value when the workgroup size can't be
     * determined. */
    info->workgroup_size = 256;
    break;
  case MESA_SHADER_TESS_EVAL:
    if (info->tes.as_es) {
      /* Set the maximum possible value by default, this will be optimized
       * during linking if possible.
       */
      info->workgroup_size = 256;
    } else {
      info->workgroup_size = info->wave_size;
    }
    break;
  case MESA_SHADER_GEOMETRY:
    /* ESGS may operate in workgroups if on-chip GS (LDS rings) are enabled.
     *
     * GFX6: Not possible in the HW.
     * GFX7-8 (unmerged): possible in the HW, but not implemented in Mesa.
     * GFX9+ (merged): implemented in Mesa.
     *
     * Set the maximum possible value by default, this will be optimized during
     * linking if possible.
     */
    if (gfx_level <= GFX8)
      info->workgroup_size = info->wave_size;
    else
      info->workgroup_size = 256;
    break;
  case MESA_SHADER_MESH:
    UNREACHABLE("Mesh shaders are unavailable on psbc");
  default:
    /* FS always operates without workgroups. Other stages are computed during
     * linking but assume no workgroups by default.
     */
    info->workgroup_size = info->wave_size;
    break;
  }
}

enum ac_hw_stage gnm_select_hw_stage(const struct gnm_shader_info *const info,
                                     const enum amd_gfx_level gfx_level) {
  switch (info->stage) {
  case MESA_SHADER_VERTEX:
    if (info->vs.as_es)
      return gfx_level >= GFX9 ? AC_HW_LEGACY_GEOMETRY_SHADER
                               : AC_HW_EXPORT_SHADER;
    else if (info->vs.as_ls)
      return gfx_level >= GFX9 ? AC_HW_HULL_SHADER : AC_HW_LOCAL_SHADER;
    else
      return AC_HW_VERTEX_SHADER;
  case MESA_SHADER_TESS_EVAL:
    if (info->tes.as_es)
      return gfx_level >= GFX9 ? AC_HW_LEGACY_GEOMETRY_SHADER
                               : AC_HW_EXPORT_SHADER;
    else
      return AC_HW_VERTEX_SHADER;
  case MESA_SHADER_TESS_CTRL:
    return AC_HW_HULL_SHADER;
  case MESA_SHADER_GEOMETRY:
    return AC_HW_LEGACY_GEOMETRY_SHADER;
  case MESA_SHADER_MESH:
    return AC_HW_NEXT_GEN_GEOMETRY_SHADER;
  case MESA_SHADER_FRAGMENT:
    return AC_HW_PIXEL_SHADER;
  case MESA_SHADER_COMPUTE:
  case MESA_SHADER_KERNEL:
  case MESA_SHADER_TASK:
  case MESA_SHADER_RAYGEN:
  case MESA_SHADER_ANY_HIT:
  case MESA_SHADER_CLOSEST_HIT:
  case MESA_SHADER_MISS:
  case MESA_SHADER_INTERSECTION:
  case MESA_SHADER_CALLABLE:
    return AC_HW_COMPUTE_SHADER;
  default:
    UNREACHABLE("Unsupported HW stage");
  }
}
