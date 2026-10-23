// FILE-SIZE-EXEMPT: ADR-0187 handle-table state machine; stream/future/waitable-set ops mutually reference the shared table (N1/N2) (investigated 2026-08-12, per ADR-0099)
//! WASI-0.3 / Component-Model async runtime (campaign D-335 Unit D; ADR-0187).
//!
//! Stackless callback-ABI model on zwasm's synchronous engine — NO fibers. This
//! module is the Zone-1 pure-data core: the per-component stream/future **handle
//! table** (the table Unit C's i32 ABI handles index into), the `CopyState`
//! machine, and the `ReturnCode` packing. The rendezvous copy logic, waitable
//! sets, subtasks, and the callback event loop land in later chunks (β–η per
//! ADR-0187); none of those import the engine — the Zone-3 host drives the loop.
//!
//! The handle-table discipline mirrors `resource_table.zig`: dense array + free
//! list, index 0 reserved as a `None` sentinel (a valid handle is ≥ 1), and
//! `remove` tombstones a slot so a double-drop / use-after-drop traps on the
//! next access.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Spec `Table.MAX_LENGTH` — leaves the high 4 bits of a handle free for guest
/// tagging (shared with the resource handle table).
pub const MAX_LENGTH: u32 = (1 << 28) - 1;

/// Spec `Buffer.MAX_LENGTH` — the most elements one `stream.read`/`write`
/// moves, so a `ReturnCode` count always fits its 28 bits.
pub const BUFFER_MAX_LENGTH: u32 = (1 << 28) - 1;

pub const Error = error{
    /// Handle index out of bounds, the reserved 0 sentinel, or a freed
    /// (tombstoned) slot — covers use-after-drop / double-drop.
    InvalidHandle,
    /// The table reached `MAX_LENGTH`.
    TableFull,
    OutOfMemory,
    /// `drop` of a readable/writable end while a copy is in progress
    /// (spec `CopyEnd.drop` traps unless the state is IDLE/DONE).
    CopyInProgress,
    /// `cancel-read`/`cancel-write` on an end with no async copy in flight.
    NotCopying,
    /// A stackless-async callback returned a reserved code (low nibble > MAX=2).
    InvalidCallbackCode,
    /// `future.drop-writable` on a future whose value was never written and
    /// whose reader has not dropped (spec `WritableFutureEnd.drop` traps —
    /// `CanonicalABI.md` §Future State).
    FutureDropBeforeWrite,
    /// `stream.read`/`write` (+ future) on an end whose copy-state is not IDLE —
    /// a second concurrent copy, or a copy on a DONE end (spec `stream_copy`/
    /// `future_copy` `trap_if(e.state != CopyState.IDLE)`).
    CopyNotIdle,
    /// `stream.read`/`write` of more than `BUFFER_MAX_LENGTH` elements (spec
    /// `GuestBuffer` `trap_if(length > Buffer.MAX_LENGTH)`).
    BufferTooLong,
};

/// Copy-state of a stream/future end (`CanonicalABI.md` §Stream State). The
/// transitions (idle → async_copying → done, + cancelling) are driven by the
/// rendezvous logic in a later chunk; α only needs the enum + the idle default.
pub const CopyState = enum { idle, sync_copying, async_copying, cancelling_copy, done };

/// An async builtin's return value (`CanonicalABI.md`; wasmtime
/// `futures_and_streams.rs`). `Blocked` is the all-ones sentinel; the others
/// pack a 4-bit code in the low bits and an item count in the high 28 bits
/// (count is always 0 for futures — at most one value).
pub const ReturnCode = union(enum) {
    blocked,
    completed: u28,
    dropped: u28,
    cancelled: u28,

    pub fn encode(self: ReturnCode) u32 {
        return switch (self) {
            .blocked => 0xffff_ffff,
            .completed => |n| @as(u32, n) << 4, // code 0
            .dropped => |n| (@as(u32, n) << 4) | 1,
            .cancelled => |n| (@as(u32, n) << 4) | 2,
        };
    }
};

/// The code a stackless-async lifted export (or its `callback`) returns to the
/// host event loop (`CanonicalABI.md` `CallbackCode`): the host either exits,
/// re-enters on a yield, or waits on a waitable set.
pub const CallbackCode = enum(u8) { exit = 0, yield = 1, wait = 2 };

pub const CallbackResult = struct { code: CallbackCode, waitable_set_index: u32 };

/// `unpack_callback_result` — decode the packed i32 the guest returns: low 4
/// bits = `CallbackCode` (a value > MAX=2 traps), high 28 bits = the
/// waitable-set index the host waits on for a WAIT.
pub fn unpackCallbackResult(bits: u32) Error!CallbackResult {
    const code: CallbackCode = switch (bits & 0xf) {
        0 => .exit,
        1 => .yield,
        2 => .wait,
        else => return Error.InvalidCallbackCode,
    };
    return .{ .code = code, .waitable_set_index = bits >> 4 };
}

/// The async event kinds delivered to core wasm (`CanonicalABI.md` `EventCode`).
pub const EventCode = enum(u8) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
};

/// One delivered event `(code, index, payload)` — `index` is the waitable
/// handle, `payload` the encoded `ReturnCode` (or subtask state).
pub const EventTuple = struct {
    code: EventCode,
    index: u32,
    payload: u32,
};

/// ADR-0195 — map an async-lifted export's first packed `CallbackResult` (the
/// `initial` the entry returns) to a fresh task's state: EXIT→done (never
/// entered), YIELD→ready (re-enter with `none`), WAIT→waiting on the named set.
/// The driver is `driveScheduler` (a single-task export is a 1-entry `TaskTable`).
/// `callback_funcidx` is filled in by the caller (the P3 runner sets the export's
/// callback; the graph runner sets each enqueued guest subtask's).
pub fn seedTask(initial: u32) Error!TaskDescriptor {
    const r = try unpackCallbackResult(initial);
    return switch (r.code) {
        .exit => .{ .callback_funcidx = 0, .state = .done },
        .yield => .{ .callback_funcidx = 0, .state = .ready },
        .wait => .{ .callback_funcidx = 0, .state = .waiting, .set_index = r.waitable_set_index },
    };
}

/// ADR-0195 — fold a callback's packed return into the task's next state:
/// EXIT→done, YIELD→ready (re-enter with `none`), WAIT→waiting on the named set.
fn foldResult(task: *TaskDescriptor, result: CallbackResult) void {
    switch (result.code) {
        .exit => task.state = .done,
        .yield => task.state = .ready,
        .wait => {
            task.state = .waiting;
            task.set_index = result.waitable_set_index;
        },
    }
}

/// ADR-0195 step (c) — the cooperative round-robin scheduler over a `TaskTable`.
/// Each pass: step every `ready` task once (deliver `none`), and for every
/// `waiting` task poll its set and, if an event is pending, deliver it. Terminate
/// when all tasks are `done`. Trap `AsyncDeadlock` when a whole pass makes NO
/// progress — no task was `ready` and no `waiting` task's poll yielded an event
/// (generalises the single-task `waitOn`-empty deadlock to N tasks) — UNLESS a
/// host timer is still armed (ADR-0205 D2): then the ctx parks until the
/// nearest deadline and the pass retries. The ctx seam is the *non-blocking*
/// multi-task triple (a task must never block the others), distinct from the
/// single-task blocking `waitOn`:
///   - `invokeTaskCallback(funcidx, event_code, p1, p2) Error!u32` — re-enter the
///     task whose stackless callback is `funcidx`;
///   - `pollSet(set_index) Error!?EventTuple` — non-blocking poll (null = none);
///   - `waitForTimer() Error!bool` — no event was deliverable: if a host timer
///     is armed, sleep until the nearest deadline + fire it (true = retry the
///     pass); false = nothing will ever wake us (deadlock).
pub fn driveScheduler(ctx: anytype, table: *TaskTable) !void {
    while (true) {
        var any_live = false; // a non-done task remains
        var progressed = false; // at least one task stepped this pass
        for (table.slots.items, 0..) |slot, i| {
            if (slot == null) continue;
            const task = &table.slots.items[i].?;
            switch (task.state) {
                .done => {},
                .ready => {
                    any_live = true;
                    progressed = true;
                    const next = try ctx.invokeTaskCallback(task.callback_funcidx, @intFromEnum(EventCode.none), 0, 0);
                    foldResult(task, try unpackCallbackResult(next));
                },
                .waiting => {
                    any_live = true;
                    if (try ctx.pollSet(task.set_index)) |ev| {
                        progressed = true;
                        if (@import("../../support/dbg.zig").on("async.sched")) std.debug.print("[sched] deliver code={s} idx={d} payload=0x{x} to task {d}\n", .{ @tagName(ev.code), ev.index, ev.payload, i });
                        const next = try ctx.invokeTaskCallback(task.callback_funcidx, @intFromEnum(ev.code), ev.index, ev.payload);
                        if (@import("../../support/dbg.zig").on("async.sched")) std.debug.print("[sched] callback -> 0x{x}\n", .{next});
                        foldResult(task, try unpackCallbackResult(next));
                    }
                },
            }
        }
        if (!any_live) return; // all tasks done
        if (!progressed) {
            if (try ctx.waitForTimer()) continue; // a timer fired — retry the pass
            return error.AsyncDeadlock; // all waiting, no events deliverable, no timer armed
        }
    }
}

