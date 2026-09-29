# `make` builds CineTray, installs it in /Applications and opens it.
APP := /Applications/CineTray.app

install:
	./build.sh build
	rm -rf $(APP)
	cp -R dist/CineTray.app $(APP)
	open $(APP)

# Keeps settings, Keychain items and downloads.
uninstall:
	pkill -x CineTray || true
	rm -rf $(APP)

# Also deletes settings, watch progress, accounts and cached artwork.
# Downloaded and library media stay in the folders you chose.
wipe: uninstall
	defaults delete CineTray 2>/dev/null || true
	while security delete-generic-password -s CineTray >/dev/null 2>&1; do :; done
	rm -rf ~/Library/Caches/CineTray ~/Library/HTTPStorages/CineTray "$${TMPDIR:-/tmp}/CineTray Playback"

clean:
	rm -rf .build dist

.PHONY: install uninstall wipe clean
