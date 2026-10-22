#!/bin/bash

#
#  Copyright (C) Pathmate Technologies AG
#
#  Released under the BSD 3-Clause License, same as the surrounding
#  nginx-clojure project. See ../LICENSE.
#
#  One call for a complete nginx-clojure release of this fork:
#
#    1. macOS binary            (build-macos.sh)
#    2. Linux binary + tarball  (build-dist.sh)
#    3. Java runtime jar        (lein jar)
#    4. Upload of the jar to the Maven repository (JAR_VERSION from versions.env)
#    5. Optional: hand tarball and jar version over to a consuming project
#       (e.g. pmcp-nginx-handler) -- files are changed, nothing is committed.
#
#  Usage:
#     ./build-all.sh [--handler <dir>] [--skip-macos] [--skip-deploy]
#
#  Requires: macOS, Docker, Leiningen, Maven and the repository credentials
#  in ~/.pathmate-credentials.properties (repo.user / repo.pass).
#

set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$DIR"

HANDLER_DIR=""
SKIP_MACOS=no
SKIP_DEPLOY=no
while [ $# -gt 0 ]; do
	case "$1" in
		--handler)     HANDLER_DIR="${2:-}"; shift ;;
		--skip-macos)  SKIP_MACOS=yes ;;
		--skip-deploy) SKIP_DEPLOY=yes ;;
		*)             echo "[ERROR] unknown argument: $1" >&2; exit 1 ;;
	esac
	shift
done

log() { echo "==> $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS"
[ -f versions.env ] || die "versions.env not found"

# shellcheck disable=SC1091
. ./versions.env

[ -n "${JAR_VERSION:-}" ]          || die "JAR_VERSION missing in versions.env"
[ -n "${MAVEN_REPOSITORY_ID:-}" ]  || die "MAVEN_REPOSITORY_ID missing in versions.env"
[ -n "${MAVEN_REPOSITORY_URL:-}" ] || die "MAVEN_REPOSITORY_URL missing in versions.env"

REPO_ROOT=$(cd "$DIR/.." && pwd)
PROJECT_VERSION=$(sed -n '1s/^(defproject [^ ]* "\([^"]*\)".*/\1/p' "$REPO_ROOT/project.clj")
[ "$PROJECT_VERSION" = "$NGINX_CLOJURE_VERSION" ] \
	|| die "project.clj ($PROJECT_VERSION) and NGINX_CLOJURE_VERSION ($NGINX_CLOJURE_VERSION) differ"
case "$JAR_VERSION" in
	"$NGINX_CLOJURE_VERSION"-*) ;;
	*) die "JAR_VERSION ($JAR_VERSION) must start with NGINX_CLOJURE_VERSION ($NGINX_CLOJURE_VERSION-)" ;;
esac

DIST_NAME="nginx-clojure-${NGINX_CLOJURE_VERSION}-nginx-${NGINX_VERSION}"
TARBALL="$DIR/out/${DIST_NAME}.tar.gz"
JAR="$REPO_ROOT/target/nginx-clojure-${NGINX_CLOJURE_VERSION}.jar"
JAR_PATH="nginx-clojure/nginx-clojure/${JAR_VERSION}/nginx-clojure-${JAR_VERSION}.jar"

command -v docker >/dev/null || die "docker is required"
command -v lein   >/dev/null || die "leiningen is required (brew install leiningen)"
command -v mvn    >/dev/null || die "maven is required (brew install maven)"

if [ -n "$HANDLER_DIR" ]; then
	HANDLER_DIR=$(cd "$HANDLER_DIR" 2>/dev/null && pwd) || die "handler directory not found"
	[ -f "$HANDLER_DIR/pom.xml" ] && [ -f "$HANDLER_DIR/setup.sh" ] \
		|| die "$HANDLER_DIR does not look like the consuming project (pom.xml / setup.sh missing)"
fi

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
	echo "  NOTE: the checkout has uncommitted changes, they end up in the build."
fi

# Credentials are needed up front: an already uploaded JAR_VERSION has to be
# detected before spending 15 minutes on the build.
if [ "$SKIP_DEPLOY" = "no" ]; then
	CREDENTIALS_FILE="$HOME/.pathmate-credentials.properties"
	if [ -z "${PATHMATE_USER:-}" ] || [ -z "${PATHMATE_PASS:-}" ]; then
		[ -f "$CREDENTIALS_FILE" ] || die "credentials file ($CREDENTIALS_FILE) required for the upload"
		PATHMATE_USER=$(grep '^repo.user=' "$CREDENTIALS_FILE" | cut -d= -f2- | tr -d '\r')
		PATHMATE_PASS=$(grep '^repo.pass=' "$CREDENTIALS_FILE" | cut -d= -f2- | tr -d '\r')
	fi
	export PATHMATE_USER PATHMATE_PASS

	STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$PATHMATE_USER:$PATHMATE_PASS" \
		"${MAVEN_REPOSITORY_URL%/}/$JAR_PATH")
	case "$STATUS" in
		404) ;;
		200) die "$JAR_VERSION is already uploaded -- raise JAR_VERSION in versions.env" ;;
		*)   die "repository check failed (HTTP $STATUS) -- credentials or network?" ;;
	esac
