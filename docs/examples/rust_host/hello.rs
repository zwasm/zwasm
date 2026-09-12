//! zwasm v2 — minimal Rust host example (§13.5).
//!
//! A third, independent embedding-ABI consumer (after `c_host/hello.c`
//! and the native `zig_host/hello.zig`). It declares the wasm-c-api
//! surface via `extern "C"` and links the Zig-built `libzwasm.a`,
//! driving the binding end-to-end:
//!
//!   engine -> store -> module -> instance -> exports -> func_call
//!
//! over the import-free payload
//!
//!   (module (func (export "main") (result i32) (i32.const 42)))
//!
//! Built + run by `zig build run-rust-host` (Mac-only: the test hosts
//! are artifact-runners with no rustc by design — see
//! `.dev/toolchain_provisioning.md`). Exits 0 on success (main == 42).
//!
//! Rust's strict FFI is a deliberate cross-check on the C ABI: a
//! layout or ownership mismatch surfaces as a link error or a wrong
//! result, the way the C conformance suite caught the imports-vec bug
//! (`5a19ebd6`).

#![allow(non_camel_case_types, non_snake_case, dead_code)]

use std::os::raw::c_void;
use std::ptr;

// --- Opaque handle types (wasm.h `WASM_DECLARE_OWN` objects) -------------
// Empty enums are uninhabited, so a `*mut wasm_engine_t` can only ever be
// produced by the C side — exactly the opaque-pointer contract.
enum wasm_engine_t {}
enum wasm_store_t {}
enum wasm_module_t {}
enum wasm_instance_t {}
enum wasm_func_t {}
enum wasm_extern_t {}
enum wasm_trap_t {}

// --- Vectors (wasm.h `WASM_DECLARE_VEC`: { size_t size; T* data; }) -------
#[repr(C)]
struct wasm_byte_vec_t {
    size: usize,
    data: *mut u8,
}

#[repr(C)]
struct wasm_extern_vec_t {
    size: usize,
    data: *mut *mut wasm_extern_t,
}

#[repr(C)]
struct wasm_val_vec_t {
    size: usize,
    data: *mut wasm_val_t,
}

// --- wasm_val_t { wasm_valkind_t kind; union { ... } of; } ----------------
// `kind` is uint8_t; the union is 8-byte aligned (holds i64/f64/ptr), so
// `of` sits at offset 8 and the struct is 16 bytes — matching the C layout.
#[repr(C)]
union wasm_val_union {
    i32_: i32,
    i64_: i64,
    f32_: f32,
    f64_: f64,
    ref_: *mut c_void,
}

#[repr(C)]
struct wasm_val_t {
    kind: u8,
    of: wasm_val_union,
}

// wasm_valkind_enum / wasm_externkind_enum first members.
const WASM_I32: u8 = 0;
const WASM_EXTERN_FUNC: u8 = 0;

extern "C" {
    fn wasm_engine_new() -> *mut wasm_engine_t;
    fn wasm_engine_delete(engine: *mut wasm_engine_t);

    fn wasm_store_new(engine: *mut wasm_engine_t) -> *mut wasm_store_t;
    fn wasm_store_delete(store: *mut wasm_store_t);

    fn wasm_module_new(store: *mut wasm_store_t, binary: *const wasm_byte_vec_t)
        -> *mut wasm_module_t;
    fn wasm_module_delete(module: *mut wasm_module_t);

    fn wasm_instance_new(
        store: *mut wasm_store_t,
        module: *const wasm_module_t,
        imports: *const wasm_extern_vec_t,
        trap_out: *mut *mut wasm_trap_t,
    ) -> *mut wasm_instance_t;
    fn wasm_instance_delete(instance: *mut wasm_instance_t);
    fn wasm_instance_exports(instance: *mut wasm_instance_t, out: *mut wasm_extern_vec_t);

    fn wasm_extern_kind(ext: *const wasm_extern_t) -> u8;
    fn wasm_extern_as_func(ext: *mut wasm_extern_t) -> *mut wasm_func_t;

    fn wasm_func_call(
        func: *mut wasm_func_t,
        args: *const wasm_val_vec_t,
        results: *mut wasm_val_vec_t,
    ) -> *mut wasm_trap_t;

    fn wasm_trap_message(trap: *const wasm_trap_t, out: *mut wasm_byte_vec_t);
    fn wasm_trap_delete(trap: *mut wasm_trap_t);

    fn wasm_byte_vec_delete(vec: *mut wasm_byte_vec_t);
    fn wasm_extern_vec_delete(vec: *mut wasm_extern_vec_t);
}