pub const EndKind = enum { stream, future, subtask };
pub const EndSide = enum { readable, writable };

/// One waitable in the handle table: a stream/future **end**, or (ADR-0205
/// phase A) a `Subtask` minted by an async-lowered host import that blocked.
/// The spec keeps ALL waitables (stream/future ends, subtasks, sets) in one
/// per-instance handle table; subtasks share this table so `waitable.join` /
/// `waitable-set.poll` resolve them uniformly. `elem_type` is the element
/// (stream) / value (future) WIT type index, or null for a payload-less
/// `stream`/`future` (always null for a subtask). The shared rendezvous buffer
/// joining the two ends lands in chunk β.
pub const StreamFutureEnd = struct {
    kind: EndKind,
    side: EndSide,
    elem_type: ?u32,
    state: CopyState = .idle,
    /// `kind == .subtask` only: the `Subtask.State` lifecycle of the blocked
    /// async-lowered host call this waitable represents.
    subtask_state: SubtaskState = .starting,
    /// `kind == .subtask` only: a host TIMER deadline (monotonic ns) — the
    /// waitable resolves (RETURNED) when the host clock passes it. Cleared on
    /// fire. Null for non-timer subtasks (resolved by their own host wiring).
    deadline_ns: ?u64 = null,
    /// spec `Waitable.pending_event` — at most one event awaits delivery. Stored
    /// as the value directly (the spec's optimized non-closure form).
    pending_event: ?EventTuple = null,
    /// the waitable-set handle this end belongs to, if any (`Waitable.wset`).
    wset: ?u32 = null,
    /// Handle into the per-task `SharedTable` of the rendezvous this end's peer
    /// shares (`stream.new`/`future.new` mint a readable+writable pair over one
    /// shared, ADR-0189 ζ2). 0 = unlinked (a bare end built directly in a test
    /// / before the arena existed); a minted end always has a ≥1 handle.
    shared: u32 = 0,

    /// `Waitable.set_pending_event`.
    pub fn setPendingEvent(self: *StreamFutureEnd, ev: EventTuple) void {
        self.pending_event = ev;
    }

    /// `Waitable.has_pending_event`.
    pub fn hasPendingEvent(self: StreamFutureEnd) bool {
        return self.pending_event != null;
    }

    /// `Waitable.get_pending_event` — delivers + clears the single event.
    pub fn takePendingEvent(self: *StreamFutureEnd) ?EventTuple {
        defer self.pending_event = null;
        return self.pending_event;
    }

    /// spec `CopyEnd.copying` — true while a copy is in flight or cancelling
    /// (the states a `drop` must not interrupt).
    pub fn copying(self: StreamFutureEnd) bool {
        return switch (self.state) {
            .idle, .done => false,
            .sync_copying, .async_copying, .cancelling_copy => true,
        };
    }

    /// Initiate a read (readable end) / write (writable end) through `shared`
    /// and fold the rendezvous result into this end's `CopyState`: a blocked
    /// op parks the end in `async_copying`, a synchronous rendezvous returns to
    /// `idle`, and a dropped peer is `done`. A within-call (synchronous)
    /// completion never lingers in `sync_copying`, so there is nothing to cancel
    /// for it — cancel only targets `async_copying`. When the rendezvous resolves
    /// the previously-pending peer, its `pending_event` is delivered here (the
    /// peer's blocked copy completes and returns to `idle`). `handle` is this
    /// end's own table handle.
    pub fn copy(self: *StreamFutureEnd, shared: anytype, table: *StreamFutureTable, handle: u32, n: u32) Error!Step {
        // Spec `stream_copy`/`future_copy`: a copy is only valid on an IDLE end —
        // a second concurrent copy, or a copy on a DONE end (peer dropped), traps.
        if (self.state != .idle) return Error.CopyNotIdle;
        const step = switch (self.side) {
            .readable => shared.read(n, handle),
            .writable => shared.write(n, handle),
        };
        self.state = switch (step.caller) {
            .blocked => .async_copying,
            .completed => .idle,
            .dropped => .done,
        };
        if (step.notify) |nt| {
            const peer = try table.get(nt.waitable);
            peer.setPendingEvent(.{ .code = nt.code, .index = nt.waitable, .payload = nt.payload });
            peer.state = .idle; // the peer's blocked copy has resolved
        }
        return step;
    }

    /// `stream.cancel-{read,write}` — cancel this end's in-flight async copy,
    /// clearing its pending slot in `shared`. Returns items copied so far (0 in
    /// the rendezvous-count model — partial-copy progress lands with the host
    /// buffer wiring). Errors if no async copy is in flight.
    pub fn cancel(self: *StreamFutureEnd, shared: anytype) Error!u32 {
        if (self.state != .async_copying) return Error.NotCopying;
        self.state = .cancelling_copy;
        if (shared.pending) |p| {
            if (p.side == self.side) shared.pending = null;
        }
        self.state = .idle;
        return 0;
    }

    /// `drop` a readable/writable end — traps (errors) if a copy is in
    /// progress; otherwise marks the shared stream dropped so the peer's next
    /// read/write observes `DROPPED`.
    pub fn drop(self: *StreamFutureEnd, shared: anytype) Error!void {
        if (self.copying()) return Error.CopyInProgress;
        shared.dropped = true;
    }
};

