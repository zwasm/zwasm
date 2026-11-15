// DBG-INIT-EXEMPT: an active ZWASM_DEBUG channel makes produceFromCompiledWasm refuse, so this runner compiles with every channel dark.
//! `zwasm compile` gives the same bytes for the same module. One module
//! with a defined global of every value type is compiled twice in this
//! process and once in a child process (this executable, re-run with
//! `--child`); the three `.cwasm` files must be byte-identical. The
//! executable is built position-independent, so the child loads at another
//! address and a byte left over from an address does not repeat.
//!
//! Usage: `zwasm-cwasm-determinism` (exit 0 = identical).

const std = @import("std");
const zwasm = @import("zwasm");

const runner = zwasm.engine.runner;
const produce = zwasm.engine.codegen.aot.produce;

/// (module
///   (global i32 (i32.const -2))   (global i64 (i64.const -2))
///   (global f32 (f32.const -1))   (global f64 (f64.const -1))
///   (global funcref (ref.null func))  (global externref (ref.null extern))
///   (global v128 (v128.const i8x16 0xF0 0xF1 … 0xFF))
///   (func (export "f") (result i32) (global.get 0)))
const module_bytes = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
    0x03, 0x02, 0x01, 0x00, // func: type 0
    0x06, 0x3e, 0x07, // global: 7 entries
    0x7f, 0x00, 0x41, 0x7e, 0x0b, // i32
    0x7e, 0x00, 0x42, 0x7e, 0x0b, // i64
    0x7d, 0x00, 0x43, 0x00, 0x00, 0x80, 0xbf, 0x0b, // f32
    0x7c, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0xbf, 0x0b, // f64
    0x70, 0x00, 0xd0, 0x70, 0x0b, // funcref
    0x6f, 0x00, 0xd0, 0x6f, 0x0b, // externref
    0x7b, 0x00, 0xfd, 0x0c, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff, 0x0b, // v128
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export "f" = func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // code: global.get 0
};

fn compileOnce(gpa: std.mem.Allocator) ![]u8 {
    var compiled = try runner.compileWasmForAot(gpa, &module_bytes);
    defer compiled.deinit(gpa);
    return produce.produceFromCompiledWasm(gpa, &compiled, &module_bytes);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next();
    if (arg_it.next()) |a| if (std.mem.eql(u8, a, "--child")) {
        const bytes = try compileOnce(gpa);
        defer gpa.free(bytes);
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
        try out.interface.writeAll(bytes);
        try out.interface.flush();
        return 0;
    };

    const first = try compileOnce(gpa);
    defer gpa.free(first);
    const second = try compileOnce(gpa);
    defer gpa.free(second);

    const self_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_path);
    const child = try std.process.run(gpa, io, .{ .argv = &.{ self_path, "--child" } });
    defer gpa.free(child.stdout);
    defer gpa.free(child.stderr);
    if (child.term != .exited or child.term.exited != 0) {
        std.debug.print("cwasm_determinism: child compile failed ({any}): {s}\n", .{ child.term, child.stderr });
        return 1;
    }

    var failed = false;
    for ([_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "second in-process compile", .bytes = second },
        .{ .name = "child-process compile", .bytes = child.stdout },
    }) |other| {
        if (std.mem.eql(u8, first, other.bytes)) continue;
        failed = true;
        const at = std.mem.findDiff(u8, first, other.bytes).?;
        std.debug.print("cwasm_determinism: the {s} differs from the first at byte {d} of {d}/{d}\n", .{ other.name, at, first.len, other.bytes.len });
    }
    if (failed) return 1;
    std.debug.print("cwasm_determinism: 3 compiles, {d} bytes each, identical\n", .{first.len});
    return 0;
}
