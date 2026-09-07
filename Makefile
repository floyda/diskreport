.PHONY: build test lint release bundle install uninstall scan-now status clean

# Every path below is derived from HOME; with it unset they would collapse to /Library/... and the
# install target would try to write outside the user's home.
ifeq ($(strip $(HOME)),)
$(error HOME is not set)
endif

DATA_DIR := $(HOME)/Library/Application Support/DiskReport
LOG_DIR  := $(HOME)/Library/Logs/DiskReport
AGENT    := com.andyfloyd.diskreport.scan
PLIST    := $(HOME)/Library/LaunchAgents/$(AGENT).plist
APP_DST  := $(HOME)/Applications/DiskReport.app
UID_     := $(shell id -u)

build:
	swift build

test: lint
	swift test

lint:
	Scripts/lint-readonly.sh

release: lint
	swift build -c release

bundle: release
	chmod +x Scripts/bundle-app.sh
	Scripts/bundle-app.sh

install: bundle
	mkdir -p "$(DATA_DIR)/bin" "$(LOG_DIR)" "$(HOME)/Applications" "$(HOME)/Library/LaunchAgents"
	cp "$$(swift build -c release --show-bin-path)/diskreport-scan" "$(DATA_DIR)/bin/diskreport-scan"
	cp Resources/scan.sb Resources/run-scan.sh "$(DATA_DIR)/bin/"
	chmod +x "$(DATA_DIR)/bin/run-scan.sh" "$(DATA_DIR)/bin/diskreport-scan"
	rm -rf "$(APP_DST)"
	cp -R build/DiskReport.app "$(APP_DST)"
	@if [ ! -f "$(DATA_DIR)/config.json" ]; then \
	  printf '{\n  "roots": ["~/Workspace"],\n  "retention": { "dailyDays": 45, "weeklyWeeks": 52 }\n}\n' > "$(DATA_DIR)/config.json"; \
	  echo "wrote default $(DATA_DIR)/config.json"; \
	fi
	sed "s|__HOME__|$(HOME)|g" Resources/$(AGENT).plist > "$(PLIST)"
	plutil -lint "$(PLIST)"
	-launchctl bootout gui/$(UID_) "$(PLIST)" 2>/dev/null
	launchctl bootstrap gui/$(UID_) "$(PLIST)"
	@echo "Installed. Scheduled daily at 07:00. Run 'make scan-now' for a first scan."

scan-now:
	launchctl kickstart -k gui/$(UID_)/$(AGENT)

status:
	launchctl print gui/$(UID_)/$(AGENT) | grep -E "state|last exit|run interval|program" || true
	@ls -la "$(LOG_DIR)" 2>/dev/null || true

uninstall:
	-launchctl bootout gui/$(UID_) "$(PLIST)" 2>/dev/null
	rm -f "$(PLIST)"
	rm -rf "$(APP_DST)" "$(DATA_DIR)/bin"
	@if [ "$(PURGE)" = "1" ]; then rm -rf "$(DATA_DIR)" "$(LOG_DIR)"; echo "purged database, config and logs"; \
	else echo "kept $(DATA_DIR) (config + database). Use PURGE=1 to remove."; fi

clean:
	rm -rf .build build
