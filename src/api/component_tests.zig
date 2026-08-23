// FILE-SIZE-EXEMPT: already the P4 test-isolation extraction from component.zig; topic-slicing would duplicate fixtures (N4) (investigated 2026-08-12, per ADR-0099)
//! Tests for `component.zig` (Zone-3 component host orchestration).
//! Extracted from `component.zig` per the file-size smell rule (P4
//! test-isolation; mirrors `validator_tests.zig`). The impl file stays lean.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const component = @import("component.zig");
const cwasi = @import("component_wasi_p2.zig");
const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const decode = @import("../feature/component/decode.zig");
const cvalidate = @import("../feature/component/validate.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const PrimValType = ctypes.PrimValType;
const WasiP2Ctx = cwasi.WasiP2Ctx;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = @import("../zwasm.zig").Value;
const Caller = @import("../zwasm/caller.zig").Caller;

// component.zig public decls the tests reference by bare name.
const instantiate = component.instantiate;
const instantiateGraph = component.instantiateGraph;
const invokeTypedBuilt = component.invokeTypedBuilt;
const runWasiP2Main = component.runWasiP2Main;
const buildWasiP2Component = component.buildWasiP2Component;
const BuiltComponent = component.BuiltComponent;
const ComponentInstance = component.ComponentInstance;
const ComponentGraph = component.ComponentGraph;
const ComponentValue = component.ComponentValue;
const WitType = component.WitType;
const FuncSig = component.FuncSig;
const InvokeTypedError = component.InvokeTypedError;
const Error = component.Error;
const MAX_FLAT_PARAMS = component.MAX_FLAT_PARAMS;
const Opened = component.Opened;
const open = component.open;
const componentNeedsWasi = component.componentNeedsWasi;

test "REQ-1 (cw CM-API): open auto-selects single path for a pure component + unified methods" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    // greet imports no wasi → predicate false → open routes to the single path.
    try testing.expect(!(try componentNeedsWasi(testing.allocator, bytes)));

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();
    try testing.expect(opened == .single);

    // Unified methods work regardless of the underlying path.
    const funcs = try opened.exportedFuncs(testing.allocator);
    defer ctypes.TypeInfo.freeExportedFuncs(testing.allocator, funcs);
    try testing.expectEqual(@as(usize, 1), funcs.len);
    try testing.expectEqualStrings("greet", funcs[0].name);

    const out = (try opened.invokeTyped("greet", &.{.{ .string = "zwasm" }}, testing.allocator)).?;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello, zwasm!", out.string);
}

test "REQ-7 (cw CM-API): an opened component outlives the caller's input buffer" {
    // cw caches the opened component long-lived (a GC-finalised instance box) and
    // frees its transient load buffer right after `open`. The component must OWN
    // its bytes: `decode.Component` borrowed the input zero-copy, so the TypeInfo
    // names (export labels slice the section bodies) dangled once the host freed
    // `bytes` — and resolveFuncSig returned null for EVERY export (cw's symptom).
    // Free + clobber the input immediately after open to pin the contract.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    const bytes = try testing.allocator.dupe(u8, src); // a private, soon-freed load buffer
    testing.allocator.free(src);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();

    // The host drops its load buffer; the opened component must not depend on it.
    @memset(bytes, 0xAA); // any dangling slice now reads garbage
    testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = (try opened.resolveFuncSig(arena.allocator(), "greet")).?;
    try testing.expectEqual(@as(usize, 1), sig.params.len);

    const out = (try opened.invokeTyped("greet", &.{.{ .string = "zwasm" }}, testing.allocator)).?;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello, zwasm!", out.string);
}

test "REQ-1 (cw CM-API): open auto-selects the WASI graph for a wasip2 component" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/typed_payload.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    // typed_payload imports wasi → predicate true → open routes to the graph.
    try testing.expect(try componentNeedsWasi(testing.allocator, bytes));

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();
    try testing.expect(opened == .wasi);

    // The same unified surface drives the graph path: resolveFuncSig works.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const funcs = try opened.exportedFuncs(testing.allocator);
    defer ctypes.TypeInfo.freeExportedFuncs(testing.allocator, funcs);
    try testing.expect(funcs.len >= 1);
    const sig = (try opened.resolveFuncSig(arena.allocator(), funcs[0].name)).?;
    try testing.expectEqual(@as(usize, 1), sig.params.len);
}

const WasiP2Error = cwasi.WasiP2Error;
const p2GetStdout = cwasi.p2GetStdout;
const p2OutStreamWrite = cwasi.p2OutStreamWrite;
const p2OutStreamDrop = cwasi.p2OutStreamDrop;
const p2DescriptorWrite = cwasi.p2DescriptorWrite;
const p2DescriptorDrop = cwasi.p2DescriptorDrop;
const p2DescriptorOpenAt = cwasi.p2DescriptorOpenAt;
const p2GetDirectories = cwasi.p2GetDirectories;

// ============================================================
// Tests
// ============================================================

/// A minimal core module: `(module (func (export "run") (result i32) i32.const 42))`.
const core_run42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // func: 1 fn, type 0
    0x07, 0x07, 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x00, // export "run" (func 0)
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
};

/// The above core module embedded in a component (core-module section, id 1).
const component_run42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_run42.len, // core-module section: id 1, size 36
} ++ core_run42;

test "IT-1: instantiate embedded core module + invoke a ()->i32 export" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();

    var ci = try instantiate(&eng, testing.allocator, &component_run42, .{});
    defer ci.deinit();

    var results = [_]Value{.{ .i32 = 0 }};
    try ci.invokeCore("run", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "IT-1: a component with no core module is rejected" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    // Empty component (preamble only, no sections).
    const empty = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try testing.expectError(Error.NoCoreModule, instantiate(&eng, testing.allocator, &empty, .{}));
}

test "E2 prereq: core-table index space resolves an alias-core-export table (ADR-0175)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/core_table_alias.wasm", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);
    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The general instantiation engine resolves a synthetic instance's table
    // re-export through this space (the shim `$imports` table — ADR-0175).
    try testing.expectEqual(@as(usize, 1), info.core_tables.items.len);
    const ref = info.resolveCoreTableExport(0).?;
    try testing.expectEqual(@as(u32, 0), ref.instance);
    try testing.expectEqualStrings("tbl", ref.name);
}

fn testHostInc(_: *Caller, x: u32) anyerror!u32 {
    return x + 1;
}

test "D-310: a guest call_indirects an imported host func through a table" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/core_host_func_table.wasm", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(bytes);
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    // The host func is placed in the module's table via an active elem segment;
    // run(x) reaches it by call_indirect — exercises the per-import placeholder
    // sig + the call_indirect host-dispatch (D-310 runtime fix).
    try lk.defineFunc("env", "inc", fn (*Caller, u32) anyerror!u32, testHostInc);
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();

    var res = [_]Value{.{ .i32 = 0 }};
    try inst.invoke("run", &.{.{ .i32 = 41 }}, &res);
    try testing.expectEqual(@as(i32, 42), res[0].i32);
}

