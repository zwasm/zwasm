- **A `.cwasm` does not record which zwasm build produced it** (#665).
  `zwasm run x.cwasm` accepts any artifact whose format version and arch
  match and reads the runtime at the producing build's layout. Load a `.cwasm`
  only into the binary that compiled it; the `--cache` directory is keyed by
  version, so only development builds sharing one are exposed.
