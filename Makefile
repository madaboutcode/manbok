# upil-appa — common dev/daemon commands (run `make help`)
.PHONY: help build release test verify install uninstall install-launchagent uninstall-launchagent authorize dev stop-quiet start start-bg start-fg start-fg-always start-always-on stop status sessions dump dump-list

LAUNCH_AGENT_LABEL := com.upil.appa
LAUNCH_AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(LAUNCH_AGENT_LABEL).plist
GUI_DOMAIN := gui/$(shell id -u)

BIN := .build/debug/upil-appa
RELEASE_BIN := .build/release/upil-appa
MINUTES ?=

# User-local install (no sudo). Override: make install PREFIX=/opt/homebrew
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALLED_BIN := $(BINDIR)/upil-appa

help:
	@echo "upil-appa"
	@echo ""
	@echo "  make build            swift build (debug)"
	@echo "  make release          swift build -c release"
	@echo "  make test             swift test"
	@echo "  make verify           test + build"
	@echo "  make install          release → $(BINDIR)/upil-appa (restarts LaunchAgent if present)"
	@echo "  make install-launchagent  install + user LaunchAgent (login, Aqua session)"
	@echo "  make uninstall-launchagent remove LaunchAgent"
	@echo "  make authorize        request mic permission (Terminal; before background daemon)"
	@echo "  make uninstall        stop daemon, remove installed binary"
	@echo "  make dev              build, stop if running, start-fg (meter)"
	@echo ""
	@echo "  make start-bg         daemon (opportunistic, background)"
	@echo "  make start            alias for start-bg"
	@echo "  make start-fg         opportunistic + meter (dump needs another app recording)"
	@echo "  make start-fg-always  always-on + meter (dump works after REC fills)"
	@echo "  make start-always-on  always-on daemon (background)"
	@echo "  make stop             stop daemon"
	@echo "  make status           watching | listening | stopped"
	@echo "  make sessions         list sessions (same as: upil-appa dump --list)"
	@echo "  make dump             export newest session (default)"
	@echo "  make dump TARGET=all  export full ring"
	@echo "  make dump TARGET=-1   prior session (-2 = two back; omit = newest)"
	@echo "  make dump MINUTES=5   last N minutes of ring"
	@echo ""
	@echo "Debug:   $(BIN)"
	@echo "Release: $(RELEASE_BIN)"

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
	@if [ -f "$(LAUNCH_AGENT_PLIST)" ]; then \
	  echo "restarting LaunchAgent with updated binary…"; \
	  -@launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT_PLIST)" 2>/dev/null || true; \
	  @launchctl bootstrap $(GUI_DOMAIN) "$(LAUNCH_AGENT_PLIST)"; \
	  @sleep 1; \
	  @$(INSTALLED_BIN) status; \
	else \
	  echo "no LaunchAgent found — run 'make install-launchagent' for login persistence"; \
	fi
	@echo "add to PATH if needed:  export PATH=\"$(BINDIR):\$$PATH\""

uninstall:
	-@if [ -x "$(INSTALLED_BIN)" ]; then "$(INSTALLED_BIN)" stop; fi 2>/dev/null || true
	@rm -f "$(INSTALLED_BIN)"
	@echo "removed $(INSTALLED_BIN) (if it existed)"

install-launchagent: release
	@install -d "$(BINDIR)" "$(HOME)/Library/LaunchAgents"
	@echo "stopping manual daemon if running…"
	-@for b in "$(INSTALLED_BIN)" "$(RELEASE_BIN)" "$(BIN)"; do \
	  if [ -x "$$b" ]; then "$$b" stop; fi; \
	done 2>/dev/null || true
	@sleep 0.3
	install -m 755 "$(RELEASE_BIN)" "$(INSTALLED_BIN)"
	@"$(INSTALLED_BIN)" authorize
	-@launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT_PLIST)" 2>/dev/null || true
	@sed -e 's|REPLACE_WITH_UPIL_APPA_PATH|$(INSTALLED_BIN)|g' \
		-e 's|REPLACE_WITH_HOME|$(HOME)|g' \
		resources/com.upil.appa.plist > "$(LAUNCH_AGENT_PLIST)"
	@launchctl bootstrap $(GUI_DOMAIN) "$(LAUNCH_AGENT_PLIST)"
	@echo "LaunchAgent loaded: $(LAUNCH_AGENT_PLIST)"
	@echo "logs: /tmp/upil-appa.stderr.log  Console: subsystem ai.upil.appa"
	@sleep 1
	@$(INSTALLED_BIN) status

uninstall-launchagent:
	-@launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT_PLIST)" 2>/dev/null || true
	@rm -f "$(LAUNCH_AGENT_PLIST)"
	-@if [ -x "$(INSTALLED_BIN)" ]; then "$(INSTALLED_BIN)" stop; fi 2>/dev/null || true
	@echo "LaunchAgent removed (binary left at $(INSTALLED_BIN))"

test:
	swift test

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