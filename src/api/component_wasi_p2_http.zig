//! `wasi:http@0.2` — the client half (#564): the `types` client resources and
//! `outgoing-handler.handle`. Rows whose lowering matches 0.3 bind the
//! `http3*` trampolines (`wasi/adapter.zig`); this file holds the rest and the
//! 0.2-only state. The exchange is `component_wasi_ctx.httpExchange`, the one
//! 0.3's `client.send` runs.

const std = @import("std");

const p3http = @import("../wasi/p3_http.zig");
const adapter = @import("../wasi/adapter.zig");
const Caller = @import("../zwasm/caller.zig").Caller;
const linker_mod = @import("../zwasm/linker.zig");
const Linker = linker_mod.Linker;
const defineMapped = linker_mod.defineFuncCtxMapped;

const ctx_mod = @import("component_wasi_ctx.zig");
const WasiP2Ctx = ctx_mod.WasiP2Ctx;
const WasiP2Error = ctx_mod.WasiP2Error;
const Memory = ctx_mod.Memory;
const ctxMemory = ctx_mod.ctxMemory;
const ctxHttpFields = ctx_mod.ctxHttpFields;
const ctxHttpFieldsSelf = ctx_mod.ctxHttpFieldsSelf;
const ctxMintHttpFields = ctx_mod.ctxMintHttpFields;
const ctxHttpRequest = ctx_mod.ctxHttpRequest;
const mapGuestFault = ctx_mod.mapGuestFault;

/// The tables behind the 0.2-only resources; each `HTTP2_*_RT` rep and the
/// body streams' reps index one of them.
pub const State = struct {
    out_bodies: std.ArrayList(OutgoingBody) = .empty,
    futures: std.ArrayList(FutureResponse) = .empty,
    in_bodies: std.ArrayList(IncomingBody) = .empty,
    /// One `taken` flag per future-trailers.
    trailers: std.ArrayList(bool) = .empty,
    free: struct {
        out_bodies: std.ArrayList(u32) = .empty,
        futures: std.ArrayList(u32) = .empty,
        in_bodies: std.ArrayList(u32) = .empty,
        trailers: std.ArrayList(u32) = .empty,
    } = .{},

    pub const OutgoingBody = struct {
        req_rep: u32,
        bytes: std.ArrayList(u8) = .empty,
        stream_taken: bool = false,
        /// The output-stream child is live; WIT traps a finish or drop then.
        stream_live: bool = false,
        finished: bool = false,
    };
    pub const FutureResponse = struct { req_rep: u32, taken: bool = false };
    /// Minted with its incoming-response (`resp_rep`); `consumed` once
    /// `consume` handed it out.
    pub const IncomingBody = struct {
        resp_rep: u32,
        bytes: []u8,
        pos: usize = 0,
        consumed: bool = false,
        stream_taken: bool = false,
        /// The input-stream child is live; WIT traps a finish or drop then.
        stream_live: bool = false,
    };

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (self.out_bodies.items) |*b| b.bytes.deinit(alloc);
        self.out_bodies.deinit(alloc);
        self.futures.deinit(alloc);
        for (self.in_bodies.items) |b| alloc.free(b.bytes);
        self.in_bodies.deinit(alloc);
        self.trailers.deinit(alloc);
        self.free.out_bodies.deinit(alloc);
        self.free.futures.deinit(alloc);
        self.free.in_bodies.deinit(alloc);
        self.free.trailers.deinit(alloc);
    }
};

// error-code ordinals (WIT declaration order).
const EC_HTTP_REQUEST_DENIED: u8 = 15;
const EC_HTTP_REQUEST_METHOD_INVALID: u8 = 18;
const EC_HTTP_REQUEST_URI_INVALID: u8 = 19;
const EC_HTTP_RESPONSE_CONTENT_CODING: u8 = 32;
const EC_INTERNAL_ERROR: u8 = 38;

fn rep(ctx: *WasiP2Ctx, rt: u32, handle: u32, len: usize) WasiP2Error!u32 {
    const r = try ctx.resources.rep(rt, handle);
    if (r >= len) return WasiP2Error.InvalidHandle;
    return r;
}

/// `error-code` at `at`: the disc, plus the option<string> of
/// `internal-error` and `HTTP-response-content-coding` at +8 (the variant's
/// payload offset).
fn writeErrorCode(ctx: *WasiP2Ctx, mem: Memory, at: u32, ordinal: u8, msg: ?[]const u8) WasiP2Error!void {
    try mem.write(at, ordinal);
    if (ordinal != EC_INTERNAL_ERROR and ordinal != EC_HTTP_RESPONSE_CONTENT_CODING) return;
    const s = msg orelse return mem.write(at + 8, @as(u8, 0));
    const p = try ctx.reallocGuest(@intCast(s.len), 1);
    @memcpy(try mem.sliceAt(p, @intCast(s.len)), s);
    try mem.write(at + 8, @as(u8, 1));
    try mem.write(at + 12, p);
    try mem.write(at + 16, @as(u32, @intCast(s.len)));
}

