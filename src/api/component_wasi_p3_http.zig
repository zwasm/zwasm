// FILE-SIZE-EXEMPT: the wasi:http 0.3 host (the `types` resources, `client.send`, the two hook targets) and its tests, one WIT package; split out of component_wasi_p3_host.zig, where it was the growth (ADR-0207 (c)).
//! `wasi:http@0.3` host: the `types` resources and `client.send`
//! (ADR-0207 (c)). The data model is `wasi/p3_http.zig`; the exchange is
//! `component_wasi_ctx.httpExchange`, which 0.2's `outgoing-handler.handle`
//! runs too. The substrate reaches `http3DropTransferredEnd` and
//! `http3ResolveSent` through `component_wasi_p3_host.hooksTable`.

const std = @import("std");
const dbg = @import("../support/dbg.zig");

const p3http = @import("../wasi/p3_http.zig");
const adapter = @import("../wasi/adapter.zig");
const async_mod = @import("../feature/component/async.zig");
const Caller = @import("../zwasm/caller.zig").Caller;
const linker_mod = @import("../zwasm/linker.zig");
const Linker = linker_mod.Linker;
const defineMapped = linker_mod.defineFuncCtxMapped;

const ctx_mod = @import("component_wasi_ctx.zig");
const WasiP2Ctx = ctx_mod.WasiP2Ctx;
const WasiP2Error = ctx_mod.WasiP2Error;
const Memory = ctx_mod.Memory;
const PendingClientSend = ctx_mod.PendingClientSend;
const ctxMemory = ctx_mod.ctxMemory;
const ctxRequireNetwork = ctx_mod.ctxRequireNetwork;
const ctxHttpFields = ctx_mod.ctxHttpFields;
const ctxHttpFieldsSelf = ctx_mod.ctxHttpFieldsSelf;
const ctxMintHttpFields = ctx_mod.ctxMintHttpFields;
const ctxHttpRequest = ctx_mod.ctxHttpRequest;
const mapGuestFault = ctx_mod.mapGuestFault;

// ============================================================
// wasi:http/types@0.3.0 (ADR-0205 phase D)
// ============================================================
// The `fields` resource: data model in src/wasi/p3_http.zig; these
// trampolines marshal guest memory. Canonical shapes: field-name = string
// (ptr,len), field-value = list<u8> (ptr,len), entries/copy-all elems =
// (name_ptr, name_len, val_ptr, val_len) 16 B; `result<_, header-error>` =
// disc u8@0, err variant disc u8@4, `other`'s option<string> none u8@8.

/// `result<_, header-error>` (ok = null).
fn writeHeaderErrResult(mem: Memory, retptr: u32, e: ?p3http.FieldsError) WasiP2Error!void {
    if (e) |err| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, p3http.headerErrorOrdinal(err));
        try mem.write(retptr + 8, @as(u8, 0)); // other's option<string>: none
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3FieldsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctxMintHttpFields(ctx, .{});
}

fn http3FieldsFromList(caller: *Caller, entries_ptr: u32, entries_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var fields: p3http.HttpFields = .{};
    var i: u32 = 0;
    while (i < entries_len) : (i += 1) {
        const rec = entries_ptr + i * 16;
        const name = try mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4));
        const value = try mem.sliceAt(try mem.read(u32, rec + 8), try mem.read(u32, rec + 12));
        if (dbg.on("async.host")) std.debug.print("[host] fields.from-list [{d}] name='{s}' value='{s}'\n", .{ i, name, value });
        fields.appendChecked(ctx.alloc, name, value) catch |e| {
            fields.deinit(ctx.alloc);
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, p3http.headerErrorOrdinal(e));
            try mem.write(retptr + 8, @as(u8, 0));
            return;
        };
    }
    const handle = try ctxMintHttpFields(ctx, fields);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// Marshal one nested byte blob (string / list<u8>) into its OWN guest
/// allocation. Nested lists must NOT share the outer table's block: the
/// guest's lift takes per-element buffer OWNERSHIP (Vec::from_raw_parts)
/// and frees the outer table separately — a packed single block gets
/// recycled by the guest allocator mid-lift, corrupting the data. A
/// zero-length blob writes a 4-aligned dangling pointer (the guest never
/// dereferences or frees a capacity-0 buffer).
fn http3AllocBlob(ctx: *WasiP2Ctx, mem: Memory, bytes: []const u8) WasiP2Error!u32 {
    if (bytes.len == 0) return 4;
    const p = try ctx.reallocGuest(@intCast(bytes.len), 1);
    const dest = try mem.sliceAt(p, @intCast(bytes.len));
    @memcpy(dest, bytes);
    return p;
}

/// Marshal `list<field-value>`: the elem table is one allocation, each
/// value another (see `http3AllocBlob`); (ptr,len) lands at `retptr`.
fn http3WriteValueList(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, values: []const []const u8) WasiP2Error!void {
    const base = if (values.len == 0) 4 else try ctx.reallocGuestArray(values.len, 8, 4);
    for (values, 0..) |v, i| {
        const p = try http3AllocBlob(ctx, mem, v);
        const rec = base + @as(u32, @intCast(i * 8));
        try mem.write(rec, p);
        try mem.write(rec + 4, @as(u32, @intCast(v.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(values.len)));
}

fn http3FieldsGet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    fields.get(&values, ctx.alloc, name) catch return WasiP2Error.OutOfMemory;
    try http3WriteValueList(ctx, mem, retptr, values.items);
}

fn http3FieldsHas(caller: *Caller, self: u32, name_ptr: u32, name_len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    return @intFromBool(fields.has(name));
}

fn http3FieldsSet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, values_ptr: u32, values_len: u32, retptr: u32) WasiP2Error!void {
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
    fields.set(ctx.alloc, name, values.items) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    fields.delete(ctx.alloc, name) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsGetAndDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |v| ctx.alloc.free(v);
        out.deinit(ctx.alloc);
    }
    fields.getAndDelete(&out, ctx.alloc, name) catch |e| {
        // result<list<field-value>, header-error> err: disc@0, err disc@4,
        // other's option none@8 (same offsets as the unit form).
        return writeHeaderErrResult(mem, retptr, e);
    };
    try mem.write(retptr, @as(u8, 0));
    try http3WriteValueList(ctx, mem, retptr + 4, out.items);
}

