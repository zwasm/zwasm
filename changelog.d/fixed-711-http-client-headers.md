- **A `wasi:http` request goes out with only the guest's headers, `host` and
  its framing** (#711). The host added `user-agent`, `accept-encoding` and
  `connection: keep-alive` the guest did not set, and a guest that set
  `user-agent` or `accept-encoding` itself sent that header twice.