/// `result<own<T>>` (no err payload): disc@0, handle@4.
fn writeHandleResult(mem: Memory, retptr: u32, handle: ?u32) WasiP2Error!void {
    const h = handle orelse return mem.write(retptr, @as(u8, 1));
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, h);
}

// -- fields: the four whose `header-error` is 0.2's payload-free variant --

/// 0.2's `header-error` has no `size-exceeded` / `other`: the model raises
/// the first nowhere and the second only on OOM.
fn headerError(e: p3http.FieldsError) WasiP2Error!u8 {
    return switch (e) {
        error.InvalidSyntax => 0,
        error.Forbidden => 1,
        error.Immutable => 2,
        error.SizeExceeded, error.Other => WasiP2Error.OutOfMemory,
    };
}

/// `result<_, header-error>`: disc@0, err disc@1.
fn writeUnitHeaderResult(mem: Memory, retptr: u32, e: ?p3http.FieldsError) WasiP2Error!void {
    const err = e orelse return mem.write(retptr, @as(u8, 0));
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + 1, try headerError(err));
}

fn http2FieldsFromList(caller: *Caller, entries_ptr: u32, entries_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var fields: p3http.HttpFields = .{};
    var i: u32 = 0;
    while (i < entries_len) : (i += 1) {
        const rec = entries_ptr + i * 16;
        const name = try mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4));
        const value = try mem.sliceAt(try mem.read(u32, rec + 8), try mem.read(u32, rec + 12));
        fields.appendChecked(ctx.alloc, name, value) catch |e| {
            fields.deinit(ctx.alloc);
            // result<own<fields>, header-error>: err disc@4, as the handle.
            try mem.write(retptr, @as(u8, 1));
            return mem.write(retptr + 4, try headerError(e));
        };
    }
    try writeHandleResult(mem, retptr, try ctxMintHttpFields(ctx, fields));
}

fn http2FieldsSet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, values_ptr: u32, values_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    var i: u32 = 0;
    while (i < values_len) : (i += 1) {
        const rec = values_ptr + i * 8;
        const v = try mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4));
        values.append(ctx.alloc, v) catch return WasiP2Error.OutOfMemory;
    }
    fields.set(ctx.alloc, name, values.items) catch |e| return writeUnitHeaderResult(mem, retptr, e);
    try writeUnitHeaderResult(mem, retptr, null);
}

fn http2FieldsDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    fields.delete(ctx.alloc, try mem.sliceAt(name_ptr, name_len)) catch |e| return writeUnitHeaderResult(mem, retptr, e);
    try writeUnitHeaderResult(mem, retptr, null);
}

fn http2FieldsAppend(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    fields.append(ctx.alloc, name, try mem.sliceAt(value_ptr, value_len)) catch |e| return writeUnitHeaderResult(mem, retptr, e);
    try writeUnitHeaderResult(mem, retptr, null);
}

// -- outgoing-request / request-options / outgoing-body --

/// `[constructor]outgoing-request(headers)`: consumes the headers, which
/// the request owns from here on, immutable (WIT `headers`).
fn http2OutgoingRequestNew(caller: *Caller, headers: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    const idx = ctx.addHttpRequest(.{ .headers_rep = headers_rep }) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, idx);
}

fn findOutBody(ctx: *WasiP2Ctx, req_rep: u32) ?*State.OutgoingBody {
    for (ctx.http2.out_bodies.items) |*b| if (b.req_rep == req_rep) return b;
    return null;
}

/// `body() -> result<outgoing-body>`: `ok` once per request.
fn http2OutgoingRequestBody(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req_rep = try rep(ctx, WasiP2Ctx.HTTP_REQUEST_RT, self, ctx.http_requests.items.len);
    if (findOutBody(ctx, req_rep) != null) return writeHandleResult(mem, retptr, null);
    const st = &ctx.http2;
    const idx = ctx_mod.addSlot(State.OutgoingBody, ctx.alloc, &st.out_bodies, &st.free.out_bodies, .{ .req_rep = req_rep }) catch return WasiP2Error.OutOfMemory;
    try writeHandleResult(mem, retptr, try ctx.resources.new(WasiP2Ctx.HTTP2_OUTGOING_BODY_RT, idx));
}

/// `set-*-timeout(option<duration>) -> result`. 0.2 has no immutable
/// request-options: `handle` consumes them.
fn reqoptsSetter(comptime field: []const u8) fn (*Caller, u32, u32, i64) WasiP2Error!u32 {
    return struct {
        fn f(caller: *Caller, self: u32, disc: u32, val: i64) WasiP2Error!u32 {
            const ctx = caller.data(WasiP2Ctx);
            const r = try rep(ctx, WasiP2Ctx.HTTP_REQOPTS_RT, self, ctx.http_reqopts.items.len);
            @field(ctx.http_reqopts.items[r], field) = if (disc != 0) @bitCast(val) else null;
            return 0;
        }
    }.f;
}

/// `write() -> result<output-stream>`: `ok` once per body.
fn http2OutgoingBodyWrite(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_OUTGOING_BODY_RT, self, ctx.http2.out_bodies.items.len);
    const body = &ctx.http2.out_bodies.items[r];
    if (body.stream_taken) return writeHandleResult(mem, retptr, null);
    body.stream_taken = true;
    body.stream_live = true;
    try writeHandleResult(mem, retptr, try ctx.resources.new(WasiP2Ctx.HTTP_BODY_OUT_RT, r));
}

