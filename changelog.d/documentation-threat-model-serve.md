- **The threat model covers `zwasm serve`.** A peer that connects to its
  listener is untrusted, and a host crash it causes is a breach of goal 2;
  the listener has no TLS or authentication, and its availability is not a
  security goal.
