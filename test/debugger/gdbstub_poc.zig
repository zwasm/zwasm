//! A GDB remote stub over zwasm's interpreter that LLDB's Wasm plugin
//! (`process connect --plugin wasm`, stock LLDB 23.1.1) can drive: breakpoints,
//! single-step, a backtrace with names and source lines, DWARF locals, and a
//! stop where the guest traps. Discussion #452 evidence, not a supported tool.
//!
//! LLDB reads the module bytes through `m` and decodes the name section and
//! DWARF itself; the stub only maps interpreter frames to module offsets
//! (`ZirFunc.body_offset` + `src_offsets`) and serves values.
//!
//! Scope: one module, one thread, the interpreter, an `(i32) -> i32` export.
//! `Runtime.debug_hook` runs before each instruction; when it stops, the stub
//! serves packets in place until LLDB resumes.
//!
//! Usage: zwasm-gdbstub-poc <module.wasm> <export> <i32 arg> <port>

const std = @import("std");
const zwasm = @import("zwasm");
const Io = std.Io;
const net = std.Io.net;

const Runtime = zwasm.runtime.Runtime;
const Frame = zwasm.runtime.Frame;
const Trap = zwasm.runtime.Trap;
const ZirFunc = zwasm.runtime.zir.ZirFunc;

/// LLDB's Wasm address layout: 2-bit kind at bit 62 (1 = code), 30-bit module
/// id at bit 32, 32-bit module offset. One module here, id 0.
const code_kind: u64 = 0x4000000000000000;

const triple_hex = "7761736d33322d756e6b6e6f776e2d756e6b6e6f776e2d7761736d"; // wasm32-unknown-unknown-wasm

const Resume = enum { cont, step, kill };

