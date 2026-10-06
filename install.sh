#!/bin/sh
# install-opencode-termux.sh — install the official opencode musl ARM64 build on Termux/Android
#
# Why this isn't just "download the musl tarball":
# opencode's linux-arm64-musl binary is musl-linked, but Termux is bionic-based:
#   1. its ELF interpreter (/lib/ld-musl-aarch64.so.1) doesn't exist in Termux
#   2. musl's resolver reads /etc/resolv.conf and sends raw UDP DNS queries,
#      which Android's firewall blocks (DNS must go through netd)
#   3. Bun's io_uring-based networking does not work on Android
#
# So this script:
#   1. installs the musl loader + musl-built libstdc++/libgcc_s (extracted from
#      Alpine .apk packages) into $PREFIX/lib
#   2. downloads the official opencode-linux-arm64-musl.tar.gz release
#   3. patches the binary's interpreter with patchelf
#   4. builds a tiny LD_PRELOAD shim that forwards DNS to bionic's getaddrinfo
#   5. installs a localhost HTTP proxy and routes opencode's traffic through it
#   6. installs an `opencode` wrapper in $PREFIX/bin that wires all of this up
#
# Usage (in Termux):
#   curl -fsSL <url-of-this-script> | sh
# or, saved locally:
#   ./install-opencode-termux.sh              # latest release
#   ./install-opencode-termux.sh v1.18.33    # pinned release
#   ./install-opencode-termux.sh --uninstall
#
# Environment overrides:
#   OPENCODE_VERSION=v1.x.y      pin a release tag (default: latest)
#   OPENCODE_TARBALL_PATH=file   use a pre-downloaded tarball (offline install)
#   INSTALL_NAME=opencode        wrapper name in $PREFIX/bin
#
# Requires: Termux (F-Droid build recommended) on an aarch64 device.
# Re-running is safe: it re-downloads and upgrades to the latest release.

set -e

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO="${REPO:-anomalyco/opencode}"
INSTALL_NAME="${INSTALL_NAME:-opencode}"
LIBEXECDIR="$PREFIX/libexec/opencode"
PROXY_PORT=8080
UNINSTALL=0
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"

case "${1:-}" in
  --uninstall) UNINSTALL=1 ;;
  "") ;;
  *) OPENCODE_VERSION="$1" ;;
esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity checks ----------------------------------------------------------

command -v pkg >/dev/null 2>&1 \
  || die "This script must run inside Termux ('pkg' not found)."
[ -n "${TERMUX_VERSION:-}" ] || warn "TERMUX_VERSION not set — assuming Termux anyway."
ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || die "Only aarch64 devices are supported (got: $ARCH)."

# --- uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
  log "Uninstalling opencode (musl build)..."
  PIDFILE="$PREFIX/var/run/opencode-proxy.pid"
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  rm -f "$PREFIX/bin/$INSTALL_NAME"
  rm -rf "$LIBEXECDIR"
  rm -f "$PREFIX/lib/libresolvefix.so"
  rm -f "$PREFIX/lib/ld-musl-aarch64.so.1" \
        "$PREFIX/lib/libgcc_s.so.1" \
        "$PREFIX/lib/libstdc++.so.6" \
        "$PREFIX"/lib/libstdc++.so.6.*
  log "Done. (Alpine libs that may be shared by other tools were removed;)"
  log "     reinstall them if something else complains."
  exit 0
fi

# --- dependencies ------------------------------------------------------------
# clang builds the DNS shim, python runs the proxy, patchelf retargets the ELF
# interpreter. libc++ is listed explicitly: Termux builds patchelf against the
# newest libc++, and on a system whose libc++_shared.so is stale, patchelf
# dies at startup with "CANNOT LINK EXECUTABLE". Everything is from the
# standard Termux repos.

log "Installing dependencies (curl tar patchelf clang python ca-certificates libc++)..."
pkg install -y curl tar patchelf clang python ca-certificates libc++ \
  || die "Failed to install dependencies via pkg."

command -v curl      >/dev/null 2>&1 || die "curl is required."
command -v tar       >/dev/null 2>&1 || die "tar is required."
command -v patchelf  >/dev/null 2>&1 || die "patchelf is required."
command -v clang     >/dev/null 2>&1 || die "clang is required."
command -v python3   >/dev/null 2>&1 || die "python is required (provides python3)."