/// The per-component stream/future handle table (ADR-0187). Index 0 is the
/// reserved `None` sentinel; holes are `null` and reused via the free list.
pub const StreamFutureTable = struct {
    slots: std.ArrayList(?StreamFutureEnd),
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Error!StreamFutureTable {
        var slots: std.ArrayList(?StreamFutureEnd) = .empty;
        errdefer slots.deinit(alloc);
        try slots.append(alloc, null); // reserve index 0
        return .{ .slots = slots, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *StreamFutureTable) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// `Table.add` — reuse a free hole or grow; returns the handle index (≥ 1).
    pub fn add(self: *StreamFutureTable, end: StreamFutureEnd) Error!u32 {
        if (self.free.pop()) |i| {
            self.slots.items[i] = end;
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, end);
        return i;
    }

    /// `Table.get` — bounds + hole check (the trap source for stale handles).
    pub fn get(self: *StreamFutureTable, i: u32) Error!*StreamFutureEnd {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?;
    }

    /// `Table.remove` — tombstone the slot + push the hole to the free list.
    pub fn remove(self: *StreamFutureTable, i: u32) Error!StreamFutureEnd {
        const end = (try self.get(i)).*;
        self.slots.items[i] = null;
        try self.free.append(self.alloc, i);
        return end;
    }

    /// True if any timer subtask is armed — lets the host skip the clock read
    /// entirely on the (overwhelmingly common) no-timer path.
    pub fn hasArmedTimer(self: *const StreamFutureTable) bool {
        for (self.slots.items) |slot| {
            const end = slot orelse continue;
            if (end.kind == .subtask and end.deadline_ns != null) return true;
        }
        return false;
    }

    /// Resolve every timer subtask whose deadline has passed at `now_ns`: mark
    /// it RETURNED and set its pending SUBTASK event (deliverable via its
    /// waitable set). Returns the nearest still-future deadline, or null when
    /// no armed timer remains — the scheduler's sleep bound.
    pub fn fireDueTimers(self: *StreamFutureTable, now_ns: u64) ?u64 {
        var nearest: ?u64 = null;
        for (self.slots.items, 0..) |*slot, i| {
            const end = &(slot.* orelse continue);
            if (end.kind != .subtask) continue;
            const dl = end.deadline_ns orelse continue;
            if (dl <= now_ns) {
                end.deadline_ns = null;
                end.subtask_state = .returned;
                end.setPendingEvent(.{ .code = .subtask, .index = @intCast(i), .payload = @intFromEnum(SubtaskState.returned) });
            } else if (nearest == null or dl < nearest.?) {
                nearest = dl;
            }
        }
        return nearest;
    }
};

/// ADR-0195 §1 — cooperative scheduler task state. A task is `ready` to be driven
/// (its callback should run with a delivered event), `waiting` on a waitable-set
/// for an event to arrive, or `done` (the callback returned EXIT).
pub const TaskState = enum { ready, waiting, done };

/// ADR-0195 §1 — one cooperative task in the per-component `TaskTable`. Pure data:
/// the Zone-3 scheduler loop (step c) drives a `ready` task's callback, polls a
/// `waiting` task's `set_index`, and marks it `done` on EXIT. The main export seeds
/// task 0; an async-lowered import to a guest callee enqueues more. A pure
/// single-task component is a 1-entry table — the byte-identical regression case.
/// The table handle index serves as the task id (`Subtask` links via it, step c).
pub const TaskDescriptor = struct {
    /// Core function index of this task's stackless callback (the `callback<f>`
    /// canonopt funcidx the driver re-enters per delivered event).
    callback_funcidx: u32,
    /// The waitable-set handle this task blocks on while `state == .waiting`
    /// (set when the callback returns WAIT(set); meaningless in other states).
    set_index: u32 = 0,
    state: TaskState = .ready,
    /// ADR-0195 step (d-a): the value this task delivered via `canon task.return`
    /// (the cross-component async DATA channel). Per-task (NOT a single shared
    /// ctx slot) so concurrent graph tasks each capture their own result. `null`
    /// until the task's callee calls task.return; `seedTask` leaves it null. The
    /// minimal single-`u32`-lowered-result form — a multi-value / typed result is
    /// an `UnsupportedBoundaryType` deferral at the graph boundary, not stored here.
    result: ?u32 = null,
};

/// ADR-0195 §1 — per-component table of cooperative tasks (mirrors
/// `StreamFutureTable`: index 0 reserved, free-list reuse, `MAX_LENGTH` cap).
/// Pure data; the scheduler policy (round-robin over `ready`, deadlock when all
/// `waiting` with no pending event) lives in the Zone-3 driver (step c).
pub const TaskTable = struct {
    slots: std.ArrayList(?TaskDescriptor),
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Error!TaskTable {
        var slots: std.ArrayList(?TaskDescriptor) = .empty;
        errdefer slots.deinit(alloc);
        try slots.append(alloc, null); // reserve index 0
        return .{ .slots = slots, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *TaskTable) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// `Table.add` — reuse a free hole or grow; returns the task id (≥ 1).
    pub fn add(self: *TaskTable, task: TaskDescriptor) Error!u32 {
        if (self.free.pop()) |i| {
            self.slots.items[i] = task;
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, task);
        return i;
    }

    /// `Table.get` — bounds + hole check (the trap source for stale task ids).
    pub fn get(self: *TaskTable, i: u32) Error!*TaskDescriptor {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?;
    }

    /// `Table.remove` — tombstone the slot + push the hole to the free list.
    pub fn remove(self: *TaskTable, i: u32) Error!TaskDescriptor {
        const task = (try self.get(i)).*;
        self.slots.items[i] = null;
        try self.free.append(self.alloc, i);
        return task;
    }
};

/// A "waitable set" (`CanonicalABI.md` `WaitableSet`): a collection of waitable
/// handles that core wasm waits on / polls for *any* member to make progress.
/// `elems` holds the member handle indices into the `StreamFutureTable`; a real
/// implementation would embed a ready-list to avoid the O(n) scan, but a member
/// can carry at most one pending event so correctness is unaffected.
pub const WaitableSet = struct {
    elems: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) WaitableSet {
        return .{ .elems = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *WaitableSet) void {
        self.elems.deinit(self.alloc);
    }

    /// `Waitable.join` (the set side) — add a member handle.
    pub fn join(self: *WaitableSet, handle: u32) Error!void {
        try self.elems.append(self.alloc, handle);
    }

    /// True if any member has a pending event (`WaitableSet.has_pending_event`).
    pub fn hasPendingEvent(self: WaitableSet, table: *StreamFutureTable) bool {
        for (self.elems.items) |h| {
            const e = table.get(h) catch continue;
            if (e.hasPendingEvent()) return true;
        }
        return false;
    }

    /// `WaitableSet.poll` — deliver (and clear) the first member's pending
    /// event, or null for `EventCode.NONE` (nothing ready). The blocking
    /// `wait` variant adds the event-loop suspension on top (Unit η).
    pub fn poll(self: *WaitableSet, table: *StreamFutureTable) Error!?EventTuple {
        for (self.elems.items) |h| {
            const e = table.get(h) catch continue;
            if (e.hasPendingEvent()) return e.takePendingEvent();
        }
        return null;
    }

    /// Complete any member whose copy is PARKED (`async_copying`) but whose
    /// rendezvous peer has since DROPPED — deliver the DROPPED event so the
    /// waiter observes the close. A peer that drops AFTER this end parked
    /// wakes it directly (`dropEndGuarded`); this covers the reverse order
    /// (the end parks its write, THEN the host drops the peer — e.g. a
    /// consume-body `res` future the guest wrote before the host dropped it,
    /// ADR-0205 D-5). Idempotent; called from the scheduler's poll seam.
    pub fn resolveDroppedPeers(self: *WaitableSet, table: *StreamFutureTable, shared: *SharedTable) void {
        for (self.elems.items) |h| {
            const e = table.get(h) catch continue;
            if (e.state != .async_copying or e.shared == 0) continue;
            const sh = shared.get(e.shared) catch continue;
            const dropped = switch (sh.*) {
                .stream => |s| s.dropped,
                .future => |f| f.dropped,
                .subtask => false,
            };
            if (!dropped) continue;
            e.state = .done;
            const code: EventCode = switch (e.kind) {
                .stream => streamEventFor(e.side),
                .future => futureEventFor(e.side),
                .subtask => continue,
            };
            e.setPendingEvent(.{ .code = code, .index = h, .payload = (ReturnCode{ .dropped = 0 }).encode() });
        }
    }
};

/// The per-task waitable-set table (`CanonicalABI.md` — sets are created by
/// `canon waitable-set.new` and named by the `waitable_set_index` a stackless
/// callback returns for a WAIT). Index 0 reserved (no set), holes reused via the
/// free list — mirrors `StreamFutureTable`. Owns each `WaitableSet`, so `remove`
/// (and `deinit`) tear down the member list.
pub const WaitableSetTable = struct {
    slots: std.ArrayList(?WaitableSet),
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Error!WaitableSetTable {
        var slots: std.ArrayList(?WaitableSet) = .empty;
        errdefer slots.deinit(alloc);
        try slots.append(alloc, null); // reserve index 0
        return .{ .slots = slots, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *WaitableSetTable) void {
        for (self.slots.items) |*slot| if (slot.*) |*ws| ws.deinit();
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// `Table.add` — install a set (the table takes ownership); returns the
    /// handle (≥ 1).
    pub fn add(self: *WaitableSetTable, ws: WaitableSet) Error!u32 {
        if (self.free.pop()) |i| {
            self.slots.items[i] = ws;
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, ws);
        return i;
    }

    /// `Table.get` — bounds + hole check (the trap source for stale set indices).
    pub fn get(self: *WaitableSetTable, i: u32) Error!*WaitableSet {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?;
    }

    /// `Waitable.join(None)` / the move half of `waitable.join`: remove
    /// `handle` from EVERY set (a waitable belongs to at most one).
    pub fn unjoin(self: *WaitableSetTable, handle: u32) void {
        for (self.slots.items) |*slot| {
            if (slot.* == null) continue;
            const ws = &slot.*.?;
            var i: usize = 0;
            while (i < ws.elems.items.len) {
                if (ws.elems.items[i] == handle) {
                    _ = ws.elems.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }
    }

    /// `Table.remove` — drop the set (tearing down its member list), tombstone
    /// the slot + push the hole to the free list.
    pub fn remove(self: *WaitableSetTable, i: u32) Error!void {
        var ws = (try self.get(i)).*;
        ws.deinit();
        self.slots.items[i] = null;
        try self.free.append(self.alloc, i);
    }
};

/// `Subtask.State` (`CanonicalABI.md`) — the lifecycle of an async-lowered
/// import call (the waitable a guest receives when it calls an async import).
pub const SubtaskState = enum(u8) {
    starting = 0,
    started = 1,
    returned = 2,
    cancelled_before_started = 3,
    cancelled_before_returned = 4,
};

/// A `Subtask` waitable (`CanonicalABI.md` `class Subtask`): returned when a
/// guest calls an async-LOWERED import that blocks. A `Waitable` (it carries a
/// `pending_event` + `wset` like a stream/future end). `lenders` are the
/// borrowed resource handles kept alive for the subtask's duration — surrendered
/// (returned to the resource table by the host) when it resolves. Zone-1 data;
/// the call that creates/drives a Subtask is the Unit-ζ₂/η host wiring.
pub const Subtask = struct {
    state: SubtaskState = .starting,
    cancellation_requested: bool = false,
    pending_event: ?EventTuple = null,
    wset: ?u32 = null,
    lenders: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Subtask {
        return .{ .lenders = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Subtask) void {
        self.lenders.deinit(self.alloc);
    }

    /// Track a borrowed resource handle held alive for this subtask
    /// (spec `Subtask.lenders`).
    pub fn addLender(self: *Subtask, handle: u32) Error!void {
        try self.lenders.append(self.alloc, handle);
    }

    pub fn requestCancel(self: *Subtask) void {
        self.cancellation_requested = true;
    }

    pub fn resolved(self: Subtask) bool {
        return switch (self.state) {
            .returned, .cancelled_before_started, .cancelled_before_returned => true,
            .starting, .started => false,
        };
    }

    /// `deliver_resolve` — move to a terminal state, queue the `SUBTASK` event
    /// (payload = the new state), and surrender the borrowed handles. Returns the
    /// lender slice for the host to drop from the resource table (Zone-1 here
    /// cannot touch that table).
    pub fn resolve(self: *Subtask, handle: u32, new_state: SubtaskState) []const u32 {
        self.state = new_state;
        self.pending_event = .{ .code = .subtask, .index = handle, .payload = @intFromEnum(new_state) };
        return self.lenders.items;
    }

    pub fn setPendingEvent(self: *Subtask, ev: EventTuple) void {
        self.pending_event = ev;
    }

    pub fn hasPendingEvent(self: Subtask) bool {
        return self.pending_event != null;
    }

    pub fn takePendingEvent(self: *Subtask) ?EventTuple {
        defer self.pending_event = null;
        return self.pending_event;
    }
};

/// Outcome of one read/write rendezvous step (`CanonicalABI.md` stream
/// `read`/`write`). `caller` is what happens to the calling end. When a
/// rendezvous resolves the previously-pending opposite end, `notify` identifies
/// it (its waitable handle + the copy event code + encoded `ReturnCode`) so the
/// caller delivers a `pending_event` to it (the Unit-δ event seam).
pub const Step = struct {
    caller: union(enum) { blocked, completed: u32, dropped },
    notify: ?Notify = null,

    pub const Notify = struct { waitable: u32, code: EventCode, payload: u32 };

    /// The `ReturnCode` this caller-side step encodes to (the value a `future.*`
    /// / `stream.*` builtin returns to the guest). `dropped` carries count 0 in
    /// the rendezvous-count model (no partial-copy progress without a host buffer).
    pub fn code(self: Step) ReturnCode {
        return switch (self.caller) {
            .blocked => .blocked,
            .completed => |n| .{ .completed = @intCast(n) },
            .dropped => .{ .dropped = 0 },
        };
    }
};

/// The copy-event code delivered to a resolved end of the given `side`
/// (a readable end's read completed → STREAM_READ; writable → STREAM_WRITE).
fn streamEventFor(side: EndSide) EventCode {
    return switch (side) {
        .readable => .stream_read,
        .writable => .stream_write,
    };
}

/// The state shared by a stream's two ends (`CanonicalABI.md` §Stream State,
/// the `SharedStreamImpl` rendezvous). Zone-1 control logic only: it computes
/// the transfer COUNT (`min` of the two buffers) and the state transitions; the
/// actual element bytes are moved by the host via the Unit-C canon store/load
/// (this module never touches guest memory). At most one end is `pending` at a
/// time (one-reader / one-writer invariant). `pending.waitable` records the
/// blocked end's handle so a later rendezvous can deliver its event.
pub const SharedStream = struct {
    /// Max bytes the synchronous cross-component rendezvous can stash between a
    /// writer's deposit and the reader's drain (ADR-0195 d-c-1). A bounded inline
    /// buffer keeps the rendezvous Zone-1-pure (no per-stream heap); a larger /
    /// ring / multi-write stream is a later slice (host-buffer wiring). A write
    /// whose `count * elem_size` exceeds this is a typed deferral at the graph
    /// boundary, not a silent truncation.
    pub const BUF_CAP: u16 = 64;

    elem_type: ?u32,
    dropped: bool = false,
    pending: ?Pending = null,
    /// The deposited element bytes a writer end stashed for the reader end to
    /// drain (the stream's DATA channel — the rendezvous itself is count-only;
    /// the actual guest↔guest byte transfer lands here, copied in/out of each
    /// end's memory by the canon host func, ADR-0195 d-c-1). `buf_len == 0` until
    /// a writer deposits; a reader drains `buf[0..buf_len]`.
    buf: [BUF_CAP]u8 = undefined,
    buf_len: u16 = 0,

    pub const Pending = struct { side: EndSide, remain: u32, waitable: u32 };

    fn notifyOf(p: Pending, n: u32) Step.Notify {
        return .{ .waitable = p.waitable, .code = streamEventFor(p.side), .payload = (ReturnCode{ .completed = @intCast(n) }).encode() };
    }

    /// `ReadableStream.read` — `cap` is the destination buffer capacity;
    /// `handle` is this readable end's table handle (recorded if it blocks).
    pub fn read(self: *SharedStream, cap: u32, handle: u32) Step {
        if (self.dropped) return .{ .caller = .dropped };
        const w = self.pending orelse {
            self.pending = .{ .side = .readable, .remain = cap, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(w.side == .writable);
        if (w.remain > 0) {
            if (cap == 0) return .{ .caller = .{ .completed = 0 } }; // writer stays pending
            const n = @min(cap, w.remain);
            self.pending = null;
            return .{ .caller = .{ .completed = n }, .notify = notifyOf(w, n) };
        }
        // Zero-length pending write: notify the writer COMPLETED(0); this read
        // becomes pending. (read has NO zero-zero shortcut — see write.)
        self.pending = .{ .side = .readable, .remain = cap, .waitable = handle };
        return .{ .caller = .blocked, .notify = notifyOf(w, 0) };
    }

    /// `WritableStream.write` — `count` is the source item count; `handle` is
    /// this writable end's table handle. The zero-zero rendezvous resolves in
    /// the writer's favour (livelock avoidance).
    pub fn write(self: *SharedStream, count: u32, handle: u32) Step {
        if (self.dropped) return .{ .caller = .dropped };
        const r = self.pending orelse {
            self.pending = .{ .side = .writable, .remain = count, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(r.side == .readable);
        if (r.remain > 0) {
            if (count == 0) return .{ .caller = .{ .completed = 0 } }; // reader stays pending
            const n = @min(count, r.remain);
            self.pending = null;
            return .{ .caller = .{ .completed = n }, .notify = notifyOf(r, n) };
        }
        // Pending reader is zero-length.
        if (count == 0) return .{ .caller = .{ .completed = 0 } }; // both zero → write wins, read pends
        self.pending = .{ .side = .writable, .remain = count, .waitable = handle };
        return .{ .caller = .blocked, .notify = notifyOf(r, 0) };
    }
};

/// The copy-event code for a resolved FUTURE end of the given `side`.
fn futureEventFor(side: EndSide) EventCode {
    return switch (side) {
        .readable => .future_read,
        .writable => .future_write,
    };
}

/// A future's shared state (`CanonicalABI.md` §Future State) — like
/// `SharedStream` but single-shot: exactly one value passes writer→reader, so
/// there is no partial copy, no count, and no zero-length cases (both ends
/// complete with `COMPLETED`, count 0). Asymmetry: only the writable end
/// observes a reader-drop (`DROPPED`); the reader never observes a drop.
/// Reuses `SharedStream.Pending` (the `{side, remain, waitable}` slot).
pub const SharedFuture = struct {
    /// Max lowered payload a future's single value can stash in the rendezvous
    /// (a small flat scalar — `u8`..`u64`/`f64`). A wider/aggregate `future<T>`
    /// payload is a typed deferral at the cross-component boundary, not stored.
    pub const VALUE_CAP: u8 = 8;

    elem_type: ?u32,
    dropped: bool = false,
    /// Set once the single value has passed writer→reader (either rendezvous
    /// order completes the write). Gates `future.drop-writable` per spec.
    written: bool = false,
    pending: ?SharedStream.Pending = null,
    /// The single value's lowered bytes, deposited by the writer end and drained
    /// by the reader end (the future's DATA channel). The rendezvous itself is
    /// count-only; the actual guest↔guest byte transfer for a future lands here,
    /// copied in/out of each end's memory by the canon host func (ADR-0195 d-b-2).
    /// `value_len == 0` until a writer deposits.
    value: [VALUE_CAP]u8 = undefined,
    value_len: u8 = 0,

    fn mkNotify(p: SharedStream.Pending) Step.Notify {
        return .{ .waitable = p.waitable, .code = futureEventFor(p.side), .payload = (ReturnCode{ .completed = 0 }).encode() };
    }

    /// `ReadableFuture.read` — `n` is ignored (a future copies exactly one
    /// value). Per spec the readable end never observes a drop.
    pub fn read(self: *SharedFuture, n: u32, handle: u32) Step {
        _ = n;
        // No `self.dropped` check here (unlike SharedStream.read / SharedFuture.write,
        // D-465): a future read with dropped=true is unreachable — the writable end
        // cannot drop before writing (guardWritableDrop traps), and a reader that
        // dropped its own end is no longer reading. Adding one would be dead code.
        const w = self.pending orelse {
            self.pending = .{ .side = .readable, .remain = 1, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(w.side == .writable);
        self.pending = null;
        self.written = true; // a pending writer's value is now delivered
        return .{ .caller = .{ .completed = 0 }, .notify = mkNotify(w) };
    }

    /// `WritableFuture.write` — observes a reader-drop as `DROPPED`; `n` ignored.
    pub fn write(self: *SharedFuture, n: u32, handle: u32) Step {
        _ = n;
        if (self.dropped) return .{ .caller = .dropped };
        const r = self.pending orelse {
            self.pending = .{ .side = .writable, .remain = 1, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(r.side == .readable);
        self.pending = null;
        self.written = true; // the value reached the pending reader
        return .{ .caller = .{ .completed = 0 }, .notify = mkNotify(r) };
    }

    /// `WritableFutureEnd.drop` guard (`CanonicalABI.md` §Future State): the
    /// writable end MUST NOT be dropped before its value is written, unless the
    /// reader has already dropped (then the writer is notified and may drop).
    pub fn guardWritableDrop(self: *const SharedFuture) Error!void {
        if (!self.written and !self.dropped) return Error.FutureDropBeforeWrite;
    }
};

/// A rendezvous object shared by a stream's (or future's) two ends. Owned by
/// the per-task `SharedTable`; `StreamFutureEnd.shared` indexes into it. A
/// `.subtask` end has no rendezvous (its `shared` stays 0/unlinked) — the
/// variant exists only to keep the union exhaustive over `EndKind`.
pub const Shared = union(EndKind) {
    stream: SharedStream,
    future: SharedFuture,
    subtask: void,
};

/// The per-task table of `Shared` rendezvous objects (ADR-0189 ζ2). A
/// `stream.new`/`future.new` mints ONE `Shared` referenced by both ends, so the
/// slot is refcounted (= live end count) and freed when the second end drops.
/// Index 0 reserved, free-list reuse — mirrors `StreamFutureTable`.
pub const SharedTable = struct {
    const Slot = struct { shared: Shared, refcount: u8 };
    slots: std.ArrayList(?Slot),
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) SharedTable {
        return .{ .slots = .empty, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *SharedTable) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// Install a new `Shared` with refcount 2 (the readable + writable ends a
    /// `*.new` mints); returns its handle (≥ 1).
    fn addPair(self: *SharedTable, shared: Shared) Error!u32 {
        // Lazily reserve index 0 as the None sentinel on first use.
        if (self.slots.items.len == 0) try self.slots.append(self.alloc, null);
        if (self.free.pop()) |i| {
            self.slots.items[i] = .{ .shared = shared, .refcount = 2 };
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, .{ .shared = shared, .refcount = 2 });
        return i;
    }

    /// Resolve a handle to its `Shared` (bounds + hole check → use-after-free trap).
    pub fn get(self: *SharedTable, i: u32) Error!*Shared {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?.shared;
    }

    /// The live-end count of shared slot `i` (null for the 0-sentinel / a
    /// hole). Lets the host layer scrub shared-keyed side tables exactly when
    /// a drop is about to free the slot (slot ids are free-list-reused).
    pub fn refcountOf(self: *SharedTable, i: u32) ?u8 {
        if (i == 0 or i >= self.slots.items.len) return null;
        const slot = self.slots.items[i] orelse return null;
        return slot.refcount;
    }

    /// Drop one reference; tombstone + free-list the slot when the last end goes.
    fn release(self: *SharedTable, i: u32) Error!void {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        const slot = &(self.slots.items[i] orelse return Error.InvalidHandle);
        slot.refcount -= 1;
        if (slot.refcount == 0) {
            self.slots.items[i] = null;
            try self.free.append(self.alloc, i);
        }
    }
};

/// The handles a `stream.new`/`future.new` mints — a linked readable+writable
/// pair (spec `canon_stream_new` returns `ri | (wi << 32)`).
pub const EndPair = struct { readable: u32, writable: u32 };

fn newPair(ends: *StreamFutureTable, shared: *SharedTable, kind: EndKind, init_shared: Shared, elem_type: ?u32) Error!EndPair {
    // A mid-mint OOM/TableFull leaves a benign partial state (an orphaned end +
    // a refcount-2 shared slot), reclaimed wholesale at table deinit — so the
    // error simply propagates (the guest traps); no rollback catch needed.
    const sh = try shared.addPair(init_shared);
    const r = try ends.add(.{ .kind = kind, .side = .readable, .elem_type = elem_type, .shared = sh });
    const w = try ends.add(.{ .kind = kind, .side = .writable, .elem_type = elem_type, .shared = sh });
    return .{ .readable = r, .writable = w };
}

/// `canon stream.new` (Zone-1 part): create the shared rendezvous + its two ends.
pub fn newStreamPair(ends: *StreamFutureTable, shared: *SharedTable, elem_type: ?u32) Error!EndPair {
    return newPair(ends, shared, .stream, .{ .stream = .{ .elem_type = elem_type } }, elem_type);
}

/// `canon future.new` (Zone-1 part) — symmetric to `newStreamPair`.
pub fn newFuturePair(ends: *StreamFutureTable, shared: *SharedTable, elem_type: ?u32) Error!EndPair {
    return newPair(ends, shared, .future, .{ .future = .{ .elem_type = elem_type } }, elem_type);
}

/// Drop one end: remove it from the ends table and release its reference to the
/// shared rendezvous (freed when the second end drops). The rendezvous-DROPPED
/// semantics (peer sees `.dropped`) layer on with the `*.drop-{readable,
/// writable}` builtins; this is the MEMORY-lifetime half (ADR-0189 ζ2).
pub fn dropEnd(ends: *StreamFutureTable, shared: *SharedTable, handle: u32) Error!void {
    const end = try ends.get(handle);
    const sh = end.shared;
    _ = try ends.remove(handle);
    if (sh != 0) try shared.release(sh);
}

/// Guest-facing end drop (the canon `{stream,future}.drop-{readable,writable}`
/// path). Beyond the raw refcount `dropEnd` it: (a) enforces the spec future
/// guard — a future WRITABLE end dropped before its value is written traps
/// `FutureDropBeforeWrite` (CanonicalABI.md §Future State); (b) marks the
/// rendezvous DROPPED via `end.drop`, so the SURVIVING peer's next read/write
/// observes DROPPED instead of BLOCKing on a rendezvous that can never complete
/// (D-464: cross-component peer-drop mid-rendezvous). The raw `dropEnd` stays
/// guard/flag-free for internal teardown + refcount tests. Used by every
/// guest-facing drop builtin (graph + WASI-P2), so they share one drop contract.
pub fn dropEndGuarded(ends: *StreamFutureTable, shared: *SharedTable, handle: u32) Error!void {
    const end = try ends.get(handle);
    if (end.shared != 0) {
        switch ((try shared.get(end.shared)).*) {
            .stream => |*s| {
                try end.drop(s);
                // Wake a PARKED peer (a blocked reader/writer waiting in a waitable
                // set) so its scheduler re-entry observes DROPPED, instead of waiting
                // forever for a rendezvous that can never complete (D-464: a parked
                // cross-component reader + peer-drop deadlocked). Mirrors how a write
                // notifies a parked reader; the peer's re-read/-write sees `s.dropped`
                // and returns DROPPED. Futures can't reach this (a future writable
                // can't drop before writing, and a write wakes the reader first).
                if (s.pending) |p| {
                    const peer = try ends.get(p.waitable);
                    peer.setPendingEvent(.{ .code = streamEventFor(p.side), .index = p.waitable, .payload = 0 });
                    peer.state = .idle;
                    s.pending = null;
                }
            },
            .future => |*f| {
                if (end.side == .writable) try f.guardWritableDrop();
                try end.drop(f);
                // Wake a PARKED WRITER on a reader-drop: its pending write
                // can never rendezvous, so deliver the DROPPED completion
                // directly (a request/response owning a transferred
                // trailers future drops the readable at destruction —
                // ADR-0205 phase D; without this the guest's wit_future
                // writer task waits forever → AsyncDeadlock).
                if (f.pending) |p| {
                    const peer = try ends.get(p.waitable);
                    peer.setPendingEvent(.{ .code = futureEventFor(p.side), .index = p.waitable, .payload = (ReturnCode{ .dropped = 0 }).encode() });
                    peer.state = .idle;
                    f.pending = null;
                }
            },
            .subtask => unreachable, // SharedTable never stores .subtask (subtask ends stay unlinked)
        }
    }
    try dropEnd(ends, shared, handle);
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "ReturnCode packs per the canonical-ABI encoding" {
    try testing.expectEqual(@as(u32, 0xffff_ffff), (@as(ReturnCode, .blocked)).encode());
    try testing.expectEqual(@as(u32, 3 << 4), (ReturnCode{ .completed = 3 }).encode());
    try testing.expectEqual(@as(u32, (5 << 4) | 1), (ReturnCode{ .dropped = 5 }).encode());
    try testing.expectEqual(@as(u32, (2 << 4) | 2), (ReturnCode{ .cancelled = 2 }).encode());
    // futures carry a zero count → just the code in the low bits.
    try testing.expectEqual(@as(u32, 0), (ReturnCode{ .completed = 0 }).encode());
}

test "D-335 unit D-η: unpackCallbackResult decodes the stackless callback-ABI return code" {
    // EXIT (0) carries no waitable set.
    try testing.expectEqual(CallbackCode.exit, (try unpackCallbackResult(0)).code);
    // WAIT (2) with waitable-set index 7: (7 << 4) | 2.
    const w = try unpackCallbackResult((7 << 4) | 2);
    try testing.expectEqual(CallbackCode.wait, w.code);
    try testing.expectEqual(@as(u32, 7), w.waitable_set_index);
    // YIELD (1), no set.
    try testing.expectEqual(CallbackCode.yield, (try unpackCallbackResult(1)).code);
    // a code > MAX (2) traps (the reserved low-nibble values).
    try testing.expectError(Error.InvalidCallbackCode, unpackCallbackResult(3));
}

test "stream rendezvous: write-then-read copies min(counts); notifies the pending writer" {
    var s = SharedStream{ .elem_type = 5 };
    try testing.expect(s.write(2, 11).caller == .blocked); // writer (handle 11) pends
    const step = s.read(4, 22); // reader rendezvous with the pending writer
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    const nt = step.notify.?;
    try testing.expectEqual(@as(u32, 11), nt.waitable); // the previously-pending writer
    try testing.expectEqual(EventCode.stream_write, nt.code);
    try testing.expectEqual((ReturnCode{ .completed = 2 }).encode(), nt.payload);
    try testing.expect(s.pending == null); // both ends resolved
}

test "stream rendezvous: read-then-write is symmetric (notifies the pending reader)" {
    var s = SharedStream{ .elem_type = null };
    try testing.expect(s.read(4, 22).caller == .blocked);
    const step = s.write(2, 11);
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    const nt = step.notify.?;
    try testing.expectEqual(@as(u32, 22), nt.waitable); // the pending reader
    try testing.expectEqual(EventCode.stream_read, nt.code);
    try testing.expect(s.pending == null);
}

test "stream rendezvous: dropped end + zero-length livelock tiebreak (write wins)" {
    var dropped = SharedStream{ .elem_type = null, .dropped = true };
    try testing.expect(dropped.read(4, 1).caller == .dropped);
    try testing.expect(dropped.write(4, 1).caller == .dropped);

    // zero-length read pends; a following zero-length write COMPLETES while the
    // read stays pending (the spec's livelock-avoidance asymmetry).
    var s = SharedStream{ .elem_type = null };
    try testing.expect(s.read(0, 22).caller == .blocked);
    const w = s.write(0, 11);
    try testing.expectEqual(@as(u32, 0), w.caller.completed);
    try testing.expect(s.pending != null); // read still pending
}

test "waitable-set: poll delivers a member's pending event once, then clears it" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    const h = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });

    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(h);
    try testing.expect(!ws.hasPendingEvent(&t));
    try testing.expect((try ws.poll(&t)) == null); // EventCode.NONE → null

    // a STREAM_READ event lands on the member end.
    (try t.get(h)).setPendingEvent(.{ .code = .stream_read, .index = h, .payload = 7 });
    try testing.expect(ws.hasPendingEvent(&t));
    const ev = (try ws.poll(&t)).?;
    try testing.expectEqual(EventCode.stream_read, ev.code);
    try testing.expectEqual(h, ev.index);
    try testing.expectEqual(@as(u32, 7), ev.payload);

    // get_pending_event clears it (at-most-one event per waitable).
    try testing.expect(!ws.hasPendingEvent(&t));
    try testing.expect((try ws.poll(&t)) == null);
}

test "stream end CopyState: blocked copy → async_copying; cancel → idle; drop traps while copying" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });
    const re = try t.get(rh);
    try testing.expect(!re.copying());

    // a read with no pending writer blocks → the end enters async_copying.
    try testing.expect((try re.copy(&shared, &t, rh, 4)).caller == .blocked);
    try testing.expectEqual(CopyState.async_copying, re.state);
    try testing.expect(re.copying());

    // dropping an end with a copy in progress traps (spec CopyEnd.drop).
    try testing.expectError(Error.CopyInProgress, re.drop(&shared));

    // cancel clears the in-flight copy and the shared pending slot → idle.
    _ = try re.cancel(&shared);
    try testing.expectEqual(CopyState.idle, re.state);
    try testing.expect(shared.pending == null);

    // now drop is allowed and sets the shared dropped flag.
    try re.drop(&shared);
    try testing.expect(shared.dropped);
}

test "stream end copy: synchronous rendezvous resolves both ends to idle; dropped peer → done" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const wh = try t.add(.{ .kind = .stream, .side = .writable, .elem_type = null });
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });

    try testing.expect((try (try t.get(wh)).copy(&shared, &t, wh, 2)).caller == .blocked); // writer pends
    const step = try (try t.get(rh)).copy(&shared, &t, rh, 4); // reader rendezvous (synchronous)
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    try testing.expectEqual(CopyState.idle, (try t.get(rh)).state);
    // the previously-pending writer got its event delivered + resolved to idle.
    try testing.expect((try t.get(wh)).hasPendingEvent());
    try testing.expectEqual(CopyState.idle, (try t.get(wh)).state);

    // a peer drop makes the next copy see DROPPED → the end is done.
    shared.dropped = true;
    try testing.expect((try (try t.get(rh)).copy(&shared, &t, rh, 1)).caller == .dropped);
    try testing.expectEqual(CopyState.done, (try t.get(rh)).state);
}

test "D-335 unit D-δ: a rendezvous delivers a STREAM_READ event to the blocked reader's waitable-set" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });
    const wh = try t.add(.{ .kind = .stream, .side = .writable, .elem_type = null });

    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(rh);

    // reader blocks (no writer yet) — nothing ready on its set.
    try testing.expect((try (try t.get(rh)).copy(&shared, &t, rh, 4)).caller == .blocked);
    try testing.expect((try ws.poll(&t)) == null);

    // writer writes 2 → the reader's set now has a STREAM_READ event.
    try testing.expectEqual(@as(u32, 2), (try (try t.get(wh)).copy(&shared, &t, wh, 2)).caller.completed);
    const ev = (try ws.poll(&t)).?;
    try testing.expectEqual(EventCode.stream_read, ev.code);
    try testing.expectEqual(rh, ev.index);
    try testing.expectEqual((ReturnCode{ .completed = 2 }).encode(), ev.payload);
}

test "D-335 unit D-ζ: subtask state machine + lender tracking + resolve delivers a SUBTASK event" {
    var st = Subtask.init(testing.allocator);
    defer st.deinit();
    try testing.expectEqual(SubtaskState.starting, st.state);
    try testing.expect(!st.resolved());

    st.state = .started;
    try st.addLender(3);
    try st.addLender(5);
    st.requestCancel();
    try testing.expect(st.cancellation_requested);

    // resolve → terminal state, surrenders the borrowed handles, queues SUBTASK.
    const lent = st.resolve(9, .returned);
    try testing.expectEqual(SubtaskState.returned, st.state);
    try testing.expect(st.resolved());
    try testing.expectEqualSlices(u32, &.{ 3, 5 }, lent);
    const ev = st.takePendingEvent().?;
    try testing.expectEqual(EventCode.subtask, ev.code);
    try testing.expectEqual(@as(u32, 9), ev.index);
    try testing.expectEqual(@as(u32, @intFromEnum(SubtaskState.returned)), ev.payload);
}

test "D-335 unit D-ε: future single-shot rendezvous delivers FUTURE_READ; writer observes reader-drop" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var fut = SharedFuture{ .elem_type = null };
    const rh = try t.add(.{ .kind = .future, .side = .readable, .elem_type = null });
    const wh = try t.add(.{ .kind = .future, .side = .writable, .elem_type = null });
    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(rh);

    // reader blocks; the writer writes the one value → reader gets FUTURE_READ.
    try testing.expect((try (try t.get(rh)).copy(&fut, &t, rh, 1)).caller == .blocked);
    try testing.expectEqual(@as(u32, 0), (try (try t.get(wh)).copy(&fut, &t, wh, 1)).caller.completed);
    const ev = (try ws.poll(&t)).?;
    try testing.expectEqual(EventCode.future_read, ev.code);
    try testing.expectEqual(rh, ev.index);
    try testing.expectEqual((ReturnCode{ .completed = 0 }).encode(), ev.payload);

    // a writer observes a dropped (reader-dropped) future as DROPPED.
    var fut2 = SharedFuture{ .elem_type = null, .dropped = true };
    const wh2 = try t.add(.{ .kind = .future, .side = .writable, .elem_type = null });
    try testing.expect((try (try t.get(wh2)).copy(&fut2, &t, wh2, 1)).caller == .dropped);
}

test "D-337: future.drop-writable guard — traps pre-write, allowed after write or reader-drop" {
    // Pristine future: writable drop traps (value never written, reader present).
    var fut = SharedFuture{ .elem_type = null };
    try testing.expectError(Error.FutureDropBeforeWrite, fut.guardWritableDrop());
    // After a completed rendezvous the value is written → drop allowed.
    fut.written = true;
    try fut.guardWritableDrop();
    // Reader-dropped first → the writer is notified and may drop without writing.
    var fut2 = SharedFuture{ .elem_type = null, .dropped = true };
    try fut2.guardWritableDrop();
}

test "stream/future end table: add/get/remove lifecycle + index-0 reserved" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();

    const h = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = 5 });
    try testing.expect(h >= 1); // a valid handle is never the 0 sentinel
    const end = try t.get(h);
    try testing.expectEqual(EndKind.stream, end.kind);
    try testing.expectEqual(EndSide.readable, end.side);
    try testing.expectEqual(@as(?u32, 5), end.elem_type);
    try testing.expectEqual(CopyState.idle, end.state);

    // index 0 is the reserved None sentinel.
    try testing.expectError(Error.InvalidHandle, t.get(0));

    // remove tombstones → use-after-drop / double-drop trap.
    _ = try t.remove(h);
    try testing.expectError(Error.InvalidHandle, t.get(h));
    try testing.expectError(Error.InvalidHandle, t.remove(h));

    // a freed slot is reused (free list) for the next add.
    const h2 = try t.add(.{ .kind = .future, .side = .writable, .elem_type = null });
    try testing.expectEqual(h, h2);
    try testing.expectEqual(EndKind.future, (try t.get(h2)).kind);
}

