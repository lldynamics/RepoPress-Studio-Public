use super::CommandResult;
use std::collections::HashSet;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::thread;
use std::time::{Duration, Instant};
use url::Url;

const MAX_WAIT: Duration = Duration::from_secs(10);
const MAX_REQUEST_TIME: Duration = Duration::from_secs(1);
const IO_POLL_INTERVAL: Duration = Duration::from_millis(100);
const RETRY_DELAY: Duration = Duration::from_millis(50);
const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_INTERIM_RESPONSES: usize = 8;
const MAX_REDIRECTS: usize = 5;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct PreviewPageProbe {
    pub url: String,
    pub status_code: Option<u16>,
    pub ready: bool,
    pub reason: &'static str,
}

pub(super) fn wait_for_page(
    url: &str,
    timeout: Duration,
    mut still_current: impl FnMut() -> bool,
) -> CommandResult<PreviewPageProbe> {
    let Some(initial) = ValidatedUrl::parse(url) else {
        return Ok(failed(url.to_string(), None, "invalid_response"));
    };

    let wait = timeout.min(MAX_WAIT);
    let deadline = Instant::now()
        .checked_add(wait)
        .unwrap_or_else(Instant::now);
    let origin_port = initial.port;
    let mut current = initial;
    let mut visited = HashSet::from([current.display.clone()]);
    let mut redirects = 0usize;
    let mut last_status = None;

    loop {
        if !still_current() {
            return Ok(failed(
                current.display.clone(),
                last_status,
                "process_exited",
            ));
        }
        if Instant::now() >= deadline {
            return Ok(failed(
                current.display.clone(),
                last_status,
                if last_status.is_some() {
                    "http_error"
                } else {
                    "timeout"
                },
            ));
        }

        match request_headers(&current, deadline, &mut still_current) {
            Ok(response) => {
                last_status = Some(response.status_code);
                match response.status_code {
                    200..=299 => {
                        return Ok(PreviewPageProbe {
                            url: current.display.clone(),
                            status_code: last_status,
                            ready: true,
                            reason: "ready",
                        });
                    }
                    300..=399 => {
                        let Some(location) = response.location else {
                            return Ok(failed(
                                current.display.clone(),
                                last_status,
                                "redirect_rejected",
                            ));
                        };
                        if redirects >= MAX_REDIRECTS {
                            return Ok(failed(
                                current.display.clone(),
                                last_status,
                                "redirect_rejected",
                            ));
                        }
                        let Some(next) = resolve_redirect(&current, &location, origin_port) else {
                            return Ok(failed(
                                current.display.clone(),
                                last_status,
                                "redirect_rejected",
                            ));
                        };
                        if !visited.insert(next.display.clone()) {
                            return Ok(failed(
                                current.display.clone(),
                                last_status,
                                "redirect_rejected",
                            ));
                        }
                        current = next;
                        redirects += 1;
                        continue;
                    }
                    _ => {}
                }
            }
            Err(AttemptError::Cancelled) => {
                return Ok(failed(
                    current.display.clone(),
                    last_status,
                    "process_exited",
                ));
            }
            Err(AttemptError::InvalidResponse(status_code)) => {
                return Ok(failed(
                    current.display.clone(),
                    status_code.or(last_status),
                    "invalid_response",
                ));
            }
            Err(AttemptError::Transport | AttemptError::TimedOut) => {}
        }

        if !wait_before_retry(deadline, &mut still_current) {
            let reason = if !still_current() {
                "process_exited"
            } else if last_status.is_some() {
                "http_error"
            } else {
                "timeout"
            };
            return Ok(failed(current.display.clone(), last_status, reason));
        }
    }
}

fn failed(url: String, status_code: Option<u16>, reason: &'static str) -> PreviewPageProbe {
    PreviewPageProbe {
        url,
        status_code,
        ready: false,
        reason,
    }
}

#[derive(Clone, Debug)]
struct ValidatedUrl {
    url: Url,
    port: u16,
    display: String,
}