# patchelf is dynamically linked against libc++_shared.so; if the installed
# libc++ is older than the one patchelf was built with, it dies at startup
# with "CANNOT LINK EXECUTABLE ... cannot locate symbol". Smoke-test it here
# so the failure surfaces with an actionable message, not mid-install.
patchelf --version >/dev/null 2>&1 \
  || die "patchelf is installed but cannot start, likely a stale libc++ package; run 'pkg upgrade' and re-run this script."

# --- work directory ----------------------------------------------------------

WORK="${TMPDIR:-$PREFIX/tmp}/opencode-musl-install.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- resolve the opencode release --------------------------------------------

if [ "$OPENCODE_VERSION" = "latest" ]; then
  log "Resolving latest opencode release..."
  OPENCODE_VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  [ -n "$OPENCODE_VERSION" ] \
    || die "Could not resolve the latest version (GitHub API). Try: ./install-opencode-termux.sh v1.18.33"
else
  case "$OPENCODE_VERSION" in v*) ;; *) OPENCODE_VERSION="v$OPENCODE_VERSION" ;; esac
fi
log "Installing opencode $OPENCODE_VERSION"

# --- download the official musl tarball --------------------------------------

TARBALL="opencode-linux-arm64-musl.tar.gz"
URL="https://github.com/$REPO/releases/download/$OPENCODE_VERSION/$TARBALL"

if [ -n "$OPENCODE_TARBALL_PATH" ]; then
  [ -f "$OPENCODE_TARBALL_PATH" ] || die "OPENCODE_TARBALL_PATH=$OPENCODE_TARBALL_PATH not found."
  log "Using local tarball: $OPENCODE_TARBALL_PATH"
  cp "$OPENCODE_TARBALL_PATH" "$WORK/$TARBALL"
else
  log "Downloading $URL (~60 MB)..."
  if ! curl -fL --progress-bar -o "$WORK/$TARBALL" "$URL"; then
    log "Hint: for a resumable manual download, run:"
    log "  curl -L -C - -o $TARBALL $URL"
    log "  then re-run with: OPENCODE_VERSION=$OPENCODE_VERSION OPENCODE_TARBALL_PATH=./$TARBALL $0"
    die "Download failed: $URL"
  fi
fi

# --- resolve Alpine packages (musl loader + C++ runtime) ---------------------
# The binary is dynamically linked against musl, so we need musl's dynamic
# linker plus musl-built libstdc++/libgcc_s. We take them from Alpine's aarch64
# repo. The Alpine version is resolved dynamically so nothing 404s on EOL.

log "Resolving Alpine release..."
ALPINE_VERSION="$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/" \
  | grep -oE 'v[0-9]+\.[0-9]+/' | sort -uV | tail -1 | tr -d /)"
[ -n "$ALPINE_VERSION" ] || die "Could not determine the latest Alpine version."
log "Using Alpine $ALPINE_VERSION."

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VERSION/main/aarch64"
ALPINE_INDEX="$(curl -fsSL "$ALPINE_BASE/" \
  | grep -oE '(musl|libstdc\+\+|libgcc)-[0-9][^"<]*\.apk' | sort -uV)"

MUSL_PKG="$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^musl-' | tail -1)"
LIBSTDC_PKG="$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libstdc\+\+-' | tail -1)"
LIBGCC_PKG="$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libgcc-' | tail -1)"
[ -n "$MUSL_PKG" ]    || die "Could not find the musl .apk in $ALPINE_BASE/"
[ -n "$LIBSTDC_PKG" ] || die "Could not find the libstdc++ .apk in $ALPINE_BASE/"
[ -n "$LIBGCC_PKG" ]  || die "Could not find the libgcc .apk in $ALPINE_BASE/"
log "Using $MUSL_PKG, $LIBSTDC_PKG, $LIBGCC_PKG."

log "Downloading musl libc + libstdc++/libgcc_s from Alpine (~1.4 MB total)..."
curl -fL --progress-bar -o "$WORK/$MUSL_PKG"    "$ALPINE_BASE/$MUSL_PKG"    || die "musl download failed"
curl -fL --progress-bar -o "$WORK/$LIBSTDC_PKG" "$ALPINE_BASE/$LIBSTDC_PKG" || die "libstdc++ download failed"
curl -fL --progress-bar -o "$WORK/$LIBGCC_PKG"  "$ALPINE_BASE/$LIBGCC_PKG"  || die "libgcc download failed"

