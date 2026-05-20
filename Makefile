BINDIR  := $(HOME)/.local/bin
UNITDIR := $(HOME)/.config/systemd/user

.PHONY: install-mpris uninstall-mpris

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