fn http3FieldsAppend(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    const name = try mem.sliceAt(name_ptr, name_len);
    const value = try mem.sliceAt(value_ptr, value_len);
    fields.append(ctx.alloc, name, value) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsCopyAll(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try ctxHttpFieldsSelf(ctx, self);
    // Elem table = one allocation; each name string and value list its own
    // (per-element buffer ownership — see http3AllocBlob).
    const items = fields.entries.items;
    const base = if (items.len == 0) 4 else try ctx.reallocGuestArray(items.len, 16, 4);
    for (items, 0..) |p, i| {
        const np = try http3AllocBlob(ctx, mem, p.name);
        const vp = try http3AllocBlob(ctx, mem, p.value);
        const rec = base + @as(u32, @intCast(i * 16));
        try mem.write(rec, np);
        try mem.write(rec + 4, @as(u32, @intCast(p.name.len)));
        try mem.write(rec + 8, vp);
        try mem.write(rec + 12, @as(u32, @intCast(p.value.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(items.len)));
}

fn http3FieldsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = try ctxHttpFieldsSelf(ctx, self);
    var copy: p3http.HttpFields = .{};
    src.cloneInto(ctx.alloc, &copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    return ctxMintHttpFields(ctx, copy);
}

// -- request / response / request-options (ADR-0205 phase D-2) --

/// A future the host mints but never writes (`response.new`'s, or a trailers
/// future the host answers through `host_trailer_ok_futures`) keeps only the
/// guest's end; holding the writable would keep both for the instance's
/// life. The raw drop leaves the rendezvous un-DROPPED, so a read waits.
fn releaseHostWritable(ctx: *WasiP2Ctx, writable: u32) WasiP2Error!void {
    try async_mod.dropEnd(&ctx.streams, &ctx.shared, writable);
}

/// Release a stream/future end TRANSFERRED into a request/response at
/// `new` time (the guest's own handle moved to the host): the peer must
/// observe DROPPED or its writer task never completes.
pub fn http3DropTransferredEnd(ctx: *WasiP2Ctx, handle: u32) void {
    if (handle == 0) return;
    _ = ctx.host_result_futures.remove(handle);
    _ = ctx.pending_reads.remove(handle);
    // A stale end has no shared; the drop below reports nothing for it either.
    const shared = if (ctx.streams.get(handle)) |end| end.shared else |_| 0;
    ctx_mod.scrubHttpRoles(ctx, handle, shared);
    // EXEMPT-FALLBACK: destructor — a stale/already-dropped end is benign (D-568)
    async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, handle) catch {};
}

fn http3RequestSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequest {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, self);
    if (rep >= ctx.http_requests.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_requests.items[rep];
}

fn http3ReqoptsSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequestOptions {
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, self);
    if (rep >= ctx.http_reqopts.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_reqopts.items[rep];
}

fn http3ResponseSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpResponse {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, self);
    if (rep >= ctx.http_responses.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_responses.items[rep];
}

/// `request.new` (headers, option<stream<u8>>, trailers future,
/// option<own<request-options>>, retptr) — consumes the headers (and
/// options) own handles: their storage now belongs to the request and both
/// become immutable. Returns tuple<request, future<result<_, error-code>>>
/// at retptr; the transmission future (`sent`) resolves at `http3ResolveSent`.
fn http3RequestNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, opts_disc: u32, opts: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    var options_rep: ?u32 = null;
    if (opts_disc != 0) {
        const orep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        (try http3ReqoptsSelf(ctx, opts)).immutable = true;
        _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        options_rep = orep;
    }
    const idx = ctx.addHttpRequest(.{
        .headers_rep = headers_rep,
        .options_rep = options_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    const req = &ctx.http_requests.items[idx];
    req.sent_readable = fut.readable;
    req.sent_writable = fut.writable;
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

/// Resolve `req`'s `sent` future once (null = ok, else the wasi:http
/// error-code ordinal) and release the host's writable, as wasmtime does on
/// a send's end and on a drop unsent. A read already parked completes in
/// place; a later one is answered from `host_sent_futures`. A reader that
/// dropped first leaves only the release.
pub fn http3ResolveSent(ctx: *WasiP2Ctx, req: *p3http.HttpRequest, outcome: ?u8) WasiP2Error!void {
    const w = req.sent_writable;
    if (w == 0) return;
    req.sent_writable = 0;
    return resolveSentEnds(ctx, req.sent_readable, w, outcome);
}

fn resolveSentEnds(ctx: *WasiP2Ctx, r: u32, w: u32, outcome: ?u8) WasiP2Error!void {
    const f = switch ((try ctx.shared.get((try ctx.streams.get(w)).shared)).*) {
        .future => |*f| f,
        .stream, .subtask => return WasiP2Error.InvalidHandle,
    };
    if (!f.dropped) {
        if (ctx.pending_reads.fetchRemove(r)) |kv| {
            try ctx_mod.writeHttpUnitResult(try ctx.memory(), kv.value.ptr, outcome);
            const reader = try ctx.streams.get(r);
            reader.state = .done;
            reader.setPendingEvent(.{ .code = .future_read, .index = r, .payload = (async_mod.ReturnCode{ .completed = 0 }).encode() });
            f.pending = null;
        } else try ctx.host_sent_futures.put(ctx.alloc, r, outcome);
        f.written = true;
    }
    try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, w);
}

const FutureWrite = union(enum) { pending, dropped, written: u32 };

/// Take the value a guest wrote to the future whose readable the host holds:
/// `written` = the address of its lowered value, the guest's write now
/// completed; `dropped` = the writer went without writing.
fn http3TakeFutureWrite(ctx: *WasiP2Ctx, readable: u32) WasiP2Error!FutureWrite {
    const f = switch ((try ctx.shared.get((try ctx.streams.get(readable)).shared)).*) {
        .future => |*f| f,
        .stream, .subtask => return WasiP2Error.InvalidHandle,
    };
    const p = f.pending orelse return if (f.dropped) .dropped else .pending;
    if (p.side != .writable) return .pending;
    const pw = ctx.pending_writes.fetchRemove(p.waitable) orelse return .pending;
    const writer = try ctx.streams.get(p.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .future_write, .index = p.waitable, .payload = (async_mod.ReturnCode{ .completed = 0 }).encode() });
    f.pending = null;
    f.written = true;
    return .{ .written = pw.value.ptr };
}

/// A `result<option<own<fields>>, error-code>` the guest wrote at `ptr`
/// (payload @8; `own` @12). The fields become the host's.
fn http3TakeRequestTrailers(ctx: *WasiP2Ctx, ptr: u32) WasiP2Error!ctx_mod.RequestTrailers {
    const mem = try ctx.memory();
    if (try mem.read(u8, ptr) != 0) return .{ .err = try mem.read(u8, ptr + 8) };
    if (try mem.read(u8, ptr + 8) == 0) return .none;
    const handle = try mem.read(u32, ptr + 12);
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, handle);
    (try ctxHttpFields(ctx, rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, handle);
    return .{ .some = rep };
}

fn http3RequestGetMethod(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    switch (req.method) {
        .other => |s| {
            try mem.write(retptr, @as(u8, 9));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 4, p);
            try mem.write(retptr + 8, @as(u32, @intCast(s.len)));
        },
        else => try mem.write(retptr, @as(u8, @backingInt(std.meta.activeTag(req.method)))),
    }
}

fn http3RequestSetMethod(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc < 9) {
        req.method.deinit(ctx.alloc);
        req.method = switch (disc) {
            0 => .get,
            1 => .head,
            2 => .post,
            3 => .put,
            4 => .delete,
            5 => .connect,
            6 => .options,
            7 => .trace,
            8 => .patch,
            else => unreachable,
        };
        return 0;
    }
    const name = try mem.sliceAt(ptr, len);
    if (!p3http.validMethod(name)) return 1;
    // other("GET") etc. normalizes to the enum case (wasi-http#194).
    inline for (p3http.Method.known_names) |k| {
        if (std.mem.eql(u8, name, k.name)) {
            req.method.deinit(ctx.alloc);
            req.method = @unionInit(p3http.Method, @tagName(k.tag), {});
            return 0;
        }
    }
    const copy = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory;
    req.method.deinit(ctx.alloc);
    req.method = .{ .other = copy };
    return 0;
}

