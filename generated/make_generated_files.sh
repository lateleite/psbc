#!/bin/bash
#
# This file runs Python scripts that generated Mesa source files.
# Because of the Python requirement, they're being stored in psbc's source tree to
# avoid any unnecessary build time dependencies.
# So this should only be run (and potentially adjusted) whenever the Mesa version we're
# using is changed.
# 
set -e

# NOTE: update this path whenever Mesa is updated
MESA_PREFIX="../zig-pkg/N-V-__8AAM8qKhaobU6Rm--zBDi_FmW5vSYSD2RGPhrV7sQE"

AMD_REGISTER_FILES=(
    "${MESA_PREFIX}/src/amd/registers/gfx6.json"
    "${MESA_PREFIX}/src/amd/registers/gfx7.json"
    "${MESA_PREFIX}/src/amd/registers/gfx8.json"
    "${MESA_PREFIX}/src/amd/registers/gfx81.json"
    "${MESA_PREFIX}/src/amd/registers/gfx9.json"
    "${MESA_PREFIX}/src/amd/registers/gfx940.json"
    "${MESA_PREFIX}/src/amd/registers/gfx10.json"
    "${MESA_PREFIX}/src/amd/registers/gfx103.json"
    "${MESA_PREFIX}/src/amd/registers/gfx11.json"
    "${MESA_PREFIX}/src/amd/registers/gfx115.json"
    "${MESA_PREFIX}/src/amd/registers/gfx12.json"
    "${MESA_PREFIX}/src/amd/registers/gfx10-rsrc.json"
    "${MESA_PREFIX}/src/amd/registers/gfx11-rsrc.json"
    "${MESA_PREFIX}/src/amd/registers/gfx12-rsrc.json"
    "${MESA_PREFIX}/src/amd/registers/pkt3.json"
    "${MESA_PREFIX}/src/amd/registers/registers-manually-defined.json"
);

mkdir -p ./include/common
mkdir -p ./include/util/format
mkdir -p ./src

python3 "${MESA_PREFIX}/src/amd/registers/makeregheader.py" "${AMD_REGISTER_FILES[@]}" > ./include/common/amdgfxregs.h
# cp ./include/common/amdgfxregs.h ./include/amdgfxregs.h

python3 "${MESA_PREFIX}/src/amd/common/sid_tables.py" "${MESA_PREFIX}/src/amd/common/sid.h" "${AMD_REGISTER_FILES[@]}" > "./include/sid_tables.h"
python3 "${MESA_PREFIX}/src/amd/compiler/aco_builder_h.py" > "./include/aco_builder.h"
python3 "${MESA_PREFIX}/src/amd/compiler/aco_opcodes_h.py" > "./include/aco_opcodes.h"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_builder_opcodes_h.py" > "./include/nir_builder_opcodes.h"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_opcodes_h.py" > "./include/nir_opcodes.h"

python3 "${MESA_PREFIX}/src/compiler/spirv/spirv_info_gen.py" "--json" "${MESA_PREFIX}/src/compiler/spirv/spirv.core.grammar.json" --out-h "./include/spirv_info.h" --out-c "./src/spirv_info.c"

python3 "${MESA_PREFIX}/src/compiler/glsl/ir_expression_operation.py" constant > "./include/ir_expression_operation_constant.h"
python3 "${MESA_PREFIX}/src/compiler/glsl/ir_expression_operation.py" strings > "./include/ir_expression_operation_strings.h"

python3 "${MESA_PREFIX}/src/compiler/spirv/vtn_generator_ids_h.py" "${MESA_PREFIX}/src/compiler/spirv/spir-v.xml" "./include/vtn_generator_ids.h"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_intrinsics_h.py" --out "./include/nir_intrinsics.h"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_intrinsics_indices_h.py" --out "./include/nir_intrinsics_indices.h"
python3 "${MESA_PREFIX}/src/compiler/builtin_types_h.py" "./include/builtin_types.h"

python3 "${MESA_PREFIX}/src/util/format/u_format_table.py" "${MESA_PREFIX}/src/util/format/u_format.yaml" "--enums" > "./include/util/format/u_format_gen.h"

python3 "${MESA_PREFIX}/src/util/format/u_format_table.py" "${MESA_PREFIX}/src/util/format/u_format.yaml" --header > "./include/u_format_pack.h"
python3 "${MESA_PREFIX}/src/util/process_shader_stats.py" "${MESA_PREFIX}/src/util/shader_stats.rnc" "${MESA_PREFIX}/src/util/shader_stats.xml" > "./include/util/shader_stats.h"
python3 "${MESA_PREFIX}/src/amd/packets/parse_cp_pm4_table_data_json.py" "${MESA_PREFIX}/src/amd/packets/cp_pm4_table_data_gfx11.json" "${MESA_PREFIX}/src/amd/packets/pm4_it_opcodes_gfx11.h" "${MESA_PREFIX}/src/amd/packets/cp_pm4_table_data_gfx12.json" "${MESA_PREFIX}/src/amd/packets/pm4_it_opcodes_gfx12.h" gfx11 packets_h > "./include/amd_cp_packets_gfx11.h"
python3 "${MESA_PREFIX}/src/amd/packets/parse_cp_pm4_table_data_json.py" "${MESA_PREFIX}/src/amd/packets/cp_pm4_table_data_gfx11.json" "${MESA_PREFIX}/src/amd/packets/pm4_it_opcodes_gfx11.h" "${MESA_PREFIX}/src/amd/packets/cp_pm4_table_data_gfx12.json" "${MESA_PREFIX}/src/amd/packets/pm4_it_opcodes_gfx12.h" gfx12 packets_h > "./include/amd_cp_packets_gfx12.h"

python3 "${MESA_PREFIX}/src/amd/compiler/aco_opcodes_cpp.py" > "./src/aco_opcodes.cpp"

python3 "${MESA_PREFIX}/src/amd/common/gfx10_format_table.py" "${MESA_PREFIX}/src/util/format/u_format.yaml" "${MESA_PREFIX}/src/amd/registers/gfx10-rsrc.json" "${MESA_PREFIX}/src/amd/registers/gfx11-rsrc.json" > "./src/gfx10_format_table.c"

python3 "${MESA_PREFIX}/src/compiler/nir/nir_constant_expressions.py" > "./src/nir_constant_expressions.c"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_opcodes_c.py" > "./src/nir_opcodes.c"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_opt_algebraic.py" --out "./src/nir_opt_algebraic.c"
python3 "${MESA_PREFIX}/src/compiler/spirv/vtn_gather_types_c.py" "${MESA_PREFIX}/src/compiler/spirv/spirv.core.grammar.json" "./src/vtn_gather_types.c"
python3 "${MESA_PREFIX}/src/compiler/nir/nir_intrinsics_c.py" --out "./src/nir_intrinsics.c"
python3 "${MESA_PREFIX}/src/compiler/builtin_types_c.py" "./src/builtin_types.c"
python3 "${MESA_PREFIX}/src/util/format_srgb.py" > "./src/format_srgb.c"
python3 "${MESA_PREFIX}/src/util/format/u_format_table.py" "${MESA_PREFIX}/src/util/format/u_format.yaml" > "./src/u_format_table.c"
