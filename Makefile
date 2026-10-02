APP_NAME := Label Printer
EXECUTABLE := LabelPrinter
APP := $(APP_NAME).app
INSTALL_DIR := /Applications

.PHONY: all app run test install uninstall icon clean

all: app

# Build a release binary and wrap it in an ad-hoc signed .app bundle.
app:
	swift build -c release
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)"
	@echo "Built $(APP)"

run: app
	open "$(APP)"

test:
	swift test

# Copy the app into /Applications, replacing any previous version.
install: app
	rm -rf "$(INSTALL_DIR)/$(APP)"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP)"
	@echo "Installed $(INSTALL_DIR)/$(APP)"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(APP)"

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift .

clean:
	swift package clean
	rm -rf "$(APP)"
