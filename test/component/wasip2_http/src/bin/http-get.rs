//! `HTTP_ENDPOINT` = `host:port`. argv[1] picks the check (default `get`);
//! each prints one line per observation.
use wasip2::http::outgoing_handler;
use wasip2::http::types::{
    Fields, FutureIncomingResponse, IncomingBody, Method, OutgoingBody,
    OutgoingRequest, Scheme,
};
use wasip2::io::streams::StreamError;

fn request(method: Method) -> OutgoingRequest {
    let endpoint = std::env::var("HTTP_ENDPOINT").expect("HTTP_ENDPOINT");
    let req = OutgoingRequest::new(Fields::new());
    req.set_method(&method).unwrap();
    req.set_scheme(Some(&Scheme::Http)).unwrap();
    req.set_authority(Some(&endpoint)).unwrap();
    req.set_path_with_query(Some("/")).unwrap();
    req
}

/// `method` with `bytes` written through the body and finished.
fn with_body(method: Method, bytes: &[u8]) -> OutgoingRequest {
    let req = request(method);
    let body = req.body().unwrap();
    let out = body.write().unwrap();
    out.blocking_write_and_flush(bytes).unwrap();
    drop(out);
    OutgoingBody::finish(body, None).unwrap();
    req
}

fn send(req: OutgoingRequest) -> Option<FutureIncomingResponse> {
    match outgoing_handler::handle(req, None) {
        Ok(fut) => Some(fut),
        Err(e) => {
            println!("handle: {e:?}");
            None
        }
    }
}

fn print_response(fut: &FutureIncomingResponse) {
    fut.subscribe().block();
    let resp = match fut.get().expect("ready") {
        Ok(Ok(resp)) => resp,
        Ok(Err(e)) => return println!("get: {e:?}"),
        Err(()) => return println!("get: taken"),
    };
    println!("status: {}", resp.status());
    let body = resp.consume().unwrap();
    let stream = body.stream().unwrap();
    let mut bytes = Vec::new();
    loop {
        match stream.blocking_read(4096) {
            Ok(chunk) => bytes.extend(chunk),
            Err(StreamError::Closed) => break,
            Err(e) => panic!("read: {e:?}"),
        }
    }
    drop(stream);
    let trailers = IncomingBody::finish(body);
    trailers.subscribe().block();
    println!("body: {}", String::from_utf8_lossy(&bytes));
    println!("trailers: {:?}", trailers.get().map(|r| r.map(|r| r.map(|t| t.is_some()))));
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "get".into());
    match mode.as_str() {
        "get" => {
            if let Some(fut) = send(request(Method::Get)) {
                print_response(&fut);
            }
        }
        "post" | "get-body" | "delete-body" => {
            let method = match mode.as_str() {
                "post" => Method::Post,
                "get-body" => Method::Get,
                _ => Method::Delete,
            };
            if let Some(fut) = send(with_body(method, b"ping")) {
                print_response(&fut);
            }
        }
        "live-in" => {
            let fut = send(with_body(Method::Post, b"ping")).unwrap();
            fut.subscribe().block();
            let resp = fut.get().unwrap().unwrap().unwrap();
            let body = resp.consume().unwrap();
            let stream = body.stream().unwrap();
            println!("read: {:?}", stream.blocking_read(2).map(String::from_utf8));
            // WIT: finish traps while the input-stream child is alive.
            let _trailers = IncomingBody::finish(body);
            println!("finished with a live stream");
            drop(stream);
        }
        "live-out" => {
            let req = request(Method::Post);
            let body = req.body().unwrap();
            let out = body.write().unwrap();
            // WIT: finish traps while the output-stream child is alive.
            println!("finish: {:?}", OutgoingBody::finish(body, None));
            drop(out);
        }
        "abandon" => {
            // A finished upload whose future is dropped before `get`.
            drop(send(with_body(Method::Post, b"ping")));
            // An upload dropped unfinished, then its request.
            let req = request(Method::Post);
            let body = req.body().unwrap();
            let out = body.write().unwrap();
            out.blocking_write_and_flush(b"ping").unwrap();
            drop(out);
            drop(body);
            drop(req);
            // A finished upload whose request is dropped unsent.
            drop(with_body(Method::Post, b"ping"));
            // A response dropped without `consume`.
            let fut = send(with_body(Method::Post, b"ping")).unwrap();
            fut.subscribe().block();
            println!("status: {}", fut.get().unwrap().unwrap().unwrap().status());
        }
        "https" => {
            let req = request(Method::Get);
            req.set_scheme(Some(&Scheme::Https)).unwrap();
            send(req);
        }
        "twice" => {
            if let Some(fut) = send(request(Method::Get)) {
                print_response(&fut);
                println!("second get: {:?}", fut.get().map(|r| r.is_err()));
            }
        }
        "unfinished" => {
            let req = request(Method::Post);
            let body = req.body().unwrap();
            if let Some(fut) = send(req) {
                print_response(&fut);
            }
            drop(body);
        }
        "fields" => {
            let f = Fields::new();
            println!("set: {:?}", f.set("hey ho", &[b"x".to_vec()]));
            println!("append: {:?}", f.append("ok", b"\n"));
            println!("delete: {:?}", f.delete(""));
            println!("from-list: {:?}", Fields::from_list(&[("(x)".into(), b"v".to_vec())]).err());
            f.append("ok", b"v").unwrap();
            println!("entries: {:?}", f.entries());
            let req = OutgoingRequest::new(f);
            let headers = req.headers();
            println!("immutable: {:?}", headers.set("ok", &[]));
        }
        _ => panic!("unknown mode {mode}"),
    }
}
