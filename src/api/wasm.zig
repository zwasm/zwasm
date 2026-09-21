//! C ABI binding for `include/wasm.h` (Phase 3 / §9.3 / 3.2).
//!
//! Zone 3 — exposes the wasm-c-api shapes upstream defines so a
//! C host can `#include <wasm.h>` and link against this binding.
//! Per ROADMAP §1.1 the wasm-c-api surface is the primary C ABI;
//! `zwasm.h` extensions land alongside (§9.3 follow-on, post-
//! v0.1.0 surface).
//!
//! After the §9.5 / 5.0 carve-out (ADR-0007), this file is the
//! **public re-export hub** for the binding. The actual code
//! lives in sibling modules:
//!
//! - `wasi.zig`          — WASI thunks + `zwasm_wasi_config_*`
//! - `trap_surface.zig`  — `Trap` / `TrapKind` / `wasm_trap_*`
//! - `vec.zig`           — `WASM_DECLARE_VEC` family
//!                         (byte / val / extern shapes + ops)
//! - `instance.zig`      — Engine / Store / Module / Instance /
//!                         Func / Extern, instantiation,
//!                         `wasm_func_call`, `wasm_instance_exports`
//!
//! Re-exports below keep call sites (`cli/run.zig`, sibling
//! carve-outs, external tests) addressing names through
//! `wasm_c_api.<name>` regardless of which file owns the symbol.
//! Linker-visible C symbols are still produced from each module's
//! own `pub export fn`s — `c_api_lib.zig` references every
//! sibling so they all land in `libzwasm.a`.

const std = @import("std");

const runtime = @import("../runtime/runtime.zig");
const wasi = @import("wasi.zig");
const trap_surface = @import("trap_surface.zig");
const vec = @import("vec.zig");
const types = @import("types.zig");
const instance = @import("instance.zig");
const module_introspect = @import("module_introspect.zig");
const extern_new = @import("extern_new.zig");
const config = @import("config.zig");
const host_info = @import("host_info.zig");
const ref_base = @import("ref_base.zig");
const module_serialize = @import("module_serialize.zig");

const testing = std.testing;

// ============================================================
// Re-exports — wasi.zig
// ============================================================

pub const zwasm_wasi_config_new = wasi.zwasm_wasi_config_new;
pub const zwasm_wasi_config_delete = wasi.zwasm_wasi_config_delete;

// ============================================================
// Re-exports — trap_surface.zig
// ============================================================

pub const TrapKind = trap_surface.TrapKind;
pub const Trap = trap_surface.Trap;
pub const wasm_trap_new = trap_surface.wasm_trap_new;
pub const wasm_trap_delete = trap_surface.wasm_trap_delete;
pub const wasm_trap_message = trap_surface.wasm_trap_message;
pub const wasm_trap_origin = trap_surface.wasm_trap_origin;
pub const wasm_trap_trace = trap_surface.wasm_trap_trace;
pub const Frame = trap_surface.Frame;
pub const FrameVec = trap_surface.FrameVec;
pub const wasm_frame_delete = trap_surface.wasm_frame_delete;
pub const wasm_frame_copy = trap_surface.wasm_frame_copy;
pub const wasm_frame_instance = trap_surface.wasm_frame_instance;
pub const wasm_frame_func_index = trap_surface.wasm_frame_func_index;
pub const wasm_frame_func_offset = trap_surface.wasm_frame_func_offset;
pub const wasm_frame_module_offset = trap_surface.wasm_frame_module_offset;
pub const wasm_frame_vec_new_empty = trap_surface.wasm_frame_vec_new_empty;
pub const wasm_frame_vec_new_uninitialized = trap_surface.wasm_frame_vec_new_uninitialized;
pub const wasm_frame_vec_new = trap_surface.wasm_frame_vec_new;
pub const wasm_frame_vec_copy = trap_surface.wasm_frame_vec_copy;
pub const wasm_frame_vec_delete = trap_surface.wasm_frame_vec_delete;

// ============================================================
// Re-exports — vec.zig
// ============================================================

