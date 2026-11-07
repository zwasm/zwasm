- **On the interpreter, an active element segment whose table64 offset lies
  past the table is refused** (#685). Before, an offset near 2^64 overflowed
  the range check and the host process stopped.
