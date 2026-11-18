- **On the arm64 JIT, `br_on_null` to a loop branches exactly when its
  operand is null.** On the back edge of a loop with no params the branch
  was never taken without a fuel budget, and always taken with one (the call
  then ended in `out_of_fuel`): it tested a register the back-edge poll had
  just written. It now reads its condition first.