pub const ByteVec = vec.ByteVec;
pub const ValVec = vec.ValVec;
pub const ExternVec = vec.ExternVec;
pub const wasm_byte_vec_new_empty = vec.wasm_byte_vec_new_empty;
pub const wasm_byte_vec_new_uninitialized = vec.wasm_byte_vec_new_uninitialized;
pub const wasm_byte_vec_new = vec.wasm_byte_vec_new;
pub const wasm_byte_vec_copy = vec.wasm_byte_vec_copy;
pub const wasm_byte_vec_delete = vec.wasm_byte_vec_delete;
pub const wasm_val_vec_new_empty = vec.wasm_val_vec_new_empty;
pub const wasm_val_vec_new_uninitialized = vec.wasm_val_vec_new_uninitialized;
pub const wasm_val_vec_new = vec.wasm_val_vec_new;
pub const wasm_val_vec_copy = vec.wasm_val_vec_copy;
pub const wasm_val_vec_delete = vec.wasm_val_vec_delete;
pub const wasm_extern_vec_new_empty = vec.wasm_extern_vec_new_empty;
pub const wasm_extern_vec_new_uninitialized = vec.wasm_extern_vec_new_uninitialized;
pub const wasm_extern_vec_new = vec.wasm_extern_vec_new;

// ============================================================
// Re-exports — types.zig (§13.2 type constructors)
// ============================================================

pub const Limits = types.Limits;
pub const ValType = types.ValType;
pub const ValTypeVec = types.ValTypeVec;
pub const FuncType = types.FuncType;
pub const GlobalType = types.GlobalType;
pub const TableType = types.TableType;
pub const MemoryType = types.MemoryType;

pub const wasm_valtype_new = types.wasm_valtype_new;
pub const wasm_valtype_delete = types.wasm_valtype_delete;
pub const wasm_valtype_kind = types.wasm_valtype_kind;
pub const wasm_valtype_copy = types.wasm_valtype_copy;
pub const wasm_valtype_vec_new_empty = types.wasm_valtype_vec_new_empty;
pub const wasm_valtype_vec_new_uninitialized = types.wasm_valtype_vec_new_uninitialized;
pub const wasm_valtype_vec_new = types.wasm_valtype_vec_new;
pub const wasm_valtype_vec_copy = types.wasm_valtype_vec_copy;
pub const wasm_valtype_vec_delete = types.wasm_valtype_vec_delete;

pub const wasm_functype_new = types.wasm_functype_new;
pub const wasm_functype_delete = types.wasm_functype_delete;
pub const wasm_functype_params = types.wasm_functype_params;
pub const wasm_functype_results = types.wasm_functype_results;
pub const wasm_functype_copy = types.wasm_functype_copy;

pub const wasm_globaltype_new = types.wasm_globaltype_new;
pub const wasm_globaltype_delete = types.wasm_globaltype_delete;
pub const wasm_globaltype_content = types.wasm_globaltype_content;
pub const wasm_globaltype_mutability = types.wasm_globaltype_mutability;
pub const wasm_globaltype_copy = types.wasm_globaltype_copy;

pub const wasm_tabletype_new = types.wasm_tabletype_new;
pub const wasm_tabletype_delete = types.wasm_tabletype_delete;
pub const wasm_tabletype_element = types.wasm_tabletype_element;
pub const wasm_tabletype_limits = types.wasm_tabletype_limits;
pub const wasm_tabletype_copy = types.wasm_tabletype_copy;

pub const wasm_memorytype_new = types.wasm_memorytype_new;
pub const wasm_memorytype_delete = types.wasm_memorytype_delete;
pub const wasm_memorytype_limits = types.wasm_memorytype_limits;
pub const wasm_memorytype_copy = types.wasm_memorytype_copy;

