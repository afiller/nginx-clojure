#!/bin/bash

#
#  Copyright (C) Pathmate Technologies AG
#
#  Released under the BSD 3-Clause License, same as the surrounding
#  nginx-clojure project. See ../LICENSE.
#
#  Builds the macOS nginx binary for LOCAL DEVELOPMENT only. Production runs
#  the Linux binary from build-dist.sh.
#
#  Run this BEFORE ./build-dist.sh -- the result (out/nginx-macosx) is picked
#  up automatically and packed into the tarball.
#
#  Requires: Xcode command line tools, a JDK (for the JNI headers).
#

set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$DIR"

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"
[ -f versions.env ] || die "versions.env not found"

# shellcheck disable=SC1091
. ./versions.env

export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home)}"
export LC_CTYPE=C
export LANG=C

case "$NGINX_CLOJURE_SRC" in
	/*) MODULE_SRC="$NGINX_CLOJURE_SRC" ;;
	*)  MODULE_SRC="$DIR/$NGINX_CLOJURE_SRC" ;;
esac
MODULE_SRC=$(cd "$MODULE_SRC" && pwd)

BUILD_DIR="$DIR/build-macos"
CACHE_DIR="$DIR/cache"
mkdir -p "$BUILD_DIR" "$CACHE_DIR" out

fetch() {
	local url="$1" file="$2" expected="$3"
	[ -f "$CACHE_DIR/$file" ] || curl -fsSL --proto '=https' -o "$CACHE_DIR/$file" "$url"
	local actual
	actual=$(shasum -a 256 "$CACHE_DIR/$file" | cut -d' ' -f1)
	if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
		die "checksum mismatch for $file (expected $expected, got $actual)"
	fi
}

fetch "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
      "nginx-${NGINX_VERSION}.tar.gz" "${NGINX_SHA256:-}"

log "extracting"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
tar xzf "$CACHE_DIR/nginx-${NGINX_VERSION}.tar.gz"

cd "nginx-${NGINX_VERSION}"

if [ "${APPLY_PROXY_PATCH:-yes}" = "yes" ]; then
	f="src/http/modules/ngx_http_proxy_module.c"
	count=$(grep -c 'if (ngx_hash_find(&headers->hash, header\[i\]\.hash,' "$f" || true)
	[ "$count" = "2" ] || die "proxy patch: expected 2 matches, found $count"
	sed -i '' \
		"s/if (ngx_hash_find(&headers->hash, header\[i\]\.hash,/if (header[i].hash == 0 || ngx_hash_find(\&headers->hash, header[i].hash,/g" \
		"$f"
	log "proxy patch applied"
fi

# macOS ships no OpenSSL or PCRE2 headers -- use the Homebrew ones. zlib comes
# from the SDK and is found by nginx automatically.
OPENSSL_PREFIX=$(brew --prefix openssl@3 2>/dev/null || echo "")
[ -n "$OPENSSL_PREFIX" ] || die "brew install openssl@3 first (macOS has no OpenSSL headers)"
PCRE2_PREFIX=$(brew --prefix pcre2 2>/dev/null || echo "")
[ -n "$PCRE2_PREFIX" ] || die "brew install pcre2 first"

log "configuring"
./configure \
	--prefix= \
	--sbin-path=nginx \
	--conf-path=conf/nginx.conf \
	--error-log-path=logs/error.log \
	--http-log-path=logs/access.log \
	--pid-path=logs/nginx.pid \
	--lock-path=logs/nginx.lock \
	--http-client-body-temp-path=temp/client_temp \
	--http-proxy-temp-path=temp/proxy_temp \
	--http-fastcgi-temp-path=temp/fastcgi_temp \
	--http-uwsgi-temp-path=temp/uwsgi_temp \
	--http-scgi-temp-path=temp/scgi_temp \
	--with-http_ssl_module \
	--with-http_stub_status_module \
	--with-http_v2_module \
	--with-http_realip_module \
	--with-http_gunzip_module \
	--with-http_gzip_static_module \
	--with-http_sub_module \
	--with-threads \
	--with-pcre-jit \
	--with-cc-opt="-I${OPENSSL_PREFIX}/include -I${PCRE2_PREFIX}/include -Wno-deprecated-declarations" \
	--with-ld-opt="-L${OPENSSL_PREFIX}/lib -L${PCRE2_PREFIX}/lib" \
	$([ "${WITH_DEBUG:-yes}" = "yes" ] && echo "--with-debug") \
	--add-module="${MODULE_SRC}/src/c"

log "compiling"
make -j"$(sysctl -n hw.ncpu)"

install -m 0755 objs/nginx "$DIR/out/nginx-macosx"
log "done: out/nginx-macosx"
"$DIR/out/nginx-macosx" -V 2>&1 | sed 's/^/    /'