fi

log "distribution : $DIST_NAME"
log "jar          : nginx-clojure:nginx-clojure:$JAR_VERSION"
log "upload       : $([ "$SKIP_DEPLOY" = "yes" ] && echo "skipped" || echo "$MAVEN_REPOSITORY_URL")"
log "handler      : ${HANDLER_DIR:-none}"

# ---------------------------------------------------------------------------
# Binaries and tarball
# ---------------------------------------------------------------------------

if [ "$SKIP_MACOS" = "no" ]; then
	./build-macos.sh
else
	# build-dist.sh packs whatever lies in out/nginx-macosx -- a stale binary
	# from an older nginx version must not slip into the new tarball.
	[ ! -f out/nginx-macosx ] || echo "  NOTE: packing the existing out/nginx-macosx (--skip-macos)"
fi
./build-dist.sh
[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"

# ---------------------------------------------------------------------------
# Jar
# ---------------------------------------------------------------------------

log "building jar"
(cd "$REPO_ROOT" && lein with-profile -dev,+provided jar)
[ -f "$JAR" ] || die "jar not found: $JAR"

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

if [ "$SKIP_DEPLOY" = "no" ]; then
	log "uploading jar"
	SETTINGS=$(mktemp)
	trap 'rm -f "$SETTINGS"' EXIT
	cat > "$SETTINGS" <<EOF
<settings>
	<servers>
		<server>
			<id>${MAVEN_REPOSITORY_ID}</id>
			<username>\${env.PATHMATE_USER}</username>
			<password>\${env.PATHMATE_PASS}</password>
		</server>
	</servers>
</settings>
EOF
	mvn -B -q -s "$SETTINGS" \
		org.apache.maven.plugins:maven-deploy-plugin:3.1.2:deploy-file \
		-Dfile="$JAR" \
		-DgroupId=nginx-clojure \
		-DartifactId=nginx-clojure \
		-Dversion="$JAR_VERSION" \
		-Dpackaging=jar \
		-DgeneratePom=true \
		-DrepositoryId="$MAVEN_REPOSITORY_ID" \
		-Durl="$MAVEN_REPOSITORY_URL"

	REMOTE_SHA=$(curl -fsS -u "$PATHMATE_USER:$PATHMATE_PASS" "${MAVEN_REPOSITORY_URL%/}/$JAR_PATH" \
		| shasum -a 256 | cut -d' ' -f1)
	LOCAL_SHA=$(shasum -a 256 "$JAR" | cut -d' ' -f1)
	[ "$REMOTE_SHA" = "$LOCAL_SHA" ] || die "uploaded jar differs from the local one"
	log "upload verified ($LOCAL_SHA)"
fi

# ---------------------------------------------------------------------------
# Hand over to the consuming project
# ---------------------------------------------------------------------------

if [ -n "$HANDLER_DIR" ]; then
	log "updating $HANDLER_DIR"

	for old in "$HANDLER_DIR"/sources/nginx-clojure-*.tar.gz; do
		[ -e "$old" ] || continue
		[ "$(basename "$old")" = "${DIST_NAME}.tar.gz" ] && continue
		git -C "$HANDLER_DIR" rm -q "sources/$(basename "$old")"
	done
	cp "$TARBALL" "$HANDLER_DIR/sources/"

	sed -i '' "s|^NGINX_CLOJURE_ARCHIVE=.*|NGINX_CLOJURE_ARCHIVE=${DIST_NAME}.tar.gz|" "$HANDLER_DIR/setup.sh"
	sed -i '' "/<artifactId>nginx-clojure<\/artifactId>/{n;s|<version>[^<]*</version>|<version>${JAR_VERSION}</version>|;}" \
		"$HANDLER_DIR/pom.xml"

	git -C "$HANDLER_DIR" add sources/ setup.sh pom.xml
	echo
	git -C "$HANDLER_DIR" status --short
fi

echo
echo "Done."
echo "  tarball : $TARBALL"
echo "  jar     : nginx-clojure:nginx-clojure:$JAR_VERSION"
if [ -n "$HANDLER_DIR" ]; then
	echo "  handler : changes staged on branch $(git -C "$HANDLER_DIR" branch --show-current), not committed"
fi