test "ADR-0195 step (b): TaskTable add/get/remove lifecycle + index-0 reserved + free-list reuse" {
    var t = try TaskTable.init(testing.allocator);
    defer t.deinit();

    // a fresh task defaults to .ready with set_index 0.
    const id = try t.add(.{ .callback_funcidx = 7 });
    try testing.expect(id >= 1); // task id is never the 0 sentinel
    const task = try t.get(id);
    try testing.expectEqual(@as(u32, 7), task.callback_funcidx);
    try testing.expectEqual(TaskState.ready, task.state);
    try testing.expectEqual(@as(u32, 0), task.set_index);

    // mutate through the pointer: the callback returned WAIT(set 4).
    task.state = .waiting;
    task.set_index = 4;
    try testing.expectEqual(TaskState.waiting, (try t.get(id)).state);
    try testing.expectEqual(@as(u32, 4), (try t.get(id)).set_index);

    // index 0 is the reserved None sentinel.
    try testing.expectError(Error.InvalidHandle, t.get(0));

    // remove tombstones → use-after-free / double-remove trap.
    _ = try t.remove(id);
    try testing.expectError(Error.InvalidHandle, t.get(id));
    try testing.expectError(Error.InvalidHandle, t.remove(id));

    // a freed slot is reused (free list) for the next add.
    const id2 = try t.add(.{ .callback_funcidx = 9, .state = .done });
    try testing.expectEqual(id, id2);
    try testing.expectEqual(TaskState.done, (try t.get(id2)).state);
}

