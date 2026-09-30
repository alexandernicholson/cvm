#!/usr/bin/env bats
# Behavioral curl fixture: independent processes rendezvous before returning ranges.
load "../helpers/common"

setup() {
  export CVM_DIR TEST_WORKDIR CURL_LOG
  CVM_DIR=$(mktemp -d)
  TEST_WORKDIR=$(mktemp -d)
  CURL_LOG="$TEST_WORKDIR/requests"
  export DOWNLOAD_FIXTURE="$TEST_WORKDIR" DOWNLOAD_MODE=valid
  mkdir -p "$TEST_WORKDIR/bin"
  cat > "$TEST_WORKDIR/bin/curl" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys, time
args = sys.argv[1:]
root = pathlib.Path(os.environ['DOWNLOAD_FIXTURE'])
mode = os.environ['DOWNLOAD_MODE']
data = bytes(range(256)) * 32768 + b'final-byte'
def arg(flag, default=None):
    return args[args.index(flag)+1] if flag in args else default
out, headers, span = arg('-o'), arg('-D'), arg('--range')
url = next((a for a in args if a.startswith('http')), '')
def log(value):
    with open(root / 'requests', 'a') as f:
        f.write(value + '\n')
if url.endswith('manifest.json'):
    digest = hashlib.sha256(data).hexdigest()
    platforms = ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64',
                 'linux-arm64-musl', 'linux-x64-musl', 'win32-arm64', 'win32-x64']
    print(json.dumps({'platforms': {p: {'checksum': digest} for p in platforms}}))
    sys.exit(0)
if '--head' in args:
    log('HEAD')
    # Include misleading redirect headers to ensure only the final block is used.
    pathlib.Path(headers).write_bytes(('HTTP/1.1 302 Found\r\nContent-Length: 1\r\n\r\n'
        'HTTP/2 200\r\ncOnTeNt-LeNgTh: %d\r\nAccept-Ranges: %s\r\nETag: "original"\r\n\r\n'
        % (len(data), 'none' if mode == 'unsupported' else 'bytes')).encode())
    sys.exit(0)
if span:
    log('RANGE ' + span)
    start, end = map(int, span.split('-'))
    (root / ('started-' + str(start))).touch()
    deadline = time.monotonic() + 5
    while len(list(root.glob('started-*'))) < 2:
        if time.monotonic() > deadline:
            sys.exit(28)
        time.sleep(.01)
    log('OVERLAP')
    body = data[start:end+1]
    status, content_range, etag = 206, 'bytes %d-%d/%d' % (start, end, len(data)), 'original'
    if mode == 'ignored':
        status, body = 200, data
    elif mode == 'mismatch':
        content_range = 'bytes 0-1/%d' % len(data)
    elif mode == 'truncated':
        body = body[:-1]
    elif mode == 'changed':
        etag = 'replacement'
    elif mode == 'corrupt':
        body = b'X' + body[1:]
    pathlib.Path(headers).write_bytes(('HTTP/1.1 %d OK\r\nContent-Range: %s\r\n'
        'ETag: "%s"\r\n\r\n' % (status, content_range, etag)).encode())
else:
    log('FULL')
    if mode == 'failfull':
        sys.exit(22)
    body = data
pathlib.Path(out).write_bytes(body)
PY
  chmod +x "$TEST_WORKDIR/bin/curl"
  export PATH="$TEST_WORKDIR/bin:$PATH"
  python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(bytes(range(256))*32768+b"final-byte")' "$TEST_WORKDIR/expected"
}

download() {
  run bash -c 'source "$1" || :; download_binary https://fixture/binary "$2"' _ "$CVM_SCRIPT" "$TEST_WORKDIR/result"
}

