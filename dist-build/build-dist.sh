#!/bin/bash

#
#  Copyright (C) Pathmate Technologies AG
#
#  Released under the BSD 3-Clause License, same as the surrounding
#  nginx-clojure project. See ../LICENSE.
#
#  Builds a nginx-clojure binary distribution tarball -- same layout as the
#  upstream SourceForge releases, but from a nginx version of your choosing.
#
#  Usage:
#     ./build-dist.sh                        # use versions.env as-is
#     NGINX_VERSION=1.28.0 ./build-dist.sh   # override a single pin
#     ./build-dist.sh --pack-only            # re-pack out/<dist>/ without
#                                            # rebuilding (e.g. after adding a
#                                            # macOS binary via build-macos.sh)
#     ./build-dist.sh --plain                # plain nginx without the
#                                            # nginx-clojure module, built on
#                                            # PLAIN_BASE_IMAGE (see versions.env)
#
#  Everything is pinned in versions.env. The result lands in out/.
#

set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$DIR"

PACK_ONLY=no
PLAIN=no
for arg in "$@"; do
	case "$arg" in
		--pack-only) PACK_ONLY=yes ;;
		--plain)     PLAIN=yes ;;
		*)           echo "[ERROR] unknown argument: $arg" >&2; exit 1 ;;
	esac
done

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

[ -f versions.env ] || die "versions.env not found"

PINS="NGINX_VERSION NGINX_SHA256 OPENSSL_VERSION OPENSSL_SHA256 OPENSSL_MODE
      NGINX_CLOJURE_SRC NGINX_CLOJURE_VERSION
      BASE_IMAGE PLAIN_BASE_IMAGE BUILD_PLATFORM MAKE_JOBS WITH_DEBUG
      APPLY_PROXY_PATCH"

# versions.env holds the pins; an already-set environment variable wins, so a
# single value can be overridden ad hoc without editing the file.
for k in $PINS; do
	eval "__pre_$k=\${$k:-}"
done
# shellcheck disable=SC1091
. ./versions.env
for k in $PINS; do
	eval "__p=\$__pre_$k"
	[ -n "$__p" ] && eval "$k=\$__p"
	eval "export $k"
done

# A plain nginx has no nginx-clojure module, so neither the proxy patch nor the
# debug logging it relies on are wanted. It is built on its own base image to
# support older target hosts than the nginx-clojure distribution.
WITH_NGINX_CLOJURE=yes
if [ "$PLAIN" = "yes" ]; then
	WITH_NGINX_CLOJURE=no
	APPLY_PROXY_PATCH=no
	WITH_DEBUG=no
	BASE_IMAGE="$PLAIN_BASE_IMAGE"
fi
export WITH_NGINX_CLOJURE APPLY_PROXY_PATCH WITH_DEBUG BASE_IMAGE

command -v docker >/dev/null || die "docker is required"

# Resolve the module checkout (path in versions.env is relative to this dir)
case "$NGINX_CLOJURE_SRC" in
	/*) MODULE_SRC="$NGINX_CLOJURE_SRC" ;;
	*)  MODULE_SRC="$DIR/$NGINX_CLOJURE_SRC" ;;
esac
MODULE_SRC=$(cd "$MODULE_SRC" 2>/dev/null && pwd) \
	|| die "nginx-clojure checkout not found: $NGINX_CLOJURE_SRC"
[ -f "$MODULE_SRC/src/c/config" ] \
	|| die "$MODULE_SRC does not look like a nginx-clojure checkout (no src/c/config)"

MODULE_DESC=$(git -C "$MODULE_SRC" describe --always --dirty 2>/dev/null || echo "no-git")

if [ "$WITH_NGINX_CLOJURE" = "yes" ]; then
	DIST_NAME="nginx-clojure-${NGINX_CLOJURE_VERSION}-nginx-${NGINX_VERSION}"
else
	DIST_NAME="nginx-${NGINX_VERSION}-linux-x64"
fi
IMAGE_TAG="nginx-clojure-builder:$(echo "$BASE_IMAGE" | tr ':/' '--')"

log "distribution : $DIST_NAME"
log "nginx        : $NGINX_VERSION"
if [ "$WITH_NGINX_CLOJURE" = "yes" ]; then
	log "module       : $MODULE_SRC ($MODULE_DESC)"
else
	log "module       : none (plain nginx)"
fi
log "openssl      : $OPENSSL_MODE"
log "base image   : $BASE_IMAGE ($BUILD_PLATFORM)"

if [ "$OPENSSL_MODE" = "system" ]; then
	echo
	echo "  NOTE: OPENSSL_MODE=system links against the build image's libssl."
	echo "        The resulting binary only runs on a host with a compatible"
	echo "        OpenSSL -- make sure BASE_IMAGE matches the production distro."
	echo
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

mkdir -p cache out

if [ "$PACK_ONLY" = "yes" ]; then
	[ -d "out/$DIST_NAME" ] || die "--pack-only: out/$DIST_NAME does not exist, run a full build first"
	log "--pack-only: reusing existing out/$DIST_NAME"
fi

if [ "$PACK_ONLY" = "no" ]; then

log "building image $IMAGE_TAG"
docker build \
	--platform "$BUILD_PLATFORM" \
	--build-arg "BASE_IMAGE=$BASE_IMAGE" \
	-t "$IMAGE_TAG" \
	-f Dockerfile .

log "running build container"
docker run --rm \
	--platform "$BUILD_PLATFORM" \
	-v "$MODULE_SRC":/work/nginx-clojure:ro \
	-v "$DIR/cache":/work/cache \
	-v "$DIR/out":/work/out \
	-v "$DIR/container-build.sh":/work/container-build.sh:ro \
	-e NGINX_VERSION -e NGINX_SHA256 \
	-e OPENSSL_VERSION -e OPENSSL_SHA256 -e OPENSSL_MODE \
	-e WITH_DEBUG -e APPLY_PROXY_PATCH -e MAKE_JOBS -e WITH_NGINX_CLOJURE \
	-e BASE_IMAGE \
	-e "ALLOW_UNPINNED=${ALLOW_UNPINNED:-0}" \
	-e "DIST_NAME=$DIST_NAME" \
	-e "NGINX_CLOJURE_GIT_DESC=$MODULE_DESC" \
	"$IMAGE_TAG" \
	bash /work/container-build.sh

[ -d "out/$DIST_NAME" ] || die "container build produced no output"

fi  # PACK_ONLY

# ---------------------------------------------------------------------------
# Optional macOS binary (for local development only)
# ---------------------------------------------------------------------------

# build-macos.sh always builds with the nginx-clojure module, so its binary
# must never end up in a plain distribution.
if [ "$WITH_NGINX_CLOJURE" = "yes" ] && [ -f "out/nginx-macosx" ]; then
	log "including locally built macOS binary (see build-macos.sh)"
	install -m 0755 "out/nginx-macosx" "out/$DIST_NAME/nginx-macosx"
fi

# ---------------------------------------------------------------------------
# Pack
# ---------------------------------------------------------------------------

TARBALL="out/${DIST_NAME}.tar.gz"
log "packing $TARBALL"
rm -f "$TARBALL"
tar czf "$TARBALL" -C out "$DIST_NAME"

echo
echo "Built: $DIR/$TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo
echo "If the consuming project globs its sources/ directory for the tarball,"
echo "make sure exactly one is present -- move the previous one aside first."
