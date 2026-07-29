.PHONY: build app run test install clean icon reinstall signing-cert

# Fast compile check of every target.
build:
	swift build

# Assemble dist/PasteDeck.app
app:
	./scripts/build_app.sh

# Build and launch (replacing any running copy).
run: app
	-pkill -x PasteDeck || true
	open dist/PasteDeck.app

test:
	swift run CoreTests

icon:
	swift scripts/make_icon.swift Resources

# Copy into /Applications so login items and Accessibility have a stable path.
install: app
	-pkill -x PasteDeck || true
	rm -rf /Applications/PasteDeck.app
	cp -R dist/PasteDeck.app /Applications/PasteDeck.app
	@./scripts/refresh_tcc.sh
	open /Applications/PasteDeck.app
	@echo "Installed to /Applications/PasteDeck.app"

reinstall: install

# One-time: a self-signed identity so the Accessibility grant survives rebuilds.
signing-cert:
	./scripts/signing_cert.sh

clean:
	swift package clean
	rm -rf dist .build
