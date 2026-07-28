#!/bin/bash

#
#  Copyright (C) Pathmate Technologies AG
#
#  Released under the BSD 3-Clause License, same as the surrounding
#  nginx-clojure project. See ../LICENSE.
#
#  Runs INSIDE the builder container (see Dockerfile). Do not call directly --
#  use ./build-dist.sh on the host.
#
#  Mounts expected:
#    /work/nginx-clojure  (ro)  nginx-clojure checkout (module source)
#    /work/cache          (rw)  downloaded tarballs, reused across builds
#    /work/out            (rw)  build output
#

set -euo pipefail

BUILD_DIR=/tmp/nginx-build
OUT_DIR=/work/out
CACHE_DIR=/work/cache
MODULE_SRC=/work/nginx-clojure

: "${NGINX_VERSION:?}"
: "${DIST_NAME:?}"
: "${OPENSSL_MODE:=static}"
: "${WITH_DEBUG:=yes}"
: "${APPLY_PROXY_PATCH:=yes}"
: "${ALLOW_UNPINNED:=0}"

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Download + integrity check
# ---------------------------------------------------------------------------
# Sources are pinned by SHA-256 in versions.env. On the very first build of a
# new version the pin is empty: the script prints the hash and stops, so the
# hash can be verified once against the upstream PGP signature and then
# recorded. Set ALLOW_UNPINNED=1 to skip that gate (not for release builds).

fetch() {
	local url="$1" file="$2" expected="$3" pin_name="$4"
	local target="$CACHE_DIR/$file"

	if [ ! -f "$target" ]; then
		log "downloading $file"
		curl -fsSL --proto '=https' --tlsv1.2 -o "$target.part" "$url"
		mv "$target.part" "$target"
	else
		log "using cached $file"
	fi

	local actual
	actual=$(sha256sum "$target" | cut -d' ' -f1)

	if [ -z "$expected" ]; then
		echo
		echo "  $file is not pinned yet."
		echo "  sha256: $actual"
		echo
		echo "  Verify this against the upstream signature, then put it into"
		echo "  versions.env as:  ${pin_name}=$actual"
		echo
		[ "$ALLOW_UNPINNED" = "1" ] || die "refusing to build with an unpinned source"
		echo "  ALLOW_UNPINNED=1 -- continuing anyway."
	elif [ "$actual" != "$expected" ]; then
		die "checksum mismatch for $file
       expected: $expected
       actual:   $actual"
	fi
}

# ---------------------------------------------------------------------------
# The nginx-clojure proxy patch
# ---------------------------------------------------------------------------
# Upstream keeps this in its own nginx fork (nginx-clojure/nginx). It is two
# identical one-line changes and applies to every nginx version so far. If the
# occurrence count is not exactly 2, nginx changed the code -- stop and look.

apply_proxy_patch() {
	local f="src/http/modules/ngx_http_proxy_module.c"
	local needle='if (ngx_hash_find(&headers->hash, header\[i\]\.hash,'
	local count

	count=$(grep -c "$needle" "$f" || true)
	if [ "$count" != "2" ]; then
		die "proxy patch: expected 2 matches in $f, found $count.
       nginx $NGINX_VERSION changed ngx_http_proxy_create_request().
       Review the patch (see README.md ("Der Proxy-Patch")) or set APPLY_PROXY_PATCH=no."
	fi

	sed -i \
		"s/if (ngx_hash_find(&headers->hash, header\[i\]\.hash,/if (header[i].hash == 0 || ngx_hash_find(\&headers->hash, header[i].hash,/g" \
		"$f"

	count=$(grep -c 'if (header\[i\]\.hash == 0 || ngx_hash_find' "$f" || true)
	[ "$count" = "2" ] || die "proxy patch did not apply cleanly ($count/2)"
	log "proxy patch applied (2/2)"
}

# ---------------------------------------------------------------------------
# Fetch sources
# ---------------------------------------------------------------------------

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"

fetch "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
      "nginx-${NGINX_VERSION}.tar.gz" "${NGINX_SHA256:-}" "NGINX_SHA256"

# zlib and PCRE2 come from the build image (zlib1g-dev / libpcre2-dev) and are
# linked dynamically -- see Dockerfile for why they are not built from source.

if [ "$OPENSSL_MODE" = "static" ]; then
	fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
	      "openssl-${OPENSSL_VERSION}.tar.gz" "${OPENSSL_SHA256:-}" "OPENSSL_SHA256"
fi

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------

log "extracting sources"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

tar xzf "$CACHE_DIR/nginx-${NGINX_VERSION}.tar.gz"
[ "$OPENSSL_MODE" = "static" ] && tar xzf "$CACHE_DIR/openssl-${OPENSSL_VERSION}.tar.gz"

# The module source is mounted read-only; nginx' configure wants to be able to
# stat it only, but make writes objects into the nginx tree, not into the
# module dir. Copy anyway so a dirty checkout can never be modified.
cp -a "$MODULE_SRC" "$BUILD_DIR/nginx-clojure-src"
MODULE_C_DIR="$BUILD_DIR/nginx-clojure-src/src/c"
[ -f "$MODULE_C_DIR/config" ] || die "no module config found at $MODULE_C_DIR"

# ---------------------------------------------------------------------------
# Configure + build
# ---------------------------------------------------------------------------

cd "$BUILD_DIR/nginx-${NGINX_VERSION}"

[ "$APPLY_PROXY_PATCH" = "yes" ] && apply_proxy_patch

