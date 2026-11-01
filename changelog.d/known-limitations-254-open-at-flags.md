- **WASI 0.2 and 0.3 `open-at` ignores the requested descriptor-flags and
  opens every file read-write** (#254), so a host file the process may read
  but not write cannot be opened.
