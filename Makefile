APP_NAME := VoiceType
CONFIG := release
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := .build/$(CONFIG)/$(APP_NAME)
RESOURCES := Resources
INSTALL_DIR ?= /Applications
STALE_USER_APP := $(HOME)/Applications/$(APP_NAME).app
SIGN_KEYCHAIN := $(HOME)/Library/Application Support/VoiceType/Signing/VoiceTypeBuild.keychain-db
SIGN_IDENTITY ?= VoiceType Build Code Signing

.PHONY: build run install clean icon signing diagnose benchmark-llm

build: icon signing
	swift build -c $(CONFIG)
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(EXECUTABLE)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp "$(RESOURCES)/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$(RESOURCES)/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp -R "$(RESOURCES)/LocalAI" "$(APP_BUNDLE)/Contents/Resources/LocalAI"
	codesign --force --deep --keychain "$(SIGN_KEYCHAIN)" --sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo "Built signed app bundle: $(APP_BUNDLE)"

icon:
	swift Tools/GenerateIcon.swift

signing:
	Tools/EnsureBuildSigningIdentity.sh

run: build
	open "$(APP_BUNDLE)"

install: build
	mkdir -p "$(INSTALL_DIR)"
	pkill -x "$(APP_NAME)" 2>/dev/null || true
	pkill -f "$(STALE_USER_APP)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	rm -rf "$(STALE_USER_APP)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"

diagnose:
	Tools/RunDiagnostics.sh

benchmark-llm:
	swift Tools/BenchmarkLLMRefinement.swift $(MODELS)

clean:
	rm -rf .build "$(BUILD_DIR)" "$(RESOURCES)/AppIcon.iconset" "$(RESOURCES)/AppIcon.icns"
