BINDIR  := $(HOME)/.local/bin
UNITDIR := $(HOME)/.config/systemd/user
SPEC    := rpm/denon-avr-controller.spec

.PHONY: install-mpris uninstall-mpris srpm tag

install-mpris: denon_mpris.py denon-mpris.service
	install -Dm755 denon_mpris.py $(BINDIR)/denon-mpris
	install -Dm644 denon-mpris.service $(UNITDIR)/denon-mpris.service
	systemctl --user daemon-reload
	systemctl --user enable --now denon-mpris.service
	@echo "denon-mpris installed and running."
	@echo "Check status: systemctl --user status denon-mpris"

uninstall-mpris:
	-systemctl --user disable --now denon-mpris.service 2>/dev/null
	rm -f $(BINDIR)/denon-mpris $(UNITDIR)/denon-mpris.service
	systemctl --user daemon-reload
	@echo "denon-mpris removed."

# Build a source RPM locally for inspection before pushing to Copr.
# Requires: sudo dnf install rpmdevtools rpm-build
srpm:
	@command -v spectool >/dev/null 2>&1 || \
	  { echo "Missing: sudo dnf install rpmdevtools"; exit 1; }
	@command -v rpmbuild >/dev/null 2>&1 || \
	  { echo "Missing: sudo dnf install rpm-build"; exit 1; }
	mkdir -p rpmbuild/SOURCES rpmbuild/SRPMS
	spectool -g -C rpmbuild/SOURCES $(SPEC)
	rpmbuild -bs \
	  --define "_sourcedir $(CURDIR)/rpmbuild/SOURCES" \
	  --define "_srcrpmdir $(CURDIR)/rpmbuild/SRPMS" \
	  $(SPEC)
	@echo "SRPM → rpmbuild/SRPMS/"

# Create a signed git tag from VERSION and remind you to push it.
# Copr can be pointed at a tag to trigger a build.
tag:
	@version=$$(cat VERSION); \
	git tag -s "v$$version" -m "Release v$$version"; \
	echo "Tagged v$$version"; \
	echo "Push with: git push origin v$$version"
