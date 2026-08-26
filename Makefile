# shellcheck disable=SC2046
# (Make's $(VAR) expansion is not shell command substitution; shellcheck
# misparses it when linting Makefiles as shell.)
# PingStatus — single-file macOS menu bar app
APP_NAME   := PingStatus
SRC        := PingStatusApp.swift
ICON_SRC   := AppIcon.png
BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RESOURCES  := $(CONTENTS)/Resources
ICONSET    := $(BUILD_DIR)/AppIcon.iconset
ICNS       := $(RESOURCES)/AppIcon.icns
BINARY     := $(MACOS_DIR)/$(APP_NAME)
STAMP      := $(BUILD_DIR)/.built

.PHONY: app run smoke clean

## Build build/PingStatus.app (ad-hoc signed, LSUIElement = true).
app: $(STAMP)

$(STAMP): $(BINARY) $(CONTENTS)/Info.plist $(ICNS)
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

## App icon: generate all required sizes from AppIcon.png (sips), then
## pack them into AppIcon.icns (iconutil). Both ship with macOS — no
## external dependencies.
$(ICNS): $(ICON_SRC)
	@mkdir -p "$(ICONSET)" "$(RESOURCES)"
	@sips -z 16 16       "$<" --out "$(ICONSET)/icon_16x16.png"      >/dev/null
	@sips -z 32 32       "$<" --out "$(ICONSET)/icon_16x16@2x.png"   >/dev/null
	@sips -z 32 32       "$<" --out "$(ICONSET)/icon_32x32.png"      >/dev/null
	@sips -z 64 64       "$<" --out "$(ICONSET)/icon_32x32@2x.png"   >/dev/null
	@sips -z 128 128     "$<" --out "$(ICONSET)/icon_128x128.png"    >/dev/null
	@sips -z 256 256     "$<" --out "$(ICONSET)/icon_128x128@2x.png" >/dev/null
	@sips -z 256 256     "$<" --out "$(ICONSET)/icon_256x256.png"    >/dev/null
	@sips -z 512 512     "$<" --out "$(ICONSET)/icon_256x256@2x.png" >/dev/null
	@sips -z 512 512     "$<" --out "$(ICONSET)/icon_512x512.png"    >/dev/null
	@sips -z 1024 1024   "$<" --out "$(ICONSET)/icon_512x512@2x.png" >/dev/null
	@iconutil -c icns -o "$@" "$(ICONSET)"
	@touch -c "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Icon $(ICNS)"

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
