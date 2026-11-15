- **A WASI path is resolved one component at a time and stays beneath its
  preopen.** A path that leaves it, as text or through a symlink, is refused
  (`notcapable` on 0.1, `not-permitted` on 0.2 and 0.3), and a new symlink's
  target is checked from the directory the link lands in.
  [GHSA-vh35-jrc2-qj4q](https://github.com/zwasm/zwasm/security/advisories/GHSA-vh35-jrc2-qj4q).