/// Write `option<string>` (disc u8@0, ptr@4, len@8) from an optional slice.
fn http3WriteOptString(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, s: ?[]const u8) WasiP2Error!void {
    if (s) |str| {
        try mem.write(retptr, @as(u8, 1));
        const p = try http3AllocBlob(ctx, mem, str);
        try mem.write(retptr + 4, p);
        try mem.write(retptr + 8, @as(u32, @intCast(str.len)));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// Store an optional validated string field (dupe + free old).
fn http3SetOptString(ctx: *WasiP2Ctx, slot: *?[]u8, s: ?[]const u8) WasiP2Error!void {
    if (slot.*) |old| ctx.alloc.free(old);
    slot.* = if (s) |str| ctx.alloc.dupe(u8, str) catch return WasiP2Error.OutOfMemory else null;
}

fn http3RequestGetPwq(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.path_with_query);
}

fn http3RequestSetPwq(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.path_with_query, null);
        return 0;
    }
    const s = try mem.sliceAt(ptr, len);
    if (!p3http.validPathWithQuery(s)) return 1;
    // The corpus pins "" → "/" (an empty path serializes as "/").
    try http3SetOptString(ctx, &req.path_with_query, if (s.len == 0) "/" else s);
    return 0;
}

fn http3RequestGetScheme(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    const sc = req.scheme orelse {
        try mem.write(retptr, @as(u8, 0));
        return;
    };
    try mem.write(retptr, @as(u8, 1));
    switch (sc) {
        .http => try mem.write(retptr + 4, @as(u8, 0)),
        .https => try mem.write(retptr + 4, @as(u8, 1)),
        .other => |s| {
            try mem.write(retptr + 4, @as(u8, 2));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 8, p);
            try mem.write(retptr + 12, @as(u32, @intCast(s.len)));
        },
    }
}

fn http3RequestSetScheme(caller: *Caller, self: u32, opt_disc: u32, scheme_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (opt_disc == 0) {
        if (req.scheme) |*old| old.deinit(ctx.alloc);
        req.scheme = null;
        return 0;
    }
    var next: p3http.Scheme = undefined;
    switch (scheme_disc) {
        0 => next = .http,
        1 => next = .https,
        else => {
            const s = try mem.sliceAt(ptr, len);
            if (!p3http.validScheme(s)) return 1;
            // other("http"/"https") normalizes to the enum case (#194).
            if (std.mem.eql(u8, s, "http")) {
                next = .http;
            } else if (std.mem.eql(u8, s, "https")) {
                next = .https;
            } else {
                next = .{ .other = ctx.alloc.dupe(u8, s) catch return WasiP2Error.OutOfMemory };
            }
        },
    }
    if (req.scheme) |*old| old.deinit(ctx.alloc);
    req.scheme = next;
    return 0;
}

fn http3RequestGetAuthority(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.authority);
}

fn http3RequestSetAuthority(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.authority, null);
        return 0;
    }
    const s = try mem.sliceAt(ptr, len);
    if (!p3http.validAuthority(s)) return 1;
    try http3SetOptString(ctx, &req.authority, s);
    return 0;
}

fn http3RequestGetOptions(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (req.options_rep) |orep| {
        const h = try ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, orep);
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, h);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3RequestGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const req = try http3RequestSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, req.headers_rep);
}

/// `response.new` (headers, option<stream<u8>>, trailers future, retptr) →
/// tuple<response, future<result<_, error-code>>>.
fn http3ResponseNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    const idx = ctx.addHttpResponse(.{
        .headers_rep = headers_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try releaseHostWritable(ctx, fut.writable);
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

fn http3ResponseGetStatus(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return (try http3ResponseSelf(ctx, self)).status;
}

fn http3ResponseSetStatus(caller: *Caller, self: u32, status: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    // A valid HTTP status code is 100..=599.
    if (status < 100 or status > 599) return 1;
    resp.status = @intCast(status);
    return 0;
}

fn http3ResponseGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, resp.headers_rep);
}

fn http3ReqoptsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const idx = ctx.addHttpReqopts(.{}) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

/// `option<duration>`: disc u8@0, u64 value@8 (align 8).
fn http3WriteOptDuration(mem: Memory, retptr: u32, v: ?u64) WasiP2Error!void {
    if (v) |ns| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 8, ns);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `result<_, request-options-error>`: disc@0; err variant disc@4 (0 =
/// not-supported, 1 = immutable, 2 = other), other's option none@8.
fn http3WriteReqoptsSetResult(mem: Memory, retptr: u32, immutable: bool) WasiP2Error!void {
    if (immutable) {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, @as(u8, 1));
        try mem.write(retptr + 8, @as(u8, 0));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3ReqoptsConnectGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).connect_timeout_ns);
}

fn http3ReqoptsConnectSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.connect_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsFirstByteGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).first_byte_timeout_ns);
}

fn http3ReqoptsFirstByteSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.first_byte_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsBetweenBytesGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).between_bytes_timeout_ns);
}

fn http3ReqoptsBetweenBytesSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.between_bytes_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

/// `[static]request.consume-body` (this, res future, retptr) →
/// tuple<stream<u8>, future<result<option<trailers>, error-code>>>: hand
/// out the stored body ends. A bodiless request gets an immediately-CLOSED
/// stream (collect → empty) and, when no guest trailers future was
/// transferred (harness-built requests), a host-resolved `ok(none)` one.
/// Consumes `this` (handle slot only — headers/options views stay valid)
/// and releases the guest's error-report future.
fn http3RequestConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, this);
    const contents = req.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        // Dropping the writable half closes the stream for the reader.
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (req.trailers_future != 0) req.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try releaseHostWritable(ctx, fut.writable);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, null);
        break :blk fut.readable;
    };
    req.contents_stream = null;
    req.trailers_future = 0;
    // `sent` takes the value the guest writes to `res`, as wasmtime's does.
    if (req.sent_writable != 0) {
        try ctx.sent_links.append(ctx.alloc, .{ .res = res_fut, .sent_readable = req.sent_readable, .sent_writable = req.sent_writable });
        req.sent_writable = 0;
    } else http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[static]response.consume-body` — the response-side mirror of the
/// request form: hand out the stored body ends (host-built responses from
/// `client.send` carry `host_body_bytes`-served streams, a bodiless one a
/// CLOSED stream, and a host-resolved trailers future with what was received).
fn http3ResponseConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const resp = try http3ResponseSelf(ctx, this);
    const contents = resp.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (resp.trailers_future != 0) resp.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try releaseHostWritable(ctx, fut.writable);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, resp.trailers_rep);
        resp.trailers_rep = null;
        break :blk fut.readable;
    };
    resp.contents_stream = null;
    resp.trailers_future = 0;
    http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_RESPONSE_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[async-lower]wasi:http/client.send` (request, retptr): consumes the
