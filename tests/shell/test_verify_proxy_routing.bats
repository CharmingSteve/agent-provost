#!/usr/bin/env bats

setup() {
  export TEST_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "verify_proxy_routing.sh passes with healthy fluent-bit and buffer evidence" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/verify_proxy_routing.sh" "$TMPDIR/verify_proxy_routing.sh"
  mkdir -p "$TMPDIR/.provost-run" "$TMPDIR/logs/fluent-bit-storage/s3"
  touch "$TMPDIR/logs/fluent-bit-storage/s3/chunk.db"

  mkdir -p "$TMPDIR/bin" "$TMPDIR/.venv/bin"
  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "inspect" ]; then
  if [ "$4" = "agent-provost" ]; then
    echo "running"
  else
    echo "healthy"
  fi
  exit 0
fi
if [ "$1" = "compose" ]; then
  exit 0
fi
if [ "$1" = "exec" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  cat > "$TMPDIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/bin/sleep"

  cat > "$TMPDIR/.venv/bin/python" <<'EOF'
#!/bin/sh
echo "initialize_status=200"
echo "tools_call_status=200"
echo "tool_is_error=False"
exit 0
EOF
  chmod +x "$TMPDIR/.venv/bin/python"

  python3 - <<EOF
import socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind("$TMPDIR/.provost-run/fluent-bit.sock")
sock.close()
EOF

  run env PATH="$TMPDIR/bin:$PATH" ROOT_DIR="$TMPDIR" PROJECT_DIR="$TMPDIR" PYTHON_BIN="$TMPDIR/.venv/bin/python" PROVOST_RUN_DIR="$TMPDIR/.provost-run" VERIFY_REQUIRE_S3=false sh "$TMPDIR/verify_proxy_routing.sh"
  [ "$status" -eq 0 ]
}

@test "verify_proxy_routing.sh fails when probe returns a non-zero exit code" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/verify_proxy_routing.sh" "$TMPDIR/verify_proxy_routing.sh"
  mkdir -p "$TMPDIR/.provost-run" "$TMPDIR/logs/fluent-bit-storage" "$TMPDIR/bin" "$TMPDIR/.venv/bin"

  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "inspect" ]; then
  if [ "$4" = "agent-provost" ]; then
    echo "running"
  else
    echo "healthy"
  fi
  exit 0
fi
if [ "$1" = "compose" ]; then
  exit 0
fi
if [ "$1" = "exec" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  cat > "$TMPDIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/bin/sleep"

  cat > "$TMPDIR/.venv/bin/python" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$TMPDIR/.venv/bin/python"

  python3 - <<EOF
import socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind("$TMPDIR/.provost-run/fluent-bit.sock")
sock.close()
EOF

  run env PATH="$TMPDIR/bin:$PATH" ROOT_DIR="$TMPDIR" PROJECT_DIR="$TMPDIR" PYTHON_BIN="$TMPDIR/.venv/bin/python" PROVOST_RUN_DIR="$TMPDIR/.provost-run" VERIFY_REQUIRE_S3=false sh "$TMPDIR/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
}

@test "verify_proxy_routing.sh fails when fluent-bit is unhealthy" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/verify_proxy_routing.sh" "$TMPDIR/verify_proxy_routing.sh"
  mkdir -p "$TMPDIR/bin" "$TMPDIR/.venv/bin"

  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "inspect" ]; then
  echo "starting"
  exit 0
fi
if [ "$1" = "compose" ]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  cat > "$TMPDIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/bin/sleep"

  cat > "$TMPDIR/.venv/bin/python" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/.venv/bin/python"

  run env PATH="$TMPDIR/bin:$PATH" ROOT_DIR="$TMPDIR" PROJECT_DIR="$TMPDIR" PYTHON_BIN="$TMPDIR/.venv/bin/python" VERIFY_REQUIRE_S3=false sh "$TMPDIR/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
}

@test "verify_proxy_routing.sh fails when socket is missing" {
  TMPDIR="$(mktemp -d)"
  cp "$TEST_REPO_ROOT/verify_proxy_routing.sh" "$TMPDIR/verify_proxy_routing.sh"
  mkdir -p "$TMPDIR/.provost-run" "$TMPDIR/logs/fluent-bit-storage" "$TMPDIR/bin" "$TMPDIR/.venv/bin"

  cat > "$TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "inspect" ]; then
  if [ "$4" = "agent-provost" ]; then
    echo "running"
  else
    echo "healthy"
  fi
  exit 0
fi
if [ "$1" = "compose" ]; then
  exit 0
fi
if [ "$1" = "exec" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPDIR/bin/docker"

  cat > "$TMPDIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/bin/sleep"

  cat > "$TMPDIR/.venv/bin/python" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$TMPDIR/.venv/bin/python"

  run env PATH="$TMPDIR/bin:$PATH" ROOT_DIR="$TMPDIR" PROJECT_DIR="$TMPDIR" PYTHON_BIN="$TMPDIR/.venv/bin/python" PROVOST_RUN_DIR="$TMPDIR/.provost-run" VERIFY_REQUIRE_S3=false sh "$TMPDIR/verify_proxy_routing.sh"
  [ "$status" -ne 0 ]
}