test "D-335 unit D-ηB: waitable-set table add/get/remove + index-0 reserved" {
    var t = try WaitableSetTable.init(testing.allocator);
    defer t.deinit();

    var ws = WaitableSet.init(testing.allocator);
    try ws.join(7); // a member waitable handle
    const h = try t.add(ws); // table takes ownership of ws
    try testing.expect(h >= 1); // never the 0 sentinel
    try testing.expectEqualSlices(u32, &.{7}, (try t.get(h)).elems.items);

    try testing.expectError(Error.InvalidHandle, t.get(0)); // reserved sentinel

    try t.remove(h); // drops the set (deinits its member list)
    try testing.expectError(Error.InvalidHandle, t.get(h)); // tombstoned
    try testing.expectError(Error.InvalidHandle, t.remove(h)); // double-drop traps

    // a freed slot is reused (free list) for the next add.
    const h2 = try t.add(WaitableSet.init(testing.allocator));
    try testing.expectEqual(h, h2);
}

/// Records what the callback loop asked of the engine + scripts the guest's
/// packed callback returns, so the pure loop driver can be tested with no real
/// component instance.
/// Scripted multi-task ctx for `driveScheduler` (the step-c seam). Records, per
/// `invokeTaskCallback`, the delivered event code + the task's funcidx; returns
/// the next scripted packed callback result. `pollSet` returns `poll_event` for
/// every poll (null = nothing deliverable → the scheduler deadlocks).
const SchedCtx = struct {
    cb_returns: []const u32, // packed callback results, consumed in order
    poll_event: ?EventTuple = null,
    next: usize = 0,
    invoked: std.ArrayList(EventTuple) = .empty, // {code = delivered event, index = funcidx}
    polls: std.ArrayList(u32) = .empty,
    alloc: Allocator,

    fn deinit(self: *SchedCtx) void {
        self.invoked.deinit(self.alloc);
        self.polls.deinit(self.alloc);
    }
    fn invokeTaskCallback(self: *SchedCtx, funcidx: u32, event_code: u32, p1: u32, p2: u32) !u32 {
        _ = p2;
        try self.invoked.append(self.alloc, .{ .code = @enumFromInt(event_code), .index = funcidx, .payload = p1 });
        const r = self.cb_returns[self.next];
        self.next += 1;
        return r;
    }
    fn pollSet(self: *SchedCtx, set_index: u32) !?EventTuple {
        try self.polls.append(self.alloc, set_index);
        return self.poll_event;
    }
    fn waitForTimer(self: *SchedCtx) !bool {
        _ = self; // scripted ctx wires no timers — a stalled pass is a deadlock
        return false;
    }
};