pub const ExternType = types.ExternType;
pub const ExternTypeVec = types.ExternTypeVec;
pub const wasm_externtype_kind = types.wasm_externtype_kind;
pub const wasm_externtype_delete = types.wasm_externtype_delete;
pub const wasm_externtype_copy = types.wasm_externtype_copy;
pub const wasm_functype_as_externtype = types.wasm_functype_as_externtype;
pub const wasm_globaltype_as_externtype = types.wasm_globaltype_as_externtype;
pub const wasm_tabletype_as_externtype = types.wasm_tabletype_as_externtype;
pub const wasm_memorytype_as_externtype = types.wasm_memorytype_as_externtype;
pub const wasm_functype_as_externtype_const = types.wasm_functype_as_externtype_const;
pub const wasm_globaltype_as_externtype_const = types.wasm_globaltype_as_externtype_const;
pub const wasm_tabletype_as_externtype_const = types.wasm_tabletype_as_externtype_const;
pub const wasm_memorytype_as_externtype_const = types.wasm_memorytype_as_externtype_const;
pub const wasm_externtype_as_functype = types.wasm_externtype_as_functype;
pub const wasm_externtype_as_globaltype = types.wasm_externtype_as_globaltype;
pub const wasm_externtype_as_tabletype = types.wasm_externtype_as_tabletype;
pub const wasm_externtype_as_memorytype = types.wasm_externtype_as_memorytype;
pub const wasm_externtype_as_functype_const = types.wasm_externtype_as_functype_const;
pub const wasm_externtype_as_globaltype_const = types.wasm_externtype_as_globaltype_const;
pub const wasm_externtype_as_tabletype_const = types.wasm_externtype_as_tabletype_const;
pub const wasm_externtype_as_memorytype_const = types.wasm_externtype_as_memorytype_const;
// tagtype (EH) — types.zig
pub const TagType = types.TagType;
pub const TagTypeVec = types.TagTypeVec;
pub const wasm_tagtype_new = types.wasm_tagtype_new;
pub const wasm_tagtype_delete = types.wasm_tagtype_delete;
pub const wasm_tagtype_functype = types.wasm_tagtype_functype;
pub const wasm_tagtype_copy = types.wasm_tagtype_copy;
pub const wasm_tagtype_as_externtype = types.wasm_tagtype_as_externtype;
pub const wasm_tagtype_as_externtype_const = types.wasm_tagtype_as_externtype_const;
pub const wasm_externtype_as_tagtype = types.wasm_externtype_as_tagtype;
pub const wasm_externtype_as_tagtype_const = types.wasm_externtype_as_tagtype_const;
pub const wasm_tagtype_vec_new_empty = types.wasm_tagtype_vec_new_empty;
pub const wasm_tagtype_vec_new_uninitialized = types.wasm_tagtype_vec_new_uninitialized;
pub const wasm_tagtype_vec_new = types.wasm_tagtype_vec_new;
pub const wasm_tagtype_vec_copy = types.wasm_tagtype_vec_copy;
pub const wasm_tagtype_vec_delete = types.wasm_tagtype_vec_delete;
pub const wasm_externtype_vec_new_empty = types.wasm_externtype_vec_new_empty;
pub const wasm_externtype_vec_new_uninitialized = types.wasm_externtype_vec_new_uninitialized;
pub const wasm_externtype_vec_new = types.wasm_externtype_vec_new;
pub const wasm_externtype_vec_copy = types.wasm_externtype_vec_copy;
pub const wasm_externtype_vec_delete = types.wasm_externtype_vec_delete;

pub const ImportType = types.ImportType;
pub const ExportType = types.ExportType;
pub const ImportTypeVec = types.ImportTypeVec;
pub const ExportTypeVec = types.ExportTypeVec;
pub const wasm_importtype_new = types.wasm_importtype_new;
pub const wasm_importtype_delete = types.wasm_importtype_delete;
pub const wasm_importtype_module = types.wasm_importtype_module;
pub const wasm_importtype_name = types.wasm_importtype_name;
pub const wasm_importtype_type = types.wasm_importtype_type;
pub const wasm_importtype_copy = types.wasm_importtype_copy;
pub const wasm_importtype_vec_new_empty = types.wasm_importtype_vec_new_empty;
pub const wasm_importtype_vec_new_uninitialized = types.wasm_importtype_vec_new_uninitialized;
pub const wasm_importtype_vec_new = types.wasm_importtype_vec_new;
pub const wasm_importtype_vec_copy = types.wasm_importtype_vec_copy;
pub const wasm_importtype_vec_delete = types.wasm_importtype_vec_delete;
pub const wasm_exporttype_new = types.wasm_exporttype_new;
pub const wasm_exporttype_delete = types.wasm_exporttype_delete;
pub const wasm_exporttype_name = types.wasm_exporttype_name;
pub const wasm_exporttype_type = types.wasm_exporttype_type;
pub const wasm_exporttype_copy = types.wasm_exporttype_copy;
pub const wasm_exporttype_vec_new_empty = types.wasm_exporttype_vec_new_empty;
pub const wasm_exporttype_vec_new_uninitialized = types.wasm_exporttype_vec_new_uninitialized;
pub const wasm_exporttype_vec_new = types.wasm_exporttype_vec_new;
pub const wasm_exporttype_vec_copy = types.wasm_exporttype_vec_copy;
pub const wasm_exporttype_vec_delete = types.wasm_exporttype_vec_delete;