# Prefix layout must match what setup.sh / templates/nginx.conf expect:
# nginx runs with WorkingDirectory=<dir>/nginx and all paths are relative.
CONFIGURE_ARGS=(
	--prefix=
	--sbin-path=nginx
	--conf-path=conf/nginx.conf
	--error-log-path=logs/error.log
	--http-log-path=logs/access.log
	--pid-path=logs/nginx.pid
	--lock-path=logs/nginx.lock
	--http-client-body-temp-path=temp/client_temp
	--http-proxy-temp-path=temp/proxy_temp
	--http-fastcgi-temp-path=temp/fastcgi_temp
	--http-uwsgi-temp-path=temp/uwsgi_temp
	--http-scgi-temp-path=temp/scgi_temp

	# Modules actually referenced by templates/nginx.conf
	--with-http_ssl_module
	--with-http_stub_status_module
	# Not used today, but cheap and likely wanted eventually
	--with-http_v2_module
	--with-http_realip_module
	--with-http_gunzip_module
	--with-http_gzip_static_module
	--with-http_sub_module

	--with-threads
	--with-file-aio
	# zlib / PCRE2 are picked up from the system (see Dockerfile)
	--with-pcre-jit

	--add-module="$MODULE_C_DIR"
)

# Deliberately NOT built (were in the upstream 0.6.0 binary, unused here):
#   http_mp4_module      -- CVE-2024-7347 lives here, and no mp4 is served
#   http_dav_module, http_flv_module, http_random_index_module,
#   http_secure_link_module, http_addition_module, http_image_filter_module,
#   mail / mail_ssl      -- no mail proxy in this deployment

[ "$WITH_DEBUG" = "yes" ] && CONFIGURE_ARGS+=(--with-debug)

if [ "$OPENSSL_MODE" = "static" ]; then
	CONFIGURE_ARGS+=(--with-openssl="../openssl-${OPENSSL_VERSION}")
fi

log "configuring nginx ${NGINX_VERSION}"
./configure "${CONFIGURE_ARGS[@]}"

log "compiling with ${MAKE_JOBS:-$(nproc)} jobs (slow under QEMU emulation)"
make -j"${MAKE_JOBS:-$(nproc)}"

# ---------------------------------------------------------------------------
# Assemble the distribution tree
# ---------------------------------------------------------------------------

DIST="$OUT_DIR/$DIST_NAME"
log "assembling $DIST_NAME"
rm -rf "$DIST"
mkdir -p "$DIST"

install -m 0755 objs/nginx "$DIST/nginx-linux-x64"

cp -a conf "$DIST/conf"
cp -a contrib "$DIST/contrib"
cp -a html "$DIST/html"

mkdir -p "$DIST/docs"
cp -a "$BUILD_DIR/nginx-clojure-src/README.md"  "$DIST/docs/" 2>/dev/null || true
cp -a "$BUILD_DIR/nginx-clojure-src/HISTORY.md" "$DIST/docs/" 2>/dev/null || true

mkdir -p "$DIST/licenses"
cp -a LICENSE "$DIST/licenses/nginx.LICENSE"
cp -a "$BUILD_DIR/nginx-clojure-src/LICENSE" "$DIST/licenses/nginx-clojure.LICENSE" 2>/dev/null || true
if [ "$OPENSSL_MODE" = "static" ]; then
	cp -a "$BUILD_DIR/openssl-${OPENSSL_VERSION}/LICENSE.txt" "$DIST/licenses/OpenSSL.LICENSE" 2>/dev/null || true
fi
# zlib / PCRE2 are dynamically linked system libraries, their licenses ship
# with the distribution package on the target host.

# Runtime directories. setup.sh empties libs/ and refills it from build/libs,
# so nothing is shipped in here -- but nginx needs the temp dirs to exist and
# jvm_classpath "libs/*" needs the directory.
mkdir -p "$DIST/logs" \
         "$DIST/libs/res" \
         "$DIST/jars" \
         "$DIST/coroutine-udfs" \
         "$DIST/temp/client_temp" \
         "$DIST/temp/proxy_temp" \
         "$DIST/temp/fastcgi_temp" \
         "$DIST/temp/uwsgi_temp" \
         "$DIST/temp/scgi_temp"

# ---------------------------------------------------------------------------
# Build report -- goes into the tarball so the deployed artifact is traceable
# ---------------------------------------------------------------------------

{
	echo "nginx-clojure distribution built by nginx-clojure/dist-build"
	echo
	echo "dist name        : $DIST_NAME"
	echo "nginx            : $NGINX_VERSION"
	echo "nginx-clojure    : $(sed -n 's/^#define NGINX_CLOJURE_VER_NUM_STR "\(.*\)"/\1/p' "$BUILD_DIR/nginx-clojure-src/src/c/ngx_http_clojure_mem.h") (source: ${NGINX_CLOJURE_GIT_DESC:-unknown})"
	echo "pcre2 / zlib     : system libraries of $BASE_IMAGE (dynamic)"
	echo "openssl          : $([ "$OPENSSL_MODE" = static ] && echo "$OPENSSL_VERSION (static)" || echo "system (dynamic)")"
	echo "debug build      : $WITH_DEBUG"
	echo "proxy patch      : $APPLY_PROXY_PATCH"
	echo "base image       : ${BASE_IMAGE:-unknown}"
	echo
	echo "configure arguments:"
	printf '  %s\n' "${CONFIGURE_ARGS[@]}"
} > "$DIST/docs/BUILD-INFO.txt"

log "verifying binary"
"$DIST/nginx-linux-x64" -V 2>&1 | sed 's/^/    /'

log "done: $DIST"
