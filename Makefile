# NeoOS curl build
MUSL_DIR ?= ../neoos-musl/build-output
OPENSSL_DIR ?= ../neoos-openssl/build-output
LIBSSH2_DIR ?= ../neoos-libssh2/build-output
PREFIX ?= build-output
UPSTREAM_DIR ?= upstream

.PHONY: all clean verify help submodule-init

all: build-output/bin/curl.nex

submodule-init:
	@if [ ! -f "$(UPSTREAM_DIR)/CMakeLists.txt" ]; then \
		echo "Initializing upstream submodule..."; \
		git submodule update --init upstream; \
	fi

build-output/bin/curl.nex: submodule-init
	@[ -d "$(MUSL_DIR)/include" ] || { \
		echo "Error: musl not found at $(MUSL_DIR) -- build neoos-musl first"; \
		exit 1; \
	}
	@[ -f "$(OPENSSL_DIR)/lib/libcrypto.a" ] || { \
		echo "Error: OpenSSL not found at $(OPENSSL_DIR) -- build neoos-openssl first"; \
		exit 1; \
	}
	@[ -f "$(LIBSSH2_DIR)/lib/libssh2.a" ] || { \
		echo "Error: libssh2 not found at $(LIBSSH2_DIR) -- build neoos-libssh2 first"; \
		exit 1; \
	}
	@MUSL_DIR="$(MUSL_DIR)" OPENSSL_DIR="$(OPENSSL_DIR)" LIBSSH2_DIR="$(LIBSSH2_DIR)" \
		PREFIX="$(PREFIX)" ./build.sh

clean:
	rm -rf $(PREFIX) build-tmp

verify:
	@if [ -f "$(PREFIX)/lib/libcurl.a" ] && [ -f "$(PREFIX)/bin/curl.nex" ]; then \
		echo "OK libcurl.a and curl.nex built"; \
	else \
		echo "ERROR libcurl.a or curl.nex not found"; \
		exit 1; \
	fi

help:
	@echo "NeoOS curl build"
	@echo "Usage: make [MUSL_DIR=path] [OPENSSL_DIR=path] [LIBSSH2_DIR=path]"