/// `[static]finish(this, option<trailers>) -> result<_, error-code>`.
/// Trailers are consumed and not sent: the std client writes none.
fn http2OutgoingBodyFinish(caller: *Caller, this: u32, trailers_disc: u32, trailers: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_OUTGOING_BODY_RT, this, ctx.http2.out_bodies.items.len);
    if (ctx.http2.out_bodies.items[r].stream_live) return WasiP2Error.Unreachable;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP2_OUTGOING_BODY_RT, this);
    ctx.http2.out_bodies.items[r].finished = true;
    if (trailers_disc != 0) {
        const t = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, trailers);
        (try ctxHttpFields(ctx, t)).deinit(ctx.alloc);
        _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, trailers);
    }
    try mem.write(retptr, @as(u8, 0));
}

/// The output-stream `write` on a request body (`HTTP_BODY_OUT_RT`).
pub fn bodyOutWrite(ctx: *WasiP2Ctx, mem: Memory, body_rep: u32, bytes: []const u8, retptr: u32) WasiP2Error!void {
    if (body_rep >= ctx.http2.out_bodies.items.len) return WasiP2Error.InvalidHandle;
    const body = &ctx.http2.out_bodies.items[body_rep];
    if (body.finished) {
        try mem.write(retptr, @as(u8, 1));
        return mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
    }
    body.bytes.appendSlice(ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0));
}

// -- outgoing-handler.handle + the response side --

/// `handle(request, option<request-options>) -> result<future-incoming-response,
/// error-code>`: consumes both, checks the request can be sent and the grant,
/// and mints the future. Nothing is sent yet (see `http2FutureResponseGet`).
fn http2Handle(caller: *Caller, request: u32, opts_disc: u32, opts: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req_rep = try rep(ctx, WasiP2Ctx.HTTP_REQUEST_RT, request, ctx.http_requests.items.len);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, request);
    const req = try ctxHttpRequest(ctx, req_rep);
    if (opts_disc != 0) {
        req.options_rep = try rep(ctx, WasiP2Ctx.HTTP_REQOPTS_RT, opts, ctx.http_reqopts.items.len);
        _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
    }
    // The result's payload sits at +8 (error-code has u64 cases).
    const failed: ?u8 = if (req.authority == null or !ctx_mod.httpSendable(req))
        EC_HTTP_REQUEST_URI_INVALID
    else if (req.method == .other)
        EC_HTTP_REQUEST_METHOD_INVALID
    else if (ctx_mod.ctxRequireNetwork(ctx)) null else |_| EC_HTTP_REQUEST_DENIED;
    if (failed) |ordinal| {
        try mem.write(retptr, @as(u8, 1));
        return writeErrorCode(ctx, mem, retptr + 8, ordinal, null);
    }
    const st = &ctx.http2;
    const idx = ctx_mod.addSlot(State.FutureResponse, ctx.alloc, &st.futures, &st.free.futures, .{ .req_rep = req_rep }) catch return WasiP2Error.OutOfMemory;
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 8, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, idx));
}

/// `subscribe` on either future: always ready, since `get` blocks.
fn http2FutureSubscribe(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self);
    if (h.rt != WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT and h.rt != WasiP2Ctx.HTTP2_FUTURE_TRAILERS_RT)
        return WasiP2Error.TypeMismatch;
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// `get() -> option<result<result<incoming-response, error-code>>>`, at
/// option@0 / outer result@8 / inner result@16 / payload@24.
///
/// The request is sent HERE, on the first `get`, and the call blocks until
/// the whole response body is read: `handle` only checks and `subscribe` is
/// always ready, so the first `get` is the only point where the request body
/// is known to be complete. A body taken but not finished by then fails the
/// request. Later `get`s answer `some(err)`.
fn http2FutureResponseGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, self, ctx.http2.futures.items.len);
    const fut = &ctx.http2.futures.items[r];
    try mem.write(retptr, @as(u8, 1));
    if (fut.taken) return mem.write(retptr + 8, @as(u8, 1));
    fut.taken = true;
    try mem.write(retptr + 8, @as(u8, 0));
    const req_rep = fut.req_rep;
    const req = try ctxHttpRequest(ctx, req_rep);
    var body: []u8 = &.{};
    // The request is spent whatever the outcome: its bytes go with it.
    defer releaseRequest(ctx, req_rep);
    if (findOutBody(ctx, req_rep)) |b| {
        if (!b.finished) {
            try mem.write(retptr + 16, @as(u8, 1));
            return writeErrorCode(ctx, mem, retptr + 24, EC_INTERNAL_ERROR, "body not finished");
        }
        body = b.bytes.items;
    }
    const ex = ctx_mod.httpExchange(ctx, req, body, null) catch |e| switch (e) {
        error.HttpFailed => {
            try mem.write(retptr + 16, @as(u8, 1));
            return writeErrorCode(ctx, mem, retptr + 24, EC_INTERNAL_ERROR, null);
        },
        error.HttpResponseContentCoding => {
            try mem.write(retptr + 16, @as(u8, 1));
            return writeErrorCode(ctx, mem, retptr + 24, EC_HTTP_RESPONSE_CONTENT_CODING, null);
        },
        else => |oe| return oe,
    };
    // 0.2 `future-trailers` answers none (#704 left it here).
    if (ex.trailers) |t| ctx.alloc.free(t);
    const resp_idx = blk: {
        errdefer ctx.alloc.free(ex.body);
        const i = ctx.addHttpResponse(.{ .status = ex.status, .headers_rep = ex.headers_rep }) catch return WasiP2Error.OutOfMemory;
        const st = &ctx.http2;
        _ = ctx_mod.addSlot(State.IncomingBody, ctx.alloc, &st.in_bodies, &st.free.in_bodies, .{ .resp_rep = i, .bytes = ex.body }) catch return WasiP2Error.OutOfMemory;
        break :blk i;
    };
    try mem.write(retptr + 16, @as(u8, 0));
    try mem.write(retptr + 24, try ctx.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, resp_idx));
}