/// (module (func (export "main") (result i32) (i32.const 42)))
const HELLO_WASM: [u8; 37] = [
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x08, 0x01, 0x04, 0x6d, 0x61, 0x69, 0x6e, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
];

unsafe fn print_trap_and_delete(trap: *mut wasm_trap_t) {
    if trap.is_null() {
        return;
    }
    let mut msg = wasm_byte_vec_t { size: 0, data: ptr::null_mut() };
    wasm_trap_message(trap, &mut msg);
    // `wasm_trap_message` leaves the vector `{0, NULL}` when it cannot
    // allocate, so both halves are checked before the length arithmetic below.
    if !msg.data.is_null() && msg.size > 0 {
        // `size` counts the terminating NUL (#441); drop it for the text.
        let bytes = std::slice::from_raw_parts(msg.data, msg.size - 1);
        eprintln!("trap: {}", String::from_utf8_lossy(bytes));
    }
    wasm_byte_vec_delete(&mut msg);
    wasm_trap_delete(trap);
}

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    unsafe {
        let engine = wasm_engine_new();
        if engine.is_null() {
            eprintln!("wasm_engine_new failed");
            return 1;
        }
        let store = wasm_store_new(engine);
        if store.is_null() {
            eprintln!("wasm_store_new failed");
            wasm_engine_delete(engine);
            return 1;
        }

        // `data` is borrowed for the duration of the call; the C side
        // copies the bytes it needs, so a non-owning view is sound.
        let binary = wasm_byte_vec_t {
            size: HELLO_WASM.len(),
            data: HELLO_WASM.as_ptr() as *mut u8,
        };
        let module = wasm_module_new(store, &binary);
        if module.is_null() {
            eprintln!("wasm_module_new failed");
            wasm_store_delete(store);
            wasm_engine_delete(engine);
            return 1;
        }

        let imports = wasm_extern_vec_t { size: 0, data: ptr::null_mut() };
        let mut instantiation_trap: *mut wasm_trap_t = ptr::null_mut();
        let instance = wasm_instance_new(store, module, &imports, &mut instantiation_trap);

        let mut rc = 1;
        let mut exports = wasm_extern_vec_t { size: 0, data: ptr::null_mut() };
        'done: {
            if instance.is_null() {
                eprintln!("wasm_instance_new failed");
                print_trap_and_delete(instantiation_trap);
                break 'done;
            }

            wasm_instance_exports(instance, &mut exports);
            if exports.size < 1 || exports.data.is_null() {
                eprintln!("module declared no exports");
                break 'done;
            }

            let main_extern = *exports.data; // exports.data[0]
            if main_extern.is_null() || wasm_extern_kind(main_extern) != WASM_EXTERN_FUNC {
                eprintln!("first export is not a func");
                break 'done;
            }
            let main_fn = wasm_extern_as_func(main_extern);
            if main_fn.is_null() {
                eprintln!("wasm_extern_as_func failed");
                break 'done;
            }

            let mut results_data = [wasm_val_t { kind: 0, of: wasm_val_union { i64_: 0 } }];
            let mut results = wasm_val_vec_t {
                size: results_data.len(),
                data: results_data.as_mut_ptr(),
            };
            let args = wasm_val_vec_t { size: 0, data: ptr::null_mut() };

            let call_trap = wasm_func_call(main_fn, &args, &mut results);
            if !call_trap.is_null() {
                print_trap_and_delete(call_trap);
                break 'done;
            }

            if results_data[0].kind != WASM_I32 {
                eprintln!("result kind {} != WASM_I32", results_data[0].kind);
                break 'done;
            }

            let value = results_data[0].of.i32_;
            println!("zwasm rust_host: main() returned {}", value);
            rc = if value == 42 { 0 } else { 2 };
        }

        if !exports.data.is_null() {
            wasm_extern_vec_delete(&mut exports);
        }
        if !instance.is_null() {
            wasm_instance_delete(instance);
        }
        wasm_module_delete(module);
        wasm_store_delete(store);
        wasm_engine_delete(engine);
        rc
    }
}