# --- extract -----------------------------------------------------------------

log "Extracting..."
tar -xzf "$WORK/$TARBALL" -C "$WORK" || die "Failed to extract the opencode tarball."
[ -f "$WORK/opencode" ] || die "The tarball did not contain an 'opencode' binary."

# .apk files are concatenated gzip'd tar streams; --ignore-zeros (-i) makes
# GNU tar read through all segments instead of stopping after the first.
mkdir -p "$WORK/musl-libs"
for pkg in "$MUSL_PKG" "$LIBSTDC_PKG" "$LIBGCC_PKG"; do
  (cd "$WORK/musl-libs" && tar -x -z -i -f "$WORK/$pkg") || die "Failed to extract $pkg"
done

# Find the versioned libstdc++ (the binary's DT_NEEDED says "libstdc++.so.6",
# so we install the versioned file and create the SONAME symlink).
LIBSTDC_FILE=""
for f in "$WORK"/musl-libs/usr/lib/libstdc++.so.6.*; do
  [ -e "$f" ] || continue
  LIBSTDC_FILE="$f"
  break
done
[ -n "$LIBSTDC_FILE" ] || die "Could not find libstdc++.so.6.* in the extracted package."

# --- install musl loader + libs ----------------------------------------------

log "Installing musl libs to $PREFIX/lib..."
install -d "$PREFIX/lib"
install -m 755 "$WORK/musl-libs/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/"
install -m 755 "$WORK/musl-libs/usr/lib/libgcc_s.so.1"    "$PREFIX/lib/"
install -m 755 "$LIBSTDC_FILE"                            "$PREFIX/lib/"
rm -f "$PREFIX/lib/libstdc++.so.6"
ln -s "$(basename "$LIBSTDC_FILE")" "$PREFIX/lib/libstdc++.so.6"

# --- build the DNS shim (libresolvefix.so) -----------------------------------
# musl reads /etc/resolv.conf (read-only on Android) and sends raw UDP DNS
# (blocked). The shim redirects resolv.conf reads to Termux's copy and
# forwards getaddrinfo/freeaddrinfo/gai_strerror to bionic's implementation,
# which goes through Android's netd daemon.

log "Building libresolvefix.so (DNS shim)..."
cat > "$WORK/libresolvefix.c" <<'SHIM_EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netdb.h>
#include <sys/types.h>

/* --- Part 1: redirect /etc/resolv.conf reads to Termux's copy --- */

static const char *redirect(const char *p) {
    static char path[512];
    static int init = 0;
    if (p && strcmp(p, "/etc/resolv.conf") == 0) {
        if (!init) {
            const char *prefix = getenv("PREFIX");
            if (prefix && *prefix)
                snprintf(path, sizeof path, "%s/etc/resolv.conf", prefix);
            else
                snprintf(path, sizeof path, "%s",
                         "/data/data/com.termux/files/usr/etc/resolv.conf");
            init = 1;
        }
        return path;
    }
    return p;
}

int open(const char *pathname, int flags, ...) {
    int (*real_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
    const char *p = redirect(pathname);
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode_t m = va_arg(ap, mode_t);
        va_end(ap);
        return real_open(p, flags, m);
    }
    return real_open(p, flags);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    int (*real_openat)(int, const char *, int, ...) = dlsym(RTLD_NEXT, "openat");
    const char *p = redirect(pathname);
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode_t m = va_arg(ap, mode_t);
        va_end(ap);
        return real_openat(dirfd, p, flags, m);
    }
    return real_openat(dirfd, p, flags);
}

FILE *fopen(const char *pathname, const char *mode) {
    FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
    return real_fopen(redirect(pathname), mode);
}

/* --- Part 2: getaddrinfo -> bionic's via dlopen --- */

static void *bionic_lib = NULL;

static void ensure_bionic(void) {
    if (bionic_lib) return;
    bionic_lib = dlopen("/apex/com.android.runtime/lib64/bionic/libc.so",
                        RTLD_NOW | RTLD_NODELETE);
    if (!bionic_lib)
        bionic_lib = dlopen("/system/lib64/libc.so", RTLD_NOW | RTLD_NODELETE);
    if (!bionic_lib)
        bionic_lib = dlopen("libc.so", RTLD_NOW | RTLD_NODELETE);
}