/// `(module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))`.
const core_add = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->(i32)
    0x03, 0x02, 0x01, 0x00, // func: 1 fn, type 0
    0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export "add"
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code: local.get 0/1; i32.add
};
const component_add = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_add.len, // core-module section
} ++ core_add;

test "IT-2: canon flat trampoline — add(u32,u32)->u32 component invoke" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_add, .{});
    defer ci.deinit();

    var out: canon.Value = undefined;
    try ci.invokeFlat("add", &.{ .{ .u32 = 40 }, .{ .u32 = 2 } }, &.{ .u32, .u32 }, .u32, &out);
    try testing.expectEqual(@as(u32, 42), out.u32);
}

test "IT-2: trampoline lifts a signed result through the canon boundary" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_add, .{});
    defer ci.deinit();
    // s32 view of the same add: -1 + -1 = -2 (two's complement through i32 core).
    var out: canon.Value = undefined;
    try ci.invokeFlat("add", &.{ .{ .s32 = -1 }, .{ .s32 = -1 } }, &.{ .s32, .s32 }, .s32, &out);
    try testing.expectEqual(@as(i32, -2), out.s32);
}

/// A core module with a 1-page memory + a bump-allocator `cabi_realloc` (it
/// ignores `old`/`old_size`/`align` — sufficient for the align-1 string test —
/// and never grows memory, keeping a captured memory slice valid):
/// ```wat
/// (module
///   (memory (export "memory") 1)
///   (global $next (mut i32) (i32.const 16))
///   (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (local $ret i32)
///     global.get $next  local.set $ret
///     global.get $next  local.get 3  i32.add  global.set $next
///     local.get $ret))
/// ```
const core_realloc = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x09, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, // type (i32×4)->i32
    0x03, 0x02, 0x01, 0x00, // func: type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1 page
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x10, 0x0b, // global $next (mut i32) = 16
    0x07, 0x19, 0x02, // export section: 2 exports
    0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00, // "memory" → mem 0
    0x0c, 'c', 'a', 'b', 'i', '_', 'r', 'e', 'a', 'l', 'l', 'o', 'c', 0x00, 0x00, // "cabi_realloc" → func 0
    0x0a, 0x13, 0x01, 0x11, 0x01, 0x01, 0x7f, // code: 1 func, body size 17, 1 i32 local
    0x23, 0x00, 0x21, 0x04, // global.get 0; local.set 4 ($ret)
    0x23, 0x00, 0x20, 0x03, 0x6a, 0x24, 0x00, // global.get 0; local.get 3; i32.add; global.set 0
    0x20, 0x04, 0x0b, // local.get 4; end
};
const component_realloc = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_realloc.len, // core-module section
} ++ core_realloc;

test "IT-3a: cabi_realloc-via-guest — string lower/lift over real guest memory" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_realloc, .{});
    defer ci.deinit();

    const cx = try ci.canonContext();
    // Lower a host string THROUGH the guest's own cabi_realloc allocator...
    const lowered = try canon.lowerString(cx, "héllo, 世界");
    try testing.expect(lowered.ptr >= 16); // past the bump start
    // ...and lift it back out of the guest linear memory.
    const back = try canon.liftString(cx, testing.allocator, lowered.ptr, lowered.packed_length);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("héllo, 世界", back);
}

test "REQ-4 (cw CM-API): component instantiate threads the budget — max_memory_pages=0 → MemoryLimitExceeded" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    // component_realloc's embedded core declares ≥1 initial memory page; a
    // zero-page cap must reject at instantiation (the budget reaches
    // module.instantiate through the new `opts` param, not the hardcoded `.{}`).
    try testing.expectError(
        Module.InstantiateError.MemoryLimitExceeded,
        instantiate(&eng, testing.allocator, &component_realloc, .{ .max_memory_pages = .{ .limited = 0 } }),
    );
    // The default budget (`.{}`) still instantiates cleanly.
    var ci = try instantiate(&eng, testing.allocator, &component_realloc, .{});
    ci.deinit();
}

test "IT-3a: two allocations via the guest allocator don't overlap" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_realloc, .{});
    defer ci.deinit();

    const cx = try ci.canonContext();
    const a = try canon.lowerString(cx, "first");
    const b = try canon.lowerString(cx, "second");
    try testing.expect(b.ptr >= a.ptr + a.packed_length); // bump advanced
    const back_a = try canon.liftString(cx, testing.allocator, a.ptr, a.packed_length);
    defer testing.allocator.free(back_a);
    try testing.expectEqualStrings("first", back_a);
    const back_b = try canon.liftString(cx, testing.allocator, b.ptr, b.packed_length);
    defer testing.allocator.free(back_b);
    try testing.expectEqualStrings("second", back_b);
}

/// Provenance of the REAL string→string component fixture (`greet(name: string)
/// -> string` ⇒ `"Hello, " ++ name ++ "!"`, built with wasm-tools). Sources at
/// `test/component/` (kept OUT of `test/edge_cases/` so the edge-case runner —
/// which runs every `.wasm` there as a core module — doesn't try to run a
/// component). Read at runtime (it lives outside the `src/`
/// package, so `@embedFile` can't reach it); `zig build test` runs from the repo
/// root so the cwd-relative path resolves.
const greet_component_path = "test/component/greet_component.wasm";

/// A real 2-component graph (wasm-tools): component B exports `adder(u32,u32)->
/// u32`; component A imports it + exports `add-five(x)=adder(x,5)`; the outer
/// instantiates B, instantiates A `with "adder"=B.adder`, re-exports add-five.
const adder_graph_path = "test/component/adder_graph.wasm";

/// D-305 security fixture: a 2-component graph (cf. strlen_graph) where A calls
/// B's `firstbyte(s: string)->u32` with an OUT-OF-BOUNDS (ptr,len) far past A's
/// 1-page memory. The boundary trampoline's source-side `sliceAt` MUST fail →
/// the cross-component call MUST trap (never a silent wrong/empty marshal).
const oob_param_graph_path = "test/component/oob_param_graph.wasm";

/// D-466 regression: a 2-component graph whose B exports a 5-param func — an
/// UNSUPPORTED boundary arity → `instantiateGraph` returns UnsupportedBoundaryType.
/// Exercises the FAILED-instantiate cleanup path (must not double-free).
const unsupported_boundary_graph_path = "test/component/unsupported_boundary_graph.wasm";

