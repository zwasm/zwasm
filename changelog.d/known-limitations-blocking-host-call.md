- **`--timeout` and `Instance.interrupt` do not stop a guest inside a host call
  that blocks** (#732). A preview1 `fd_read` of a silent stdin outlasts them; a
  preview1 `poll_oneoff` clock wait is interrupted. A WASI 0.2 / 0.3 clock wait
  and a 0.2 socket read outlast them too (#730).
