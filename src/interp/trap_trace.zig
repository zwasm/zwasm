//! Where a trap happened on the interpreter (ADR-0232 D2).
//!
//! `dispatch.run` appends the frame it owns as an error leaves it, so a trap
//! collects one frame per wasm level, innermost first, across instances. The
//! buffer holds only the failure unwinding now; `enter` keeps it that way.
//!
//! Zone 2 (`src/interp/`).

const runtime = @import("../runtime/runtime.zig");
const dispatch_table = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const dispatch = @import("dispatch.zig");

const Runtime = runtime.Runtime;

/// A frame as `wasm_frame_t` names it, without the instance: an instance can
/// be freed while its `Runtime` lives on as a zombie, so a pointer could dangle.
pub const Frame = extern struct {
    func_idx: u32,
    module_offset: u32,
    func_offset: u32,
};

pub const capacity = 64;

pub const Trace = struct {
    len: u32 = 0,
    frames: [capacity]Frame = undefined,

    pub fn slice(self: *const Trace) []const Frame {
        return self.frames[0..self.len];
    }
};

/// One per thread. The engine is single-threaded (`include/zwasm.h`,
/// "Threads"), so this is one buffer in practice and adds nothing to the
/// process-global state that contract names.
threadlocal var current: Trace = .{};

/// Called from `dispatch.run`'s `errdefer` for the frame that `run` owns.
pub fn record(frame: *const runtime.Frame) void {
    const func = frame.func orelse return;
    // An import's placeholder is not lowered and has no table.
    if (frame.pc >= func.src_offsets.items.len) return;
    if (current.len == capacity) return;
    const off = func.src_offsets.items[frame.pc];
    current.frames[current.len] = .{
        .func_idx = func.func_idx,
        .module_offset = func.func_start + off,
        .func_offset = off,
    };
    current.len += 1;
}

pub const Target = union(enum) {
    body: struct { table: *const dispatch_table.DispatchTable, instrs: []const zir.ZirInstr },
    host: runtime.HostCall,
};

/// Every call that enters the interpreter from outside it goes through here.
/// The call starts with an empty buffer and the caller's contents come back
/// on the way out, so a guest entered from a host function, or from a callback
/// while a trap is unwinding, neither leaks its frames into the outer trace
/// nor erases it. On an error the call's trace is copied into `trace_out`
/// first. The native stack is checked here as `mvp.invoke` checks it for a
/// call inside the interpreter.
///
/// `inline` for the reason `zwasm.Instance.invokeInner` is: an out-of-line
/// wrapper around `dispatch.run` cost the interpreter 10.8–14.6%.
pub inline fn enter(rt: *Runtime, target: Target, trace_out: ?*Trace) anyerror!void {
    try rt.checkNativeStackLimit(@frameAddress());
    const unwinding = current.len != 0;
    var saved: Trace = undefined;
    if (unwinding) saved = current;
    current.len = 0;
    defer {
        if (unwinding) current = saved else current.len = 0;
    }
    const result = switch (target) {
        .body => |b| dispatch.run(rt, b.table, b.instrs),
        .host => |h| h.fn_ptr(rt, h.ctx),
    };
    result catch |err| {
        if (trace_out) |out| {
            out.len = current.len;
            @memcpy(out.frames[0..current.len], current.frames[0..current.len]);
        }
        return err;
    };
}

/// What the running thread's buffer holds, for tests that drive `run` without
/// going through `enter`.
pub fn currentForTest() *Trace {
    return &current;
}
