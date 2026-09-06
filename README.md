# NeoOS curl

curl 8.22.0 (CLI + `libcurl.a`), built for NeoOS with `neoos-openssl`
as its TLS backend and `neoos-libssh2` as its SFTP/SCP backend.
HTTP, HTTPS, and SFTP only -- every other curl-supported protocol is
disabled at build time.

## Quick Start

Build `neoos-musl`, `neoos-openssl`, and `neoos-libssh2` first, then:

```sh
make MUSL_DIR=../neoos-musl/build-output \
     OPENSSL_DIR=../neoos-openssl/build-output \
     LIBSSH2_DIR=../neoos-libssh2/build-output
# Produces: build-output/lib/libcurl.a, build-output/bin/curl.nex,
#           build-output/cacert.pem
```

## Documentation

- **Design spec:** [neoos-kernel's
  docs/superpowers/specs/2026-09-06-curl-port-design.md](https://github.com/NeoOSOrganization/neoos-kernel/blob/main/docs/superpowers/specs/2026-09-06-curl-port-design.md)

## In This Organization

- **[neoos-kernel](https://github.com/NeoOSOrganization/neoos-kernel)** — Kernel source
- **[neoos-musl](https://github.com/NeoOSOrganization/neoos-musl)** — musl libc (build dependency)
- **[neoos-openssl](https://github.com/NeoOSOrganization/neoos-openssl)** — OpenSSL, this repo's TLS backend
- **[neoos-libssh2](https://github.com/NeoOSOrganization/neoos-libssh2)** — libssh2, this repo's SFTP/SCP backend
- **[neoos-docs](https://github.com/NeoOSOrganization/neoos-docs)** — Guides and architecture
