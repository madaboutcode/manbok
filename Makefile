# upil-appa — common dev/daemon commands (run `make help`)
.PHONY: help build release test verify install uninstall dev stop-quiet start start-bg start-fg start-fg-always start-always-on stop status sessions dump

BIN := .build/debug/upil-appa
RELEASE_BIN := .build/release/upil-appa
MINUTES ?=

# User-local install (no sudo). Override: make install PREFIX=/opt/homebrew
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

help:
	@echo "upil-appa"
	@echo ""
	@echo "  make build            swift build (debug)"
	@echo "  make release          swift build -c release"
	@echo "  make test             swift test"
	@echo "  make verify           test + build"
	@echo "  make install          release build → $(BINDIR)/upil-appa"
	@echo "  make uninstall        remove installed binary"
	@echo "  make dev              build, stop if running, start-fg (meter)"
	@echo ""
	@echo "  make start-bg         daemon (opportunistic, background)"
	@echo "  make start            alias for start-bg"
	@echo "  make start-fg         opportunistic + meter (dump needs another app recording)"
	@echo "  make start-fg-always  always-on + meter (dump works after REC fills)"
	@echo "  make start-always-on  always-on daemon (background)"
	@echo "  make stop             stop daemon"
	@echo "  make status           watching | listening | stopped"
	@echo "  make sessions         list ring sessions (5s gap markers)"
	@echo "  make dump             export WAV (optional: MINUTES=5)"
	@echo "  make dump SESSION=2   export one session by id"
	@echo ""
	@echo "Debug:   $(BIN)"
	@echo "Release: $(RELEASE_BIN)"

build:
	swift build

release: $(RELEASE_BIN)

$(RELEASE_BIN):
	swift build -c release

install: $(RELEASE_BIN)
	@install -d "$(BINDIR)"
	install -m 755 "$(RELEASE_BIN)" "$(BINDIR)/upil-appa"
	@echo "installed $(BINDIR)/upil-appa"
	@echo "add to PATH if needed:  export PATH=\"$(BINDIR):\$$PATH\""

uninstall:
	@rm -f "$(BINDIR)/upil-appa"
	@echo "removed $(BINDIR)/upil-appa (if it existed)"

test:
	swift test

verify: test build

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
ifdef SESSION
	@$(BIN) dump --session $(SESSION)
else ifdef MINUTES
	@$(BIN) dump --minutes $(MINUTES)
else
	@$(BIN) dump
endif