/// request handle and PARKS as a subtask — the request body is a guest
/// stream fed by a guest writer task, so the blocking exchange can only
/// run once the guest closes it (`pollPendingClientSends`). A bodiless
/// request resolves at the first poll (its shared is never written).
pub fn http3ClientSend(caller: *Caller, request: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, request);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, request);
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
    });
    const pcs = ctx.alloc.create(PendingClientSend) catch return WasiP2Error.OutOfMemory;
    pcs.* = .{ .req_rep = rep, .retptr = retptr, .subtask = h, .granted = if (ctxRequireNetwork(ctx)) |_| true else |_| false };
    ctx.pending_client_sends.append(ctx.alloc, pcs) catch {
        ctx.alloc.destroy(pcs);
        return WasiP2Error.OutOfMemory;
    };
    const req = try ctxHttpRequest(ctx, rep);
    if (req.contents_stream) |cs| {
        const end = try ctx.streams.get(cs);
        pcs.body_shared = end.shared;
        try http3RegisterCaptureSink(ctx, end.shared, &pcs.body);
    }
    return @backingInt(async_mod.SubtaskState.started) | (h << 4);
}

/// Resolve parked `client.send`s whose request body is complete (the body
/// stream's writer dropped — or no body at all) and whose trailers future
/// was written: run the blocking HTTP exchange, mint the response resource,
/// marshal the result, and flip the subtask to RETURNED (the timer-fire
/// shape). Also resolves a consumed request's `sent` once `res` is written.
pub fn pollPendingClientSends(self: *WasiP2Ctx) WasiP2Error!bool {
    var progressed = false;
    var l: usize = 0;
    while (l < self.sent_links.items.len) {
        const link = self.sent_links.items[l];
        const outcome: ?u8 = switch (try http3TakeFutureWrite(self, link.res)) {
            .pending => {
                l += 1;
                continue;
            },
            .dropped => null,
            .written => |ptr| blk: {
                const mem = try self.memory();
                break :blk if (try mem.read(u8, ptr) == 0) null else try mem.read(u8, ptr + 8);
            },
        };
        try resolveSentEnds(self, link.sent_readable, link.sent_writable, outcome);
        http3DropTransferredEnd(self, link.res);
        _ = self.sent_links.swapRemove(l);
        progressed = true;
    }
    var i: usize = 0;
    while (i < self.pending_client_sends.items.len) {
        const pcs = self.pending_client_sends.items[i];
        const req = try ctxHttpRequest(self, pcs.req_rep);
        if (req.trailers_future != 0) {
            const taken: ?ctx_mod.RequestTrailers = switch (try http3TakeFutureWrite(self, req.trailers_future)) {
                .pending => null,
                .dropped => .none,
                .written => |ptr| try http3TakeRequestTrailers(self, ptr),
            };
            if (taken) |t| {
                pcs.trailers = t;
                http3DropTransferredEnd(self, req.trailers_future);
                req.trailers_future = 0;
                progressed = true;
            }
        }
        const body_done = if (pcs.body_shared) |sid| blk: {
            const sh = self.shared.get(sid) catch break :blk true;
            break :blk switch (sh.*) {
                .stream => |s| s.dropped,
                .future, .subtask => true,
            };
        } else true;
        if (!body_done or req.trailers_future != 0) {
            i += 1;
            continue;
        }
        try http3PerformSend(self, pcs);
        if (pcs.body_shared) |sid| _ = self.host_capture_sinks.remove(sid);
        pcs.body.deinit(self.alloc);
        self.alloc.destroy(pcs);
        _ = self.pending_client_sends.orderedRemove(i);
        progressed = true;
    }
    return progressed;
}

