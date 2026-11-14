- **Each release archive carries SLSA build provenance.** `gh attestation
  verify <archive> --repo zwasm/zwasm` confirms the archive was built by the
  release workflow from the tagged commit; `SHA256SUMS` alone could not tell a
  replaced archive from the original.