test "C2-3b-1: a real 2-component graph decodes (nested components + instances + wiring)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, adder_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);

    // The outer embeds 2 nested child components (§4).
    var children: usize = 0;
    for (comp.sections.items) |sec| {
        if (sec.id == .component) children += 1;
    }
    try testing.expectEqual(@as(usize, 2), children);

    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // Two component-instances: instantiate child 0 (B) and child 1 (A) with a
    // `with` arg satisfying A's import.
    try testing.expectEqual(@as(usize, 2), info.component_instances.items.len);
    try testing.expectEqual(@as(u32, 0), info.component_instances.items[0].instantiate.component);
    try testing.expectEqual(@as(u32, 1), info.component_instances.items[1].instantiate.component);
    try testing.expect(info.component_instances.items[1].instantiate.args.len >= 1);

    // The outer re-exports add-five.
    var found = false;
    for (info.exports.items) |e| {
        if (std.mem.eql(u8, e.name, "add-five")) found = true;
    }
    try testing.expect(found);

    // Recursively decode child component B → it canon-lifts its `adder` export.
    const b_bytes = for (comp.sections.items) |sec| {
        if (sec.id == .component) break sec.body;
    } else unreachable;
    try testing.expectEqual(decode.Kind.component, try decode.classify(b_bytes));
    var b = try decode.decode(testing.allocator, b_bytes);
    defer b.deinit(testing.allocator);
    var b_info = try ctypes.decodeTypeInfo(testing.allocator, &b);
    defer b_info.deinit();
    var b_lift = false;
    for (b_info.canons.items) |c| {
        if (c == .lift) b_lift = true;
    }
    try testing.expect(b_lift);
}

/// A real WASI Preview 2 "hello world" component (hand-authored + wasm-tools):
/// imports `wasi:cli/stdout` + `wasi:io/streams` (+ `wasi:io/error`), exports
/// `wasi:cli/run`'s `run`, prints "hello" (verified via wasmtime). Source +
/// provenance: `test/component/wasi_p2_hello.{wat,go}` + README.
const wasi_p2_hello_path = "test/component/wasi_p2_hello.wasm";

test "D1-2: WASI-P2 hello-world component decodes structurally (imports wasi:cli/io)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    try testing.expectEqual(decode.Kind.component, try decode.classify(bytes));
    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);

    var has_import = false;
    var has_core_module = false;
    var has_canon = false;
    for (comp.sections.items) |sec| {
        switch (sec.id) {
            .import => has_import = true,
            .core_module => has_core_module = true,
            .canon => has_canon = true,
            else => {},
        }
    }
    try testing.expect(has_import and has_core_module and has_canon);

    // It imports the WASI P2 CLI-print interfaces (the adapter D1-1 name-maps).
    try testing.expect(std.mem.find(u8, bytes, "wasi:cli/stdout") != null);
    try testing.expect(std.mem.find(u8, bytes, "wasi:io/streams") != null);

    // Full type-info decode now succeeds (instance-type decode landed): the
    // component imports the 3 wasi instances + has a canon section.
    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 3), info.imports.items.len);
    var has_stdout = false;
    for (info.imports.items) |imp| {
        if (std.mem.find(u8, imp.name, "wasi:cli/stdout") != null) has_stdout = true;
        try testing.expect(imp.desc == .instance); // each wasi import is an instance
    }
    try testing.expect(has_stdout);
    try testing.expect(info.canons.items.len > 0);

    // The core-func index space interleaves the canon lowers (host-implemented
    // wasi imports) + the resource.drop builtin + the core-export alias for the
    // lowered `run`, in definition order — the unified model the host run path
    // resolves against (an alias-only count would mis-index slot 3).
    try testing.expectEqual(@as(usize, 4), info.core_funcs.items.len);
    try testing.expect(info.core_funcs.items[0] == .lower); // get-stdout
    try testing.expect(info.core_funcs.items[1] == .lower); // blocking-write-and-flush
    try testing.expect(info.core_funcs.items[2] == .resource_drop); // output-stream drop
    try testing.expect(info.core_funcs.items[3] == .alias); // $m "run"
    const run_ref = info.resolveCoreFuncExport(3).?;
    try testing.expectEqualStrings("run", run_ref.name);
    try testing.expectEqual(@as(u32, 2), run_ref.instance); // core-instance $m
}

test "C2-3b-2 (EXIT): a 2-component graph links + runs (A calls B across components)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, adder_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // add-five(10) = adder(10, 5) = 15 — the call crosses from component A into B.
    var results = [_]Value{.{ .i32 = 0 }};
    try graph.invokeFlat("add-five", &.{.{ .i32 = 10 }}, &results);
    try testing.expectEqual(@as(i32, 15), results[0].i32);
}

test "D-466: a graph with an unsupported boundary shape fails to instantiate WITHOUT a double-free" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, unsupported_boundary_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    // The wide-u64-param boundary is unsupported → instantiateGraph errors
    // mid-build, AFTER an earlier child's module (and any bctx/fctx) were appended
    // to the graph. Its `errdefer graph.deinit()` must free each EXACTLY once — the
    // prior surviving local errdefers double-freed, which testing.allocator panics on.
    try testing.expectError(error.UnsupportedBoundaryType, instantiateGraph(&eng, testing.allocator, bytes, .{}));
}

test "D-305 (security): an OOB (ptr,len) into a cross-component string import TRAPS, not silently returns 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, oob_param_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A passes (ptr=0x10000000, len=0x10000000) — both far past A's 1-page (64
    // KiB) memory. The boundary marshaller's `caller_mem.sliceAt` over A's
    // memory fails → the call must TRAP (canonical-ABI / untrusted-component
    // sandboxing). The pre-fix behaviour silently returned 0.
    var results = [_]Value{.{ .i32 = 0 }};
    try testing.expectError(error.OutOfBoundsLoad, graph.invokeFlat("run", &.{}, &results));
}

test "IT-3b-2: a real wasm-tools string→string component decodes through the pipeline" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const greet_component = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(greet_component);

    try testing.expectEqual(decode.Kind.component, try decode.classify(greet_component));

    var comp = try decode.decode(testing.allocator, greet_component);
    defer comp.deinit(testing.allocator);

    var has_core_module = false;
    var has_canon = false;
    for (comp.sections.items) |sec| {
        if (sec.id == .core_module) has_core_module = true;
        if (sec.id == .canon) has_canon = true;
    }
    try testing.expect(has_core_module and has_canon);

    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The component-level func type: greet(name: string) -> string.
    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(PrimValType.string, ft.params[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, ft.result.?.primitive);

    // The canon section lifts greet with utf8 + memory + realloc + post-return.
    var found_lift = false;
    for (info.canons.items) |c| {
        if (c == .lift) {
            found_lift = true;
            try testing.expectEqual(ctypes.StringEncoding.utf8, c.lift.opts.string_encoding);
            try testing.expect(c.lift.opts.memory != null);
            try testing.expect(c.lift.opts.realloc != null);
            try testing.expect(c.lift.opts.post_return != null);
        }
    }
    try testing.expect(found_lift);

    // A top-level export named "greet".
    var found_export = false;
    for (info.exports.items) |e| {
        if (std.mem.eql(u8, e.name, "greet")) found_export = true;
    }
    try testing.expect(found_export);
}

