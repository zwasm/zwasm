- **A `wasi:http` client request is sent only when its scheme is `http`.**
  In 0.3, `https`, any other scheme, or none fails with
  `HTTP-protocol-error`; in 0.2, `handle` refuses them with
  `HTTP-request-URI-invalid`, which now covers a request with no scheme.
  The client does not speak `https` yet.