const Stub = struct {
    r: *Io.Reader,
    w: *Io.Writer,
    rt: *Runtime,
    bytes: []const u8,
    name: []const u8,
    no_ack: bool = false,
    /// LLDB is waiting for a stop reply to its last continue/step.
    running: bool = false,
    stop_next: bool = true,
    bps: [64]u32 = undefined,
    n_bps: usize = 0,
    trap_seen: bool = false,
    cur_addr: u64 = code_kind,

    fn send(s: *Stub, data: []const u8) !void {
        var sum: u8 = 0;
        for (data) |c| sum +%= c;
        var tail: [3]u8 = undefined;
        _ = try std.fmt.bufPrint(&tail, "#{x:0>2}", .{sum});
        try s.w.writeAll("$");
        try s.w.writeAll(data);
        try s.w.writeAll(&tail);
        try s.w.flush();
    }

    /// Read one packet body into `buf`; acks it unless no-ack mode is on.
    fn recv(s: *Stub, buf: []u8) ![]const u8 {
        while (true) {
            const c = try s.r.takeByte();
            if (c == '$') break; // '+', '-' and ^C are ignored
        }
        var n: usize = 0;
        while (true) {
            const c = try s.r.takeByte();
            if (c == '#') break;
            if (n == buf.len) return error.PacketTooLong;
            buf[n] = c;
            n += 1;
        }
        _ = try s.r.takeByte();
        _ = try s.r.takeByte();
        if (!s.no_ack) {
            try s.w.writeAll("+");
            try s.w.flush();
        }
        return buf[0..n];
    }

    /// A stop reply carrying the pc (register 0, eight bytes little-endian),
    /// so LLDB matches the stop to its breakpoint site instead of a bare SIGTRAP.
    fn sendStop(s: *Stub, reason: []const u8) !void {
        var buf: [320]u8 = undefined;
        try s.send(try std.fmt.bufPrint(&buf, "T05thread:1;00:{x:0>16};{s}", .{ @byteSwap(s.cur_addr), reason }));
    }

    /// Frames innermost first, skipping ones with no function (a frame `run` pushes for itself).
    fn frameAt(s: *Stub, want: usize) ?*Frame {
        var seen: usize = 0;
        var i: usize = s.rt.frame_len;
        while (i > 0) {
            i -= 1;
            const f = &s.rt.frame_buf[i];
            if (f.func == null) continue;
            if (seen == want) return f;
            seen += 1;
        }
        return null;
    }

    fn moduleOffset(func: *const ZirFunc, pc: usize) ?u32 {
        const offs = func.src_offsets.items;
        if (pc >= offs.len) return null;
        return func.body_offset + offs[pc];
    }

    /// The code address a frame reports: the current instruction for the
    /// innermost frame, the return address (the instruction after the call)
    /// for the frames above it, as wasmtime reports them.
    fn frameAddr(f: *Frame, innermost: bool) u64 {
        const func = f.func.?;
        const n = func.src_offsets.items.len;
        if (n == 0) return code_kind;
        const pc = @min(if (innermost) f.pc else f.pc + 1, n - 1);
        return code_kind | moduleOffset(func, pc).?;
    }

    fn serve(s: *Stub) !Resume {
        var in_buf: [4096]u8 = undefined;
        var out: [1 << 17]u8 = undefined;
        while (true) {
            const p = try s.recv(&in_buf);
            if (std.mem.eql(u8, p, "QStartNoAckMode")) {
                try s.send("OK");
                s.no_ack = true;
            } else if (std.mem.startsWith(u8, p, "qSupported")) {
                // PacketSize is hex: 0x1000 bytes, the size of `in_buf`.
                try s.send("PacketSize=1000;QStartNoAckMode+;qXfer:libraries:read+;swbreak+;vContSupported+");
            } else if (std.mem.eql(u8, p, "qHostInfo")) {
                try s.send("triple:" ++ triple_hex ++ ";endian:little;ptrsize:4;");
            } else if (std.mem.eql(u8, p, "qProcessInfo")) {
                try s.send("pid:1;triple:" ++ triple_hex ++ ";endian:little;ptrsize:4;");
            } else if (std.mem.eql(u8, p, "?")) {
                try s.sendStop("");
            } else if (std.mem.eql(u8, p, "qfThreadInfo")) {
                try s.send("m1");
            } else if (std.mem.eql(u8, p, "qsThreadInfo")) {
                try s.send("l");
            } else if (std.mem.eql(u8, p, "qC")) {
                try s.send("QC1");
            } else if (std.mem.startsWith(u8, p, "H") or
                std.mem.startsWith(u8, p, "QThreadSuffixSupported") or
                std.mem.startsWith(u8, p, "QListThreadsInStopReply") or
                std.mem.startsWith(u8, p, "QEnableErrorStrings"))
            {
                try s.send("OK");
            } else if (std.mem.eql(u8, p, "qRegisterInfo0")) {
                try s.send("name:pc;alt-name:pc;bitsize:64;offset:0;encoding:uint;format:hex;set:General Purpose Registers;gcc:16;dwarf:16;generic:pc;");
            } else if (std.mem.startsWith(u8, p, "qRegisterInfo")) {
                try s.send("E45");
            } else if (std.mem.startsWith(u8, p, "p0") or std.mem.eql(u8, p, "g")) {
                var hex: [16]u8 = undefined;
                try s.send(try std.fmt.bufPrint(&hex, "{x:0>16}", .{@byteSwap(s.cur_addr)}));
            } else if (std.mem.startsWith(u8, p, "qXfer:libraries:read::")) {
                const rest = p["qXfer:libraries:read::".len..];
                const comma = std.mem.findScalar(u8, rest, ',') orelse {
                    try s.send("E01");
                    continue;
                };
                const off = std.fmt.parseInt(usize, rest[0..comma], 16) catch {
                    try s.send("E01");
                    continue;
                };
                if (off > 0) {
                    try s.send("l");
                } else {
                    // Written in decimal, as wasmtime does: bare digits are read as decimal.
                    const xml = try std.fmt.bufPrint(&out, "l<library-list><library name=\"{s}\"><section address=\"{d}\"/></library></library-list>", .{ s.name, code_kind });
                    try s.send(xml);
                }
            } else if (std.mem.startsWith(u8, p, "m")) {
                try s.readMemory(p[1..], &out);
            } else if (std.mem.startsWith(u8, p, "qWasmCallStack")) {
                var w: Io.Writer = .fixed(&out);
                var k: usize = 0;
                while (s.frameAt(k)) |f| : (k += 1) try w.print("{x:0>16}", .{@byteSwap(frameAddr(f, k == 0))});
                try s.send(w.buffered());
            } else if (std.mem.startsWith(u8, p, "qWasmLocal:")) {
                try s.readLocal(p["qWasmLocal:".len..], &out);
            } else if (std.mem.startsWith(u8, p, "qWasmGlobal:")) {
                try s.readGlobal(p["qWasmGlobal:".len..], &out);
            } else if (std.mem.startsWith(u8, p, "Z0,") or std.mem.startsWith(u8, p, "z0,")) {
                const rest = p[3..];
                const comma = std.mem.findScalar(u8, rest, ',') orelse rest.len;
                const addr = std.fmt.parseInt(u64, rest[0..comma], 16) catch {
                    try s.send("E01");
                    continue;
                };
                const off: u32 = @truncate(addr);
                if (p[0] == 'Z') {
                    if (s.n_bps == s.bps.len) {
                        try s.send("E0E");
                        continue;
                    }
                    s.bps[s.n_bps] = off;
                    s.n_bps += 1;
                } else if (std.mem.findScalar(u32, s.bps[0..s.n_bps], off)) |i| {
                    s.bps[i] = s.bps[s.n_bps - 1];
                    s.n_bps -= 1;
                }
                try s.send("OK");
            } else if (std.mem.eql(u8, p, "vCont?")) {
                try s.send("vCont;c;C;s;S");
            } else if (std.mem.startsWith(u8, p, "vCont;s") or std.mem.eql(u8, p, "s")) {
                s.running = true;
                return .step;
            } else if (std.mem.startsWith(u8, p, "vCont;c") or std.mem.eql(u8, p, "c")) {
                s.running = true;
                return .cont;
            } else if (std.mem.eql(u8, p, "k")) {
                try s.send("X09");
                return .kill;
            } else if (std.mem.startsWith(u8, p, "D")) {
                try s.send("OK");
                s.n_bps = 0;
                return .cont;
            } else {
                try s.send("");
            }
        }
    }

    fn readMemory(s: *Stub, args: []const u8, out: []u8) !void {
        const comma = std.mem.findScalar(u8, args, ',') orelse return s.send("E01");
        const addr = std.fmt.parseInt(u64, args[0..comma], 16) catch return s.send("E01");
        const len = std.fmt.parseInt(usize, args[comma + 1 ..], 16) catch return s.send("E01");
        const kind = addr >> 62;
        const off: usize = @truncate(addr & 0xffff_ffff);
        // Code addresses read the module bytes (LLDB's source of DWARF and
        // names); everything else reads linear memory.
        const src: []const u8 = if (kind == 1) s.bytes else s.rt.memory;
        if (kind > 1 or off >= src.len) return s.send("E03");
        const n = @min(len, src.len - off, out.len / 2);
        try s.send(try std.fmt.bufPrint(out, "{x}", .{src[off .. off + n]}));
    }

    /// `frame;index` — the form LLDB 23 sends for qWasmLocal / qWasmGlobal.
    fn frameAndIndex(args: []const u8) ?struct { frame: usize, index: usize } {
        const semi = std.mem.findScalar(u8, args, ';') orelse return null;
        return .{
            .frame = std.fmt.parseInt(usize, args[0..semi], 10) catch return null,
            .index = std.fmt.parseInt(usize, args[semi + 1 ..], 10) catch return null,
        };
    }

    fn readLocal(s: *Stub, args: []const u8, out: []u8) !void {
        const fi = frameAndIndex(args) orelse return s.send("E01");
        const f = s.frameAt(fi.frame) orelse return s.send("E03");
        if (fi.index >= f.locals.len) return s.send("E03");
        const params = f.sig.params;
        const vt = if (fi.index < params.len) params[fi.index] else f.func.?.locals[fi.index - params.len];
        const size: usize = switch (vt) {
            .i32, .f32 => 4,
            .v128 => 16,
            else => 8,
        };
        try s.send(try std.fmt.bufPrint(out, "{x}", .{std.mem.asBytes(&f.locals[fi.index])[0..size]}));
    }

    fn readGlobal(s: *Stub, args: []const u8, out: []u8) !void {
        const fi = frameAndIndex(args) orelse return s.send("E01");
        if (fi.index >= s.rt.globals.len) return s.send("E03");
        try s.send(try std.fmt.bufPrint(out, "{x}", .{std.mem.asBytes(s.rt.globals[fi.index])[0..8]}));
    }
};

