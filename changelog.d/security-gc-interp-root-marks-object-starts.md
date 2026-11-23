- **On the interpreter, a garbage collection marks a value only when it is the
  start of a GC object.** Before, an even integer in a local, an operand or a
  global that fell inside the GC heap was marked as a reference, which changed a
  field or a reference inside an object or aborted the process; a GC program
  with over 1 MiB of heap could get a wrong value.
