#!/bin/bash
set -e

MUSL_DIR="${MUSL_DIR:-../neoos-musl/build-output}"
OPENSSL_DIR="${OPENSSL_DIR:-../neoos-openssl/build-output}"
LIBSSH2_DIR="${LIBSSH2_DIR:-../neoos-libssh2/build-output}"
PREFIX="${PREFIX:-build-output}"
UPSTREAM_DIR="${UPSTREAM_DIR:-upstream}"
BUILD_TMP="${BUILD_TMP:-build-tmp}"

if [ ! -d "$MUSL_DIR/include" ]; then
    echo "Error: musl not found at $MUSL_DIR (build neoos-musl first)" >&2
    exit 1
fi
if [ ! -f "$OPENSSL_DIR/lib/libcrypto.a" ]; then
    echo "Error: OpenSSL not found at $OPENSSL_DIR (build neoos-openssl first)" >&2
    exit 1
fi
if [ ! -f "$LIBSSH2_DIR/lib/libssh2.a" ]; then
    echo "Error: libssh2 not found at $LIBSSH2_DIR (build neoos-libssh2 first)" >&2
    exit 1
fi
if [ ! -f "$UPSTREAM_DIR/CMakeLists.txt" ]; then
    echo "Error: upstream curl checkout not found at $UPSTREAM_DIR" >&2
    exit 1
fi

ABS_PREFIX="$(mkdir -p "$PREFIX" && cd "$PREFIX" && pwd)"
ABS_MUSL_DIR="$(cd "$MUSL_DIR" && pwd)"
ABS_OPENSSL_DIR="$(cd "$OPENSSL_DIR" && pwd)"
ABS_LIBSSH2_DIR="$(cd "$LIBSSH2_DIR" && pwd)"

echo "Building curl for NeoOS..."
rm -rf "$BUILD_TMP"

# CMAKE_FIND_ROOT_PATH now covers THREE prefixes (OpenSSL, libssh2,
# musl) -- curl's find_package(OpenSSL) and find_package(Libssh2 MODULE)
# both need to land inside it, or a host-installed OpenSSL (very likely
# present on any real dev machine) gets found instead of the
# cross-built one. See neoos-libssh2/build.sh for why
# CMAKE_REQUIRED_LIBRARIES (musl's crt1.o + libc.a) matters: without
# it, curl's own HAVE_*/CURL_* check_c_source_compiles probes fail to
# link against our -nostdlib flags and are silently recorded as
# unavailable regardless of what musl actually provides -- exactly the
# false negative that broke libssh2 the first time it was built here.
#
# BUILD_CURL_EXE=OFF is deliberate: CMake's own attempt to link the
# curl executable does not know about NeoOS's user.ld linker script or
# crt1.o, and would fail (or silently produce something that will not
# run) if asked to. The CLI is linked by hand below instead, the same
# way neoos-libssh2's own SFTP/exec test programs were hand-linked
# against libssh2.a. Building only libcurl here keeps `cmake --build`
# green.
cmake -S "$UPSTREAM_DIR" -B "$BUILD_TMP" \
    -DCMAKE_TOOLCHAIN_FILE="$(pwd)/toolchain.cmake" \
    -DCMAKE_FIND_ROOT_PATH="$ABS_OPENSSL_DIR;$ABS_LIBSSH2_DIR;$ABS_MUSL_DIR" \
    -DCMAKE_INSTALL_PREFIX="$ABS_PREFIX" \
    -DCMAKE_C_FLAGS="-static -nostdlib -mcmodel=large -fno-pic -mno-red-zone -fno-stack-protector -O2 -isystem $ABS_MUSL_DIR/include" \
    -DCMAKE_REQUIRED_LIBRARIES="$ABS_MUSL_DIR/lib/crt1.o;$ABS_MUSL_DIR/lib/libc.a" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_CURL_MANUAL=OFF \
    -DBUILD_LIBCURL_DOCS=OFF \
    -DBUILD_MISC_DOCS=OFF \
    -DCURL_USE_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$ABS_OPENSSL_DIR" \
    -DOPENSSL_INCLUDE_DIR="$ABS_OPENSSL_DIR/include" \
    -DCURL_USE_LIBSSH2=ON \
    -DLIBSSH2_INCLUDE_DIR="$ABS_LIBSSH2_DIR/include" \
    -DLIBSSH2_LIBRARY="$ABS_LIBSSH2_DIR/lib/libssh2.a" \
    -DCURL_CA_BUNDLE=/opt/curl/cacert.pem \
    -DCURL_ZLIB=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DUSE_NGHTTP2=OFF \
    -DUSE_LIBIDN2=OFF \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_DISABLE_FTP=ON \
    -DCURL_DISABLE_FILE=ON \
    -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_DICT=ON \
    -DCURL_DISABLE_GOPHER=ON \
    -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_MQTT=ON \
    -DCURL_DISABLE_POP3=ON \
    -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_SMTP=ON \
    -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_WEBSOCKETS=ON \
    -DCURL_DISABLE_IPFS=ON \
    -DCURL_ENABLE_SMB=OFF \
    -DCURL_DISABLE_DOH=ON

cmake --build "$BUILD_TMP" --target libcurl_static -j"$(nproc)"
cmake --install "$BUILD_TMP"

mkdir -p "$ABS_PREFIX"
cp "$ABS_OPENSSL_DIR/etc/ssl/cert.pem" "$ABS_PREFIX/cacert.pem"

if [ -f "$PREFIX/lib/libcurl.a" ]; then
    echo ""
    echo "OK libcurl.a built successfully at $PREFIX"
    ls -lh "$PREFIX/lib/libcurl.a"
else
    echo "ERROR: build finished but libcurl.a not found" >&2
    exit 1
fi