/// `consume() -> result<incoming-body>`: `ok` once per response.
fn http2IncomingResponseConsume(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const resp_rep = try rep(ctx, WasiP2Ctx.HTTP_RESPONSE_RT, self, ctx.http_responses.items.len);
    for (ctx.http2.in_bodies.items, 0..) |*b, i| {
        if (b.resp_rep != resp_rep) continue;
        if (b.consumed) break;
        b.consumed = true;
        return writeHandleResult(mem, retptr, try ctx.resources.new(WasiP2Ctx.HTTP2_INCOMING_BODY_RT, @intCast(i)));
    }
    try writeHandleResult(mem, retptr, null);
}

/// `stream() -> result<input-stream>`: `ok` once per body.
fn http2IncomingBodyStream(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_INCOMING_BODY_RT, self, ctx.http2.in_bodies.items.len);
    const body = &ctx.http2.in_bodies.items[r];
    if (body.stream_taken) return writeHandleResult(mem, retptr, null);
    body.stream_taken = true;
    body.stream_live = true;
    try writeHandleResult(mem, retptr, try ctx.resources.new(WasiP2Ctx.HTTP_BODY_IN_RT, r));
}

/// `[static]finish(this) -> future-trailers`: consumes the body and frees
/// its bytes.
fn http2IncomingBodyFinish(caller: *Caller, this: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_INCOMING_BODY_RT, this, ctx.http2.in_bodies.items.len);
    if (ctx.http2.in_bodies.items[r].stream_live) return WasiP2Error.Unreachable;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP2_INCOMING_BODY_RT, this);
    releaseInBody(ctx, r);
    const st = &ctx.http2;
    const idx = ctx_mod.addSlot(bool, ctx.alloc, &st.trailers, &st.free.trailers, false) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_TRAILERS_RT, idx);
}

fn releaseInBody(ctx: *WasiP2Ctx, r: u32) void {
    const body = &ctx.http2.in_bodies.items[r];
    ctx.alloc.free(body.bytes);
    body.bytes = &.{};
    body.pos = 0;
}

/// `get() -> option<result<result<option<trailers>, error-code>>>`: 0.2
/// does not surface a received trailer section, so `some(ok(ok(none)))`,
/// then `some(err)`.
fn http2FutureTrailersGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const r = try rep(ctx, WasiP2Ctx.HTTP2_FUTURE_TRAILERS_RT, self, ctx.http2.trailers.items.len);
    try mem.write(retptr, @as(u8, 1));
    if (ctx.http2.trailers.items[r]) return mem.write(retptr + 8, @as(u8, 1));
    ctx.http2.trailers.items[r] = true;
    try mem.write(retptr + 8, @as(u8, 0));
    try mem.write(retptr + 16, @as(u8, 0));
    try mem.write(retptr + 24, @as(u8, 0));
}

/// `http-error-code(borrow<io-error>) -> option<error-code>`: none, since
/// the body streams report `closed` and mint no io-error.
fn http2HttpErrorCode(caller: *Caller, err: u32, retptr: u32) WasiP2Error!void {
    _ = err;
    try (try ctxMemory(caller)).write(retptr, @as(u8, 0));
}

/// The input-stream `read` / `blocking-read` on a response body
/// (`HTTP_BODY_IN_RT`): up to `len` bytes, then `closed` once drained.
pub fn bodyInRead(ctx: *WasiP2Ctx, mem: Memory, body_rep: u32, len: u64, retptr: u32) WasiP2Error!void {
    if (body_rep >= ctx.http2.in_bodies.items.len) return WasiP2Error.InvalidHandle;
    const body = &ctx.http2.in_bodies.items[body_rep];
    const rest = body.bytes[body.pos..];
    if (rest.len == 0 and len != 0) {
        try mem.write(retptr, @as(u8, 1));
        return mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
    }
    const n: u32 = @intCast(@min(len, rest.len));
    const p: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    if (n != 0) @memcpy(try mem.sliceAt(p, n), rest[0..n]);
    body.pos += n;
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, p);
    try mem.write(retptr + 8, n);
}

