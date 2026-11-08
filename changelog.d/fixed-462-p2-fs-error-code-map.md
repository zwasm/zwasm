- **A WASI 0.2 guest's filesystem error for a path outside the preopen is
  `not-permitted`, as the spec and wasmtime give it** (#462). That and seven
  other conditions (`deadlock`, `quota`, `no-lock`, `not-recoverable`,
  `no-tty`, `no-such-device`, `text-file-busy`) read as `io` before.