test "IT-3b-3 (EXIT): a real string→string component runs end-to-end" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    // greet("zwasm") ⇒ "Hello, zwasm!" — a real component runs via zwasm.
    const result = try ci.invokeString("greet", "cabi_post_greet", "zwasm", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, zwasm!", result);

    // A second call (fresh allocations through the guest) still works.
    const result2 = try ci.invokeString("greet", "cabi_post_greet", "世界", testing.allocator);
    defer testing.allocator.free(result2);
    try testing.expectEqualStrings("Hello, 世界!", result2);
}

test "C2-2 (D-304): resolve the component export → core funcs (no hard-coded names)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    // The resolver maps the component func type + canon-lift to the core exports.
    const r = ci.info.resolveLiftedFunc("greet").?;
    try testing.expectEqualStrings("greet", r.core_func.name);
    try testing.expectEqualStrings("cabi_realloc", r.realloc.?.name);
    try testing.expectEqualStrings("cabi_post_greet", r.post_return.?.name);
    try testing.expectEqual(ctypes.StringEncoding.utf8, r.string_encoding);

    // Invoke BY THE COMPONENT EXPORT NAME — the host resolves the core funcs.
    const result = try ci.invokeStringExport("greet", "zwasm", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, zwasm!", result);
}

/// A `$M`-shaped core module (the print core of `wasi_p2_hello.wat`): imports
/// `io.{get-stdout,write,drop-os}` + owns a 1-page memory with `"hello\n"` at
/// offset 16, and exports `run` which calls get-stdout, writes 6 bytes via
/// write(self, 16, 6, 128), drops the stream, returns 0. (In the real fixture
/// memory is imported from `$libc`; here it is module-owned to isolate the
/// trampoline wiring from the cross-instance-memory wiring — that is the next
/// chunk.) Assembled via wasm-tools (name section stripped).
const p2_print_core = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00, 0x60, 0x01,
    0x7f, 0x00, 0x02, 0x29, 0x03, 0x02, 0x69, 0x6f, 0x0a, 0x67, 0x65, 0x74,
    0x2d, 0x73, 0x74, 0x64, 0x6f, 0x75, 0x74, 0x00, 0x00, 0x02, 0x69, 0x6f,
    0x05, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x01, 0x02, 0x69, 0x6f, 0x07,
    0x64, 0x72, 0x6f, 0x70, 0x2d, 0x6f, 0x73, 0x00, 0x02, 0x03, 0x02, 0x01,
    0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x10, 0x02, 0x06, 0x6d, 0x65,
    0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x03,
    0x0a, 0x1b, 0x01, 0x19, 0x01, 0x01, 0x7f, 0x10, 0x00, 0x21, 0x00, 0x20,
    0x00, 0x41, 0x10, 0x41, 0x06, 0x41, 0x80, 0x01, 0x10, 0x01, 0x20, 0x00,
    0x10, 0x02, 0x41, 0x00, 0x0b, 0x0b, 0x0c, 0x01, 0x00, 0x41, 0x10, 0x0b,
    0x06, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a,
};

test "D1-2 trampolines: WASI-P2 output-stream funcs print to a captured fd" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&p2_print_core);
    defer mod.deinit();

    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    // Bind the trampolines directly by name — this test exercises the trampoline
    // logic in isolation (no component decode → no classifier path).
    try lk.defineFuncCtx("io", "get-stdout", &ctx, fn (*Caller) WasiP2Error!u32, p2GetStdout);
    try lk.defineFuncCtx("io", "write", &ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2OutStreamWrite);
    try lk.defineFuncCtx("io", "drop-os", &ctx, fn (*Caller, u32) WasiP2Error!void, p2OutStreamDrop);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();

    var results = [_]Value{.{ .i32 = 1 }};
    try inst.invoke("run", &.{}, &results);
    try testing.expectEqual(@as(i32, 0), results[0].i32); // run returns ok (0)
    try testing.expectEqualStrings("hello\n", capture.items); // trampoline wrote via fd 1
}

test "D1-2 (EXIT): a real WASI-P2 hello-world component runs + prints via the adapter" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();

    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // greet/adder proved component invoke; this proves a real P2 CLI program
    // runs through the canon-lowered wasi imports → the P2 trampolines.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "D2: a WASI-P2 component prints to STDERR via get-stderr (fd 2 stream)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_stderr.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var cap_err: std.ArrayList(u8) = .empty;
    defer cap_err.deinit(testing.allocator);
    var cap_out: std.ArrayList(u8) = .empty;
    defer cap_out.deinit(testing.allocator);
    host.stderr_buffer = &cap_err;
    host.stdout_buffer = &cap_out;

    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("oops\n", cap_err.items); // wrote to fd 2
    try testing.expectEqualStrings("", cap_out.items); // NOT stdout
}

test "D3: a WASI-P2 component calls wasi:cli/exit(err) → host exit code 1" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_exit.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // The component's `run` calls wasi:cli/exit.exit(err) — the cli_exit trampoline
    // records the code via P1 proc_exit and unwinds (noreturn); runWasiP2Main treats
    // a set exit_code as a clean termination.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 1), host.exit_code.?);
}

test "D-308: a WASI-P2 component importing an unknown wasi interface errors cleanly (no signal)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_unknown_import.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // wasi:sockets/tcp is not in the adapter classify table; building the host
    // synthetic instance must raise a CLEAN error — never a fatal signal from
    // the deferred instance/linker/module cleanup (the D-308 partial-state path,
    // forced here by a guest core instance built before the failing host one).
    try testing.expectError(error.UnsupportedWasiImport, runWasiP2Main(&eng, testing.allocator, bytes, &host, .{}));
}

test "D3: a WASI-P2 component reads monotonic-clock.now() — sane + monotonic → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_clock.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() reads now() twice; exit(0) iff first>0 and second>=first (the
    // clocks_monotonic_now trampoline forwards to the host monotonic clock).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component reads wall-clock.now() — realtime past 2017 → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_wallclock.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() reads wall-clock.now() into a 12-byte datetime record at retptr and
    // exit(0) iff seconds>1.5e9 (the clocks_wall_now trampoline writes seconds@0,
    // nanoseconds@8 to guest memory; realtime clock id 0).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "official 0.3.0: a component reads system-clock.now() + both get-resolution — sane → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p3_systemclock.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() reads system-clock.now() (official WASI 0.3.0: the renamed
    // wall-clock, instant{seconds: s64, nanoseconds: u32} at retptr) and both
    // clocks' get-resolution(); exit(0) iff seconds>1.5e9 and 0 < res <= 1s.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component calls random.get-random-bytes(16) — list realloc → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_random.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() calls get-random-bytes(16) — the trampoline allocates 16 bytes via the
    // guest cabi_realloc, fills with secure random, returns (ptr,len); run ORs the
    // bytes and exit(0) iff len==16 and some byte is nonzero.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "WASI random: a component calls insecure.get-insecure-random-bytes(16) — import resolves → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_insecure_random.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // `wasi:random/insecure` over-satisfied by the secure fill (same handler);
    // a clean exit(0) proves the insecure import resolves + marshals end-to-end.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "WASI random: a component calls insecure-seed() → tuple<u64,u64> at retptr → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_insecure_seed.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // insecure-seed flattens past MAX_FLAT_RESULTS=1 → the two u64 land at retptr;
    // exit(0) iff some bit is set proves the tuple marshalled end-to-end.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component reads stdin via get-stdin+input-stream.read — echo check → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_stdin.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.stdin_bytes = "zwasm";

    // run() mints an input-stream (get-stdin), read(16) returns ok(list) with the
    // 5 fed bytes via cabi_realloc; run checks len==5 + 'z'../'m' → exit 0.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D2 (EXIT): a WASI-P2 fs component writes a file via get-directories+open-at+write e2e" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // Drives get-directories (realloc list area) → open-at "out.txt" → write "DATA42" → drop, all
    // through the classified fs trampolines + the guest's cabi_realloc (nested invoke).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});

    // Read the written file back through the still-open preopen dir.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..7], "out.txt");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, 0, wasi_p1.RIGHTS_FD_READ | wasi_p1.RIGHTS_FD_SEEK, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little);
    std.mem.writeInt(u32, pmem[20..24], 6, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqualStrings("DATA42", pmem[32..38]);
}