/// Marshal one resolved `client.send` (`ctx_mod.httpExchange` performs it):
/// the response minted as a host-built resource (`host_body_bytes`-served
/// body; trailers via the host-resolved future at consume-body).
/// result<own<response>, error-code> marshals at retptr with payload offset
/// 8 (error-code carries u64 cases).
fn http3PerformSend(self: *WasiP2Ctx, pcs: *PendingClientSend) WasiP2Error!void {
    const mem = try self.memory();
    const req = try ctxHttpRequest(self, pcs.req_rep);
    // The trailer fields are the host's (the guest's handle went with the
    // write); nothing else reaches them.
    defer switch (pcs.trailers) {
        .some => |rep| self.http_fields.items[rep].deinit(self.alloc),
        .none, .err => {},
    };
    const fail = struct {
        fn code(ctx: *WasiP2Ctx, m: Memory, p: *PendingClientSend, r: *p3http.HttpRequest, ordinal: u8) WasiP2Error!void {
            try ctx_mod.writeHttpUnitResult(m, p.retptr, ordinal);
            try http3ResolveSent(ctx, r, ordinal);
            const sub = try ctx.streams.get(p.subtask);
            sub.subtask_state = .returned;
            sub.setPendingEvent(.{ .code = .subtask, .index = p.subtask, .payload = @backingInt(async_mod.SubtaskState.returned) });
        }
    };
    // Denied or refused here rather than at `client.send`, so the parked body
    // stream drains and releases as on any failed exchange.
    // `HTTP-request-denied` = 15, `HTTP-protocol-error` = 35.
    if (!pcs.granted) return fail.code(self, mem, pcs, req, 15);
    if (!ctx_mod.httpSendable(req)) return fail.code(self, mem, pcs, req, 35);
    const trailers: ?*const p3http.HttpFields = switch (pcs.trailers) {
        .none => null,
        .some => |rep| try ctxHttpFields(self, rep),
        // The request is aborted, as wasmtime does: no exchange.
        .err => |code| return fail.code(self, mem, pcs, req, code),
    };
    const ex = ctx_mod.httpExchange(self, req, pcs.body.items, trailers) catch |e| switch (e) {
        // `internal-error(none)` / `HTTP-response-content-coding(none)`.
        error.HttpFailed => return fail.code(self, mem, pcs, req, 38),
        error.HttpResponseContentCoding => return fail.code(self, mem, pcs, req, 32),
        else => |oe| return oe,
    };
    var contents: ?u32 = null;
    if (ex.body.len > 0) {
        // Block-scoped: disarmed once `put` has handed the bytes to the map.
        errdefer self.alloc.free(ex.body);
        const pair = try async_mod.newStreamPair(&self.streams, &self.shared, null);
        const shared_id = (try self.streams.get(pair.readable)).shared;
        try self.host_body_bytes.put(self.alloc, shared_id, .{ .data = ex.body });
        contents = pair.readable;
    } else self.alloc.free(ex.body);
    const trailers_rep: ?u32 = if (ex.trailers) |raw| blk: {
        defer self.alloc.free(raw);
        const rep = self.addHttpFields(.{}) catch return WasiP2Error.OutOfMemory;
        var it: std.http.HeaderIterator = .{ .bytes = raw, .index = 0, .is_trailer = true };
        // A field the guest could not set (#698) is dropped, as for headers.
        while (it.next()) |t| self.http_fields.items[rep].appendChecked(self.alloc, t.name, t.value) catch continue;
        self.http_fields.items[rep].immutable = true;
        break :blk rep;
    } else null;
    const resp_idx = self.addHttpResponse(.{
        .status = ex.status,
        .headers_rep = ex.headers_rep,
        .contents_stream = contents,
        .trailers_rep = trailers_rep,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try self.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, resp_idx);
    try mem.write(pcs.retptr, @as(u8, 0));
    try mem.write(pcs.retptr + 8, handle);
    try http3ResolveSent(self, try ctxHttpRequest(self, pcs.req_rep), null);
    // Re-fetch: newStreamPair/http_* appends above may have grown the
    // streams table, dangling the `sub` pointer taken at entry.
    const sub2 = try self.streams.get(pcs.subtask);
    sub2.subtask_state = .returned;
    sub2.setPendingEvent(.{ .code = .subtask, .index = pcs.subtask, .payload = @backingInt(async_mod.SubtaskState.returned) });
}

/// Register a harness capture sink for `shared_id`, draining a write that
/// parked before registration (the guest's spawned body writer may run
/// before the harness learns the response's stream id).
pub fn http3RegisterCaptureSink(ctx: *WasiP2Ctx, shared_id: u32, cap: *std.ArrayList(u8)) WasiP2Error!void {
    try ctx.host_capture_sinks.put(ctx.alloc, shared_id, cap);
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const mem = try ctx.memory();
    const bytes = try mem.sliceAt(pw.ptr, try ctx_mod.streamSpan(pw.count, pw.elem_size));
    cap.appendSlice(ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
    const writer = try ctx.streams.get(pending.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

fn http3ReqoptsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = (try http3ReqoptsSelf(ctx, self)).*;
    const idx = ctx.addHttpReqopts(.{
        .connect_timeout_ns = src.connect_timeout_ns,
        .first_byte_timeout_ns = src.first_byte_timeout_ns,
        .between_bytes_timeout_ns = src.between_bytes_timeout_ns,
    }) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

/// The sync-lowered plain funcs. `client.send` is not here: it arrives
/// ASYNC-lowered (`component_wasi_p3_host.defineAsyncLoweredOp`).
const binds = .{
    .{ adapter.P2Op.http3_fields_new, fn (*Caller) WasiP2Error!u32, http3FieldsNew },
    .{ adapter.P2Op.http3_fields_from_list, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3FieldsFromList },
    .{ adapter.P2Op.http3_fields_get, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGet },
    .{ adapter.P2Op.http3_fields_has, fn (*Caller, u32, u32, u32) WasiP2Error!u32, http3FieldsHas },
    .{ adapter.P2Op.http3_fields_set, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsSet },
    .{ adapter.P2Op.http3_fields_delete, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsDelete },
    .{ adapter.P2Op.http3_fields_get_and_delete, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGetAndDelete },
    .{ adapter.P2Op.http3_fields_append, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsAppend },
    .{ adapter.P2Op.http3_fields_copy_all, fn (*Caller, u32, u32) WasiP2Error!void, http3FieldsCopyAll },
    .{ adapter.P2Op.http3_fields_clone, fn (*Caller, u32) WasiP2Error!u32, http3FieldsClone },
    .{ adapter.P2Op.http3_request_new, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3RequestNew },
    .{ adapter.P2Op.http3_request_get_method, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetMethod },
    .{ adapter.P2Op.http3_request_set_method, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetMethod },
    .{ adapter.P2Op.http3_request_get_pwq, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetPwq },
    .{ adapter.P2Op.http3_request_set_pwq, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetPwq },
    .{ adapter.P2Op.http3_request_get_scheme, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetScheme },
    .{ adapter.P2Op.http3_request_set_scheme, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetScheme },
    .{ adapter.P2Op.http3_request_get_authority, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetAuthority },
    .{ adapter.P2Op.http3_request_set_authority, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetAuthority },
    .{ adapter.P2Op.http3_request_get_options, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetOptions },
    .{ adapter.P2Op.http3_request_get_headers, fn (*Caller, u32) WasiP2Error!u32, http3RequestGetHeaders },
    .{ adapter.P2Op.http3_response_new, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!void, http3ResponseNew },
    .{ adapter.P2Op.http3_response_get_status, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetStatus },
    .{ adapter.P2Op.http3_response_set_status, fn (*Caller, u32, u32) WasiP2Error!u32, http3ResponseSetStatus },
    .{ adapter.P2Op.http3_response_get_headers, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetHeaders },
    .{ adapter.P2Op.http3_reqopts_new, fn (*Caller) WasiP2Error!u32, http3ReqoptsNew },
    .{ adapter.P2Op.http3_reqopts_connect_get, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsConnectGet },
    .{ adapter.P2Op.http3_reqopts_connect_set, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsConnectSet },
    .{ adapter.P2Op.http3_reqopts_first_byte_get, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsFirstByteGet },
    .{ adapter.P2Op.http3_reqopts_first_byte_set, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsFirstByteSet },
    .{ adapter.P2Op.http3_reqopts_between_bytes_get, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsBetweenBytesGet },
    .{ adapter.P2Op.http3_reqopts_between_bytes_set, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsBetweenBytesSet },
    .{ adapter.P2Op.http3_reqopts_clone, fn (*Caller, u32) WasiP2Error!u32, http3ReqoptsClone },
    .{ adapter.P2Op.http3_request_consume_body, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3RequestConsumeBody },
    .{ adapter.P2Op.http3_response_consume_body, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3ResponseConsumeBody },
};

/// Bind one `http3_*` op (the classifier's arm in `component_wasi_p3_host.registerP3Arms`).
pub fn defineHttp3Op(lk: *Linker, ns: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    inline for (binds) |b| {
        if (op == b[0]) return defineMapped(lk, ns, name, ctx, b[1], b[2], mapGuestFault);
    }
    return error.UnsupportedWasiImport;
}

// ============================================================
// Tests
// ============================================================
const wasi_host = @import("../wasi/host.zig");
const Engine = @import("../zwasm/engine.zig").Engine;

test "an outbound HTTP exchange that fails answers internal-error, not configuration-error" {
    const testing = std.testing;
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

    // No authority, so the exchange fails before it reaches the network.
    const req_rep = try ctx.addHttpRequest(.{ .headers_rep = 0, .scheme = .http });
    _ = try http3ClientSend(&caller, try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, req_rep), 0);
    _ = try pollPendingClientSends(&ctx);
    const mem = try ctx.memory();
    try testing.expectEqual(@as(u8, 1), try mem.read(u8, 0));
    try testing.expectEqual(@as(u8, 38), try mem.read(u8, 8));
}

test "a 0.3 request's sent future carries the send's outcome to a read issued before or after it, and goes with a reader that dropped first (#703)" {
    const testing = std.testing;
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
    var abc: ctx_mod.AsyncBuiltinCtx = .{ .ctx = &ctx, .type_index = 0 };
    var copy_caller: Caller = .{ .rt = inst.handle.runtime.?, .host_data = &abc };
    const mem = try ctx.memory();
    const blocked = (async_mod.ReturnCode{ .blocked = {} }).encode();
    const completed = (async_mod.ReturnCode{ .completed = 0 }).encode();

    // Three `http` requests with no authority, so each exchange fails with
    // internal-error (38). Each `request.new` result lands at 0, the send's
    // result at 16 + 32*i.
    var sent: [3]u32 = undefined;
    var writable: [3]u32 = undefined;
    @memset(try mem.sliceAt(224, 16), 0);
    for (&sent, &writable, 0..) |*s, *w, i| {
        const trailers = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        const headers = try ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, try ctx.addHttpFields(.{}));
        try http3RequestNew(&caller, headers, 0, 0, trailers.readable, 0, 0, 0);
        const req = try mem.read(u32, 0);
        s.* = try mem.read(u32, 4);
        const r = &ctx.http_requests.items[try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, req)];
        r.scheme = .http;
        w.* = r.sent_writable;
        _ = try http3ClientSend(&caller, req, 16 + 32 * @as(u32, @intCast(i)));
        // The trailers future resolves `ok(none)`, as wit-bindgen's writer
        // does when dropped.
        _ = try ctx_mod.p2FutureCopy(&copy_caller, trailers.writable, 224);
    }
    // [1] is read before the exchange ends; [2] is dropped unread.
    try testing.expectEqual(blocked, try ctx_mod.p2FutureCopy(&copy_caller, sent[1], 160));
    try ctx_mod.p2StreamFutureDrop(&copy_caller, sent[2]);
    _ = try pollPendingClientSends(&ctx);

    // [0], read after: completes at once, err(internal-error) in the @8 layout.
    @memset((try mem.sliceAt(128, 24)), 0xaa);
    try testing.expectEqual(completed, try ctx_mod.p2FutureCopy(&copy_caller, sent[0], 128));
    try testing.expectEqualSlices(u8, &.{ 1, 38, 0 }, &.{ try mem.read(u8, 128), try mem.read(u8, 136), try mem.read(u8, 144) });
    // [1], parked: completed in place, with its FUTURE_READ event pending.
    try testing.expectEqualSlices(u8, &.{ 1, 38, 0 }, &.{ try mem.read(u8, 160), try mem.read(u8, 168), try mem.read(u8, 176) });
    const ev = (try ctx.streams.get(sent[1])).takePendingEvent().?;
    try testing.expectEqual(async_mod.EventCode.future_read, ev.code);
    try testing.expectEqual(completed, ev.payload);
    // The host's writables are gone, and nothing of [2] is left.
    for (writable) |w| try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(w));
    try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(sent[2]));
    try testing.expectEqual(@as(u32, 0), ctx.host_sent_futures.count());
}