/// Stop where the guest traps. `debug_trap` also hears errors that are not
/// traps, and hears each error again from every enclosing call; only the first
/// report of a trap stops.
fn trapHook(ctx: *anyopaque, pc: u32, err: anyerror) void {
    const s: *Stub = @ptrCast(@alignCast(ctx));
    // Not traps: the stub's own stop or kill, and a WASI exit.
    if (err == Trap.Interrupted or err == error.WasiExit) return;
    // A thrown exception is one only once no caller is left to catch it; the
    // outermost frame then reports it at its own pc, not at the `throw`.
    if (err == Trap.UncaughtException and s.rt.pending_exception != null and s.frameAt(1) != null) return;
    if (s.trap_seen) return;
    // A frame with no function, or a pc past its offset table, leaves the
    // report to the enclosing call.
    const func = s.rt.currentFrame().func orelse return;
    const off = Stub.moduleOffset(func, pc) orelse return;
    s.trap_seen = true;
    s.cur_addr = code_kind | off;
    if (!s.running) return;
    s.running = false;
    stopAtTrap(s, err) catch |e| report("trap stop", e);
}

fn stopAtTrap(s: *Stub, err: anyerror) !void {
    var msg_buf: [96]u8 = undefined;
    var reason_buf: [256]u8 = undefined;
    // The message the CLI and the C API give for the same trap.
    const trap_surface = zwasm.api.trap_surface;
    const msg = try std.fmt.bufPrint(&msg_buf, "trap: {s}", .{trap_surface.trapMessageFor(trap_surface.mapInterpTrap(err))});
    try s.sendStop(try std.fmt.bufPrint(&reason_buf, "reason:exception;description:{x};", .{msg}));
    // The guest cannot resume past a trap: continue, step and kill all end it.
    _ = try s.serve();
}

