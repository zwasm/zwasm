- **A WASI 0.1 `poll_oneoff` clock subscription with an unknown `clock_id`
  fails with `inval` on the relative path too** (#311). Before, an id that is
  none of the four `clockid` values was checked only when `ABSTIME` was set,
  and a relative subscription with it became a plain timer.