test "D3-6: a WASI-P2 fs component drives sync/stat/get-type/read + stdout flush e2e" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_full.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // The guest asserts every descriptor result (sync ok, stat size==6 +
    // regular-file, get-type regular-file, read "DATA42"+eof, flush ok) and
    // traps (unreachable) on any mismatch — a clean return proves all five
    // D3-6 trampolines returned correct data.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
}

test "D-307: a failing descriptor.open-at returns result.err(no-entry), not a trap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_err.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // open-at "nope.txt" without the create flag → P1 noent → the trampoline
    // writes result.err(error-code::no-entry); the guest asserts disc==err +
    // code==20 and traps on mismatch, so a clean return proves the D-307 map.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
}

test "D3-7: a WASI-P2 component drives wasi:io/poll (subscribe + poll + ready/block)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_poll.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.stdin_bytes = "x";

    // subscribe-duration + input-stream.subscribe mint pollables; poll([p1,p2])
    // reports both ready (indices 0,1); ready()==true, block()==noop. The guest
    // asserts each + traps on mismatch — a clean return proves the poll path.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
}

test "E2: WASI-P2 cli/environment + terminal + check-write (sandboxed non-tty host)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_cli_env.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // get-environment/get-arguments empty, initial-cwd + get-terminal-stdout none,
    // check-write reports a permit. The guest asserts each + traps on mismatch.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
}

test "E2 (bundle exit): a real Rust wasm32-wasip2 component runs + prints via zwasm" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_hello_rust.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // A real `rustc --target wasm32-wasip2` component (full wasi:cli world,
    // wit-bindgen shim/fixup-table indirection) runs end-to-end through the
    // general instance-graph engine (ADR-0175) + the D-310 host-funcs-in-tables
    // fix — THE Phase E2 "CM actually works, real toolchain" existence proof.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("hello from a real rust wasip2 component\n", capture.items);
}

test "D2: WASI-P2 get-directories returns a preopen descriptor list (realloc from trampoline)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/get_directories_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "get-directories", &ctx, fn (*Caller, u32) WasiP2Error!void, p2GetDirectories);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.realloc_instance = &inst; // allocate the return area via the guest's cabi_realloc (nested invoke)

    var res = [_]Value{.{ .i32 = 0 }};
    try inst.invoke("run", &.{}, &res);
    try testing.expectEqual(@as(i32, 1008), res[0].i32); // list_len=1 ×1000 + str_len=8

    // The minted descriptor handle (tuple[0]) resolves to the preopen dir fd; the path string round-trips.
    const mem = inst.memory().?;
    const list_ptr = try mem.read(u32, 16);
    const handle = try mem.read(u32, list_ptr);
    const str_ptr = try mem.read(u32, list_ptr + 4);
    try testing.expectEqual(dirfd, @as(wasi_p1.Fd, @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, handle))));
    try testing.expectEqualStrings("/sandbox", try mem.sliceAt(str_ptr, 8));
}

test "D2: WASI-P2 descriptor.open-at creates+writes a file under a dir descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/open_at_write_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    const dir_handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, dirfd);

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "open-at", &ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorOpenAt);
    try lk.defineFuncCtx("fs", "write", &ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite);
    try lk.defineFuncCtx("fs", "drop", &ctx, fn (*Caller, u32) WasiP2Error!void, p2DescriptorDrop);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    var res = [_]Value{.{ .i32 = 9 }};
    try inst.invoke("run", &.{.{ .i32 = @bitCast(dir_handle) }}, &res);
    try testing.expectEqual(@as(i32, 0), res[0].i32); // open-at ok

    // Re-open "f.txt" (the file descriptor was dropped) and read it back.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..5], "f.txt");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 5, 0, wasi_p1.RIGHTS_FD_READ | wasi_p1.RIGHTS_FD_SEEK, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little);
    std.mem.writeInt(u32, pmem[20..24], 6, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqualStrings("DATA42", pmem[32..38]);
}

test "D2: WASI-P2 descriptor.write writes a file via the descriptor resource (fd from handle)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // Create "out.txt" in the preopen + mint a descriptor resource bound to its fd.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..8], "out.txt\x00");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, wasi_p1.OFLAGS_CREAT, wasi_p1.RIGHTS_FD_WRITE | wasi_p1.RIGHTS_FD_READ, 0, 0, 96));
    const wfd = std.mem.readInt(u32, pmem[96..100], .little);

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, wfd);

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/descriptor_write_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "write", &ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite);
    try lk.defineFuncCtx("fs", "drop", &ctx, fn (*Caller, u32) WasiP2Error!void, p2DescriptorDrop);

    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    var noret = [_]Value{};
    try inst.invoke("run", &.{.{ .i32 = @bitCast(handle) }}, &noret); // write + drop

    // Re-open the file (the descriptor was dropped → its fd closed) and read it back.
    @memset(pmem[0..128], 0);
    @memcpy(pmem[0..8], "out.txt\x00");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, 0, wasi_p1.RIGHTS_FD_READ | wasi_p1.RIGHTS_FD_SEEK, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little); // iovec: buf=32, len=8
    std.mem.writeInt(u32, pmem[20..24], 8, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, pmem[64..68], .little));
    try testing.expectEqualStrings("HELLO-FS", pmem[32..40]);
}