impl ValidatedUrl {
    fn parse(raw: &str) -> Option<Self> {
        if raw.is_empty()
            || raw.chars().any(|character| {
                character.is_control() || character.is_whitespace() || character == '\\'
            })
            || contains_encoded_crlf(raw)
            || raw.contains('#')
        {
            return None;
        }

        let (scheme, remainder) = raw.split_once("://")?;
        if !scheme.eq_ignore_ascii_case("http") || remainder.is_empty() {
            return None;
        }
        let authority_end = remainder.find(['/', '?', '#']).unwrap_or(remainder.len());
        let authority = &remainder[..authority_end];
        if authority.contains('@') {
            return None;
        }
        let (host, raw_port) = authority.split_once(':')?;
        if host != "127.0.0.1"
            || raw_port.is_empty()
            || raw_port.contains(':')
            || !raw_port.bytes().all(|byte| byte.is_ascii_digit())
        {
            return None;
        }
        let port = raw_port.parse::<u16>().ok().filter(|port| *port > 0)?;
        let url = Url::parse(raw).ok()?;
        if url.scheme() != "http"
            || url.host_str() != Some("127.0.0.1")
            || url.port_or_known_default() != Some(port)
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return None;
        }
        let display = canonical_url_text(&url, port);
        Some(Self { url, port, display })
    }
}

fn contains_encoded_crlf(value: &str) -> bool {
    let lower = value.as_bytes();
    lower.windows(3).any(|window| {
        window[0] == b'%' && window[1] == b'0' && matches!(window[2], b'a' | b'A' | b'd' | b'D')
    })
}

fn resolve_redirect(
    current: &ValidatedUrl,
    location: &str,
    origin_port: u16,
) -> Option<ValidatedUrl> {
    if location.is_empty()
        || location.chars().any(|character| {
            character.is_control() || character.is_whitespace() || character == '\\'
        })
        || contains_encoded_crlf(location)
        || location.starts_with("//")
    {
        return None;
    }

    let next = if location.contains("://") {
        ValidatedUrl::parse(location)?
    } else {
        let joined = current.url.join(location).ok()?;
        ValidatedUrl::parse(&canonical_url_text(&joined, current.port))?
    };
    (next.port == origin_port).then_some(next)
}

fn canonical_url_text(url: &Url, port: u16) -> String {
    let mut text = format!("http://127.0.0.1:{port}{}", url.path());
    if let Some(query) = url.query() {
        text.push('?');
        text.push_str(query);
    }
    text
}

