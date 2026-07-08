# manbok — common dev/daemon commands (run `make help`)
.PHONY: help build release test test-e2e verify install uninstall authorize dev stop-quiet start start-bg start-fg start-fg-always start-always-on stop status sessions dump dump-list app install-app run-app

BIN := .build/debug/manbok
RELEASE_BIN := .build/release/manbok
MINUTES ?=

# User-local install (no sudo). Override: make install PREFIX=/opt/homebrew
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALLED_BIN := $(BINDIR)/manbok

help:
	@echo "manbok — the app is the product; most people only need the first three."
	@echo ""
	@echo "  make install-app      build + install → ~/Applications/Manbok.app"
	@echo "  make run-app          build + open Manbok.app (no install)"
	@echo "  make verify           test + build (run before a PR)"
	@echo ""
	@echo "  CLI client (optional):"
	@echo "  make install          release CLI → $(BINDIR)/manbok"
	@echo "  make uninstall        remove installed CLI binary"
	@echo ""
	@echo "  Building blocks:"
	@echo "  make build / release / test / app"
	@echo "  make test-e2e          real speaker→mic loopback proof (interactive, needs audio)"
	@echo ""
	@echo "  Debug (daemon in a terminal, no app):"
	@echo "  make dev              build, restart, foreground meter"
	@echo "  make start-fg         opportunistic + meter (start-fg-always = always-on)"
	@echo "  make start / start-always-on / stop / status    background daemon control"
	@echo "  make sessions         list sessions"
	@echo "  make dump             export newest session (TARGET=all | TARGET=-1 | MINUTES=5)"
	@echo "  make authorize        mic permission for the CLI binary (needed before daemon use)"
	@echo ""
	@echo "Binaries — debug: $(BIN)   release: $(RELEASE_BIN)"

build:
	swift build

# Always invoke SPM — file mtime alone does not track source changes.
release:
	swift build -c release

install: release
	@install -d "$(BINDIR)"
	@echo "stopping manual daemon if running…"
	-@for b in "$(INSTALLED_BIN)" "$(RELEASE_BIN)" "$(BIN)"; do \
	  if [ -x "$$b" ]; then "$$b" stop; fi; \
	done 2>/dev/null || true
	@sleep 0.3
	install -m 755 "$(RELEASE_BIN)" "$(INSTALLED_BIN)"
	@echo "installed $(INSTALLED_BIN)"
	@"$(INSTALLED_BIN)" authorize
	@echo "add to PATH if needed:  export PATH=\"$(BINDIR):\$$PATH\""
	@echo "login persistence: use the app (popover → Settings → Start at login)"

uninstall:
	-@if [ -x "$(INSTALLED_BIN)" ]; then "$(INSTALLED_BIN)" stop; fi 2>/dev/null || true
	@rm -f "$(INSTALLED_BIN)"
	@echo "removed $(INSTALLED_BIN) (if it existed)"

test:
	swift test

test-e2e:
	MANBOK_E2E=1 swift test --filter CaptureE2E

verify: test build

authorize: $(BIN)
	$(BIN) authorize

dev: build stop-quiet start-fg

stop-quiet: $(BIN)
	-@$(BIN) stop 2>/dev/null

$(BIN):
	swift build

start-bg: $(BIN)
	$(BIN) start

start: start-bg

start-fg: $(BIN)
	$(BIN) start --foreground

start-fg-always: $(BIN)
	$(BIN) start --foreground --always-on

start-always-on: $(BIN)
	$(BIN) start --always-on

stop: $(BIN)
	$(BIN) stop

status: $(BIN)
	$(BIN) status

sessions: $(BIN)
	$(BIN) sessions

dump: $(BIN)
	@status=$$($(BIN) status 2>/dev/null | awk '{print $$1}'); \
	if [ "$$status" = "stopped" ]; then \
	  echo "dump failed: daemon is stopped. Run make start-fg or make start." >&2; \
	  exit 1; \
	fi
ifdef TARGET
	@$(BIN) dump $(TARGET)
else ifdef MINUTES
	@$(BIN) dump --minutes $(MINUTES)
else
	@$(BIN) dump
endif

dump-list: $(BIN)
	@$(BIN) dump --list

# --- App targets ---

APP_BUNDLE := .build/Manbok.app

app: release-app
	@scripts/assemble-app.sh .build release

release-app:
	swift build -c release --product ManbokApp

install-app: app
	@install -d "$(HOME)/Applications"
	@rm -rf "$(HOME)/Applications/Manbok.app"
	@cp -R "$(APP_BUNDLE)" "$(HOME)/Applications/Manbok.app"
	@echo "installed ~/Applications/Manbok.app"

run-app: app
	@open "$(APP_BUNDLE)"