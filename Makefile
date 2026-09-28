# `make` builds QuPi, installs it in /Applications and opens it.
APP := /Applications/QuPi.app

install:
	./build.sh build
	rm -rf $(APP)
	cp -R dist/QuPi.app $(APP)
	open $(APP)

# Keeps settings, Keychain items and downloads.
uninstall:
	pkill -x QuPi || true
	rm -rf $(APP)

# Also deletes settings, watch progress, accounts and cached artwork.
# Downloaded and library media stay in the folders you chose.
wipe: uninstall
	defaults delete QuPi 2>/dev/null || true
	while security delete-generic-password -s QuPi >/dev/null 2>&1; do :; done
	rm -rf ~/Library/Caches/QuPi ~/Library/HTTPStorages/QuPi

clean:
	rm -rf .build dist

.PHONY: install uninstall wipe clean
