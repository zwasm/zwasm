//! Embedder observability hooks (#216, ADR-0231) — the five engine events a
//! host can listen to, and the emit helpers every raising site calls.
//!
//! Zone 1 (`src/runtime/`) on purpose: the raising sites span all three zones
//! (`runtime.growMemory` here, `engine/setup.jitMemoryGrow` in Zone 2, the
//! trap funnel and both instantiate arms in Zone 3), and only a Zone-1 home
//! is importable from all of them. That is also why `trap_kind` is a plain
//! `i32` and not `api/trap_surface.TrapKind`: the value IS the C-ABI number
//! `zwasm_trap_kind` returns (`check_trap_abi_sync.sh` guards it), and naming
//! the Zone-3 enum here would be an upward import.
//!
//! Contract (stated once, in `include/zwasm.h` and ADR-0231; not repeated at
//! each site): calling back into the engine from a hook is undefined, the
//! slots are set before first use and never changed concurrently, and a
//! `(ptr, len)` string is valid only for the callback's duration.

const std = @import("std");

const Engine = @import("engine.zig").Engine;

/// A module was offered to the engine. `accepted` false = the bytes were
/// rejected by parse or validation.
pub const CompileFn = *const fn (user_data: ?*anyopaque, wasm_len: usize, accepted: bool) callconv(.c) void;

/// An instantiation succeeded and minted `instance_id`.
pub const InstantiateFn = *const fn (user_data: ?*anyopaque, instance_id: u64) callconv(.c) void;

/// The engine raised a trap. `message` is borrowed for the call only.
pub const TrapFn = *const fn (
    user_data: ?*anyopaque,
    instance_id: u64,
    trap_kind: i32,
    message_ptr: ?[*]const u8,
    message_len: usize,
) callconv(.c) void;

/// A fuel budget ran out. Always paired with a `trap` event of the same
/// instance carrying kind 17 — this one exists so a host metering fuel need
/// not switch on the kind.
pub const FuelExhaustedFn = *const fn (user_data: ?*anyopaque, instance_id: u64) callconv(.c) void;

/// A linear memory grew. Only success is reported; a refused grow is the
/// spec's recoverable -1, not an event.
pub const MemoryGrowthFn = *const fn (
    user_data: ?*anyopaque,
    instance_id: u64,
    memory_index: u32,
    old_pages: u64,
    new_pages: u64,
) callconv(.c) void;

/// The engine's five nullable slots. `extern` because it is embedded in the
/// C-visible `Engine`; every field is a pointer pair, so the layout is
/// C-stable by construction.
pub const Hooks = extern struct {
    compile: ?CompileFn = null,
    compile_user_data: ?*anyopaque = null,
    instantiate: ?InstantiateFn = null,
    instantiate_user_data: ?*anyopaque = null,
    trap: ?TrapFn = null,
    trap_user_data: ?*anyopaque = null,
    fuel_exhausted: ?FuelExhaustedFn = null,
    fuel_exhausted_user_data: ?*anyopaque = null,
    memory_growth: ?MemoryGrowthFn = null,
    memory_growth_user_data: ?*anyopaque = null,
};

/// What a raising site needs to name itself: which engine to ask for the
/// slots, and which instance the event belongs to.
///
/// A value, not a slot, wherever the facts are already reachable: the interp
/// derives one from `Runtime.instance` (`Runtime.hookSite`) precisely so that
/// struct's layout is untouched — Zig's auto layout re-packs on any field
/// added, and a 16-byte slot there moved `memory` and `fuel`, both read per
/// executed instruction. The JIT's `MemGrowCtx` does store one, because
/// emitted code reaches its grow helper with nothing but `rt.host_state` in
/// hand and that context is off the hot path entirely.
pub const Site = struct {
    engine: ?*Engine = null,
    instance_id: u64 = 0,
};