test "ADR-0195 step (c): driveScheduler runs every ready task once + terminates when all done" {
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    const a = try table.add(.{ .callback_funcidx = 10 }); // .ready
    const b = try table.add(.{ .callback_funcidx = 20 }); // .ready
    var ctx = SchedCtx{ .cb_returns = &.{ 0, 0 }, .alloc = testing.allocator }; // both EXIT
    defer ctx.deinit();

    try driveScheduler(&ctx, &table);
    try testing.expectEqual(@as(usize, 2), ctx.invoked.items.len); // each task's callback ran once
    try testing.expectEqual(TaskState.done, (try table.get(a)).state);
    try testing.expectEqual(TaskState.done, (try table.get(b)).state);
}

test "ADR-0195 step (c): driveScheduler traps AsyncDeadlock when all tasks wait with no deliverable event" {
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    _ = try table.add(.{ .callback_funcidx = 10, .state = .waiting, .set_index = 5 });
    var ctx = SchedCtx{ .cb_returns = &.{}, .poll_event = null, .alloc = testing.allocator }; // poll yields nothing
    defer ctx.deinit();

    try testing.expectError(error.AsyncDeadlock, driveScheduler(&ctx, &table));
    try testing.expectEqualSlices(u32, &.{5}, ctx.polls.items); // polled the waiting task's set
    try testing.expectEqual(@as(usize, 0), ctx.invoked.items.len); // never re-entered the guest
}

