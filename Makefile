# pdf-music-breakout -- development and packaging tasks.
#
# Written for the GNU Make 3.81 that ships with macOS, so no .ONESHELL and no
# $(file ...). Run `make` on its own to see what's here.

PYTHON   ?= python3
PORT     ?= 8756
APP_DEST ?= $(HOME)/Applications

VENV    := .venv
BIN     := $(VENV)/bin
STAMP   := $(VENV)/.installed
MODULE  := pdf_music_breakout.py
FORMULA := Formula/pdf-music-breakout.rb
REPO    := https://github.com/sandinak/pdf-music-breakout
TAP     := sandinak/tap
VERSION  = $(shell sed -n 's/^__version__ = "\(.*\)"/\1/p' $(MODULE))
# Whether VERSION was supplied on the command line, so `release` can insist.
VERSION_GIVEN := $(filter command line,$(origin VERSION))
TARBALL  = $(REPO)/archive/refs/tags/v$(VERSION).tar.gz

.DEFAULT_GOAL := help

# ---------------------------------------------------------------- development

$(STAMP): pyproject.toml $(MODULE)
	@test -d $(VENV) || $(PYTHON) -m venv $(VENV)
	@$(BIN)/pip install -q --upgrade pip
	@$(BIN)/pip install -q -e ".[dev]"
	@touch $@

dev: $(STAMP) ## Create the virtualenv and install in editable mode
	@echo "ready: $(BIN)/pdf-music-breakout ($(VERSION))"

test: $(STAMP) ## Run the test suite
	@$(BIN)/python -m pytest -q

test-v: $(STAMP) ## Run the test suite, verbosely
	@$(BIN)/python -m pytest -v

lint: $(STAMP) ## Check style, if ruff is installed
	@if command -v ruff >/dev/null 2>&1; then \
		ruff check $(MODULE) breakout_web.py tests; \
	else \
		echo "ruff not installed; checking syntax only"; \
		$(BIN)/python -m compileall -q $(MODULE) breakout_web.py tests; \
	fi

serve: $(STAMP) ## Run the review UI from the working tree
	@$(BIN)/python $(MODULE) --serve --port $(PORT)

# -------------------------------------------------------------------- running

# Split a PDF without installing: make split PDF=path/to/file.pdf OUT=dir
split: $(STAMP) ## Split a PDF from the working tree (PDF=... [OUT=...])
	@test -n "$(PDF)" || { echo "usage: make split PDF=file.pdf [OUT=dir]"; exit 1; }
	@$(BIN)/python $(MODULE) "$(PDF)" $(if $(OUT),-o "$(OUT)",--list)

# ------------------------------------------------------------------ installing

install: ## Install onto PATH with uv (or pipx)
	@if command -v uv >/dev/null 2>&1; then \
		uv tool install --force . ; \
	elif command -v pipx >/dev/null 2>&1; then \
		pipx install --force . ; \
	else \
		echo "need uv or pipx; try: brew install uv"; exit 1; \
	fi

uninstall: ## Remove the uv/pipx installation
	@if command -v uv >/dev/null 2>&1; then uv tool uninstall pdf-music-breakout || true; fi
	@if command -v pipx >/dev/null 2>&1; then pipx uninstall pdf-music-breakout || true; fi

app: ## Build the macOS launcher app (APP_DEST=~/Applications)
	@./packaging/make-app.sh "$(APP_DEST)"

# ------------------------------------------------------------------- homebrew

brew-tap: ## Add this repository as a Homebrew tap
	@brew tap $(TAP) $(REPO) 2>/dev/null || echo "already tapped"

brew-install: brew-tap ## Install through Homebrew
	@brew install --formula $(TAP)/pdf-music-breakout

brew-reinstall: ## Reinstall through Homebrew, picking up formula changes
	@brew uninstall pdf-music-breakout 2>/dev/null || true
	@brew install --formula $(TAP)/pdf-music-breakout

brew-test: ## Run the formula's own test block
	@brew test $(TAP)/pdf-music-breakout

brew-uninstall: ## Remove the Homebrew installation
	@brew uninstall pdf-music-breakout 2>/dev/null || true

formula-sha: ## Print the sha256 of the current version's release tarball
	@echo "version  $(VERSION)"
	@echo "url      $(TARBALL)"
	@printf "sha256   "
	@curl -fsSL "$(TARBALL)" | shasum -a 256 | cut -d' ' -f1

# ------------------------------------------------------------------ releasing

dist: $(STAMP) ## Build a wheel and sdist into dist/
	@$(BIN)/pip install -q build
	@$(BIN)/python -m build

# Bump the version, tag it, push, then point the formula at the new tarball.
release: ## Cut a release (make release VERSION=0.1.2)
	@test -n "$(VERSION_GIVEN)" || { echo "usage: make release VERSION=0.1.2"; exit 1; }
	@test -z "`git status --porcelain`" || { echo "working tree is dirty"; exit 1; }
	@echo "==> releasing v$(VERSION)"
	@sed -i '' 's/^__version__ = ".*"/__version__ = "$(VERSION)"/' $(MODULE)
	@$(MAKE) --no-print-directory test
	@git add -A && git commit -q -m "Release v$(VERSION)" || true
	@git tag -a "v$(VERSION)" -m "v$(VERSION)"
	@git push -q origin main --tags
	@echo "==> waiting for the tag tarball, then updating the formula"
	@sha=""; for i in 1 2 3 4 5 6 7 8 9 10; do \
		sha=`curl -fsSL "$(TARBALL)" 2>/dev/null | shasum -a 256 | cut -d' ' -f1`; \
		test -n "$$sha" && break; sleep 3; \
	done; \
	test -n "$$sha" || { echo "could not fetch $(TARBALL)"; exit 1; }; \
	sed -i '' -e 's|/archive/refs/tags/v.*\.tar\.gz|/archive/refs/tags/v$(VERSION).tar.gz|' \
	          -e "s|^  sha256 \".*\"|  sha256 \"$$sha\"|" $(FORMULA); \
	echo "    sha256 $$sha"
	@git add $(FORMULA) && git commit -q -m "Point the formula at v$(VERSION)"
	@git push -q origin main
	@echo "==> released v$(VERSION)"

# --------------------------------------------------------------------- tidying

clean: ## Remove build artefacts and caches
	@rm -rf build dist *.egg-info .pytest_cache
	@find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

distclean: clean ## Also remove the virtualenv
	@rm -rf $(VENV)

# ------------------------------------------------------------------------ help

help: ## Show this help
	@echo "pdf-music-breakout $(VERSION)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  variables: PDF= OUT= PORT=$(PORT) APP_DEST=$(APP_DEST)"

.PHONY: dev test test-v lint serve split install uninstall app \
        brew-tap brew-install brew-reinstall brew-test brew-uninstall \
        formula-sha dist release clean distclean help
