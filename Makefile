# shellcheck disable=SC2046
# (Make's $(VAR) expansion is not shell command substitution; shellcheck
# misparses it when linting Makefiles as shell.)
# PingStatus — single-file macOS menu bar app
APP_NAME   := PingStatus
SRC        := PingStatusApp.swift
BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
BINARY     := $(MACOS_DIR)/$(APP_NAME)
STAMP      := $(BUILD_DIR)/.built

.PHONY: app run smoke clean

## Build build/PingStatus.app (ad-hoc signed, LSUIElement = true).
app: $(STAMP)

$(STAMP): $(BINARY) $(CONTENTS)/Info.plist
	codesign --force --sign - "$(APP_BUNDLE)"
	@touch "$@"
	@echo "Built $(APP_BUNDLE)"

$(BINARY): $(SRC)
	@mkdir -p "$(MACOS_DIR)"
	# -parse-as-library: a lone .swift file defaults to script mode (top-level
	# code), which forbids @main. Library mode lets @main supply the entry point.
	swiftc -O -whole-module-optimization -parse-as-library "$(SRC)" -o "$@"

$(CONTENTS)/Info.plist: Info.plist
	@mkdir -p "$(CONTENTS)"
	cp "$<" "$@"

## Run the bundled app (launchd-managed; LSUIElement hides the Dock icon).
run: app
	open "$(APP_BUNDLE)"

## Run the raw binary in the background for ~6 s to verify it stays alive.
smoke: app
	"$(BINARY)" & \
	sleep 6; \
	if kill -0 "$$!" 2>/dev/null; then \
		echo "SMOKE OK — app alive after 6 s (killing now)"; kill "$$!"; \
	else \
		echo "SMOKE FAIL — app exited early"; exit 1; \
	fi

clean:
	rm -rf "$(BUILD_DIR)"
