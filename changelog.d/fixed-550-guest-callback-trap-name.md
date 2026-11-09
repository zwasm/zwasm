- **A trap the guest's `cabi_realloc` or a resource destructor raises reaches
  the embedder as that trap** (#550). Before, both reported `HostTrap`, the
  name for a host-side failure.
