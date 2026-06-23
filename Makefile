APP = Pager
DIST = dist
VERSION := $(shell git describe --tags --always 2>/dev/null || echo 0.0.0)
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

.PHONY: build bundle zip clean test

build:
	swift build -c release --arch arm64 --arch x86_64

bundle: build
	rm -rf $(DIST)/$(APP).app
	mkdir -p $(DIST)/$(APP).app/Contents/MacOS
	cp .build/apple/Products/Release/$(APP) $(DIST)/$(APP).app/Contents/MacOS/$(APP)
	cp packaging/Info.plist $(DIST)/$(APP).app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(DIST)/$(APP).app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(DIST)/$(APP).app/Contents/Info.plist
	mkdir -p $(DIST)/$(APP).app/Contents/Resources
	cp packaging/AppIcon.icns $(DIST)/$(APP).app/Contents/Resources/AppIcon.icns
	cp packaging/pager-logo.png $(DIST)/$(APP).app/Contents/Resources/pager-logo.png
	codesign --force -s - $(DIST)/$(APP).app

zip: bundle
	cd $(DIST) && rm -f $(APP).zip && zip -qry $(APP).zip $(APP).app
	@echo "→ $(DIST)/$(APP).zip"

test:
	swift test

clean:
	rm -rf .build $(DIST)
