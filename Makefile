# MeetRec: run `make` to list the targets

APP    := dist/MeetRec.app
ZIP    := dist/MeetRec.zip
DEST   := $(HOME)/Applications/MeetRec.app
CLI    := $(HOME)/.local/bin/meet
PYTHON ?= $(shell command -v /opt/homebrew/bin/python3 || command -v python3)

.DEFAULT_GOAL := help
.PHONY: help build install install-zip open cli check docs release uninstall clean

help: ## list the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

build: ## build dist/MeetRec.app (universal) and dist/MeetRec.zip
	./build.sh

install: build ## build, copy to ~/Applications and open
	@if pgrep -f meetrec-capture >/dev/null; then echo "a recording is running: stop it first"; exit 1; fi
	-@pkill -x MeetRec
	@mkdir -p $(HOME)/Applications
	@if [ -d "$(DEST)" ]; then rm -r "$(DEST)"; fi
	ditto $(APP) "$(DEST)"
	open "$(DEST)"

install-zip: ## install the committed dist/MeetRec.zip, without building
	@if pgrep -f meetrec-capture >/dev/null; then echo "a recording is running: stop it first"; exit 1; fi
	-@pkill -x MeetRec
	@tmp=$$(mktemp -d) && ditto -x -k $(ZIP) "$$tmp" && mkdir -p $(HOME)/Applications && \
	  if [ -d "$(DEST)" ]; then rm -r "$(DEST)"; fi && ditto "$$tmp/MeetRec.app" "$(DEST)" && rm -r "$$tmp"
	open "$(DEST)"

open: ## open the installed app
	open "$(DEST)"

cli: ## install the meet command (~/.local/bin/meet), using the installed app
	@mkdir -p $(dir $(CLI))
	@printf '#!/bin/sh\n# installed by MeetRec.app\nMEETREC_CAPTURE="%s" exec "%s" "%s" "$$@"\n' \
	  "$(DEST)/Contents/MacOS/meetrec-capture" "$(PYTHON)" "$(DEST)/Contents/Resources/meet.py" > $(CLI)
	@chmod 755 $(CLI) && echo "installed $(CLI)"

check: ## syntax check of meet.py, locale keys, Info.plist
	$(PYTHON) -m py_compile meet.py && rm -r __pycache__
	plutil -lint menubar/Info.plist
	$(PYTHON) scripts/check_locales.py

docs: build ## render the README images (docs/*.png) from the app, in English
	MEETREC_CONFIG_FILE=docs/demo-config.json $(APP)/Contents/MacOS/MeetRec --render-docs "$(CURDIR)/docs"
	ffmpeg -loglevel error -y -i docs/settings.png -vf "crop=iw:ih-24:0:0" docs/settings.tmp.png && mv docs/settings.tmp.png docs/settings.png

release: check docs ## check + build + docs; then commit (zip and docs included), push a branch, open the MR
	@echo "ready: commit dist/MeetRec.zip and docs/ with the code, push a branch, open the merge request"

uninstall: ## remove the app and the meet command (config, tokens and recordings are kept)
	-@pkill -x MeetRec
	@if [ -d "$(DEST)" ]; then rm -r "$(DEST)" && echo "removed $(DEST)"; fi
	@if grep -q "installed by MeetRec" $(CLI) 2>/dev/null; then rm $(CLI) && echo "removed $(CLI)"; fi

clean: ## remove the build folder dist/MeetRec.app (the zip stays)
	@if [ -d "$(APP)" ]; then rm -r "$(APP)"; fi
