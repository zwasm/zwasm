# 0226 — The liveness parity check gates the JIT spec lane, with a named list

- **Status**: Proposed (gate definition per ADR-0212 D1 — lands in one PR
  with the lane it defines, and flips to Accepted on the maintainer's word
  on that PR, the way ADR-0225 did on #380; D1's placement is the part that
  needs it, D3 is apparatus-internal)
- **Date**: 2026-09-05
- **Author**: Junji Takakura
- **Tags**: ci, jit, liveness, gate, ratchet

## Context

`ZWASM_DEBUG=liveverify` (#269, 2026-08-24) compares, per instruction, the
operand stack liveness simulated against the one the emit actually pushed
(`src/engine/codegen/shared/liveness_parity.zig`, the D-596 invariant). A
divergence means liveness numbers vregs differently from the emit from that
point on, and the JIT can read a dead register with no trap. That class
shipped four silent miscompiles in v2.6.0 (#250, #252, #258, #272) and is the
one the differential lanes are weakest against: a stale merge register only
shows in a value when a call sits between the branch and the consumer
(D-330), which the spec corpus mostly does not do — so a lane can be green
over a divergence (#400: "no wrong answer is demonstrated").

#269 landed the check as "**Diagnostic, not a gate** — prints and continues"
and deferred gating explicitly: "Blocking CI on it needs an ADR (ADR-0076 D9,
ADR-0212 D1)". Two numbers were missing then and are measured now, on `main`
at `7c7e434ea`, the whole `test-spec-wasm-3.0-assert` step (both engines, all
six sub-corpora):

| | wall | `[liveverify]` residual lines, JIT lane |
|---|---|---|
| gate off | 7.46 s | 0 |
| gate on | 7.61 s | **69 over 10 modules** |

That pair is the check's own overhead inside one lane, not what this decision
costs; D1 carries that figure. The ten commonest ops the divergence is first
seen at: `end` 21, `return` 16,
`i32.const` 8, `i32.add` 4, `drop` 4, `call_ref` 4, `unreachable` 3,
`struct.get_s` 2, `br_on_cast` 2, `block` 2 (66 of the 69). #269 measured 178 on the spec
corpus; #398 (open) takes the `end` / `return` class next. Every residual so
far has been found by hand and filed as its own issue — eight numbers for
one root, which #400 now holds as a table.

Two facts shape where the check can live. The env must not be set on
`test-all`: the AOT unit tests fail under it by design
(`.dev/lessons/2026-08-24-measurement-scaffolding-hid-the-product-gate.md`).
And the checker is `void` — it prints a line carrying `func[N]` and nothing
else, so nothing today can attribute a residual to a module or count it.

The house already has two gates of the shape this one needs: #376's JIT spec
lane, which enumerates known-wrong outcomes per target (`jitKnownFails`,
`.{ .key, .count }`) and reports `enumerated / unexpected / stale`; and
ADR-0225's preview1 ratchet, which records names, never a count, and trips
on a row that stops firing.

## Decision

### D1 — The JIT spec lane runs once more with the parity check on, and blocks

A step beside `test-spec-wasm-3.0-assert`'s JIT run — same runner, same
corpus, `ZWASM_SPEC_ENGINE=jit`, the product gate `dbg.on("liveverify")`
on — joins `test-all` and therefore the core `ci-required` gate on all three
legs. It exits non-zero when the residuals it observes differ from a named
list: a residual on a module no row names is `unexpected`, and so is a listed
module that fires MORE than its row enumerates — a divergence the list has not
seen, on a module that happens to be listed. A listed module that fires fewer,
none included, is `stale`: the row over-claims and must come down. All three
red the PR.

The cost is the run, not the check: turning the gate on inside a lane is 2 %
(the table above), but D1 is a second full JIT lane, so `test-all` grows by one
JIT lane — the same order as the step it sits beside. That is #376's argument
for the core gate rather than `ZWASM_CI_EXTENDED`, whose extended set covers
only the Unix legs.

The step must fail if the channel it asks for is not on. `liveness_parity` is
comptime-dead in ReleaseFast / ReleaseSmall, and every branch of this gate —
down to its summary line — is inside `if (lv_mode)`, so a dark channel is an
exit 0 with nothing printed rather than a quieter lane. The runner says
`LIVEVERIFY-CHANNEL-DARK` and exits non-zero instead.

### D2 — The list names modules, per target, and is held in both directions

`test/spec/spec_assert_runner_wasm_3_0.zig` grows a `liveverifyKnown()`
table in `jitKnownFails`'s shape: rows are `.{ .key =
"<proposal>/<dir>/<module>.wasm", .count = <residual lines> }`, one table
per target (x86_64 SysV / x86_64 Win64 / aarch64), selected the way
`jitKnownFails` selects. A row must name its line in #400's table. The
count is per row so that "one func fixed, one regressed" in the same module
is visible; the list carries no total.

The seeds are taken the way #376 took its Windows row: the x86_64 SysV table
is seeded from this host (the 69 above, re-taken on the PR's base), and the
x86_64 Win64 and aarch64 tables start **empty**, so the PR's first CI run
reports every residual on those legs as `unexpected` and names them. Those
names are copied into the tables and pushed; the second run is the proof
that the tables describe CI's runners and nothing else (ADR-0225 D2). This
is why the ADR and the lane are one PR — two of the three tables cannot be
written before the lane runs in CI.

### D3 — The checker counts, the runner attributes; the env stays off `test-all`

Two apparatus-internal changes, no sign-off (ADR-0212 D1):

- `liveness_parity` keeps a residual counter the runner can read and reset
  per module. `check` stays `void` and keeps printing; the count is what the
  gate compares.
- The runner prints the module path with the first residual of each module
  and reads the counter after each, so a residual line can be attributed
  without re-running the module by hand.

The new step is the only place the env is set. `test-all` with
`ZWASM_DEBUG=liveverify` remains unsupported for the reason the lesson
records.

### D4 — #400 is the ledger; rows leave with their fix

A PR that fixes a drift removes its row in the same change, which `stale`
enforces. A new drift lands as a row here **and** a row on #400, not as a
new issue. #398, if it lands after this, retires the `end` / `return` rows
it fixes in its own diff. Retiring the root — deriving liveness's
control-flow mirror from the emit's source (ADR-0088 extended to edges) —
is #400's move 2 and is not decided here.

## Alternatives considered

### Alternative A — Report first, block later

- **Sketch**: land the same step with `continue-on-error: true`; promote it
  to blocking at a residual count the maintainer names.
- **Why not chosen**: `continue-on-error` rewrites `conclusion` to
  `success`, which is what `ci-required` reads — #307 item 6 and ADR-0225's
  Context are the record of a check that reported and was not read. The
  list mechanism already makes day-one blocking safe: 10 rows carrying 69
  lines are debt made visible, not red PRs. **This is the maintainer's call, not a rejection**:
  if A is preferred, D1 gains the `continue-on-error` and a promotion
  threshold, and the Status line records it.

### Alternative B — Keep the check diagnostic

- **Sketch**: leave #269 as it is; run it by hand when touching liveness.
- **Why rejected**: that is the current state, and it produced eight issues
  and four shipped miscompiles. The class is the one the other lanes cannot
  see.

### Alternative C — Gate on the total residual count

- **Sketch**: a single number; red when it rises.
- **Why rejected**: ADR-0225's reason — a count cannot tell "one fixed, one
  regressed" from "no change", and a copied count has already gone stale
  against its debt row once in this repository.

## Consequences

- **Positive**: a liveness/emit divergence becomes a red PR on the commit
  that introduces it, on every target CI runs, instead of an issue filed
  after someone runs the check by hand. The 10 rows become load-bearing:
  each is one someone must retire, and #398's rows must go in #398.
- **Negative**: a divergence with no demonstrated wrong answer still reds a
  PR until it is listed. That is the point of an invariant gate, but it is
  a new kind of red for this lane and the failure message must say which
  row to add.
- **Negative**: a row's unit is the module, so a fix and a new divergence in
  the same module cancel and the gate stays quiet — the objection Alternative
  C is rejected for, one level down. The residual lines carry `func[N]`, so the
  granularity to close it exists; it is not spent here because a per-func list
  is a table an order of magnitude longer for a debt that only ratchets down.
- **Neutral / follow-ups**: the arm64 and Win64 seeds are taken from CI's
  own legs, not from a Linux host; ADR-0225 D2's "the table describes CI's
  runner" applies. The 2.0 corpus is not in this lane; whether it should be
  is a measurement for later, not a gap in this decision.

## References

- #269 (the check, and its deferral of gating), #376 (`jitKnownFails`, core
  placement), #380 / ADR-0225 (names not counts, `stale`), #400 (the ledger
  of rows), #398 (open, the `.end` class)
- ADR-0212 D1 (gate definitions need sign-off; apparatus does not),
  ADR-0076 D9 (CI is authoritative), ADR-0088 (stack-effect extraction — the
  half of the mirror that is table-driven)
- `.dev/lessons/2026-06-02-jit-liveness-must-mirror-emit-pushed-vregs.md`
  (D-596), `.dev/lessons/2026-08-24-measurement-scaffolding-hid-the-product-gate.md`
