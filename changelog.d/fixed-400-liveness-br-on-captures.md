- **A block whose first exit is `br_on_null`, `br_on_non_null`, `br_on_cast`
  or `br_on_cast_fail` returns the right result on the JIT** (#400). The
  liveness pass did not record the block's merge values at those four
  instructions as the emit does, so with a call between the block's end and
  the use of its result, the register holding it could be reused first.
