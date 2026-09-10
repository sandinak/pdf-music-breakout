# pdf-music-breakout -- development and packaging tasks.
#
# Written for the GNU Make 3.81 that ships with macOS, so no .ONESHELL and no
# $(file ...). Run `make` on its own to see what's here.

PYTHON   ?= python3
PORT     ?= 8756
APP_DEST ?= /Applications

VENV    := .venv
BIN     := $(VENV)/bin
STAMP   := $(VENV)/.installed
MODULE  := pdf_music_breakout.py
FORMULA := Formula/pdf-music-breakout.rb
REPO    := https://github.com/sandinak/pdf-music-breakout
TAP     := sandinak/tap
VERSION  = $(shell sed -n 's/^__version__ = "\(.*\)"/\1/p' $(MODULE))
APP_NAME := PDF Music Breakout
APP_SRC  := $(wildcard macapp/Sources/*.swift)
# Make splits target names on spaces, so build under a plain name and only
# use the display name when installing.
APP_OUT  := build/PDFMusicBreakout.app
APP_ZIP   = build/PDFMusicBreakout-v$(VERSION).zip
# Built for every Mac that can run it, not just the one it was built on:
# a bare swiftc targets the host's macOS, which would refuse to launch
# anywhere older.
MACOS_MIN := 14.0
ARCHS     := arm64 x86_64
# Signing. Ad-hoc is all a local build needs; a release is signed with the
# Developer ID certificate so the app opens on someone else's Mac.
DEV_ID    = $(shell security find-identity -v -p codesigning 2>/dev/null | \
              sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
SIGN_ID  ?= -
# Notarisation credentials: a notarytool keychain profile, or the same
# APPLE_* variables the other projects here keep in a .env. Set the profile
# up once with:
#   xcrun notarytool store-credentials pdf-music-breakout \
#       --apple-id ... --team-id ... --password <app-specific>
NOTARY_PROFILE ?= pdf-music-breakout
NOTARY_AUTH = $(if $(APPLE_APP_SPECIFIC_PASSWORD),--apple-id "$(APPLE_ID)" \
    --team-id "$(APPLE_TEAM_ID)" --password "$(APPLE_APP_SPECIFIC_PASSWORD)",\
    --keychain-profile "$(NOTARY_PROFILE)")
GH       ?= gh
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

# ------------------------------------------------------------- windows / exe

exe: $(STAMP) ## Build a standalone executable (runs without Python installed)
	@$(BIN)/pip install -q pyinstaller
	@$(BIN)/pyinstaller --noconfirm --clean --onefile \
		--name pdf-music-breakout \
		--hidden-import breakout_web \
		--distpath dist --workpath build/pyinstaller --specpath build \
		$(MODULE)
	@echo "built: dist/pdf-music-breakout"

# ELECTRON_RUN_AS_NODE turns Electron into a plain Node interpreter, and some
# tooling sets it. Inherited into these targets it looks like a hang.
ELECTRON := env -u ELECTRON_RUN_AS_NODE npx

desktop: $(STAMP) ## Run the desktop shell against the working tree
	@cd desktop && npm install --silent --no-audit --no-fund
	@cd desktop && $(ELECTRON) electron . $(if $(PDF),"$(PDF)",)

desktop-shot: $(STAMP) ## Screenshot the desktop shell without showing a window
	@cd desktop && npm install --silent --no-audit --no-fund
	@cd desktop && $(ELECTRON) electron . $(if $(PDF),"$(PDF)",) \
		--screenshot=../build/desktop.png

desktop-dist: exe ## Package the desktop app for this platform
	@rm -rf desktop/sidecar && mkdir -p desktop/sidecar
	@cp dist/pdf-music-breakout desktop/sidecar/
	@cd desktop && npm install --silent --no-audit --no-fund
	@cd desktop && $(ELECTRON) electron-builder -p never
	@echo "built: desktop/dist"

sample: $(STAMP) ## Write a synthetic combined book to try things on
	@$(BIN)/python tools/sample_book.py $(if $(OUT),$(OUT),sample-ALL.pdf)

# ------------------------------------------------------------------ mac app

$(APP_OUT)/Contents/MacOS/PDFMusicBreakout: $(APP_SRC) macapp/Info.plist.in $(MODULE)
	@echo "==> building $(APP_NAME) $(VERSION) for $(ARCHS)"
	@mkdir -p $(APP_OUT)/Contents/MacOS $(APP_OUT)/Contents/Resources
	@sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@MACOS_MIN@/$(MACOS_MIN)/g' \
		macapp/Info.plist.in > $(APP_OUT)/Contents/Info.plist
	@for arch in $(ARCHS); do \
		swiftc -O -parse-as-library -target $$arch-apple-macos$(MACOS_MIN) \
			$(APP_SRC) -o build/pmb-$$arch || exit 1; \
	done
	@lipo -create $(addprefix build/pmb-,$(ARCHS)) -o $@
	@rm -f $(addprefix build/pmb-,$(ARCHS))
	@if [ "$(SIGN_ID)" = "-" ]; then \
		codesign --force --sign - $(APP_OUT) 2>/dev/null || echo "    (unsigned)"; \
	else \
		echo "==> signing as $(SIGN_ID)"; \
		codesign --force --options runtime --timestamp \
			--sign "$(SIGN_ID)" $(APP_OUT); \
	fi

app: $(APP_OUT)/Contents/MacOS/PDFMusicBreakout ## Build the native macOS app
	@echo "built: $(APP_OUT)"

app-dist: ## Build a Developer ID signed, zipped app for release
	@test -n "$(DEV_ID)" || { echo "no Developer ID Application certificate"; exit 1; }
	@rm -rf $(APP_OUT)
	@$(MAKE) --no-print-directory app SIGN_ID="$(DEV_ID)"
	@codesign --verify --strict $(APP_OUT)
	@rm -f $(APP_ZIP)
	@ditto -c -k --keepParent $(APP_OUT) $(APP_ZIP)
	@echo "built: $(APP_ZIP)"

app-notarize: app-dist ## Notarise the signed app so it opens without a warning
	@xcrun notarytool submit $(APP_ZIP) $(NOTARY_AUTH) --wait
	@xcrun stapler staple $(APP_OUT)
	@rm -f $(APP_ZIP)
	@ditto -c -k --keepParent $(APP_OUT) $(APP_ZIP)
	@echo "notarised: $(APP_ZIP)"

app-run: app ## Build and launch the app
	@open $(APP_OUT)

app-install: app ## Install the app into /Applications
	@rm -rf "$(APP_DEST)/$(APP_NAME).app"
	@cp -R $(APP_OUT) "$(APP_DEST)/$(APP_NAME).app"
	@echo "installed: $(APP_DEST)/$(APP_NAME).app"

# Compare the two implementations on a generated book. This is the check
# that caught PDFKit returning "Score 1" -- a part name and a page number
# sharing a baseline -- where PyMuPDF returns two separate lines.
app-check: $(STAMP) app-verify ## Check the app and the CLI split a sample the same way
	@mkdir -p build
	@$(BIN)/python tools/sample_book.py build/sample-ALL.pdf >/dev/null
	@$(BIN)/python $(MODULE) build/sample-ALL.pdf --list \
		| grep -E '^  .*\.pdf' | tr -s ' ' > build/split-python.txt
	@./build/verify build/sample-ALL.pdf \
		| grep -E '^  .*\.pdf' | tr -s ' ' > build/split-swift.txt
	@diff -u build/split-python.txt build/split-swift.txt \
		&& echo "the app and the CLI agree on `wc -l < build/split-python.txt | tr -d ' '` parts"

app-verify: ## Check the app's detection matches the Python implementation
	@mkdir -p build
	@swiftc -O macapp/Sources/Naming.swift macapp/Sources/Detection.swift \
		macapp/Sources/Splitter.swift macapp/Tools/main.swift -o build/verify
	@echo "built build/verify -- run it against a PDF to compare with 'make split'"

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
	@echo "==> building the app for the release"
	@if xcrun notarytool history $(NOTARY_AUTH) >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory app-notarize; \
	else \
		$(MAKE) --no-print-directory app-dist; \
		echo "    (no notarytool profile '$(NOTARY_PROFILE)' -- signed, not notarised)"; \
	fi
	@$(GH) release create "v$(VERSION)" $(APP_ZIP) \
		--title "v$(VERSION)" --generate-notes \
		|| $(GH) release upload "v$(VERSION)" $(APP_ZIP) --clobber
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

.PHONY: dev test test-v lint serve split install uninstall exe sample \
        desktop desktop-shot desktop-dist \
        app app-run app-install app-verify app-check app-dist app-notarize \
        brew-tap brew-install brew-reinstall brew-test brew-uninstall \
        formula-sha dist release clean distclean help