/// Free the request body of `req_rep` once no send can use it: after `get`,
/// or when its request or future is dropped unsent.
pub fn releaseRequest(ctx: *WasiP2Ctx, req_rep: u32) void {
    if (findOutBody(ctx, req_rep)) |b| b.bytes.clearAndFree(ctx.alloc);
}

/// Free the body of a response dropped before `consume` handed it out.
pub fn releaseResponse(ctx: *WasiP2Ctx, resp_rep: u32) void {
    for (ctx.http2.in_bodies.items, 0..) |b, i| {
        if (b.resp_rep == resp_rep and !b.consumed) releaseInBody(ctx, @intCast(i));
    }
}

/// Drop of a 0.2-only resource (`p2ResourceDrop`'s arm). A body dropped
/// with its stream child live traps, as WIT says; a stream drop ends that.
pub fn dropResource(ctx: *WasiP2Ctx, rt: u32, r: u32) WasiP2Error!void {
    const st = &ctx.http2;
    switch (rt) {
        WasiP2Ctx.HTTP_BODY_OUT_RT => if (r < st.out_bodies.items.len) {
            st.out_bodies.items[r].stream_live = false;
        },
        WasiP2Ctx.HTTP_BODY_IN_RT => if (r < st.in_bodies.items.len) {
            st.in_bodies.items[r].stream_live = false;
        },
        WasiP2Ctx.HTTP2_OUTGOING_BODY_RT => if (r < st.out_bodies.items.len) {
            const b = &st.out_bodies.items[r];
            if (b.stream_live) return WasiP2Error.Unreachable;
            // Unfinished = corrupted: no send will use the bytes.
            if (!b.finished) b.bytes.clearAndFree(ctx.alloc);
        },
        WasiP2Ctx.HTTP2_INCOMING_BODY_RT => if (r < st.in_bodies.items.len) {
            if (st.in_bodies.items[r].stream_live) return WasiP2Error.Unreachable;
            releaseInBody(ctx, r);
        },
        WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT => if (r < st.futures.items.len and !st.futures.items[r].taken) {
            releaseRequest(ctx, st.futures.items[r].req_rep);
        },
        else => {},
    }
}

const binds = .{
    .{ adapter.P2Op.http2_fields_from_list, fn (*Caller, u32, u32, u32) WasiP2Error!void, http2FieldsFromList },
    .{ adapter.P2Op.http2_fields_set, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http2FieldsSet },
    .{ adapter.P2Op.http2_fields_delete, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http2FieldsDelete },
    .{ adapter.P2Op.http2_fields_append, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http2FieldsAppend },
    .{ adapter.P2Op.http2_outgoing_request_new, fn (*Caller, u32) WasiP2Error!u32, http2OutgoingRequestNew },
    .{ adapter.P2Op.http2_outgoing_request_body, fn (*Caller, u32, u32) WasiP2Error!void, http2OutgoingRequestBody },
    .{ adapter.P2Op.http2_reqopts_connect_set, fn (*Caller, u32, u32, i64) WasiP2Error!u32, reqoptsSetter("connect_timeout_ns") },
    .{ adapter.P2Op.http2_reqopts_first_byte_set, fn (*Caller, u32, u32, i64) WasiP2Error!u32, reqoptsSetter("first_byte_timeout_ns") },
    .{ adapter.P2Op.http2_reqopts_between_bytes_set, fn (*Caller, u32, u32, i64) WasiP2Error!u32, reqoptsSetter("between_bytes_timeout_ns") },
    .{ adapter.P2Op.http2_outgoing_body_write, fn (*Caller, u32, u32) WasiP2Error!void, http2OutgoingBodyWrite },
    .{ adapter.P2Op.http2_outgoing_body_finish, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http2OutgoingBodyFinish },
    .{ adapter.P2Op.http2_handle, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http2Handle },
    .{ adapter.P2Op.http2_future_subscribe, fn (*Caller, u32) WasiP2Error!u32, http2FutureSubscribe },
    .{ adapter.P2Op.http2_future_response_get, fn (*Caller, u32, u32) WasiP2Error!void, http2FutureResponseGet },
    .{ adapter.P2Op.http2_incoming_response_consume, fn (*Caller, u32, u32) WasiP2Error!void, http2IncomingResponseConsume },
    .{ adapter.P2Op.http2_incoming_body_stream, fn (*Caller, u32, u32) WasiP2Error!void, http2IncomingBodyStream },
    .{ adapter.P2Op.http2_incoming_body_finish, fn (*Caller, u32) WasiP2Error!u32, http2IncomingBodyFinish },
    .{ adapter.P2Op.http2_future_trailers_get, fn (*Caller, u32, u32) WasiP2Error!void, http2FutureTrailersGet },
    .{ adapter.P2Op.http2_http_error_code, fn (*Caller, u32, u32) WasiP2Error!void, http2HttpErrorCode },
};