const RawEndpoint = @import("component_http_echo.zig").RawEndpoint;

/// A ctx with the network granted and a one-page memory, the two callers
/// the host funcs and the canon copy builtins take, all at stable addresses.
const Http3Rig = struct {
    threaded: std.Io.Threaded,
    host: wasi_host.Host,
    ctx_value: WasiP2Ctx,
    eng: Engine,
    mod: @import("../zwasm/module.zig").Module,
    lk: Linker,
    inst: @import("../zwasm.zig").Instance,
    abc: ctx_mod.AsyncBuiltinCtx,
    caller_value: Caller,
    copy_caller_value: Caller,
    ctx: *WasiP2Ctx,
    caller: *Caller,
    copy_caller: *Caller,

    fn create() !*Http3Rig {
        const a = std.testing.allocator;
        const rig = try a.create(Http3Rig);
        errdefer a.destroy(rig);
        rig.threaded = .init(a, .{});
        errdefer rig.threaded.deinit();
        rig.host = try wasi_host.Host.init(a);
        errdefer rig.host.deinit();
        rig.host.io = rig.threaded.io();
        rig.host.allow_network = true;
        rig.ctx_value = try WasiP2Ctx.init(a, &rig.host);
        errdefer rig.ctx_value.deinit();
        rig.eng = try Engine.init(a, .{});
        errdefer rig.eng.deinit();
        rig.mod = try rig.eng.compile("\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00");
        errdefer rig.mod.deinit();
        rig.lk = rig.eng.linker();
        errdefer rig.lk.deinit();
        rig.inst = try rig.lk.instantiate(&rig.mod, .{});
        rig.ctx = &rig.ctx_value;
        rig.ctx.mem_instance = &rig.inst;
        rig.abc = .{ .ctx = rig.ctx, .type_index = 0 };
        rig.caller_value = .{ .rt = rig.inst.handle.runtime.?, .host_data = rig.ctx };
        rig.copy_caller_value = .{ .rt = rig.inst.handle.runtime.?, .host_data = &rig.abc };
        rig.caller = &rig.caller_value;
        rig.copy_caller = &rig.copy_caller_value;
        return rig;
    }

    fn destroy(rig: *Http3Rig) void {
        rig.inst.deinit();
        rig.lk.deinit();
        rig.mod.deinit();
        rig.eng.deinit();
        rig.ctx_value.deinit();
        rig.host.deinit();
        rig.threaded.deinit();
        std.testing.allocator.destroy(rig);
    }

    const Request = struct { handle: u32, rep: u32, sent: u32, body: u32, trailers: u32 };

    /// A guest-made POST with a body stream and a trailers future, as
    /// wasi-testsuite's `send_with_trailers` builds it. `request.new`'s
    /// result lands at 0.
    fn newRequest(rig: *Http3Rig, port: u16) !Request {
        const ctx = rig.ctx;
        const body = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        const trailers = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        const headers = try ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, try ctx.addHttpFields(.{}));
        try http3RequestNew(rig.caller, headers, 1, body.readable, trailers.readable, 0, 0, 0);
        const mem = try ctx.memory();
        const handle = try mem.read(u32, 0);
        const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, handle);
        const req = &ctx.http_requests.items[rep];
        req.method = .post;
        req.scheme = .http;
        req.authority = try ctx.alloc.print("127.0.0.1:{d}", .{port});
        return .{ .handle = handle, .rep = rep, .sent = try mem.read(u32, 4), .body = body.writable, .trailers = trailers.writable };
    }

    /// The guest's side of a send: write `body` and close the stream, then
    /// write the trailers value already lowered at 64, and let the host run.
    fn send(rig: *Http3Rig, r: Request, body: []const u8, retptr: u32) !void {
        const mem = try rig.ctx.memory();
        _ = try http3ClientSend(rig.caller, r.handle, retptr);
        @memcpy(try mem.sliceAt(256, @intCast(body.len)), body);
        _ = try ctx_mod.p2StreamFutureCopy(rig.copy_caller, r.body, 256, @intCast(body.len));
        try ctx_mod.p2StreamFutureDrop(rig.copy_caller, r.body);
        try std.testing.expectEqual((async_mod.ReturnCode{ .blocked = {} }).encode(), try ctx_mod.p2FutureCopy(rig.copy_caller, r.trailers, 64));
        _ = try pollPendingClientSends(rig.ctx);
        const ev = (try rig.ctx.streams.get(r.trailers)).takePendingEvent().?;
        try std.testing.expectEqual(async_mod.EventCode.future_write, ev.code);
    }

    /// Lower `result<option<own<fields>>, error-code>` at 64.
    fn lowerTrailers(rig: *Http3Rig, value: union(enum) { none, some: []const [2][]const u8, err: u8 }) !void {
        const mem = try rig.ctx.memory();
        @memset(try mem.sliceAt(64, 16), 0);
        switch (value) {
            .none => {},
            .some => |pairs| {
                var f: p3http.HttpFields = .{};
                for (pairs) |p| try f.appendPair(rig.ctx.alloc, p[0], p[1]);
                try mem.write(@as(u32, 72), @as(u8, 1));
                try mem.write(@as(u32, 76), try rig.ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, try rig.ctx.addHttpFields(f)));
            },
            .err => |code| {
                try mem.write(@as(u32, 64), @as(u8, 1));
                try mem.write(@as(u32, 72), code);
            },
        }
    }
};