test "ADR-0195 step (c): driveScheduler delivers a polled event to a waiting task, which then exits" {
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    const a = try table.add(.{ .callback_funcidx = 7, .state = .waiting, .set_index = 3 });
    var ctx = SchedCtx{
        .cb_returns = &.{0}, // after the delivered event the callback EXITs
        .poll_event = .{ .code = .stream_read, .index = 1, .payload = 0 },
        .alloc = testing.allocator,
    };
    defer ctx.deinit();

    try driveScheduler(&ctx, &table);
    try testing.expectEqual(@as(usize, 1), ctx.invoked.items.len);
    try testing.expectEqual(@as(u32, 7), ctx.invoked.items[0].index); // delivered to task 7's callback
    try testing.expectEqual(EventCode.stream_read, ctx.invoked.items[0].code);
    try testing.expectEqual(TaskState.done, (try table.get(a)).state);
}

test "ADR-0195 step (c) [single-task char]: a 1-entry table drives a MULTI-iteration WAIT sequence in order" {
    // Ports the retired driveCallbackLoop II(a) net to the unified driver: WAIT(5)
    // → event → callback re-issues WAIT(7) → event → EXIT. The scheduler must poll
    // set 5 THEN 7 and re-enter the one task twice.
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    _ = try table.add(.{ .callback_funcidx = 99, .state = .waiting, .set_index = 5 });
    var ctx = SchedCtx{
        .cb_returns = &.{ (7 << 4) | 2, 0 }, // 1st → WAIT set 7; 2nd → EXIT
        .poll_event = .{ .code = .stream_read, .index = 1, .payload = 0 },
        .alloc = testing.allocator,
    };
    defer ctx.deinit();

    try driveScheduler(&ctx, &table);
    try testing.expectEqualSlices(u32, &.{ 5, 7 }, ctx.polls.items); // polled 5 then 7, in order
    try testing.expectEqual(@as(usize, 2), ctx.invoked.items.len); // re-entered the one task twice
}