test "D-306 (EXIT): a component with renamed core imports runs via classified wiring" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Core imports are opaque p0/p1/p2 (NOT get-stdout/write/drop-os); only the
    // COMPONENT interfaces match. Printing "hello" proves the host selected each
    // trampoline by interface, not by the core import name.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_hello_renamed.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "D2/D-306: a lowered func resolves back to its WASI component interface + func" {
    const io = testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var decoded = try decode.decode(testing.allocator, bytes);
    defer decoded.deinit(testing.allocator);
    var info = try ctypes.decodeTypeInfo(testing.allocator, &decoded);
    defer info.deinit();

    // canon lower[0] lowers component func 0 (a func alias of imported instance
    // `wasi:cli/stdout`'s `get-stdout` export); the @version suffix is stripped
    // so it matches the WASI adapter's interface table.
    const r0 = info.resolveComponentImport(0).?;
    try testing.expectEqualStrings("wasi:cli/stdout", r0.interface);
    try testing.expectEqualStrings("get-stdout", r0.func);
    // lower[1] → component func 1 → `wasi:io/streams` blocking-write-and-flush.
    const r1 = info.resolveComponentImport(1).?;
    try testing.expectEqualStrings("wasi:io/streams", r1.interface);
    try testing.expectEqualStrings("[method]output-stream.blocking-write-and-flush", r1.func);
    // A locally-defined / non-import func index does not resolve to an interface.
    try testing.expectEqual(@as(?ctypes.TypeInfo.ImportRef, null), info.resolveComponentImport(99));
}

test "IT-1: a core module (not a component) is rejected as NotAComponent" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    try testing.expectError(decode.Error.NotAComponent, instantiate(&eng, testing.allocator, &core_run42, .{}));
}

test "E2: a real tinygo wasm32-wasip2 component runs end-to-end (Go cross-toolchain proof)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_hello_go.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // A real `tinygo build -target=wasip2` component (full wasi:cli world +
    // filesystem/random interfaces, wit-component start-shim calling
    // `_initialize` as an IMPORTED start function) runs end-to-end — the
    // SECOND Phase E2 cross-toolchain existence proof beside Rust.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "E2: the tinygo fs component round-trips mkdir/write/stat/rename/readdir/remove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_go.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/work");
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // Exercises the path-addressed descriptor trampolines end-to-end through
    // Go's os package: create-directory-at, open-at (create + POSIX-style
    // directory open without OFLAGS_DIRECTORY), descriptor.write, stat-at,
    // rename-at, read-directory + directory-entry-stream, unlink-file-at,
    // remove-directory-at. The guest asserts each step and prints the
    // renamed entry it saw in the directory stream.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("FS-OK b.txt\n", capture.items);
}

test "E3: the tinygo fs error-path component sees exist/no-entry/empty-stream correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_err_go.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/work");
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // Boundary fixtures for the path-trampoline ERROR arms (D-307 errno →
    // P2 error-code ordinals): duplicate mkdir → exist; stat/remove/rename
    // on a missing path → no-entry; ReadDir on an empty dir → stream end
    // (option none) on the first read-directory-entry. Guest asserts each
    // via Go's os error predicates and prints ERR-OK.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("ERR-OK\n", capture.items);
}

/// One-shot echo server for the TCP e2e: accept one connection, read up to
/// 16 bytes, reply with "pong-<data>", close.
fn tcpEchoServerOnce(io: std.Io, server: *std.Io.net.Server) void {
    var conn = server.accept(io) catch return;
    defer conn.close(io);
    var buf: [16]u8 = undefined;
    var bufs = [_][]u8{&buf};
    const n = io.vtable.netRead(io.userdata, conn.socket.handle, &bufs) catch return;
    var reply_buf: [32]u8 = undefined;
    const reply = std.fmt.bufPrint(&reply_buf, "pong-{s}", .{buf[0..n]}) catch return;
    const data = [_][]const u8{reply};
    _ = io.vtable.netWrite(io.userdata, conn.socket.handle, "", &data, 1) catch return;
}

test "ADR-0180: a real rust wasip2 TCP client connects + echoes through wasi:sockets" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_tcp_rust.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    // Host-side loopback echo server on an ephemeral port, served
    // concurrently while the guest runs.
    const listen_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try listen_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{server.socket.address.getPort()});
    var server_fut = try io.concurrent(tcpEchoServerOnce, .{ io, &server });
    defer server_fut.cancel(io);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    try host.setArgs(&.{ "tcp_echo", port_str });
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // A real `rustc --target wasm32-wasip2` std::net::TcpStream client:
    // create-tcp-socket -> start/finish-connect (socket-backed stream pair)
    // -> write "ping" -> subscribe/poll readiness -> read the reply — the
    // ADR-0180 Phase-1 existence proof.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("got pong-ping\n", capture.items);
}

/// Host-side client for the listener e2e: retry-connect to the guest's
/// port until its listen completes, send "ping", read the echo.
fn tcpClientOnce(io: std.Io, port: u16) void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var attempts: u32 = 0;
    var stream = while (attempts < 500) : (attempts += 1) {
        if (addr.connect(io, .{ .mode = .stream, .protocol = .tcp })) |s| break s else |_| {
            // Guest hasn't reached listen yet — back off and retry.
            io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch return;
        }
    } else return;
    defer stream.close(io);
    const data = [_][]const u8{"ping"};
    _ = io.vtable.netWrite(io.userdata, stream.socket.handle, "", &data, 1) catch return;
    // Read until the guest's full "ping-ack" reply arrived (2 writes).
    var buf: [16]u8 = undefined;
    var total: usize = 0;
    while (total < 8) {
        var bufs = [_][]u8{buf[total..]};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, &bufs) catch return;
        if (n == 0) return;
        total += n;
    }
}

test "ADR-0180 Phase 2: a real rust wasip2 TCP listener accepts + echoes through wasi:sockets" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_listen_rust.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    // Pick a free loopback port for the guest (bind :0, note, release —
    // the test-local reuse window is accepted).
    const probe_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var probe = try probe_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    const port = probe.socket.address.getPort();
    probe.deinit(io);
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    var client_fut = try io.concurrent(tcpClientOnce, .{ io, port });
    defer client_fut.cancel(io);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    try host.setArgs(&.{ "tcp_listen", port_str });
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // A real `rustc --target wasm32-wasip2` std::net::TcpListener guest:
    // bind(argv port) -> start/finish-listen -> local-address ->
    // subscribe/poll readiness -> accept (3-tuple mint + remote-address)
    // -> echo "ping"+"-ack" — the ADR-0180 Phase-2 existence proof.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host, .{});
    var expect_buf: [48]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "served ping on {d}\n", .{port});
    try testing.expectEqualStrings(expected, capture.items);
}

