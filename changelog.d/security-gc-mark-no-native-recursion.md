- **A garbage collection marks a chain of GC objects of any length without
  recursing on the native stack.** Before, the mark phase recursed once per
  object, so a linked list of about 90,000 structs overflowed an 8 MiB stack at
  the next collection and the process died on a fatal signal, on the
  interpreter and on the JIT.
