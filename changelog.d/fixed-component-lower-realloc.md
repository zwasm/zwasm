- **A component built with the preview1 adapter (a Go reactor, for one)
  places lowered results through the lower's own realloc** (#639). It used
  `cabi_realloc`, and the adapter asserted. Lowers naming two different
  reallocs now fail the build with `UnsupportedLowerRealloc`.