test "ADR-0195 step (c) [single-task char]: a ready task delivers `none` without polling; a waiting task polls" {
    // Ports the retired YIELD-vs-WAIT dispatch net: a `ready` (yielded) task is
    // re-entered with EventCode.none and does NOT poll; only a `waiting` task polls.
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    _ = try table.add(.{ .callback_funcidx = 8 }); // .ready (the YIELD-equivalent state)
    var ctx = SchedCtx{
        .cb_returns = &.{ (3 << 4) | 2, 0 }, // ready → WAIT set 3; then EXIT
        .poll_event = .{ .code = .stream_read, .index = 9, .payload = 0 },
        .alloc = testing.allocator,
    };
    defer ctx.deinit();

    try driveScheduler(&ctx, &table);
    try testing.expectEqualSlices(u32, &.{3}, ctx.polls.items); // ONLY the waiting step polled (set 3)
    try testing.expectEqual(@as(usize, 2), ctx.invoked.items.len);
    try testing.expectEqual(EventCode.none, ctx.invoked.items[0].code); // ready → none
    try testing.expectEqual(EventCode.stream_read, ctx.invoked.items[1].code); // waiting → delivered event
}

test "ADR-0195 step (c) [single-task char]: a table seeded with a done task drives nothing (immediate EXIT)" {
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    _ = try table.add(try seedTask(0)); // initial = EXIT → .done
    var ctx = SchedCtx{ .cb_returns = &.{}, .alloc = testing.allocator };
    defer ctx.deinit();

    try driveScheduler(&ctx, &table);
    try testing.expectEqual(@as(usize, 0), ctx.invoked.items.len); // never re-entered
}

test "ADR-0195: seedTask maps the initial packed callback-result to a task state" {
    try testing.expectEqual(TaskState.done, (try seedTask(0)).state); // EXIT → done (never entered)
    try testing.expectEqual(TaskState.ready, (try seedTask(1)).state); // YIELD → ready
    const w = try seedTask((9 << 4) | 2); // WAIT(9) → waiting on set 9
    try testing.expectEqual(TaskState.waiting, w.state);
    try testing.expectEqual(@as(u32, 9), w.set_index);
}

test "D-335 unit D-ζ2: newStreamPair mints linked readable+writable ends; shared freed on 2nd drop" {
    var ends = try StreamFutureTable.init(testing.allocator);
    defer ends.deinit();
    var shared = SharedTable.init(testing.allocator);
    defer shared.deinit();

    // stream.new: one shared rendezvous, two ends linked to it. Capture the
    // shared handle by value — the end pointers dangle once dropped.
    const pair = try newStreamPair(&ends, &shared, 5);
    const sh = (try ends.get(pair.readable)).shared;
    try testing.expectEqual(EndSide.readable, (try ends.get(pair.readable)).side);
    try testing.expectEqual(EndSide.writable, (try ends.get(pair.writable)).side);
    try testing.expectEqual(sh, (try ends.get(pair.writable)).shared); // same rendezvous
    try testing.expect(sh >= 1); // never the 0 sentinel
    try testing.expectEqual(@as(?u32, 5), (try shared.get(sh)).stream.elem_type);

    // refcount = 2: dropping the readable keeps the shared alive for the writer.
    try dropEnd(&ends, &shared, pair.readable);
    try testing.expectError(Error.InvalidHandle, ends.get(pair.readable)); // end gone
    try testing.expect((try shared.get(sh)).* == .stream); // shared alive (1 ref)
    // dropping the writable releases the last ref → shared freed.
    try dropEnd(&ends, &shared, pair.writable);
    try testing.expectError(Error.InvalidHandle, shared.get(sh));
    try testing.expectError(Error.InvalidHandle, ends.get(pair.writable));
}

test "D-335 unit D-ζ2: future.new pair + reverse drop order frees the shared symmetrically" {
    var ends = try StreamFutureTable.init(testing.allocator);
    defer ends.deinit();
    var shared = SharedTable.init(testing.allocator);
    defer shared.deinit();

    const pair = try newFuturePair(&ends, &shared, null);
    const sh = (try ends.get(pair.readable)).shared;
    try testing.expect((try shared.get(sh)).* == .future);

    // reverse order: writable first, then readable — shared still freed at 0.
    try dropEnd(&ends, &shared, pair.writable);
    try testing.expect((try shared.get(sh)).* == .future); // alive (1 ref left)
    try dropEnd(&ends, &shared, pair.readable);
    try testing.expectError(Error.InvalidHandle, shared.get(sh)); // freed at 0
    // the freed slot is reused by the next pair (free-list).
    const p2 = try newStreamPair(&ends, &shared, 9);
    try testing.expectEqual(@as(?u32, 9), (try shared.get((try ends.get(p2.readable)).shared)).stream.elem_type);
}

test "ADR-0205 D2: timer subtask fires at its deadline + reports the nearest future one" {
    var table = try StreamFutureTable.init(testing.allocator);
    defer table.deinit();
    try testing.expect(!table.hasArmedTimer());
    const early = try table.add(.{ .kind = .subtask, .side = .readable, .elem_type = null, .subtask_state = .started, .deadline_ns = 100 });
    const late = try table.add(.{ .kind = .subtask, .side = .readable, .elem_type = null, .subtask_state = .started, .deadline_ns = 900 });
    try testing.expect(table.hasArmedTimer());

    // now=500: `early` fires (RETURNED + pending SUBTASK event), `late` is the bound.
    try testing.expectEqual(@as(?u64, 900), table.fireDueTimers(500));
    const e = try table.get(early);
    try testing.expectEqual(SubtaskState.returned, e.subtask_state);
    try testing.expectEqual(@as(?u64, null), e.deadline_ns);
    const ev = e.pending_event.?;
    try testing.expectEqual(EventCode.subtask, ev.code);
    try testing.expectEqual(early, ev.index);
    try testing.expectEqual(@as(u32, @intFromEnum(SubtaskState.returned)), ev.payload);
    // A joined set delivers it like any waitable event.
    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(early);
    try testing.expectEqual(EventCode.subtask, ((try ws.poll(&table)).?).code);

    // now=900: the late timer fires too; nothing remains armed.
    try testing.expectEqual(@as(?u64, null), table.fireDueTimers(900));
    try testing.expectEqual(SubtaskState.returned, (try table.get(late)).subtask_state);
    try testing.expect(!table.hasArmedTimer());
}

test "ADR-0205 D2: driveScheduler retries a stalled pass when the ctx reports a fired timer" {
    // Ctx: one task waiting on set 7; the first poll delivers nothing, then
    // waitForTimer "fires" (returns true once) and arms poll_event.
    const TimerCtx = struct {
        polls: u32 = 0,
        timer_fired: bool = false,
        fn invokeTaskCallback(self: *@This(), funcidx: u32, event_code: u32, p1: u32, p2: u32) !u32 {
            _ = self;
            _ = funcidx;
            _ = p1;
            _ = p2;
            std.debug.assert(event_code == @intFromEnum(EventCode.subtask));
            return 0; // EXIT
        }
        fn pollSet(self: *@This(), set_index: u32) !?EventTuple {
            std.debug.assert(set_index == 7);
            self.polls += 1;
            if (!self.timer_fired) return null;
            return .{ .code = .subtask, .index = 3, .payload = @intFromEnum(SubtaskState.returned) };
        }
        fn waitForTimer(self: *@This()) !bool {
            if (self.timer_fired) return false;
            self.timer_fired = true;
            return true;
        }
    };
    var table = try TaskTable.init(testing.allocator);
    defer table.deinit();
    _ = try table.add(.{ .callback_funcidx = 1, .state = .waiting, .set_index = 7 });
    var ctx = TimerCtx{};
    try driveScheduler(&ctx, &table);
    try testing.expectEqual(@as(u32, 2), ctx.polls); // stalled poll + post-timer poll
}
