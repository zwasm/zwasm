- **`invokeTyped` calls a single-module component that has no memory** (#676).
  A component lifting only scalar signatures needs none, but the call failed
  with `NoMemory` before it reached the guest.
