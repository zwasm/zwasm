#!/usr/bin/env python3
"""The source of call_stack_args.wasm. No .wat is committed: it is 2.7 MB.

    python3 call_stack_args.py call_stack_args.wat
    wasm-tools parse call_stack_args.wat -o call_stack_args.wasm

(Python 3.12, wasm-tools 1.262.0; the output is deterministic, so the
rebuilt .wasm is byte-identical to the committed one.)

Each cell is a call whose signature sits on or across a register/stack
boundary of a convention. The callee folds every argument into a checksum: it
calls each reference (each position passes a function returning its own
value) and reads both lanes of a `v128`. The caller folds in two values that
are live across the call. So a stack write that lands on a live slot or on
another argument changes the result. The expected value of each cell is
computed here, not taken from an engine. `test` returns how many cells differ
from it.

Axes: integer kind (funcref, or i64/funcref/i32 in turn) x count, f64 count,
v128 count, where the integers sit (before, after or between the floats, or
the last one between two v128s), the callee's result count (3 = MEMORY-class),
and whether the caller is MEMORY-class. The JIT does not lower a spilled v128 argument (D-078 (c)),
and integer and FP values draw on one slot space (#635), so every scalar
argument pushed before the first v128 comes out of an identity call, which
moves it to a frame slot; one pushed after a v128 is a constant. A v128 is
then never the vreg the allocator spills.
"""
import itertools
import struct
import sys

INT_KINDS = ["mixed", "funcref"]
N_INT = [0, 2, 3, 4, 5, 6, 7]
N_F64 = [0, 7, 8]
N_V128 = [1, 2]
PLACEMENTS = ["ints_first", "ints_last", "interleaved", "split"]
CALLEE_RES = [1, 3]
CALLER_MEM = [False, True]

MASK = (1 << 64) - 1


def s64(x):
    x &= MASK
    return x - (1 << 64) if x >> 63 else x


def int_kind(kind, i):
    return ["i64", "funcref", "i32"][i % 3] if kind == "mixed" else kind


def params(kind, n_int, n_f64, n_v128, placement):
    ints = [int_kind(kind, i) for i in range(n_int)]
    fps = ["f64"] * n_f64 + ["v128"] * n_v128
    if placement == "ints_first":
        return ints + fps
    if placement == "ints_last":
        return fps + ints
    if placement == "split":
        # The last integer sits between the first v128 and the rest, so a SysV
        # integer overflow can fall between two v128 overflows.
        f64s, v128s = fps[:n_f64], fps[n_f64:]
        return f64s + ints[:-1] + v128s[:1] + ints[-1:] + v128s[1:]
    out = []
    for i in range(max(len(ints), len(fps))):
        out += ints[i : i + 1] + fps[i : i + 1]
    return out


IDENTITY = {"i64": "$id_i64", "i32": "$id_i32", "f64": "$id_f64", "funcref": "$id_ref"}


# A reference argument is typed `(ref null $t)` so the callee can `call_ref`
# it; it is still a reference to the ABI. Position k passes `$leaf{k}`.
WAT_TYPE = {"funcref": "(ref null $t)"}
MAX_PARAMS = max(N_INT) + max(N_F64) + max(N_V128)


def leaf_value(k):
    return 0x4C4C000000000000 + (k << 8) + 0x2B


def v128_lanes(k, cell):
    return 0x7700000000000000 + (cell << 16) + (k << 4) + 1, 0x6600000000000000 + (cell << 16) + (k << 4) + 2


def arg(p, k, cell, via_call, j):
    """(wat instructions, value folded into the checksum). `j` numbers the v128s."""
    if p == "i64":
        v = 0x0101010101010101 * (k + 1) + cell
        instr = f"i64.const {v}"
    elif p == "i32":
        v = 1000 * k + cell + 7
        instr = f"i32.const {v}"
    elif p == "f64":
        x = 1.5 + k + cell / 1024
        v = struct.unpack("<Q", struct.pack("<d", x))[0]
        instr = f"f64.const {x!r}"
    elif p == "funcref":
        v = leaf_value(k)
        instr = f"ref.func $leaf{k}"
    else:
        lo, hi = v128_lanes(k, cell)
        return ("local.get $v" if j == 0 else f"v128.const i64x2 {lo} {hi}"), lo + 7 * hi
    return (f"{instr} call {IDENTITY[p]}" if via_call else instr), v