pub const wasm_functype_vec_new_empty = types.wasm_functype_vec_new_empty;
pub const wasm_functype_vec_new_uninitialized = types.wasm_functype_vec_new_uninitialized;
pub const wasm_functype_vec_new = types.wasm_functype_vec_new;
pub const wasm_functype_vec_copy = types.wasm_functype_vec_copy;
pub const wasm_functype_vec_delete = types.wasm_functype_vec_delete;
pub const wasm_globaltype_vec_new_empty = types.wasm_globaltype_vec_new_empty;
pub const wasm_globaltype_vec_new_uninitialized = types.wasm_globaltype_vec_new_uninitialized;
pub const wasm_globaltype_vec_new = types.wasm_globaltype_vec_new;
pub const wasm_globaltype_vec_copy = types.wasm_globaltype_vec_copy;
pub const wasm_globaltype_vec_delete = types.wasm_globaltype_vec_delete;
pub const wasm_tabletype_vec_new_empty = types.wasm_tabletype_vec_new_empty;
pub const wasm_tabletype_vec_new_uninitialized = types.wasm_tabletype_vec_new_uninitialized;
pub const wasm_tabletype_vec_new = types.wasm_tabletype_vec_new;
pub const wasm_tabletype_vec_copy = types.wasm_tabletype_vec_copy;
pub const wasm_tabletype_vec_delete = types.wasm_tabletype_vec_delete;
pub const wasm_memorytype_vec_new_empty = types.wasm_memorytype_vec_new_empty;
pub const wasm_memorytype_vec_new_uninitialized = types.wasm_memorytype_vec_new_uninitialized;
pub const wasm_memorytype_vec_new = types.wasm_memorytype_vec_new;
pub const wasm_memorytype_vec_copy = types.wasm_memorytype_vec_copy;
pub const wasm_memorytype_vec_delete = types.wasm_memorytype_vec_delete;

// ============================================================
// Re-exports — instance.zig
// ============================================================

