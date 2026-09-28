# `make` builds QuPi, installs it in /Applications and opens it.
APP := /Applications/QuPi.app

install:
	./build.sh build
	rm -rf $(APP)
	ditto dist/QuPi.app $(APP)
	open $(APP)

.PHONY: install