typedef int (*bionic_getaddrinfo_fn)(const char *, const char *,
                                     const struct addrinfo *, struct addrinfo **);
typedef void (*bionic_freeaddrinfo_fn)(struct addrinfo *);
typedef const char *(*bionic_gai_strerror_fn)(int);

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_getaddrinfo_fn real =
            (bionic_getaddrinfo_fn)dlsym(bionic_lib, "getaddrinfo");
        if (real)
            return real(node, service, hints, res);
    }
    bionic_getaddrinfo_fn real =
        (bionic_getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
    return real(node, service, hints, res);
}

void freeaddrinfo(struct addrinfo *res) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_freeaddrinfo_fn real =
            (bionic_freeaddrinfo_fn)dlsym(bionic_lib, "freeaddrinfo");
        if (real) { real(res); return; }
    }
    bionic_freeaddrinfo_fn real =
        (bionic_freeaddrinfo_fn)dlsym(RTLD_NEXT, "freeaddrinfo");
    real(res);
}

const char *gai_strerror(int errcode) {
    ensure_bionic();
    if (bionic_lib) {
        bionic_gai_strerror_fn real =
            (bionic_gai_strerror_fn)dlsym(bionic_lib, "gai_strerror");
        if (real) return real(errcode);
    }
    bionic_gai_strerror_fn real =
        (bionic_gai_strerror_fn)dlsym(RTLD_NEXT, "gai_strerror");
    return real(errcode);
}
SHIM_EOF

# -nostdlib is essential: the shim is LD_PRELOADed into a *musl* process, so it
# must not declare a DT_NEEDED on Termux's (bionic) libc.so. Undefined symbols
# are resolved at runtime from the musl loader.
clang -shared -fPIC -O2 -o "$WORK/libresolvefix.so" "$WORK/libresolvefix.c" \
  -Wl,--dynamic-linker="$PREFIX/lib/ld-musl-aarch64.so.1" \
  -L"$PREFIX/lib" -nostdlib \
  || die "Failed to compile libresolvefix.so"
install -m 755 "$WORK/libresolvefix.so" "$PREFIX/lib/"

# --- install the HTTP proxy --------------------------------------------------
# Bun's io_uring-based networking doesn't work on Android, so all outbound
# traffic (API calls, webfetch, model registry, plugin installs) goes through
# this localhost Python proxy, which uses ordinary bionic sockets.

log "Installing localhost HTTP proxy..."
install -d "$LIBEXECDIR"
cat > "$LIBEXECDIR/proxy.py" <<'PROXY_EOF'
#!/usr/bin/env python3
"""HTTP proxy for opencode on Android (Termux).

Bun's io_uring networking doesn't work on Android, so all outbound
HTTP/HTTPS traffic is routed through this proxy on 127.0.0.1.

Modes:
1. Absolute-URL forward proxy: request lines like "GET http://host/path"
   are forwarded to the absolute target (this is what HTTP libraries do
   when HTTP_PROXY is set).
2. HTTP CONNECT tunnel: for HTTPS targets, a raw TCP tunnel is opened
   and bytes are piped both ways.
"""
import http.server
import urllib.request
import urllib.error
import ssl
import sys
import os
import socket
import select
import threading
from urllib.parse import urlparse

PORT = int(os.environ.get("PROXY_PORT", "8080"))