test "D-322: a wit-bindgen guest-defined resource component builds + counter round-trips via the synthesized builtins" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/resource_counter.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    // The core module imports its OWN exported resource's builtins
    // ([export]<iface> [resource-new/drop]counter) — the build must
    // synthesize them over the guest resource table (was: UnknownImport).
    var built = try cwasi.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();

    // Drive the generated core exports directly: constructor mints an own
    // handle through [resource-new]; get/increment read it back via rep.
    // (The main module is not necessarily the LAST instance — wit-bindgen
    // graphs append shim/fixup instances — so find it by export.)
    const ctor = "zwasm:restest/counter-api#[constructor]counter";
    const main_inst = blk: {
        for (built.instances.items) |gi| {
            for (gi.handle.exports_storage) |exp| {
                if (exp.kind == .func and std.mem.eql(u8, exp.name, ctor)) break :blk gi;
            }
        }
        return error.TestUnexpectedResult;
    };
    var hres = [_]Value{.{ .i32 = 0 }};
    try main_inst.invoke(ctor, &.{.{ .i32 = 5 }}, &hres);
    const handle: u32 = @bitCast(hres[0].i32);
    try testing.expect(handle >= 1);

    // Core method exports take the REP (canon lift translates handle->rep
    // before entering the guest); emulate the lift via the guest table.
    const ti: u32 = blk: {
        for (built.info.type_space.items, 0..) |entry, i| switch (entry) {
            .def => |d| if (built.info.deftypes.items[d] == .resource) break :blk @intCast(i),
            .named => {},
        };
        return error.TestUnexpectedResult;
    };
    const rep: i32 = @bitCast(try built.ctx.guest_resources.rep(ti, handle));

    var vres = [_]Value{.{ .i32 = 0 }};
    try main_inst.invoke("zwasm:restest/counter-api#[method]counter.get", &.{.{ .i32 = rep }}, &vres);
    try testing.expectEqual(@as(i32, 5), vres[0].i32);
    try main_inst.invoke("zwasm:restest/counter-api#[method]counter.increment", &.{.{ .i32 = rep }}, &vres);
    try testing.expectEqual(@as(i32, 6), vres[0].i32);
    try main_inst.invoke("zwasm:restest/counter-api#[method]counter.get", &.{.{ .i32 = rep }}, &vres);
    try testing.expectEqual(@as(i32, 6), vres[0].i32);

    // TYPED path (D-322 slice b): instance-path export resolution +
    // own-result lift + borrow-param lower through the table hook.
    const h = (try invokeTypedBuilt(&built, "zwasm:restest/counter-api#[constructor]counter", &.{.{ .u32 = 40 }}, testing.allocator)).?;
    try testing.expect(h == .own);
    const g1 = (try invokeTypedBuilt(&built, "zwasm:restest/counter-api#[method]counter.get", &.{.{ .borrow = h.own }}, testing.allocator)).?;
    try testing.expectEqual(@as(u32, 40), g1.u32);
    const g2 = (try invokeTypedBuilt(&built, "zwasm:restest/counter-api#[method]counter.increment", &.{.{ .borrow = h.own }}, testing.allocator)).?;
    try testing.expectEqual(@as(u32, 41), g2.u32);
    // an unknown borrow handle is a typed shape error, not a crash
    try testing.expectError(
        error.ValueTypeMismatch,
        invokeTypedBuilt(&built, "zwasm:restest/counter-api#[method]counter.get", &.{.{ .borrow = 999 }}, testing.allocator),
    );
}

test "REQ-5 (cw CM-API): host drops a guest resource handle (runs destructor); double-drop traps" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/resource_counter.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // resource_counter has guest resources → open routes to the graph path.
    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();
    try testing.expect(opened == .wasi);

    // Construct a counter → an OWN handle the host now owns.
    const ctor = "zwasm:restest/counter-api#[constructor]counter";
    const h = (try opened.invokeTyped(ctor, &.{.{ .u32 = 7 }}, testing.allocator)).?;
    try testing.expect(h == .own);

    // Host-facing drop removes the handle AND runs the guest destructor
    // cleanly — the destructor (module 0's `[dtor]counter`) is reached via the
    // wit-bindgen shim's cross-instance `call_indirect` and now executes in its
    // OWN runtime context (D-325 fix).
    try opened.dropResource(h.own);
    // A second drop of the same handle is a use-after-drop trap.
    try testing.expectError(component.DropResourceError.InvalidHandle, opened.dropResource(h.own));
}

test "REQ-5 (cw CM-API): dropResource on a single-module component is a misuse error" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    var opened = try open(&eng, testing.allocator, bytes, &host, .{});
    defer opened.deinit();
    try testing.expect(opened == .single);
    try testing.expectError(component.DropResourceError.NoResourceTable, opened.dropResource(1));
}

test "exportedFuncs enumerates interface-nested funcs path-qualified (CWFS component intake)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/resource_counter.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var built = try cwasi.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();

    // The component exports NO top-level funcs — everything lives inside
    // the exported `zwasm:restest/counter-api` instance. Enumeration must
    // surface those, path-qualified exactly as `invokeTyped` accepts them.
    const funcs = try built.info.exportedFuncs(testing.allocator);
    defer ctypes.TypeInfo.freeExportedFuncs(testing.allocator, funcs);

    const expected = [_][]const u8{
        "zwasm:restest/counter-api#[constructor]counter",
        "zwasm:restest/counter-api#[method]counter.get",
        "zwasm:restest/counter-api#[method]counter.increment",
    };
    for (expected) |want| {
        for (funcs) |f| {
            if (std.mem.eql(u8, f.name, want)) break;
        } else return error.TestUnexpectedResult;
    }
    // Signatures came along: the constructor takes one u32 param.
    for (funcs) |f| {
        if (std.mem.eql(u8, f.name, expected[0])) {
            try testing.expectEqual(@as(usize, 1), f.ty.params.len);
            try testing.expectEqual(ctypes.PrimValType.u32, f.ty.params[0].ty.primitive);
        }
    }
}

test "ADR-0183 F1: greet introspects as (param string) -> string from the binary" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    const funcs = try ci.exportedFuncs(testing.allocator);
    defer ctypes.TypeInfo.freeExportedFuncs(testing.allocator, funcs);
    try testing.expectEqual(@as(usize, 1), funcs.len);
    try testing.expectEqualStrings("greet", funcs[0].name);
    try testing.expectEqual(@as(usize, 1), funcs[0].ty.params.len);
    try testing.expectEqual(ctypes.PrimValType.string, funcs[0].ty.params[0].ty.primitive);
    try testing.expectEqual(ctypes.PrimValType.string, funcs[0].ty.result.?.primitive);
}

test "REQ-3 (cw CM-API): resolveFuncSig — greet resolves to (string) -> string WitType" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = (try ci.resolveFuncSig(arena.allocator(), "greet")).?;
    try testing.expectEqual(@as(usize, 1), sig.params.len);
    try testing.expect(sig.params[0].name.len > 0); // a borrowed WIT param name
    try testing.expectEqual(WitType{ .prim = .string }, sig.params[0].ty);
    try testing.expectEqual(WitType{ .prim = .string }, sig.result.?);
    // A non-resolving name returns null, not an error.
    try testing.expect((try ci.resolveFuncSig(arena.allocator(), "nope")) == null);
}

