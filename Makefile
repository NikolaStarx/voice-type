APP_NAME := VoiceType
CONFIG := release
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := .build/$(CONFIG)/$(APP_NAME)
RESOURCES := Resources
INSTALL_DIR := $(HOME)/Applications
LOCAL_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/VoiceType Local Code Signing/ { print $$2; exit }')
SIGN_IDENTITY ?= $(if $(LOCAL_SIGN_IDENTITY),$(LOCAL_SIGN_IDENTITY),-)

.PHONY: build run install clean icon

build: icon
	swift build -c $(CONFIG)
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(EXECUTABLE)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp "$(RESOURCES)/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$(RESOURCES)/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp -R "$(RESOURCES)/LocalAI" "$(APP_BUNDLE)/Contents/Resources/LocalAI"
	codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo "Built signed app bundle: $(APP_BUNDLE)"

icon:
	swift Tools/GenerateIcon.swift

run: build
	open "$(APP_BUNDLE)"

install: build
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build "$(BUILD_DIR)" "$(RESOURCES)/AppIcon.iconset" "$(RESOURCES)/AppIcon.icns"