test "a 0.3 request goes chunked with the trailers its future resolves to, with today's framing on none, and is aborted on err (#705)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();
    const ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    {
        const ep = try RawEndpoint.start(io, ok_response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        try rig.lowerTrailers(.{ .some = &.{ .{ "x-checksum", "abc123" }, .{ "x-parts", "1" } } });
        try rig.send(r, "ping", 128);
        ep.stop();
        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        const wire = ep.request();
        try testing.expect(std.ascii.findIgnoreCase(wire, "transfer-encoding: chunked\r\n") != null);
        try testing.expect(std.ascii.findIgnoreCase(wire, "content-length") == null);
        try testing.expect(std.mem.endsWith(u8, wire, "\r\nping\r\n0\r\nx-checksum: abc123\r\nx-parts: 1\r\n\r\n"));
    }
    {
        // std writes no body for a GET; the host frames it itself.
        const ep = try RawEndpoint.start(io, ok_response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        ctx.http_requests.items[r.rep].method = .get;
        try rig.lowerTrailers(.{ .some = &.{.{ "x-parts", "1" }} });
        try rig.send(r, "ping", 128);
        ep.stop();
        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        const wire = ep.request();
        try testing.expect(std.mem.startsWith(u8, wire, "GET / HTTP/1.1\r\n"));
        try testing.expect(std.ascii.findIgnoreCase(wire, "transfer-encoding: chunked\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n4\r\nping\r\n0\r\nx-parts: 1\r\n\r\n"));
    }
    {
        const ep = try RawEndpoint.start(io, ok_response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        try rig.lowerTrailers(.none);
        try rig.send(r, "ping", 128);
        ep.stop();
        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        const wire = ep.request();
        try testing.expect(std.ascii.findIgnoreCase(wire, "content-length: 4\r\n") != null);
        try testing.expect(std.ascii.findIgnoreCase(wire, "transfer-encoding") == null);
        try testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\nping"));
    }
    {
        const ep = try RawEndpoint.start(io, ok_response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        // HTTP-request-body-size = 22 (any ordinal: the guest's is passed on).
        try rig.lowerTrailers(.{ .err = 22 });
        try rig.send(r, "ping", 128);
        ep.stop();
        // No exchange: client.send and `sent` both carry the guest's err.
        try testing.expectEqualStrings("", ep.request());
        try testing.expectEqualSlices(u8, &.{ 1, 22 }, &.{ try mem.read(u8, 128), try mem.read(u8, 136) });
        try testing.expectEqual((async_mod.ReturnCode{ .completed = 0 }).encode(), try ctx_mod.p2FutureCopy(rig.copy_caller, r.sent, 160));
        try testing.expectEqualSlices(u8, &.{ 1, 22 }, &.{ try mem.read(u8, 160), try mem.read(u8, 168) });
    }
}

test "a 0.3 request whose scheme is not http is refused with HTTP-protocol-error before a connection opens" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();
    const ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    const Case = enum { https, other, unset, http };
    for ([_]Case{ .https, .other, .unset, .http }) |case| {
        const ep = try RawEndpoint.start(io, ok_response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        ctx.http_requests.items[r.rep].scheme = switch (case) {
            .https => .https,
            .other => .{ .other = try ctx.alloc.dupe(u8, "ftp") },
            .unset => null,
            .http => .http,
        };
        try rig.lowerTrailers(.none);
        try rig.send(r, "ping", 128);
        ep.stop();
        if (case == .http) {
            try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
            try testing.expect(std.mem.startsWith(u8, ep.request(), "POST / HTTP/1.1\r\n"));
            continue;
        }
        try testing.expectEqualStrings("", ep.request());
        try testing.expectEqualSlices(u8, &.{ 1, 35 }, &.{ try mem.read(u8, 128), try mem.read(u8, 136) });
        try testing.expectEqual((async_mod.ReturnCode{ .completed = 0 }).encode(), try ctx_mod.p2FutureCopy(rig.copy_caller, r.sent, 160));
        try testing.expectEqualSlices(u8, &.{ 1, 35 }, &.{ try mem.read(u8, 160), try mem.read(u8, 168) });
    }
}

test "consume-body on a guest-made 0.3 request resolves its sent future with what the guest writes to res (#705)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const mem = try ctx.memory();
    const blocked = (async_mod.ReturnCode{ .blocked = {} }).encode();

    const r = try rig.newRequest(0);
    const res = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try http3RequestConsumeBody(rig.caller, r.handle, res.readable, 32);
    try testing.expectEqual(blocked, try ctx_mod.p2FutureCopy(rig.copy_caller, r.sent, 160));
    _ = try pollPendingClientSends(ctx);
    try testing.expect(!(try ctx.streams.get(r.sent)).hasPendingEvent());
    // The guest reports err(internal-error) on `res`.
    @memset(try mem.sliceAt(64, 24), 0);
    try mem.write(@as(u32, 64), @as(u8, 1));
    try mem.write(@as(u32, 72), @as(u8, 38));
    try testing.expectEqual(blocked, try ctx_mod.p2FutureCopy(rig.copy_caller, res.writable, 64));
    _ = try pollPendingClientSends(ctx);
    try testing.expectEqualSlices(u8, &.{ 1, 38 }, &.{ try mem.read(u8, 160), try mem.read(u8, 168) });
    try testing.expectEqual(async_mod.EventCode.future_read, (try ctx.streams.get(r.sent)).takePendingEvent().?.code);
    try testing.expectEqual(async_mod.EventCode.future_write, (try ctx.streams.get(res.writable)).takePendingEvent().?.code);
    try testing.expectEqual(@as(usize, 0), ctx.sent_links.items.len);
}

test "a 0.3 response's trailer section reaches the guest through consume-body's trailers future, and outlives a sweep before the read (#704)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();

    const ep = try RawEndpoint.start(io, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\npayload\r\n0\r\nx-checksum: abc123\r\nx-parts: 1\r\n\r\n");
    defer ep.destroy();
    const r = try rig.newRequest(ep.port);
    try rig.lowerTrailers(.none);
    try rig.send(r, "", 128);
    ep.stop();
    try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
    const res = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try http3ResponseConsumeBody(rig.caller, try mem.read(u32, 136), res.readable, 32);
    const trailers = try mem.read(u32, 36);

    try ctx_mod.sweepHttpTables(ctx);
    @memset(try mem.sliceAt(160, 16), 0xaa);
    try testing.expectEqual((async_mod.ReturnCode{ .completed = 0 }).encode(), try ctx_mod.p2FutureCopy(rig.copy_caller, trailers, 160));
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, &.{ try mem.read(u8, 160), try mem.read(u8, 168) });
    const fields = try ctxHttpFieldsSelf(ctx, try mem.read(u32, 172));
    try testing.expectEqual(@as(usize, 2), fields.entries.items.len);
    try testing.expectEqualStrings("x-checksum", fields.entries.items[0].name);
    try testing.expectEqualStrings("abc123", fields.entries.items[0].value);
    try testing.expectEqualStrings("x-parts", fields.entries.items[1].name);
    try testing.expectEqualStrings("1", fields.entries.items[1].value);
    try testing.expect(fields.immutable);
}

test "a 3xx reaches the 0.3 guest as the response, and the host sends no second request (#711)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();

    var away_buf: [64]u8 = undefined;
    const away = try std.mem.print(&away_buf, "https://127.0.0.1:{d}/", .{try @import("component_http_echo.zig").HttpEndpoint.reserveClosedPort(io)});
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
        const r = try rig.newRequest(ep.port);
        ctx.http_requests.items[r.rep].method = .get;
        try rig.lowerTrailers(.none);
        try rig.send(r, "", 128);
        ep.stop();

        try testing.expectEqual(@as(u32, 1), ep.connections);
        try testing.expect(std.mem.startsWith(u8, ep.request(), "GET / HTTP/1.1\r\n"));
        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        const resp = ctx.http_responses.items[try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, try mem.read(u32, 136))];
        try testing.expectEqual(c.status, resp.status);
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(testing.allocator);
        try ctx.http_fields.items[resp.headers_rep].get(&values, testing.allocator, "location");
        try testing.expectEqual(@as(usize, 1), values.items.len);
        try testing.expectEqualStrings(c.location, values.items[0]);
        if (c.body.len == 0) {
            try testing.expectEqual(@as(?u32, null), resp.contents_stream);
        } else {
            const shared_id = (try ctx.streams.get(resp.contents_stream.?)).shared;
            try testing.expectEqualStrings(c.body, ctx.host_body_bytes.get(shared_id).?.data);
        }
    }
}