test "REQ-3 (cw CM-API): resolveFuncSig — rich types keep specialization + carry labels" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/typed_payload.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    // typed_payload imports wasi, so it goes through the WASI-P2 graph path.
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var built = try cwasi.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();

    const funcs = try built.info.exportedFuncs(testing.allocator);
    defer ctypes.TypeInfo.freeExportedFuncs(testing.allocator, funcs);
    try testing.expect(funcs.len >= 1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = (try built.resolveFuncSig(arena.allocator(), funcs[0].name)).?;
    // param 0 is a record{ xs: list<u32>, label: string } — record stays a
    // record (NOT despecialized), field names + list element resolved.
    try testing.expectEqual(@as(usize, 1), sig.params.len);
    const rec = sig.params[0].ty.record;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("xs", rec[0].name);
    try testing.expectEqual(WitType{ .prim = .u32 }, rec[0].ty.list.*);
    try testing.expectEqualStrings("label", rec[1].name);
    try testing.expectEqual(WitType{ .prim = .string }, rec[1].ty);
    // result stays a `result<…>` (specialization preserved, not a variant).
    try testing.expect(sig.result.? == .result);
}

test "ADR-0183 F2b: greet invoked TYPED — string arg in, owned string result out" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    const out = (try ci.invokeTyped("greet", &.{.{ .string = "zwasm" }}, testing.allocator)).?;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello, zwasm!", out.string);

    // Shape validation: wrong arm + wrong arity reject before any call.
    try testing.expectError(InvokeTypedError.ValueShapeMismatch, ci.invokeTyped("greet", &.{.{ .u32 = 1 }}, testing.allocator));
    try testing.expectError(InvokeTypedError.ArgArityMismatch, ci.invokeTyped("greet", &.{}, testing.allocator));
}

test "REQ-6 (cw CM-API): typed-invoke failures set a user-facing diagnostic" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/greet_component.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes, .{});
    defer ci.deinit();

    // Unresolved export → the diagnostic names the export.
    diagnostic.clearDiag();
    try testing.expectError(InvokeTypedError.ExportNotResolved, ci.invokeTyped("nope", &.{}, testing.allocator));
    {
        const d = diagnostic.lastDiagnostic().?;
        try testing.expect(std.mem.find(u8, d.message(), "nope") != null);
    }

    // Arity mismatch → the diagnostic names the expected/got counts.
    diagnostic.clearDiag();
    try testing.expectError(InvokeTypedError.ArgArityMismatch, ci.invokeTyped("greet", &.{}, testing.allocator));
    {
        const d = diagnostic.lastDiagnostic().?;
        try testing.expect(std.mem.find(u8, d.message(), "expected 1") != null);
    }

    // Per-arg shape mismatch → the diagnostic blames arg 0 + the type.
    diagnostic.clearDiag();
    try testing.expectError(InvokeTypedError.ValueShapeMismatch, ci.invokeTyped("greet", &.{.{ .u32 = 1 }}, testing.allocator));
    {
        const d = diagnostic.lastDiagnostic().?;
        try testing.expect(std.mem.find(u8, d.message(), "arg 0") != null);
    }
}

test "ADR-0183 F3/F4: wit-bindgen rich types round-trip TYPED — record{list<u32>, string} <-> result" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/typed_payload.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    var built = try cwasi.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();

    // ok path: process({xs: [1,2,3], label: "sum"}) appends sum(xs)=6 and "!".
    const xs = [_]ComponentValue{ .{ .u32 = 1 }, .{ .u32 = 2 }, .{ .u32 = 3 } };
    const in_fields = [_]ComponentValue.Field{
        .{ .name = "xs", .value = .{ .list = @constCast(&xs) } },
        .{ .name = "label", .value = .{ .string = "sum" } },
    };
    const out = (try invokeTypedBuilt(&built, "process", &.{.{ .record = @constCast(&in_fields) }}, testing.allocator)).?;
    defer out.deinit(testing.allocator);
    try testing.expect(out.result.is_ok);
    const payload = out.result.payload.?.*;
    try testing.expectEqualStrings("xs", payload.record[0].name);
    const out_xs = payload.record[0].value.list;
    try testing.expectEqual(@as(usize, 4), out_xs.len);
    try testing.expectEqual(@as(u32, 6), out_xs[3].u32);
    try testing.expectEqualStrings("sum!", payload.record[1].value.string);

    // err path: label "fail" -> result err "boom: fail".
    const fail_fields = [_]ComponentValue.Field{
        .{ .name = "xs", .value = .{ .list = @constCast(xs[0..0]) } },
        .{ .name = "label", .value = .{ .string = "fail" } },
    };
    const err_out = (try invokeTypedBuilt(&built, "process", &.{.{ .record = @constCast(&fail_fields) }}, testing.allocator)).?;
    defer err_out.deinit(testing.allocator);
    try testing.expect(!err_out.result.is_ok);
    try testing.expectEqualStrings("boom: fail", err_out.result.payload.?.string);
}

test "D-527: a component with two exports validates (the func index space counts exports)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/two_export.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);

    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The regression: validation returned InvalidSort for ANY component with
    // two or more exports, because a component-level func `export` adds an
    // entry to the func index space and `component_funcs` did not count it —
    // so from the second export onward each lift's sortidx read out of bounds.
    try cvalidate.validate(&info);

    // Two func exports, and the space now interleaves lift / export / lift /
    // export, so it holds four entries rather than two.
    var func_exports: usize = 0;
    for (info.exports.items) |ex| {
        if (std.meta.activeTag(ex.sort) == .func) func_exports += 1;
    }
    try testing.expectEqual(@as(usize, 2), func_exports);
    try testing.expectEqual(@as(usize, 4), info.component_funcs.items.len);

    // Every func export's sortidx is in bounds and resolves to a real lift —
    // the property the bound check was trying to express.
    for (info.exports.items) |ex| {
        if (std.meta.activeTag(ex.sort) != .func) continue;
        try testing.expect(ex.index < info.component_funcs.items.len);
    }
}

test "ADR-0205 A: official wasip3 binary decodes the async-support canon builtins" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3_official/monotonic-clock.wasm", testing.allocator, .limited(8 << 20));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);
    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The wit-bindgen async runtime imports the full builtin set; decode must
    // surface each (previously Error.UnsupportedCanon killed the whole binary).
    var seen = [_]bool{false} ** 6; // task_cancel, subtask_cancel, subtask_drop, ctx_get, ctx_set, ws_poll
    var async_lowers: usize = 0;
    for (info.canons.items) |c| switch (c) {
        .task_cancel => seen[0] = true,
        .subtask_cancel => seen[1] = true,
        .subtask_drop => seen[2] = true,
        .context_get => |cg| {
            seen[3] = true;
            try testing.expectEqual(false, cg.is_i64);
            try testing.expectEqual(@as(u32, 0), cg.slot);
        },
        .context_set => |cs| {
            seen[4] = true;
            try testing.expectEqual(@as(u32, 0), cs.slot);
        },
        .waitable_set => |ws| {
            if (ws.op == .poll) {
                seen[5] = true;
                try testing.expect(ws.memory != null);
            }
        },
        .lower => |l| {
            if (l.opts.is_async) async_lowers += 1;
        },
        else => {},
    };
    for (seen) |s| try testing.expect(s);
    // wait-until + wait-for are the two async-lowered host imports.
    try testing.expectEqual(@as(usize, 2), async_lowers);
}
