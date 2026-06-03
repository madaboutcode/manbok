# upil-appa — common dev/daemon commands (run `make help`)
.PHONY: help build release test verify dev stop-quiet start start-bg start-fg start-fg-always start-always-on stop status dump

BIN := .build/debug/upil-appa
RELEASE_BIN := .build/release/upil-appa
MINUTES ?=

help:
	@echo "upil-appa"
	@echo ""
	@echo "  make build            swift build (debug)"
	@echo "  make release          swift build -c release"
	@echo "  make test             swift test"
	@echo "  make verify           test + build"
	@echo "  make dev              build, stop if running, start-fg (meter)"
	@echo ""
	@echo "  make start-bg         daemon (opportunistic, background)"
	@echo "  make start            alias for start-bg"
	@echo "  make start-fg         opportunistic + meter (dump needs another app recording)"
	@echo "  make start-fg-always  always-on + meter (dump works after REC fills)"
	@echo "  make start-always-on  always-on daemon (background)"
	@echo "  make stop             stop daemon"
	@echo "  make status           watching | listening | stopped"
	@echo "  make dump             export WAV (optional: MINUTES=5)"
	@echo ""
	@echo "Debug:   $(BIN)"
	@echo "Release: $(RELEASE_BIN)"

build:
	swift build

release:
	swift build -c release

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

dump: $(BIN)
	@status=$$($(BIN) status 2>/dev/null | awk '{print $$1}'); \
	if [ "$$status" = "stopped" ]; then \
	  echo "dump failed: daemon is stopped. Run make start-fg or make start." >&2; \
	  exit 1; \
	fi
ifdef MINUTES
	@$(BIN) dump --minutes $(MINUTES)
else
	@$(BIN) dump
endif