/// The id an instantiation gets. Monotonic per engine and never reused;
/// a failed instantiation burns its id rather than returning it, so a gap
/// in the sequence carries no meaning. Id 0 is "no instance": an event
/// raised before instantiation, or by a handle with no instance behind it.
///
/// "Never reused" is bounded by the counter: at `maxInt(u64)` this is an
/// integer overflow, which panics in Debug and ReleaseSafe and wraps in
/// ReleaseFast. No policy is coded for it because the bound is not reachable
/// — an engine would have to instantiate 2^64 modules, which at one per
/// nanosecond is roughly 584 years — and a saturating or wrapping arm would
/// be dead code asserting a weaker guarantee than the one above.
pub fn nextInstanceId(engine: ?*Engine) u64 {
    const e = engine orelse return 0;
    e.next_instance_id += 1;
    return e.next_instance_id;
}

pub fn emitCompile(engine: ?*Engine, wasm_len: usize, accepted: bool) void {
    const e = engine orelse return;
    const f = e.hooks.compile orelse return;
    f(e.hooks.compile_user_data, wasm_len, accepted);
}

pub fn emitInstantiate(engine: ?*Engine, instance_id: u64) void {
    const e = engine orelse return;
    const f = e.hooks.instantiate orelse return;
    f(e.hooks.instantiate_user_data, instance_id);
}

/// The trap funnel. `kind` is the C-ABI trap-kind number. Kind 17
/// (`out_of_fuel`) additionally raises `fuel_exhausted`, so a budget that ran
/// out is reported once by each hook and the two orders never diverge — this
/// is the only place that pairing is decided.
pub fn emitTrap(engine: ?*Engine, instance_id: u64, kind: i32, message: []const u8) void {
    const e = engine orelse return;
    if (e.hooks.trap) |f| f(e.hooks.trap_user_data, instance_id, kind, message.ptr, message.len);
    if (kind == fuel_trap_kind) {
        if (e.hooks.fuel_exhausted) |f| f(e.hooks.fuel_exhausted_user_data, instance_id);
    }
}

/// `TrapKind.out_of_fuel` / `ZWASM_TRAP_OUT_OF_FUEL`. Spelled as a number
/// because the enum is Zone 3; `check_trap_abi_sync.sh` holds the header and
/// the enum together, and the test below holds this constant to the enum.
pub const fuel_trap_kind: i32 = 17;

pub fn emitMemoryGrowth(site: Site, memory_index: u32, old_pages: u64, new_pages: u64) void {
    const e = site.engine orelse return;
    const f = e.hooks.memory_growth orelse return;
    f(e.hooks.memory_growth_user_data, site.instance_id, memory_index, old_pages, new_pages);
}

const testing = std.testing;

test "nextInstanceId: monotonic from 1, and 0 for no engine" {
    var e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    try testing.expectEqual(@as(u64, 1), nextInstanceId(&e));
    try testing.expectEqual(@as(u64, 2), nextInstanceId(&e));
    try testing.expectEqual(@as(u64, 0), nextInstanceId(null));
}

test "an engine with no hooks registered emits nothing and cannot fault" {
    var e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    emitCompile(&e, 7, true);
    emitInstantiate(&e, 1);
    emitTrap(&e, 1, fuel_trap_kind, "all fuel consumed");
    emitMemoryGrowth(.{ .engine = &e, .instance_id = 1 }, 0, 1, 2);
    emitCompile(null, 7, true);
    emitMemoryGrowth(.{}, 0, 1, 2);
}

var seen_trap: u32 = 0;
var seen_fuel: u32 = 0;

fn countTrap(_: ?*anyopaque, _: u64, _: i32, _: ?[*]const u8, _: usize) callconv(.c) void {
    seen_trap += 1;
}

fn countFuel(_: ?*anyopaque, _: u64) callconv(.c) void {
    seen_fuel += 1;
}

test "#216: an out-of-fuel trap raises both hooks; any other kind raises only trap" {
    var e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    e.hooks.trap = countTrap;
    e.hooks.fuel_exhausted = countFuel;
    seen_trap = 0;
    seen_fuel = 0;

    emitTrap(&e, 1, 1, "unreachable"); // TrapKind.unreachable_
    try testing.expectEqual(@as(u32, 1), seen_trap);
    try testing.expectEqual(@as(u32, 0), seen_fuel);

    emitTrap(&e, 1, fuel_trap_kind, "all fuel consumed");
    try testing.expectEqual(@as(u32, 2), seen_trap);
    try testing.expectEqual(@as(u32, 1), seen_fuel);
}