#[derive(Debug)]
struct HeaderResponse {
    status_code: u16,
    location: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AttemptError {
    Transport,
    TimedOut,
    Cancelled,
    InvalidResponse(Option<u16>),
}

fn request_headers(
    target: &ValidatedUrl,
    overall_deadline: Instant,
    still_current: &mut impl FnMut() -> bool,
) -> Result<HeaderResponse, AttemptError> {
    if !still_current() {
        return Err(AttemptError::Cancelled);
    }
    let request_deadline = overall_deadline.min(
        Instant::now()
            .checked_add(MAX_REQUEST_TIME)
            .unwrap_or(overall_deadline),
    );
    let address = SocketAddr::from(([127, 0, 0, 1], target.port));
    let connect_timeout = remaining(request_deadline)?;
    let mut stream = TcpStream::connect_timeout(&address, connect_timeout).map_err(io_error)?;
    let _ = stream.set_nodelay(true);

    let path = if target.url.path().is_empty() {
        "/"
    } else {
        target.url.path()
    };
    let mut request_target = path.to_string();
    if let Some(query) = target.url.query() {
        request_target.push('?');
        request_target.push_str(query);
    }
    let request = format!(
        "GET {request_target} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nAccept: text/html,application/xhtml+xml\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        target.port
    );

    set_write_timeout(&stream, request_deadline)?;
    stream.write_all(request.as_bytes()).map_err(io_error)?;
    read_header_response(&mut stream, request_deadline, still_current)
}

fn read_header_response(
    stream: &mut TcpStream,
    request_deadline: Instant,
    still_current: &mut impl FnMut() -> bool,
) -> Result<HeaderResponse, AttemptError> {
    let mut bytes = Vec::with_capacity(1024);
    let mut block_start = 0usize;
    let mut interim_count = 0usize;
    let mut buffer = [0u8; 2048];

    loop {
        while let Some(boundary_start) = find_header_boundary(&bytes, block_start) {
            let boundary_end = boundary_start + 4;
            if boundary_end > MAX_HEADER_BYTES {
                return Err(AttemptError::InvalidResponse(None));
            }
            let parsed = parse_header_block(&bytes[block_start..boundary_start])?;
            if (100..=199).contains(&parsed.status_code) {
                if parsed.status_code == 101 || interim_count >= MAX_INTERIM_RESPONSES {
                    return Err(AttemptError::InvalidResponse(Some(parsed.status_code)));
                }
                interim_count += 1;
                block_start = boundary_end;
                continue;
            }
            return Ok(parsed);
        }

        if bytes.len() >= MAX_HEADER_BYTES {
            return Err(AttemptError::InvalidResponse(None));
        }
        if !still_current() {
            return Err(AttemptError::Cancelled);
        }
        set_read_timeout(stream, request_deadline)?;
        let allowed = (MAX_HEADER_BYTES - bytes.len()).min(buffer.len());
        match stream.read(&mut buffer[..allowed]) {
            Ok(0) => return Err(AttemptError::InvalidResponse(None)),
            Ok(count) => bytes.extend_from_slice(&buffer[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) && Instant::now() < request_deadline => {}
            Err(error) => return Err(io_error(error)),
        }
    }
}

fn find_header_boundary(bytes: &[u8], from: usize) -> Option<usize> {
    bytes
        .get(from..)?
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|offset| from + offset)
}

fn parse_header_block(block: &[u8]) -> Result<HeaderResponse, AttemptError> {
    for (index, byte) in block.iter().enumerate() {
        if (*byte == b'\n' && (index == 0 || block[index - 1] != b'\r'))
            || (*byte == b'\r' && block.get(index + 1) != Some(&b'\n'))
        {
            return Err(AttemptError::InvalidResponse(None));
        }
    }
    let mut lines = block.split(|byte| *byte == b'\n');
    let status_line = trim_line_ending(lines.next().unwrap_or_default());
    let status_code = parse_status_line(status_line)?;
    let mut location = None;

    for raw_line in lines {
        let line = trim_line_ending(raw_line);
        if line.is_empty() || matches!(line.first(), Some(b' ' | b'\t')) {
            return Err(AttemptError::InvalidResponse(Some(status_code)));
        }
        let Some(separator) = line.iter().position(|byte| *byte == b':') else {
            return Err(AttemptError::InvalidResponse(Some(status_code)));
        };
        let name = &line[..separator];
        let value = &line[separator + 1..];
        if name.is_empty() || !name.iter().all(|byte| is_header_name_byte(*byte)) {
            return Err(AttemptError::InvalidResponse(Some(status_code)));
        }
        if value
            .iter()
            .any(|byte| (*byte < 0x20 && *byte != b'\t') || *byte == 0x7f)
        {
            return Err(AttemptError::InvalidResponse(Some(status_code)));
        }
        if name.eq_ignore_ascii_case(b"location") {
            if location.is_some() {
                return Err(AttemptError::InvalidResponse(Some(status_code)));
            }
            let trimmed = trim_optional_whitespace(value);
            let decoded = std::str::from_utf8(trimmed)
                .map_err(|_| AttemptError::InvalidResponse(Some(status_code)))?;
            location = Some(decoded.to_string());
        }
    }

    Ok(HeaderResponse {
        status_code,
        location,
    })
}

fn trim_line_ending(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn parse_status_line(line: &[u8]) -> Result<u16, AttemptError> {
    let remainder = line
        .strip_prefix(b"HTTP/1.1 ")
        .or_else(|| line.strip_prefix(b"HTTP/1.0 "))
        .ok_or(AttemptError::InvalidResponse(None))?;
    if remainder.len() < 3
        || !remainder[..3].iter().all(|byte| byte.is_ascii_digit())
        || (remainder.len() > 3 && remainder[3] != b' ')
        || remainder[3.min(remainder.len())..]
            .iter()
            .any(|byte| (*byte < 0x20 && *byte != b'\t') || *byte == 0x7f)
    {
        return Err(AttemptError::InvalidResponse(None));
    }
    let status_code = ((remainder[0] - b'0') as u16) * 100
        + ((remainder[1] - b'0') as u16) * 10
        + (remainder[2] - b'0') as u16;
    (100..=599)
        .contains(&status_code)
        .then_some(status_code)
        .ok_or(AttemptError::InvalidResponse(None))
}

fn is_header_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

fn trim_optional_whitespace(mut value: &[u8]) -> &[u8] {
    while matches!(value.first(), Some(b' ' | b'\t')) {
        value = &value[1..];
    }
    while matches!(value.last(), Some(b' ' | b'\t')) {
        value = &value[..value.len() - 1];
    }
    value
}

fn remaining(deadline: Instant) -> Result<Duration, AttemptError> {
    let duration = deadline.saturating_duration_since(Instant::now());
    (!duration.is_zero())
        .then_some(duration.min(IO_POLL_INTERVAL))
        .ok_or(AttemptError::TimedOut)
}

fn set_read_timeout(stream: &TcpStream, deadline: Instant) -> Result<(), AttemptError> {
    stream
        .set_read_timeout(Some(remaining(deadline)?))
        .map_err(|_| AttemptError::Transport)
}

fn set_write_timeout(stream: &TcpStream, deadline: Instant) -> Result<(), AttemptError> {
    stream
        .set_write_timeout(Some(remaining(deadline)?))
        .map_err(|_| AttemptError::Transport)
}

fn io_error(error: io::Error) -> AttemptError {
    match error.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => AttemptError::TimedOut,
        _ => AttemptError::Transport,
    }
}

fn wait_before_retry(deadline: Instant, still_current: &mut impl FnMut() -> bool) -> bool {
    let retry_end = deadline.min(Instant::now().checked_add(RETRY_DELAY).unwrap_or(deadline));
    while Instant::now() < retry_end {
        if !still_current() {
            return false;
        }
        let sleep_for = retry_end
            .saturating_duration_since(Instant::now())
            .min(Duration::from_millis(10));
        if sleep_for.is_zero() {
            break;
        }
        thread::sleep(sleep_for);
    }
    Instant::now() < deadline && still_current()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::thread::JoinHandle;

    fn fixture(handler: impl FnOnce(TcpListener) + Send + 'static) -> (String, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback fixture");
        let port = listener.local_addr().expect("fixture address").port();
        let handle = thread::spawn(move || handler(listener));
        (format!("http://127.0.0.1:{port}/"), handle)
    }

    fn read_request(stream: &mut TcpStream) -> Vec<u8> {
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("request timeout");
        let mut request = Vec::new();
        let mut buffer = [0u8; 512];
        while find_header_boundary(&request, 0).is_none() {
            let count = stream.read(&mut buffer).expect("read request");
            assert_ne!(count, 0, "client closed before request headers");
            request.extend_from_slice(&buffer[..count]);
        }
        request
    }

    fn scripted(responses: Vec<Vec<u8>>) -> (String, JoinHandle<()>) {
        fixture(move |listener| {
            for response in responses {
                let (mut stream, _) = listener.accept().expect("accept scripted request");
                let _ = read_request(&mut stream);
                stream
                    .write_all(&response)
                    .expect("write scripted response");
            }
        })
    }

    #[test]
    fn returns_at_headers_for_empty_and_unending_bodies() {
        for body_mode in 0..2 {
            let (url, handle) = fixture(move |listener| {
                let (mut stream, _) = listener.accept().expect("accept request");
                let request = read_request(&mut stream);
                let request = String::from_utf8(request).expect("ASCII request");
                assert!(request.starts_with("GET / HTTP/1.1\r\n"));
                assert!(request.contains("\r\nAccept: text/html,application/xhtml+xml\r\n"));
                assert!(request.contains("\r\nCache-Control: no-cache\r\n"));
                assert!(request.contains("\r\nConnection: close\r\n"));
                stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n")
                    .expect("write headers");
                if body_mode == 0 {
                    thread::sleep(Duration::from_millis(250));
                } else {
                    for _ in 0..10 {
                        if stream.write_all(b"body-never-finishes").is_err() {
                            break;
                        }
                        thread::sleep(Duration::from_millis(30));
                    }
                }
            });
            let started = Instant::now();
            let result = wait_for_page(&url, Duration::from_secs(1), || true).unwrap();
            assert!(result.ready);
            assert_eq!(result.status_code, Some(200));
            assert_eq!(result.reason, "ready");
            assert!(started.elapsed() < Duration::from_millis(200));
            handle.join().unwrap();
        }
    }

    #[test]
    fn retries_not_ready_statuses_and_preserves_the_last_status() {
        let (url, handle) = scripted(vec![
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec(),
            b"HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let result = wait_for_page(&url, Duration::from_millis(180), || true).unwrap();
        assert!(!result.ready);
        assert_eq!(result.status_code, Some(500));
        assert_eq!(result.reason, "http_error");
        handle.join().unwrap();
    }

    #[test]
    fn retries_a_404_until_the_page_is_ready() {
        let (url, handle) = scripted(vec![
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec(),
            b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_vec(),
        ]);
        let result = wait_for_page(&url, Duration::from_secs(1), || true).unwrap();
        assert!(result.ready);
        assert_eq!(result.status_code, Some(200));
        handle.join().unwrap();
    }

    #[test]
    fn bounds_a_slow_trickle_by_the_overall_deadline() {
        let (url, handle) = fixture(|listener| {
            let (mut stream, _) = listener.accept().expect("accept request");
            let _ = read_request(&mut stream);
            for byte in b"HTTP/1.1 200 OK\r\n" {
                if stream.write_all(&[*byte]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(30));
            }
        });
        let started = Instant::now();
        let result = wait_for_page(&url, Duration::from_millis(160), || true).unwrap();
        assert!(!result.ready);
        assert_eq!(result.status_code, None);
        assert_eq!(result.reason, "timeout");
        assert!(started.elapsed() < Duration::from_millis(500));
        handle.join().unwrap();
    }

    #[test]
    fn accepts_bounded_early_hints_before_the_final_response() {
        let (url, handle) = scripted(vec![
            b"HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                .to_vec(),
        ]);
        let result = wait_for_page(&url, Duration::from_secs(1), || true).unwrap();
        assert!(result.ready);
        assert_eq!(result.status_code, Some(200));
        handle.join().unwrap();
    }

    #[test]
    fn rejects_switching_protocols_oversize_and_malformed_statuses() {
        let mut oversize = b"HTTP/1.1 200 OK\r\nX-Fill: ".to_vec();
        oversize.resize(MAX_HEADER_BYTES + 16, b'a');
        for response in [
            b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_vec(),
            oversize,
            b"HTTP/1.1 two-hundred OK\r\nContent-Length: 0\r\n\r\n".to_vec(),
            b"HTTP/1.1 200 OK\r\nLocation: /one\r\nLocation: /two\r\n\r\n".to_vec(),
            b"HTTP/1.1 200 OK\r\nBroken Header\r\n\r\n".to_vec(),
        ] {
            let (url, handle) = scripted(vec![response]);
            let result = wait_for_page(&url, Duration::from_secs(1), || true).unwrap();
            assert!(!result.ready);
            assert_eq!(result.reason, "invalid_response");
            handle.join().unwrap();
        }
    }

    #[test]
    fn follows_a_relative_same_origin_redirect_and_reports_the_final_url() {
        let (url, handle) = fixture(|listener| {
            let (mut first, _) = listener.accept().expect("accept first request");
            let first_request = String::from_utf8(read_request(&mut first)).unwrap();
            assert!(first_request.starts_with("GET / HTTP/1.1\r\n"));
            first
                .write_all(b"HTTP/1.1 302 Found\r\nLocation: /ready?q=1\r\n\r\n")
                .unwrap();

            let (mut second, _) = listener.accept().expect("accept redirected request");
            let second_request = String::from_utf8(read_request(&mut second)).unwrap();
            assert!(second_request.starts_with("GET /ready?q=1 HTTP/1.1\r\n"));
            second
                .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                .unwrap();
        });
        let result = wait_for_page(&url, Duration::from_secs(1), || true).unwrap();
        assert!(result.ready);
        assert_eq!(result.status_code, Some(204));
        assert!(result.url.ends_with("/ready?q=1"));
        handle.join().unwrap();
    }

    #[test]
    fn rejects_cross_origin_redirects_encoded_crlf_and_redirect_loops() {
        let (cross_url, cross_handle) = scripted(vec![
            b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/other\r\n\r\n".to_vec(),
        ]);
        let cross = wait_for_page(&cross_url, Duration::from_secs(1), || true).unwrap();
        assert_eq!(cross.reason, "redirect_rejected");
        cross_handle.join().unwrap();

        let (encoded_url, encoded_handle) = scripted(vec![
            b"HTTP/1.1 302 Found\r\nLocation: /next%0d%0aInjected\r\n\r\n".to_vec(),
        ]);
        let encoded = wait_for_page(&encoded_url, Duration::from_secs(1), || true).unwrap();
        assert_eq!(encoded.reason, "redirect_rejected");
        encoded_handle.join().unwrap();

        let (loop_url, loop_handle) = fixture(|listener| {
            let (mut first, _) = listener.accept().unwrap();
            let _ = read_request(&mut first);
            first
                .write_all(b"HTTP/1.1 302 Found\r\nLocation: /again\r\n\r\n")
                .unwrap();
            let (mut second, _) = listener.accept().unwrap();
            let _ = read_request(&mut second);
            second
                .write_all(b"HTTP/1.1 302 Found\r\nLocation: /\r\n\r\n")
                .unwrap();
        });
        let looped = wait_for_page(&loop_url, Duration::from_secs(1), || true).unwrap();
        assert_eq!(looped.reason, "redirect_rejected");
        loop_handle.join().unwrap();
    }

    #[test]
    fn validates_raw_numeric_loopback_urls_before_url_canonicalization() {
        for invalid in [
            "http://localhost:8080/",
            "http://127.1:8080/",
            "http://0x7f000001:8080/",
            "http://2130706433:8080/",
            "http://user@127.0.0.1:8080/",
            "https://127.0.0.1:8080/",
            "http://127.0.0.1/",
            "http://127.0.0.1:8080/%0d%0aInjected",
        ] {
            let result = wait_for_page(invalid, Duration::from_millis(10), || true).unwrap();
            assert_eq!(result.reason, "invalid_response", "{invalid}");
            assert!(!result.ready);
        }
    }

    #[test]
    fn cancellation_stops_without_connecting() {
        let (sender, receiver) = mpsc::channel();
        let result = wait_for_page("http://127.0.0.1:9/", Duration::from_secs(10), || {
            let _ = sender.send(());
            false
        })
        .unwrap();
        receiver.recv_timeout(Duration::from_millis(100)).unwrap();
        assert_eq!(result.reason, "process_exited");
        assert_eq!(result.status_code, None);
    }

    #[test]
    fn cancellation_is_polled_while_waiting_for_response_headers() {
        let (url, server) = fixture(|listener| {
            let (mut stream, _) = listener.accept().expect("accept request");
            let _ = read_request(&mut stream);
            thread::sleep(Duration::from_millis(300));
        });
        let current = Arc::new(AtomicBool::new(true));
        let controller_current = Arc::clone(&current);
        let controller = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            controller_current.store(false, Ordering::SeqCst);
        });

        let started = Instant::now();
        let result = wait_for_page(&url, Duration::from_secs(1), || {
            current.load(Ordering::SeqCst)
        })
        .unwrap();
        assert_eq!(result.reason, "process_exited");
        assert!(started.elapsed() < Duration::from_millis(250));
        controller.join().unwrap();
        server.join().unwrap();
    }
}