pub const Engine = instance.Engine;
pub const Store = instance.Store;
pub const Module = instance.Module;
pub const Instance = instance.Instance;
pub const Func = instance.Func;
pub const ValKind = instance.ValKind;
pub const Val = instance.Val;
pub const wasm_val_copy = vec.wasm_val_copy;
pub const wasm_val_delete = vec.wasm_val_delete;
pub const ExternKind = instance.ExternKind;
pub const Extern = instance.Extern;
pub const storeAllocator = instance.storeAllocator;
pub const externSlotOf = instance.externSlotOf;
pub const Config = config.Config;
pub const wasm_engine_new = instance.wasm_engine_new;
pub const wasm_engine_new_with_config = config.wasm_engine_new_with_config;
pub const wasm_engine_delete = instance.wasm_engine_delete;
pub const wasm_config_new = config.wasm_config_new;
pub const wasm_config_delete = config.wasm_config_delete;
pub const wasm_store_new = instance.wasm_store_new;
pub const wasm_store_delete = instance.wasm_store_delete;
pub const zwasm_store_set_wasi = instance.zwasm_store_set_wasi;
pub const wasm_module_new = instance.wasm_module_new;
pub const wasm_module_validate = instance.wasm_module_validate;
pub const wasm_module_delete = instance.wasm_module_delete;
pub const SharedModule = module_serialize.SharedModule;
pub const wasm_module_serialize = module_serialize.wasm_module_serialize;
pub const wasm_module_deserialize = module_serialize.wasm_module_deserialize;
pub const wasm_module_share = module_serialize.wasm_module_share;
pub const wasm_module_obtain = module_serialize.wasm_module_obtain;
pub const wasm_shared_module_delete = module_serialize.wasm_shared_module_delete;
pub const wasm_module_imports = module_introspect.wasm_module_imports;
pub const wasm_module_exports = module_introspect.wasm_module_exports;
pub const wasm_extern_type = module_introspect.wasm_extern_type;
pub const wasm_func_type = module_introspect.wasm_func_type;
pub const wasm_func_param_arity = module_introspect.wasm_func_param_arity;
pub const wasm_func_result_arity = module_introspect.wasm_func_result_arity;
pub const wasm_global_type = module_introspect.wasm_global_type;
pub const wasm_table_type = module_introspect.wasm_table_type;
pub const wasm_memory_type = module_introspect.wasm_memory_type;
pub const wasm_instance_new = instance.wasm_instance_new;
pub const wasm_instance_delete = instance.wasm_instance_delete;
pub const zwasm_instance_get_func = instance.zwasm_instance_get_func;
pub const wasm_func_delete = instance.wasm_func_delete;
pub const wasm_extern_kind = instance.wasm_extern_kind;
pub const wasm_extern_delete = instance.wasm_extern_delete;
pub const wasm_extern_as_func = instance.wasm_extern_as_func;
pub const wasm_extern_as_func_const = instance.wasm_extern_as_func_const;
pub const wasm_extern_as_global_const = instance.wasm_extern_as_global_const;
pub const wasm_extern_as_table_const = instance.wasm_extern_as_table_const;
pub const wasm_extern_as_memory_const = instance.wasm_extern_as_memory_const;
pub const wasm_func_as_extern = extern_new.wasm_func_as_extern;
pub const wasm_global_as_extern = extern_new.wasm_global_as_extern;
pub const wasm_table_as_extern = extern_new.wasm_table_as_extern;
pub const wasm_memory_as_extern = extern_new.wasm_memory_as_extern;
pub const wasm_func_as_extern_const = extern_new.wasm_func_as_extern_const;
pub const wasm_global_as_extern_const = extern_new.wasm_global_as_extern_const;
pub const wasm_table_as_extern_const = extern_new.wasm_table_as_extern_const;
pub const wasm_memory_as_extern_const = extern_new.wasm_memory_as_extern_const;
pub const wasm_global_new = extern_new.wasm_global_new;
pub const wasm_memory_new = extern_new.wasm_memory_new;
pub const wasm_table_new = extern_new.wasm_table_new;
pub const wasm_func_new = extern_new.wasm_func_new;
pub const wasm_func_new_with_env = extern_new.wasm_func_new_with_env;
pub const wasm_ref_copy = extern_new.wasm_ref_copy;
pub const wasm_ref_delete = instance.wasm_ref_delete;
pub const wasm_ref_same = extern_new.wasm_ref_same;
pub const wasm_func_as_ref = extern_new.wasm_func_as_ref;
pub const wasm_ref_as_func = extern_new.wasm_ref_as_func;
pub const wasm_func_as_ref_const = extern_new.wasm_func_as_ref_const;
pub const wasm_ref_as_func_const = extern_new.wasm_ref_as_func_const;
pub const wasm_foreign_new = extern_new.wasm_foreign_new;
pub const wasm_foreign_delete = extern_new.wasm_foreign_delete;
pub const wasm_foreign_as_ref = extern_new.wasm_foreign_as_ref;
pub const wasm_ref_as_foreign = extern_new.wasm_ref_as_foreign;
pub const wasm_foreign_as_ref_const = extern_new.wasm_foreign_as_ref_const;
pub const wasm_ref_as_foreign_const = extern_new.wasm_ref_as_foreign_const;
pub const wasm_foreign_get_host_info = extern_new.wasm_foreign_get_host_info;
pub const wasm_foreign_set_host_info = extern_new.wasm_foreign_set_host_info;
pub const wasm_foreign_set_host_info_with_finalizer = extern_new.wasm_foreign_set_host_info_with_finalizer;