@test "parallel download overlaps workers and assembles byte-exact uneven ranges" {
  export CVM_DOWNLOAD_THREADS=8
  download
  assert_success
  cmp "$TEST_WORKDIR/expected" "$TEST_WORKDIR/result"
  [ "$(grep -c '^RANGE ' "$CURL_LOG")" -eq 2 ]
  [ "$(grep -c '^OVERLAP$' "$CURL_LOG")" -eq 2 ]
  ! grep -q '^FULL$' "$CURL_LOG"
  [ "$(echo "$TEST_WORKDIR"/result.parts-*)" = "$TEST_WORKDIR/result.parts-*" ]
}

@test "one download thread bypasses probing and ranges" {
  export CVM_DOWNLOAD_THREADS=1
  download
  assert_success
  cmp "$TEST_WORKDIR/expected" "$TEST_WORKDIR/result"
  [ "$(cat "$CURL_LOG")" = FULL ]
}

@test "system Bash preserves download cleanup state through EXIT" {
  [ -x /bin/bash ] || skip "system Bash unavailable"
  export CVM_DOWNLOAD_THREADS=8
  run /bin/bash -c 'source "$1" || :; download_binary https://fixture/binary "$2"' _ "$CVM_SCRIPT" "$TEST_WORKDIR/result"
  assert_success
  cmp "$TEST_WORKDIR/expected" "$TEST_WORKDIR/result"
  [ "$(echo "$TEST_WORKDIR"/result.parts-*)" = "$TEST_WORKDIR/result.parts-*" ]
}

@test "unsupported ranges use one complete sequential response" {
  export CVM_DOWNLOAD_THREADS=8 DOWNLOAD_MODE=unsupported
  download
  assert_success
  cmp "$TEST_WORKDIR/expected" "$TEST_WORKDIR/result"
  ! grep -q '^RANGE ' "$CURL_LOG"
  grep -q '^FULL$' "$CURL_LOG"
}

@test "ignored ranges mismatched offsets truncated bytes and changed identity discard chunks" {
  local mode
  export CVM_DOWNLOAD_THREADS=2
  for mode in ignored mismatch truncated changed; do
    export DOWNLOAD_MODE="$mode"
    rm -f "$CURL_LOG" "$TEST_WORKDIR"/started-*
    download
    assert_success
    cmp "$TEST_WORKDIR/expected" "$TEST_WORKDIR/result"
    grep -q '^FULL$' "$CURL_LOG"
    [ "$(echo "$TEST_WORKDIR"/result.parts-*)" = "$TEST_WORKDIR/result.parts-*" ]
  done
}

@test "invalid thread configuration fails before HTTP requests" {
  local value
  for value in 0 33 -1 abc 1.5 '' 999999999999999999999999; do
    export CVM_DOWNLOAD_THREADS="$value"
    download
    assert_failure
    [ ! -e "$CURL_LOG" ]
    [ ! -e "$TEST_WORKDIR/result" ]
  done
}

@test "valid ranges with corrupt content cannot install or select a version" {
  export CVM_DOWNLOAD_THREADS=2 DOWNLOAD_MODE=corrupt
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_failure
  [ ! -e "$CVM_DIR/versions/2.1.71/claude" ]
  [ ! -e "$CVM_DIR/versions/2.1.71/claude.exe" ]
  [ ! -e "$CVM_DIR/version" ]
  [ "$(echo "$CVM_DIR"/cache/*)" = "$CVM_DIR/cache/*" ]
}

@test "sequential failure removes partial output and staging directory" {
  export CVM_DOWNLOAD_THREADS=1 DOWNLOAD_MODE=failfull
  download
  assert_failure
  [ ! -e "$TEST_WORKDIR/result" ]
  [ "$(echo "$TEST_WORKDIR"/result.parts-*)" = "$TEST_WORKDIR/result.parts-*" ]
}

@test "Python manifest fallback reads JSON rather than script stdin" {
  run bash -c '
    source "$1" || :
    command() {
      if [[ "$1" == -v && "$2" == jq ]]; then return 1; fi
      builtin command "$@"
    }
    checksum_from_manifest linux-x64 '\''{"platforms":{"linux-x64":{"checksum":"abc123"}}}'\''
  ' _ "$CVM_SCRIPT"
  assert_success
  [ "$output" = abc123 ]
}