/// Bind one `http2_*` op (the classifier's arm in `component_wasi_p2.zig`).
pub fn defineHttp2Op(lk: *Linker, ns: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    inline for (binds) |b| {
        if (op == b[0]) return defineMapped(lk, ns, name, ctx, b[1], b[2], mapGuestFault);
    }
    return error.UnsupportedWasiImport;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;
const wasi_host = @import("../wasi/host.zig");
const Engine = @import("../zwasm/engine.zig").Engine;
const p2 = @import("component_wasi_p2.zig");
const HttpEndpoint = @import("component_http_echo.zig").HttpEndpoint;

/// Run `test/component/wasip2_http/http-get.wasm` in `mode` and return its
/// stdout. `serve` starts the echo endpoint; without it `HTTP_ENDPOINT`
/// names a port nothing is sent to.
fn runHttpGuest(mode: []const u8, allow_network: bool, serve: bool) ![]u8 {
    const r = try runHttpGuestOutcome(mode, allow_network, serve, null);
    if (r.err) |e| {
        testing.allocator.free(r.out);
        return e;
    }
    return r.out;
}

const Outcome = struct { out: []u8, err: ?anyerror };

/// `runHttpGuest` that keeps the stdout of a run that traps, and hands the
/// 0.2 state to `inspect` before the component is torn down.
fn runHttpGuestOutcome(mode: []const u8, allow_network: bool, serve: bool, inspect: ?*const fn (*const State) anyerror!void) !Outcome {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip2_http/http-get.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.allow_network = allow_network;
    var endpoint: ?*HttpEndpoint = null;
    defer if (endpoint) |e| e.stop();
    var addr_buf: [32]u8 = undefined;
    const addr = if (serve) blk: {
        endpoint = try HttpEndpoint.start(io, null);
        break :blk try std.mem.print(&addr_buf, "127.0.0.1:{d}", .{endpoint.?.port});
    } else "127.0.0.1:9";
    try host.setEnvs(&.{"HTTP_ENDPOINT"}, &.{addr});
    try host.setArgs(&.{ "http-get", mode });
    var capture: std.ArrayList(u8) = .empty;
    errdefer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;
    var built = try p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    const run_err: ?anyerror = if (p2.runWasiP2MainBuilt(&built)) null else |e| e;
    if (inspect) |f| try f(&built.ctx.http2);
    return .{ .out = try capture.toOwnedSlice(testing.allocator), .err = run_err };
}

test "wasi:http@0.2: a POST through outgoing-handler.handle reads the echoed body, status and trailers" {
    const out = try runHttpGuest("post", true, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("status: 200\nbody: ping\ntrailers: Some(Ok(Ok(false)))\n", out);
}

test "wasi:http@0.2: without the network grant handle returns HTTP-request-denied" {
    const out = try runHttpGuest("get", false, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("handle: ErrorCode::HttpRequestDenied\n", out);
}

test "wasi:http@0.2: handle refuses a scheme other than http rather than send it in the clear" {
    const out = try runHttpGuest("https", true, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("handle: ErrorCode::HttpRequestUriInvalid\n", out);
}

test "wasi:http@0.2: a second future-incoming-response.get is some(err)" {
    const out = try runHttpGuest("twice", true, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("status: 200\nbody: \ntrailers: Some(Ok(Ok(false)))\nsecond get: Some(true)\n", out);
}

test "wasi:http@0.2: a request body taken and not finished fails the request at get" {
    const out = try runHttpGuest("unfinished", true, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("get: ErrorCode::InternalError(Some(\"body not finished\"))\n", out);
}

test "wasi:http@0.2: fields errors land at 0.2's header-error offsets" {
    const out = try runHttpGuest("fields", false, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\set: Err(HeaderError::InvalidSyntax)
        \\append: Err(HeaderError::InvalidSyntax)
        \\delete: Err(HeaderError::InvalidSyntax)
        \\from-list: Some(HeaderError::InvalidSyntax)
        \\entries: [("ok", [118])]
        \\immutable: Err(HeaderError::Immutable)
        \\
    , out);
}

test "wasi:http@0.2: a GET and a DELETE send the body the guest wrote" {
    for ([_][]const u8{ "get-body", "delete-body" }) |mode| {
        const out = try runHttpGuest(mode, true, true);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("status: 200\nbody: ping\ntrailers: Some(Ok(Ok(false)))\n", out);
    }
}

test "wasi:http@0.2: finishing a body while its stream child is live traps (WIT `finish`)" {
    const in = try runHttpGuestOutcome("live-in", true, true, null);
    defer testing.allocator.free(in.out);
    try testing.expect(in.err != null);
    try testing.expectEqualStrings("read: Ok(Ok(\"pi\"))\n", in.out);
    const out = try runHttpGuestOutcome("live-out", true, false, null);
    defer testing.allocator.free(out.out);
    try testing.expect(out.err != null);
    try testing.expectEqualStrings("", out.out);
}

fn expectBodiesReleased(st: *const State) anyerror!void {
    try testing.expectEqual(@as(usize, 4), st.out_bodies.items.len);
    for (st.out_bodies.items) |b| try testing.expectEqual(@as(usize, 0), b.bytes.capacity);
    try testing.expectEqual(@as(usize, 1), st.in_bodies.items.len);
    try testing.expectEqual(@as(usize, 0), st.in_bodies.items[0].bytes.len);
}

test "wasi:http@0.2: an abandoned upload or an unconsumed response frees its body" {
    const r = try runHttpGuestOutcome("abandon", true, true, &expectBodiesReleased);
    defer testing.allocator.free(r.out);
    try testing.expectEqual(@as(?anyerror, null), r.err);
    try testing.expectEqualStrings("status: 200\n", r.out);
}

test "wasi:http@0.2: a response's trailer section is freed, since future-trailers answers none (#704)" {
    const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = threaded.io();
    host.allow_network = true;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.mem_instance = &inst;
    var caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &ctx };

    const ep = try RawEndpoint.start(host.io.?, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\npayload\r\n0\r\nx-checksum: abc123\r\n\r\n");
    defer ep.destroy();
    const req_rep = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(.{}), .scheme = .http, .authority = try ctx.alloc.print("127.0.0.1:{d}", .{ep.port}) });
    try ctx.http2.futures.append(ctx.alloc, .{ .req_rep = req_rep });
    try http2FutureResponseGet(&caller, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, 0), 0);
    ep.stop();
    const mem = try ctx.memory();
    // some(ok(ok(response))): the exchange ran; the testing allocator holds
    // the section to account at deinit.
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &.{ try mem.read(u8, 0), try mem.read(u8, 8), try mem.read(u8, 16) });
}

test "wasi:http@0.2: a 3xx reaches the guest as the response, and the host sends no second request (#711)" {
    const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    const io = threaded.io();
    host.io = io;
    host.allow_network = true;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.mem_instance = &inst;
    var caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &ctx };
    const mem = try ctx.memory();

    var away_buf: [64]u8 = undefined;
    const away = try std.mem.print(&away_buf, "https://127.0.0.1:{d}/", .{try HttpEndpoint.reserveClosedPort(io)});
    const Case = struct { status: u16, location: []const u8, body: []const u8 };
    const cases = [_]Case{
        .{ .status = 301, .location = away, .body = "moved" },
        .{ .status = 302, .location = away, .body = "moved" },
        .{ .status = 303, .location = away, .body = "moved" },
        .{ .status = 307, .location = away, .body = "moved" },
        .{ .status = 308, .location = away, .body = "moved" },
        // Back to the endpoint itself, where a second request would land.
        .{ .status = 302, .location = "/again", .body = "moved" },
        .{ .status = 304, .location = away, .body = "" },
    };
    for (cases) |c| {
        var resp_buf: [256]u8 = undefined;
        const response = try std.mem.print(&resp_buf, "HTTP/1.1 {d} Redirect\r\nLocation: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ c.status, c.location, c.body.len, c.body });
        const ep = try RawEndpoint.start(io, response);
        defer ep.destroy();
        const req_rep = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(.{}), .scheme = .http, .authority = try ctx.alloc.print("127.0.0.1:{d}", .{ep.port}) });
        try ctx.http2.futures.append(ctx.alloc, .{ .req_rep = req_rep });
        try http2FutureResponseGet(&caller, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, @intCast(ctx.http2.futures.items.len - 1)), 0);
        ep.stop();

        try testing.expectEqual(@as(u32, 1), ep.connections);
        try testing.expect(std.mem.startsWith(u8, ep.request(), "GET / HTTP/1.1\r\n"));
        try testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &.{ try mem.read(u8, 0), try mem.read(u8, 8), try mem.read(u8, 16) });
        const resp_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, try mem.read(u32, 24));
        const resp = ctx.http_responses.items[resp_rep];
        try testing.expectEqual(c.status, resp.status);
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(testing.allocator);
        try ctx.http_fields.items[resp.headers_rep].get(&values, testing.allocator, "location");
        try testing.expectEqual(@as(usize, 1), values.items.len);
        try testing.expectEqualStrings(c.location, values.items[0]);
        const body = for (ctx.http2.in_bodies.items) |b| {
            if (b.resp_rep == resp_rep) break b.bytes;
        } else return error.TestUnexpectedResult;
        try testing.expectEqualStrings(c.body, body);
    }
}