fn hook(ctx: *anyopaque, pc: u32) bool {
    const s: *Stub = @ptrCast(@alignCast(ctx));
    const func = s.rt.currentFrame().func orelse return false;
    const off = Stub.moduleOffset(func, pc) orelse return false;
    if (!s.stop_next and std.mem.findScalar(u32, s.bps[0..s.n_bps], off) == null) return false;
    s.stop_next = false;
    s.cur_addr = code_kind | off;
    if (s.running) {
        s.running = false;
        s.sendStop("swbreak:;") catch |e| {
            report("stop reply", e);
            return true;
        };
    }
    const action = s.serve() catch |e| {
        report("serving a stop", e);
        return true;
    };
    switch (action) {
        .cont => {},
        .step => s.stop_next = true,
        .kill => return true,
    }
    return false;
}

fn report(what: []const u8, err: anyerror) void {
    std.debug.print("gdbstub-poc: {s} failed: {s}; abandoning the session\n", .{ what, @errorName(err) });
}

pub fn main(init: std.process.Init) !void {
    zwasm.support.dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));
    const io = init.io;
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.Usage;
    const export_name = args.next() orelse return error.Usage;
    const arg0 = try std.fmt.parseInt(i32, args.next() orelse return error.Usage, 10);
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);

    // The stub serves these bytes to LLDB, so they outlive the module.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);

    var eng = try zwasm.Engine.init(gpa, .{});
    defer eng.deinit();
    var mod = try eng.compile(bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .interp, .fuel = .unmetered });
    defer inst.deinit();
    const rt = inst.handle.runtime orelse return error.NotInterpreter;
    // `typedFunc` resolves the export only when called, after LLDB has
    // connected; a wrong name or type would drop LLDB without a reply.
    const sig = inst.exportFuncSig(export_name) orelse return error.ExportNotFound;
    if (sig.params.len != 1 or sig.params[0] != .i32 or sig.results.len != 1 or sig.results[0] != .i32)
        return error.ExportNotI32ToI32;

    var addr = try net.IpAddress.parse("127.0.0.1", port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("gdbstub-poc: listening; in LLDB: process connect --plugin wasm connect://127.0.0.1:{d}\n", .{port});
    const stream = try server.accept(io);
    defer stream.close(io);

    var rbuf: [8192]u8 = undefined;
    var wbuf: [1 << 17]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);

    var stub: Stub = .{
        .r = &sr.interface,
        .w = &sw.interface,
        .rt = rt,
        .bytes = bytes,
        .name = std.Io.Dir.path.basename(path),
    };
    rt.debug_hook = hook;
    rt.debug_trap = trapHook;
    rt.debug_ctx = @ptrCast(&stub);

    const func = inst.typedFunc(fn (i32) i32, export_name);
    var exit_buf: [8]u8 = undefined;
    const exit_packet = if (func.call(.{arg0})) |result| blk: {
        std.debug.print("gdbstub-poc: {s}({d}) = {d}\n", .{ export_name, arg0, result });
        // GDB exit status is one byte; report the result's low byte.
        break :blk try std.fmt.bufPrint(&exit_buf, "W{x:0>2}", .{@as(u8, @truncate(@as(u32, @bitCast(result))))});
    } else |err| blk: {
        std.debug.print("gdbstub-poc: guest ended with {s}\n", .{@errorName(err)});
        break :blk "X05"; // terminated by the SIGTRAP the trap stop reported
    };
    if (stub.running) try stub.send(exit_packet);
}