test "a 0.3 request on the wire carries host, its framing and the guest's headers, each once, and none of the client's own (#711)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();

    const Case = struct { method: p3http.Method, body: []const u8, headers: []const [2][]const u8, wire: []const u8 };
    const cases = [_]Case{
        .{ .method = .get, .body = "", .headers = &.{}, .wire = "GET / HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\n\r\n" },
        .{
            .method = .post,
            .body = "ping",
            .headers = &.{ .{ "user-agent", "guest-ua" }, .{ "accept-encoding", "br" } },
            .wire = "POST / HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\ncontent-length: 4\r\nuser-agent: guest-ua\r\naccept-encoding: br\r\n\r\nping",
        },
    };
    inline for (cases) |c| {
        const ep = try RawEndpoint.start(io, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        const req = &ctx.http_requests.items[r.rep];
        req.method = c.method;
        for (c.headers) |h| try ctx.http_fields.items[req.headers_rep].appendPair(ctx.alloc, h[0], h[1]);
        try rig.lowerTrailers(.none);
        try rig.send(r, c.body, 128);
        ep.stop();

        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        var want_buf: [256]u8 = undefined;
        try testing.expectEqualStrings(try std.mem.print(&want_buf, c.wire, .{ep.port}), ep.request());
    }
}

test "a 0.3 response std would decode reaches the guest undecoded, one std cannot parse fails, and neither waits for the peer to close (#738)" {
    const testing = std.testing;
    const rig = try Http3Rig.create();
    defer rig.destroy();
    const ctx = rig.ctx;
    const io = rig.host.io.?;
    const mem = try ctx.memory();

    // `coding` set: the response reaches the guest; else it fails with `code`
    // (`HTTP-response-content-coding` = 32, `internal-error` = 38).
    const Case = struct { head: []const u8, coding: ?[]const u8 = null, code: u8 = 0 };
    const cases = [_]Case{
        .{ .head = "Content-Encoding: zstd\r\n", .coding = "zstd" },
        .{ .head = "Content-Encoding: compress\r\n", .coding = "compress" },
        .{ .head = "Content-Encoding: br\r\n", .code = 32 },
        .{ .head = ": x\r\n", .code = 38 },
    };
    for (cases) |c| {
        var resp_buf: [128]u8 = undefined;
        const response = try std.mem.print(&resp_buf, "HTTP/1.1 200 OK\r\n{s}Content-Length: 2\r\n\r\nhi", .{c.head});
        const ep = try RawEndpoint.startHolding(io, response);
        defer ep.destroy();
        const r = try rig.newRequest(ep.port);
        ctx.http_requests.items[r.rep].method = .get;
        try rig.lowerTrailers(.none);
        try mem.write(144, @as(u8, 0xff));
        try rig.send(r, "", 128);
        ep.stop();

        try testing.expect(!ep.held_out);
        const coding = c.coding orelse {
            // err(code(none)).
            try testing.expectEqualSlices(u8, &.{ 1, c.code, 0 }, &.{ try mem.read(u8, 128), try mem.read(u8, 136), try mem.read(u8, 144) });
            continue;
        };
        try testing.expectEqual(@as(u8, 0), try mem.read(u8, 128));
        const resp = ctx.http_responses.items[try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, try mem.read(u32, 136))];
        var values: std.ArrayList([]const u8) = .empty;
        defer values.deinit(testing.allocator);
        try ctx.http_fields.items[resp.headers_rep].get(&values, testing.allocator, "content-encoding");
        try testing.expectEqual(@as(usize, 1), values.items.len);
        try testing.expectEqualStrings(coding, values.items[0]);
        const shared_id = (try ctx.streams.get(resp.contents_stream.?)).shared;
        try testing.expectEqualStrings("hi", ctx.host_body_bytes.get(shared_id).?.data);
    }
}