ctx = ssl.create_default_context()
opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self, url):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            if key.lower() not in ("host", "proxy-connection",
                                   "accept-encoding", "content-length"):
                req.add_header(key, val)
        try:
            resp = opener.open(req, timeout=120)
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            if e.readable():
                self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_request(self):
        target = None
        if self.path.startswith(("http://", "https://")):
            target = self.path
        if not target:
            self.send_response(400)
            self.send_header("Connection", "close")
            self.end_headers()
            return
        self._forward(target)

    def do_CONNECT(self):
        try:
            host, port = self.path.split(":", 1)
            port = int(port)
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        try:
            upstream = socket.create_connection((host, port), timeout=30)
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())
            return
        self.send_response(200, "Connection Established")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self._tunnel(self.connection, upstream)
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    def _tunnel(self, client, upstream):
        sockets = [client, upstream]
        try:
            while True:
                readable, _, _ = select.select(sockets, [], [], 60)
                if not readable:
                    break
                for s in readable:
                    other = upstream if s is client else client
                    data = s.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        except (OSError, ConnectionResetError):
            pass
        finally:
            for s in sockets:
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    do_GET = do_request
    do_POST = do_request
    do_PUT = do_request
    do_PATCH = do_request
    do_DELETE = do_request
    do_HEAD = do_request
    do_OPTIONS = do_request

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a thread so CONNECT tunnels don't block."""

    def process_request(self, request, client_address):
        t = threading.Thread(
            target=self._process_request,
            args=(request, client_address), daemon=True)
        t.start()

    def _process_request(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    if os.environ.get("PROXY_DEBUG"):
        log_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "opencode-proxy.log")
        sys.stdout = open(log_path, "a")
        sys.stderr = sys.stdout
    else:
        sys.stdout = open(os.devnull, "w")
        sys.stderr = sys.stdout
    server = ThreadedHTTPServer(("127.0.0.1", PORT), ProxyHandler)
    server.serve_forever()
PROXY_EOF
chmod 755 "$LIBEXECDIR/proxy.py"

# --- install the binary + patch its interpreter ------------------------------

log "Installing opencode binary..."
install -m 755 "$WORK/opencode" "$LIBEXECDIR/opencode-musl.bin"

log "Patching ELF interpreter..."
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
  "$LIBEXECDIR/opencode-musl.bin" \
  || die "patchelf failed to set the musl interpreter."

# --- wrapper -----------------------------------------------------------------

log "Installing wrapper script..."
install -d "$PREFIX/bin"
{
  echo "#!$PREFIX/bin/sh"
  cat <<'WRAPPER_EOF'
# opencode wrapper — runs the official musl build inside Termux.
#
#   - clears any stale LD_PRELOAD (old glibc-only shims crash musl processes
#     before main() even runs), then loads libresolvefix.so for DNS
#   - points LD_LIBRARY_PATH at the musl libstdc++/libgcc_s we installed
#   - routes outbound HTTP(S) through the localhost proxy
#   - sets the env vars opencode needs on Android
unset LD_PRELOAD
export LD_PRELOAD="$PREFIX/lib/libresolvefix.so"
export PREFIX
export HOME
export PATH
export TERM="${TERM:-xterm-256color}"
export LANG="${LANG:-en_US.UTF-8}"

# Timezone: follow the phone's so session times match the status-bar clock.
if [ -z "$TZ" ]; then
  __TZ=""
  command -v getprop >/dev/null 2>&1 && __TZ=$(getprop persist.sys.timezone 2>/dev/null)
  if [ -z "$__TZ" ] && [ -e /etc/localtime ]; then
    __TZ=$(readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  fi
  [ -n "$__TZ" ] && export TZ="$__TZ"
  unset __TZ
fi

export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMP="$TMPDIR" TEMP="$TMPDIR"
export LD_LIBRARY_PATH="$PREFIX/lib"
export OPENCODE_DISABLE_TUI_AUDIO=1
export OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER=true
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
export NODE_EXTRA_CA_CERTS="$PREFIX/etc/tls/cert.pem"
export CURL_CA_BUNDLE="$PREFIX/etc/tls/cert.pem"
export HTTP_PROXY="http://127.0.0.1:8080"
export HTTPS_PROXY="$HTTP_PROXY"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="$NO_PROXY"

# Start the localhost HTTP proxy if it isn't already running.
PIDFILE="$PREFIX/var/run/opencode-proxy.pid"
if ! { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }; then
  mkdir -p "$PREFIX/var/run"
  nohup python3 "$PREFIX/libexec/opencode/proxy.py" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  sleep 0.3
fi

exec "$PREFIX/libexec/opencode/opencode-musl.bin" "$@"
WRAPPER_EOF
} > "$PREFIX/bin/$INSTALL_NAME"
chmod 755 "$PREFIX/bin/$INSTALL_NAME"

# --- done ---------------------------------------------------------------------

log "Verifying..."
"$PREFIX/bin/$INSTALL_NAME" --version

log "Done. Run '$INSTALL_NAME' inside a project folder to start."
log "To remove everything later: re-run this script with --uninstall."