test "wasi:http@0.2: the request on the wire carries host and the guest's headers, each once, and none of the client's own (#711)" {
    const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    const io = threaded.io();
    host.io = io;
    host.allow_network = true;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.mem_instance = &inst;
    var caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &ctx };
    const mem = try ctx.memory();

    const Case = struct { headers: []const [2][]const u8, wire: []const u8 };
    const cases = [_]Case{
        .{ .headers = &.{}, .wire = "" },
        .{ .headers = &.{ .{ "user-agent", "guest-ua" }, .{ "accept-encoding", "br" } }, .wire = "user-agent: guest-ua\r\naccept-encoding: br\r\n" },
    };
    for (cases) |c| {
        const ep = try RawEndpoint.start(io, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        defer ep.destroy();
        var fields: p3http.HttpFields = .{};
        for (c.headers) |h| try fields.appendPair(ctx.alloc, h[0], h[1]);
        const req_rep = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(fields), .scheme = .http, .authority = try ctx.alloc.print("127.0.0.1:{d}", .{ep.port}) });
        try ctx.http2.futures.append(ctx.alloc, .{ .req_rep = req_rep });
        try http2FutureResponseGet(&caller, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, @intCast(ctx.http2.futures.items.len - 1)), 0);
        ep.stop();

        try testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &.{ try mem.read(u8, 0), try mem.read(u8, 8), try mem.read(u8, 16) });
        var want_buf: [256]u8 = undefined;
        try testing.expectEqualStrings(try std.mem.print(&want_buf, "GET / HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\n{s}\r\n", .{ ep.port, c.wire }), ep.request());
    }
}

