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
# HAVE_EVENTFD=0 is a deliberate override, not a missing feature this
# needs fixing later: musl provides a real eventfd() WRAPPER FUNCTION
# (it links fine, so check_function_exists("eventfd") reports true),
# but NeoOS's shim does not implement the eventfd2 syscall underneath
# it -- calling it fails at runtime with ENOSYS, which surfaced as
# curl's own generic "(27) Out of memory" from lib/socketpair.c's
# wakeup_eventfd() failing. This is the mirror image of the
# HAVE_O_NONBLOCK problem libssh2 hit: there, a probe FALSE NEGATIVE
# hid a capability NeoOS genuinely has; here, a probe FALSE POSITIVE
# claims one it does not, because check_function_exists can only prove
# a symbol resolves, never that calling it actually works, and no
# cross-compile probe can run the target's kernel to find out. Forcing
# HAVE_EVENTFD off makes curl's own multi-handle wakeup fall through
# to HAVE_PIPE's pipe2()-based implementation (lib/socketpair.c) --
# NeoOS's real, working, already-tested pipe2 -- instead of adding
# eventfd2 as a THIRD kernel primitive for a pure optimization curl
# itself treats as an optional fast path over an equivalent fallback.
#
# ENABLE_THREADED_RESOLVER=OFF: curl's default async resolver (the
# only other option here, since c-ares is not ported) spawns a pthread
# per lookup and synchronizes it back to the transfer via a
# socketpair/pipe wakeup -- a real DNS lookup (curl -v http://example.com)
# hung forever with it on, with zero output even under -v, pointing at
# that cross-thread handoff rather than resolution itself (a raw-IP
# request, which never touches the resolver at all, connects and fails
# normally). Rather than debug a second cross-thread synchronization
# path this session already spent real effort proving correct for a
# more essential case (libssh2's poll()), this switches curl to its
# synchronous resolver (CURLRES_SYNCH, still a fully supported mode in
# 8.22.0): a direct getaddrinfo() call on the transfer's own thread --
# exactly the call already proven working end-to-end in the DNS
# milestone. The right engineering trade for a CLI tool that mostly
# fetches one URL per invocation, where the threaded resolver's real
# benefit (not blocking OTHER concurrent transfers on the same
# multi-handle) does not apply.
#
# HAVE_ALARM=0 is the same false-positive class as HAVE_EVENTFD above:
# musl provides a real alarm() wrapper (links fine), but it calls
# setitimer() underneath, which NeoOS's shim does not implement --
# ENOSYS at runtime, immediately after a real DNS lookup, from the
# synchronous resolver's alarm()+sigsetjmp/siglongjmp DNS-timeout
# mechanism (USE_ALARM_TIMEOUT, lib/vdns/hostip.c -- gated behind
# HAVE_ALARM && HAVE_SIGSETJMP && ...). This is a legacy fallback for
# platforms with no better way to bound a blocking resolver call; the
# getaddrinfo() call itself is already proven fast and reliable (the
# DNS milestone), so no timeout enforcement here is a fine trade
# against implementing a fourth kernel-level primitive (real interval
# timers + SIGALRM delivery) for a mechanism curl itself treats as a
# fallback of a fallback.
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
    -DCURL_DISABLE_DOH=ON \
    -DHAVE_EVENTFD=0 \
    -DENABLE_THREADED_RESOLVER=OFF \
    -DHAVE_ALARM=0

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