CONVERT = {"i64": [], "i32": ["i64.extend_i32_u"], "f64": ["i64.reinterpret_f64"], "funcref": ["call_ref $t"]}
LOCALS = "(local $v v128)"


def fold_arg(k, p):
    if p == "v128":
        return [f"local.get {k}", "i64x2.extract_lane 0", f"local.get {k}", "i64x2.extract_lane 1", "i64.const 7", "i64.mul", "i64.add"]
    return [f"local.get {k}"] + CONVERT[p]


def fold3(n_res):
    return ["i64.const 31", "i64.mul", "i64.add"] * (n_res - 1)


def fold_value(rs):
    r = rs[-1]
    for x in reversed(rs[:-1]):
        r = x + 31 * r
    return r


def cell_wat(cell, ps, n_res, caller_mem):
    sig = " ".join(f"(param {WAT_TYPE.get(p, p)})" for p in ps)
    body, acc, pushes, init = [], 0, [], []
    first_v128 = ps.index("v128")
    for k, p in enumerate(ps):
        j = ps[:k].count("v128")
        instr, v = arg(p, k, cell, k < first_v128, j)
        if p == "v128" and j == 0:
            init += [f"v128.const i64x2 {' '.join(map(str, v128_lanes(k, cell)))}", "local.set $v"]
        pushes.append(instr)
        acc = (acc + v * (2 * k + 3)) & MASK
        body += fold_arg(k, p) + [f"i64.const {2 * k + 3}", "i64.mul", "local.get $acc", "i64.add", "local.set $acc"]
    rets = ["local.get $acc"]
    for j in range(1, n_res):
        rets += ["local.get $acc", f"i64.const {j}", "i64.add"]
    out = [f"(func $callee{cell} {sig} (result {' '.join(['i64'] * n_res)}) (local $acc i64) {' '.join(body + rets)})"]

    # Two canaries sit under the arguments on the operand stack, live across
    # the call. The caller has no integer local, so no home-save area: what
    # lies just above the outgoing-args region is spilled values, and for a
    # MEMORY-class caller the slot holding its own result pointer.
    canaries = [0x5A5A5A5A5A5A5A5A + cell, 0x3C3C3C3C3C3C3C3C + cell]
    caller = init + [f"i64.const {c}" for c in canaries]
    caller += pushes + [f"call $callee{cell}"] + fold3(n_res)
    x = fold_value([acc + j for j in range(n_res)])
    # The stack is now [canary0, canary1, x].
    if caller_mem:
        out.append(f"(func $mid{cell} (result i64 i64 i64) {LOCALS} {' '.join(caller)})")
        out.append(f'(func $c{cell} (export "c{cell}") (result i64) call $mid{cell} {" ".join(fold3(3))})')
    else:
        out.append(f'(func $c{cell} (export "c{cell}") (result i64) {LOCALS} {" ".join(caller + fold3(3))})')
    return out, s64(fold_value(canaries + [x]))


def main(path):
    funcs, checks = [], []
    cells = list(itertools.product(INT_KINDS, N_INT, N_F64, N_V128, PLACEMENTS, CALLEE_RES, CALLER_MEM))
    for cell, (kind, n_int, n_f64, n_v128, placement, n_res, caller_mem) in enumerate(cells):
        fs, expected = cell_wat(cell, params(kind, n_int, n_f64, n_v128, placement), n_res, caller_mem)
        funcs += fs
        checks.append(f"call $c{cell} i64.const {expected} i64.ne local.get $bad i32.add local.set $bad")
    with open(path, "w") as f:
        f.write(f";; Generated by call_stack_args.py: {len(cells)} cells. `test` returns the number that differ.\n")
        f.write("(module\n(type $t (func (result i64)))\n")
        leaves = [f"$leaf{k}" for k in range(MAX_PARAMS)]
        for k, name in enumerate(leaves):
            f.write(f"(func {name} (type $t) i64.const {leaf_value(k)})\n")
        f.write(f"(elem declare func {' '.join(leaves)})\n")
        for p, name in IDENTITY.items():
            t = WAT_TYPE.get(p, p)
            f.write(f"(func {name} (param {t}) (result {t}) local.get 0)\n")
        f.write("\n".join(funcs) + "\n")
        f.write('(func (export "test") (result i32) (local $bad i32)\n' + "\n".join(checks) + "\nlocal.get $bad))\n")


if __name__ == "__main__":
    main(sys.argv[1])