// host_info trio for func/global/table/memory/ref/extern (host_info.zig)
pub const wasm_func_get_host_info = host_info.wasm_func_get_host_info;
pub const wasm_func_set_host_info = host_info.wasm_func_set_host_info;
pub const wasm_func_set_host_info_with_finalizer = host_info.wasm_func_set_host_info_with_finalizer;
pub const wasm_global_get_host_info = host_info.wasm_global_get_host_info;
pub const wasm_global_set_host_info = host_info.wasm_global_set_host_info;
pub const wasm_global_set_host_info_with_finalizer = host_info.wasm_global_set_host_info_with_finalizer;
pub const wasm_table_get_host_info = host_info.wasm_table_get_host_info;
pub const wasm_table_set_host_info = host_info.wasm_table_set_host_info;
pub const wasm_table_set_host_info_with_finalizer = host_info.wasm_table_set_host_info_with_finalizer;
pub const wasm_memory_get_host_info = host_info.wasm_memory_get_host_info;
pub const wasm_memory_set_host_info = host_info.wasm_memory_set_host_info;
pub const wasm_memory_set_host_info_with_finalizer = host_info.wasm_memory_set_host_info_with_finalizer;
pub const wasm_ref_get_host_info = host_info.wasm_ref_get_host_info;
pub const wasm_ref_set_host_info = host_info.wasm_ref_set_host_info;
pub const wasm_ref_set_host_info_with_finalizer = host_info.wasm_ref_set_host_info_with_finalizer;
pub const wasm_extern_get_host_info = host_info.wasm_extern_get_host_info;
pub const wasm_extern_set_host_info = host_info.wasm_extern_set_host_info;
pub const wasm_extern_set_host_info_with_finalizer = host_info.wasm_extern_set_host_info_with_finalizer;
pub const wasm_module_get_host_info = host_info.wasm_module_get_host_info;
pub const wasm_module_set_host_info = host_info.wasm_module_set_host_info;
pub const wasm_module_set_host_info_with_finalizer = host_info.wasm_module_set_host_info_with_finalizer;
pub const wasm_trap_get_host_info = host_info.wasm_trap_get_host_info;
pub const wasm_trap_set_host_info = host_info.wasm_trap_set_host_info;
pub const wasm_trap_set_host_info_with_finalizer = host_info.wasm_trap_set_host_info_with_finalizer;
pub const wasm_instance_get_host_info = host_info.wasm_instance_get_host_info;
pub const wasm_instance_set_host_info = host_info.wasm_instance_set_host_info;
pub const wasm_instance_set_host_info_with_finalizer = host_info.wasm_instance_set_host_info_with_finalizer;

// ref-base `wasm_X_same` (ref_base.zig, ADR-0158) — entity identity
pub const wasm_func_same = ref_base.wasm_func_same;
pub const wasm_global_same = ref_base.wasm_global_same;
pub const wasm_table_same = ref_base.wasm_table_same;
pub const wasm_memory_same = ref_base.wasm_memory_same;
pub const wasm_extern_same = ref_base.wasm_extern_same;
pub const wasm_instance_same = ref_base.wasm_instance_same;
pub const wasm_module_same = ref_base.wasm_module_same;
pub const wasm_trap_same = ref_base.wasm_trap_same;
pub const wasm_foreign_same = ref_base.wasm_foreign_same;
pub const wasm_global_as_ref = ref_base.wasm_global_as_ref;
pub const wasm_ref_as_global = ref_base.wasm_ref_as_global;
pub const wasm_global_as_ref_const = ref_base.wasm_global_as_ref_const;
pub const wasm_ref_as_global_const = ref_base.wasm_ref_as_global_const;
pub const wasm_table_as_ref = ref_base.wasm_table_as_ref;
pub const wasm_ref_as_table = ref_base.wasm_ref_as_table;
pub const wasm_table_as_ref_const = ref_base.wasm_table_as_ref_const;
pub const wasm_ref_as_table_const = ref_base.wasm_ref_as_table_const;
pub const wasm_memory_as_ref = ref_base.wasm_memory_as_ref;
pub const wasm_ref_as_memory = ref_base.wasm_ref_as_memory;
pub const wasm_memory_as_ref_const = ref_base.wasm_memory_as_ref_const;
pub const wasm_ref_as_memory_const = ref_base.wasm_ref_as_memory_const;
pub const wasm_extern_as_ref = ref_base.wasm_extern_as_ref;
pub const wasm_ref_as_extern = ref_base.wasm_ref_as_extern;
pub const wasm_extern_as_ref_const = ref_base.wasm_extern_as_ref_const;
pub const wasm_ref_as_extern_const = ref_base.wasm_ref_as_extern_const;
pub const wasm_module_as_ref = ref_base.wasm_module_as_ref;
pub const wasm_ref_as_module = ref_base.wasm_ref_as_module;
pub const wasm_module_as_ref_const = ref_base.wasm_module_as_ref_const;
pub const wasm_ref_as_module_const = ref_base.wasm_ref_as_module_const;
pub const wasm_trap_as_ref = ref_base.wasm_trap_as_ref;
pub const wasm_ref_as_trap = ref_base.wasm_ref_as_trap;
pub const wasm_trap_as_ref_const = ref_base.wasm_trap_as_ref_const;
pub const wasm_ref_as_trap_const = ref_base.wasm_ref_as_trap_const;
pub const wasm_instance_as_ref = ref_base.wasm_instance_as_ref;
pub const wasm_ref_as_instance = ref_base.wasm_ref_as_instance;
pub const wasm_instance_as_ref_const = ref_base.wasm_instance_as_ref_const;
pub const wasm_ref_as_instance_const = ref_base.wasm_ref_as_instance_const;
pub const wasm_func_copy = ref_base.wasm_func_copy;
pub const wasm_global_copy = ref_base.wasm_global_copy;
pub const wasm_table_copy = ref_base.wasm_table_copy;
pub const wasm_memory_copy = ref_base.wasm_memory_copy;
pub const wasm_extern_copy = ref_base.wasm_extern_copy;
pub const wasm_module_copy = ref_base.wasm_module_copy;
pub const wasm_trap_copy = ref_base.wasm_trap_copy;
pub const wasm_instance_copy = ref_base.wasm_instance_copy;
pub const wasm_foreign_copy = extern_new.wasm_foreign_copy;
pub const wasm_extern_vec_copy = ref_base.wasm_extern_vec_copy;
pub const wasm_extern_vec_delete = instance.wasm_extern_vec_delete;
pub const wasm_instance_exports = instance.wasm_instance_exports;
pub const wasm_func_call = instance.wasm_func_call;

