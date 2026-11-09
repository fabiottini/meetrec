# MeetRec: run `make` to list the targets

APP    := dist/MeetRec.app
ZIP    := dist/MeetRec.zip
DEST   := $(HOME)/Applications/MeetRec.app
CLI    := $(HOME)/.local/bin/meet
PYTHON ?= $(shell command -v /opt/homebrew/bin/python3 || command -v python3)

.DEFAULT_GOAL := help
VERSION := $(shell tr -d ' \n' < VERSION)

.PHONY: help build install install-zip open cli check docs release uninstall clean version bump-patch bump-minor bump-major tag sync-github release-github github-hardening

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
	@grep -q "^## $(VERSION) " CHANGELOG.md || echo "remember: CHANGELOG.md section for $(VERSION) (and make bump-* if needed)"
	@echo "ready: commit dist/MeetRec.zip and docs/ with the code, push a branch, open the merge request; after the merge: make tag"

uninstall: ## remove the app and the meet command (config, tokens and recordings are kept)
	-@pkill -x MeetRec
	@if [ -d "$(DEST)" ]; then rm -r "$(DEST)" && echo "removed $(DEST)"; fi
	@if grep -q "installed by MeetRec" $(CLI) 2>/dev/null; then rm $(CLI) && echo "removed $(CLI)"; fi

clean: ## remove the build folder dist/MeetRec.app (the zip stays)
	@if [ -d "$(APP)" ]; then rm -r "$(APP)"; fi

version: ## print the version (VERSION file, semver)
	@echo $(VERSION)

bump-patch: ## 1.2.3 -> 1.2.4 (fixes)
	@$(PYTHON) -c "v=open('VERSION').read().split('.'); v=[int(x) for x in v]; v[2]+=1; open('VERSION','w').write('.'.join(map(str,v))+'\n')" && cat VERSION

bump-minor: ## 1.2.3 -> 1.3.0 (new features)
	@$(PYTHON) -c "v=[int(x) for x in open('VERSION').read().split('.')]; v=[v[0],v[1]+1,0]; open('VERSION','w').write('.'.join(map(str,v))+'\n')" && cat VERSION

bump-major: ## 1.2.3 -> 2.0.0 (breaking changes)
	@$(PYTHON) -c "v=[int(x) for x in open('VERSION').read().split('.')]; v=[v[0]+1,0,0]; open('VERSION','w').write('.'.join(map(str,v))+'\n')" && cat VERSION

tag: ## after the merge, on main: create and push the tag v$(VERSION)
	@git fetch -q origin
	@test "$$(git rev-parse --abbrev-ref HEAD)" = main || { echo "switch to main first"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "uncommitted changes"; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "main is not up to date with origin (git pull)"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "tag v$(VERSION) already exists: bump the version"; exit 1; }
	@grep -q "^## $(VERSION) " CHANGELOG.md || { echo "CHANGELOG.md has no section for $(VERSION)"; exit 1; }
	@unzip -p $(ZIP) MeetRec.app/Contents/Resources/VERSION | grep -qx "$(VERSION)" || { echo "dist/MeetRec.zip is not version $(VERSION): make build and commit"; exit 1; }
	git tag -a "v$(VERSION)" -m "MeetRec $(VERSION)"
	git push origin "v$(VERSION)"
	@$(MAKE) --no-print-directory sync-github
	@$(MAKE) --no-print-directory release-github

GITHUB := git@github.com:fabiottini/meetrec.git

sync-github: ## mirror main and the tags to GitHub (remote "github"); run after every merge
	@git fetch -q origin
	@test "$$(git rev-parse --abbrev-ref HEAD)" = main || { echo "switch to main first"; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "main is not up to date with origin (git pull)"; exit 1; }
	@git remote get-url github >/dev/null 2>&1 || git remote add github $(GITHUB)
	git push github main
	git push github --tags

GH_PERSONAL := GH_CONFIG_DIR=$(HOME)/.config/gh-fabiottini gh

release-github: ## GitHub release v$(VERSION) with the zip and the changelog notes (personal gh account)
	@tmp=$$(mktemp -d) && cp $(ZIP) "$$tmp/MeetRec-$(VERSION).zip" && \
	  $(PYTHON) scripts/changelog_section.py $(VERSION) > "$$tmp/notes.md" && \
	  $(GH_PERSONAL) release create "v$(VERSION)" -R fabiottini/meetrec --verify-tag --latest \
	    --title "MeetRec $(VERSION)" --notes-file "$$tmp/notes.md" "$$tmp/MeetRec-$(VERSION).zip" && \
	  rm -r "$$tmp"

github-hardening: ## once the GitHub repo is public: protect main and tags, approve outside workflows, private security reports
	@$(GH_PERSONAL) api -X POST repos/fabiottini/meetrec/rulesets --input scripts/ruleset-main.json --jq '"ruleset: " + .name' || true
	@$(GH_PERSONAL) api -X POST repos/fabiottini/meetrec/rulesets --input scripts/ruleset-tags.json --jq '"ruleset: " + .name' || true
	@$(GH_PERSONAL) api -X PUT repos/fabiottini/meetrec/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors && echo "outside contributors: workflows need approval"
	@$(GH_PERSONAL) api -X PUT repos/fabiottini/meetrec/private-vulnerability-reporting && echo "private vulnerability reporting: on"
