# Build and install the qr command-line tool.
#
#   make                      build a release binary
#   make test                 run the tests
#   sudo make install         install to /usr/local/bin
#   make install PREFIX=~/.local
#   make universal            build an arm64 + x86_64 binary
#   sudo make uninstall
#   make clean

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
DESTDIR ?=

SWIFT       ?= swift
BUILD_FLAGS ?= --disable-sandbox -c release
PRODUCT      = qr

BIN_PATH = $(shell $(SWIFT) build $(BUILD_FLAGS) --show-bin-path)

.PHONY: all build universal test install uninstall clean

all: build

build:
	$(SWIFT) build $(BUILD_FLAGS) --product $(PRODUCT)

universal:
	$(SWIFT) build $(BUILD_FLAGS) --product $(PRODUCT) --arch arm64 --arch x86_64
	@echo "Built $$($(SWIFT) build $(BUILD_FLAGS) --arch arm64 --arch x86_64 --show-bin-path)/$(PRODUCT)"

test:
	$(SWIFT) test

install: build
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 "$(BIN_PATH)/$(PRODUCT)" "$(DESTDIR)$(BINDIR)/$(PRODUCT)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(PRODUCT)"

clean:
	$(SWIFT) package clean
	rm -rf .build