// ============================================================
// Smoke tests (re-export shape stability)
// ============================================================

test "wasm_c_api shapes: top-level types instantiate cleanly" {
    const e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    const s: Store = .{ .engine = null };
    const m: Module = .{ .store = null, .bytes_ptr = null, .bytes_len = 0 };
    const i: Instance = .{ .store = null, .module = null, .runtime = null };
    const f: Func = .{ .instance = null, .func_idx = 0 };
    const t: Trap = .{ .store = null, .kind = .binding_error, .message_ptr = null, .message_len = 0 };
    _ = .{ e, s, m, i, f, t };
}

test "wasm_c_api: ValKind tag values match wasm.h" {
    // wasm.h declares:
    //   WASM_I32 = 0, WASM_I64 = 1, WASM_F32 = 2, WASM_F64 = 3,
    //   WASM_EXTERNREF = 128, WASM_FUNCREF = 129
    // Our `ValKind.anyref` aliases WASM_EXTERNREF (same value);
    // the name divergence is historical (the original wasm-c-api
    // draft used `anyref`).
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ValKind.i32));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ValKind.i64));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ValKind.f32));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ValKind.f64));
    try testing.expectEqual(@as(u8, 128), @intFromEnum(ValKind.anyref));
    try testing.expectEqual(@as(u8, 129), @intFromEnum(ValKind.funcref));
}

test "wasm_c_api: Val tagged-union round-trip" {
    const v_i32: Val = .{ .kind = .i32, .of = .{ .i32 = -42 } };
    try testing.expectEqual(@as(i32, -42), v_i32.of.i32);

    const v_f64: Val = .{ .kind = .f64, .of = .{ .f64 = 3.14 } };
    try testing.expectEqual(@as(f64, 3.14), v_f64.of.f64);
}

test "wasm_c_api: ByteVec carries size + data" {
    var bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const v: ByteVec = .{ .size = bytes.len, .data = &bytes };
    try testing.expectEqual(@as(usize, 4), v.size);
    try testing.expectEqual(@as(u8, 0xDE), v.data.?[0]);
}

test "wasm_c_api: imports interp namespace (Zone-3 layering)" {
    // Compile-time check that the binding can reach
    // `runtime.Runtime` shape; the §9.3 / 3.5 instance binding
    // will own one. Just touch the type name to assert the
    // import resolves.
    _ = runtime.Runtime;
}
