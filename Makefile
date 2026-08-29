APP := KVMConsole
DEST := /Applications/$(APP).app
# Local installs skip notarization; set NOTARIZE=1 to notarize like a release.
export NOTARIZE ?= 0

.PHONY: install
install:
	Scripts/build-developer-id.sh
	rm -rf "$(DEST)"
	ditto build/developer-id/export/$(APP).app "$(DEST)"
	@echo "Installed $(DEST)"
