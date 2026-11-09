- **`zwasm serve` runs a WASI 0.3 `wasi:http/service` component as an
  HTTP/1.1 server** (#688). One instance, one request at a time; `--addr`
  (default `127.0.0.1:8080`, port 0 picks a free one); prints
  `Serving HTTP on http://…` to stderr. The 0.2 `incoming-handler` half is
  still not served.