test "wasi:http@0.2: a response std would decode reaches the guest undecoded, one std cannot parse fails, and neither waits for the peer to close (#738)" {
    const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    const io = threaded.io();
    host.io = io;
    host.allow_network = true;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.mem_instance = &inst;
    var caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &ctx };
    const mem = try ctx.memory();

    // `coding` set: the response reaches the guest; else it fails with `code`.
    const Case = struct { head: []const u8, coding: ?[]const u8 = null, code: u8 = 0 };
    const cases = [_]Case{
        .{ .head = "Content-Encoding: zstd\r\n", .coding = "zstd" },
        .{ .head = "Content-Encoding: compress\r\n", .coding = "compress" },
        .{ .head = "Content-Encoding: br\r\n", .code = EC_HTTP_RESPONSE_CONTENT_CODING },
        .{ .head = ": x\r\n", .code = EC_INTERNAL_ERROR },
    };
    for (cases) |c| {
        var resp_buf: [128]u8 = undefined;
        const response = try std.mem.print(&resp_buf, "HTTP/1.1 200 OK\r\n{s}Content-Length: 2\r\n\r\nhi", .{c.head});
        const ep = try RawEndpoint.startHolding(io, response);
        defer ep.destroy();
        const req_rep = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(.{}), .scheme = .http, .authority = try ctx.alloc.print("127.0.0.1:{d}", .{ep.port}) });
        try ctx.http2.futures.append(ctx.alloc, .{ .req_rep = req_rep });
        // The payload's option disc, so a get that leaves it reads as some.
        try mem.write(32, @as(u8, 0xff));
        try http2FutureResponseGet(&caller, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, @intCast(ctx.http2.futures.items.len - 1)), 0);
        ep.stop();

        try testing.expect(!ep.held_out);
        const coding = c.coding orelse {
            // some(ok(err(code(none)))).
            try testing.expectEqualSlices(u8, &.{ 1, 0, 1, c.code, 0 }, &.{ try mem.read(u8, 0), try mem.read(u8, 8), try mem.read(u8, 16), try mem.read(u8, 24), try mem.read(u8, 32) });
            continue;
        };
        try testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, &.{ try mem.read(u8, 0), try mem.read(u8, 8), try mem.read(u8, 16) });
        const resp_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, try mem.read(u32, 24));
        const resp = ctx.http_responses.items[resp_rep];
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(testing.allocator);
        try ctx.http_fields.items[resp.headers_rep].get(&values, testing.allocator, "content-encoding");
        try testing.expectEqual(@as(usize, 1), values.items.len);
        try testing.expectEqualStrings(coding, values.items[0]);
        const body = for (ctx.http2.in_bodies.items) |b| {
            if (b.resp_rep == resp_rep) break b.bytes;
        } else return error.TestUnexpectedResult;
        try testing.expectEqualStrings("hi", body);
    }
}

test "wasi:http@0.2: a request with no scheme is refused at handle, and is not sent by a get that skips handle" {
    const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = threaded.io();
    host.allow_network = true;
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    var inst = try lk.instantiate(&mod, .{});
    defer inst.deinit();
    ctx.mem_instance = &inst;
    var caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &ctx };
    const mem = try ctx.memory();

    const ep = try RawEndpoint.start(host.io.?, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer ep.destroy();
    const authority = "127.0.0.1:{d}";
    const handled = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(.{}), .authority = try ctx.alloc.print(authority, .{ep.port}) });
    try http2Handle(&caller, try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, handled), 0, 0, 0);
    try testing.expectEqualSlices(u8, &.{ 1, EC_HTTP_REQUEST_URI_INVALID }, &.{ try mem.read(u8, 0), try mem.read(u8, 8) });

    const req_rep = try ctx.addHttpRequest(.{ .headers_rep = try ctx.addHttpFields(.{}), .authority = try ctx.alloc.print(authority, .{ep.port}) });
    try ctx.http2.futures.append(ctx.alloc, .{ .req_rep = req_rep });
    try http2FutureResponseGet(&caller, try ctx.resources.new(WasiP2Ctx.HTTP2_FUTURE_RESPONSE_RT, 0), 64);
    ep.stop();
    // some(ok(err(internal-error))), and nothing reached the endpoint.
    try testing.expectEqualSlices(u8, &.{ 1, 0, 1, EC_INTERNAL_ERROR }, &.{ try mem.read(u8, 64), try mem.read(u8, 72), try mem.read(u8, 80), try mem.read(u8, 88) });
    try testing.expectEqualStrings("", ep.request());
}
