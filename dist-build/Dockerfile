#
#  Copyright (C) Pathmate Technologies AG
#
#  Released under the BSD 3-Clause License, same as the surrounding
#  nginx-clojure project. See ../LICENSE.
#
#  Builder image for the self-built nginx-clojure distribution.
#

ARG BASE_IMAGE=debian:bullseye
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# build-essential + perl      : nginx and OpenSSL build
# default-jdk-headless        : the nginx-clojure module config script runs
#                               javac to discover the JNI include paths
#                               (compile time only -- the JVM itself is
#                               dlopen'ed at runtime)
# zlib1g-dev / libpcre2-dev   : nginx links these dynamically. Building them
#                               from source instead trips a GNU make 4.3
#                               jobserver bug in zlib's distclean recursion
#                               ("write jobserver: Bad file descriptor") and
#                               buys nothing -- both SONAMEs are stable and
#                               get patched by apt on the target host.
# libssl-dev                  : only needed for OPENSSL_MODE=system
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      perl \
      make \
      pkg-config \
      default-jdk-headless \
      zlib1g-dev \
      libpcre2-dev \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