# ---------------------------------------------------------------------
# The curl CLI: hand-linked. CMake's own executable target does not
# know about NeoOS's user.ld linker script or crt1.o and would fail
# (or silently produce something that will not run) if asked to build
# it -- BUILD_CURL_EXE=OFF above skips that entirely. This mirrors how
# neoos-libssh2's own SFTP/exec test programs were hand-linked against
# libssh2.a.
#
# Source list is curl-8_22_0's src/Makefile.inc, read directly rather
# than asked of CMake: CURL_CFILES (40 files in src/), plus
# toolx/tool_time.c, plus the 16 lib/curlx/*.c files the CLI reuses
# directly (curlx_* functions are internal to libcurl, not part of its
# public API, so the CLI compiles its own copy rather than linking
# against symbols libcurl.a does not export).
CLI_SRCS=""
for f in config2setopts slist_wc terminal tool_cb_dbg tool_cb_hdr \
         tool_cb_prg tool_cb_rea tool_cb_see tool_cb_soc tool_cb_wrt \
         tool_cfgable tool_dirhie tool_doswin tool_easysrc tool_filetime \
         tool_findfile tool_formparse tool_getparam tool_getpass tool_help \
         tool_helpers tool_ipfs tool_libinfo tool_listhelp tool_main tool_msgs \
         tool_operate tool_operhlp tool_paramhlp tool_parsecfg tool_progress \
         tool_setopt tool_ssls tool_stderr tool_urlglob tool_util tool_vms \
         tool_writeout tool_writeout_json tool_xattr var; do
    CLI_SRCS="$CLI_SRCS $UPSTREAM_DIR/src/$f.c"
done
CLI_SRCS="$CLI_SRCS $UPSTREAM_DIR/src/toolx/tool_time.c"
for f in base64 basename dynbuf fopen multibyte nonblock strcopy strdup \
         strerr strparse timediff timeval version_win32 wait warnless winapi; do
    CLI_SRCS="$CLI_SRCS $UPSTREAM_DIR/lib/curlx/$f.c"
done

echo ""
echo "Linking curl CLI..."
x86_64-elf-gcc -static -nostdlib -nostdinc -ffreestanding \
    -mcmodel=large -fno-pic -mno-red-zone -fno-stack-protector -O2 \
    -ffunction-sections -fdata-sections \
    -isystem "$ABS_MUSL_DIR/include" \
    -isystem "$ABS_OPENSSL_DIR/include" \
    -isystem "$ABS_LIBSSH2_DIR/include" \
    -I"$(pwd)/$UPSTREAM_DIR/include" \
    -I"$(pwd)/$UPSTREAM_DIR/lib" \
    -I"$(pwd)/$UPSTREAM_DIR/lib/curlx" \
    -I"$(pwd)/$UPSTREAM_DIR/src" \
    -I"$(pwd)/$BUILD_TMP/lib" \
    -DHAVE_CONFIG_H \
    -DCURL_STATICLIB \
    -T user.ld -z noexecstack -Wl,--gc-sections \
    -o "$ABS_PREFIX/bin/curl.elf" \
    "$ABS_MUSL_DIR/lib/crt1.o" $CLI_SRCS \
    -Wl,--start-group \
    -L"$ABS_PREFIX/lib" -lcurl \
    -L"$ABS_LIBSSH2_DIR/lib" -lssh2 \
    -L"$ABS_OPENSSL_DIR/lib" -lssl -lcrypto \
    -Wl,--end-group \
    -L"$ABS_MUSL_DIR/lib" -lc -lgcc -lm
mkdir -p "$ABS_PREFIX/bin"
cp "$ABS_PREFIX/bin/curl.elf" "$ABS_PREFIX/bin/curl.nex"

# ALSO at the top level of $PREFIX, not just bin/: neoos-kernel's
# PORT_DIRS install step (Makefile) only scans a port's build output
# one level deep for *.nex files -- every earlier CMake-based port
# (libssh2, OpenSSL) built a library only, with nothing living in a
# bin/ subdirectory, so this never came up before curl. bin/curl.nex
# stays too, matching the CMake-conventional bin/lib/include layout
# for anyone building this repo by hand.
cp "$ABS_PREFIX/bin/curl.elf" "$ABS_PREFIX/curl.nex"

if [ -f "$PREFIX/bin/curl.nex" ]; then
    echo ""
    echo "OK curl CLI linked successfully at $PREFIX/bin/curl.nex"
    ls -lh "$PREFIX/bin/curl.nex"
else
    echo "ERROR: build finished but curl.nex not found" >&2
    exit 1
fi
