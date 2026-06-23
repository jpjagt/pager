APP = Pager
DIST = dist
VERSION := $(shell git describe --tags --always 2>/dev/null || echo 0.0.0)
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
SITE := /Users/jeroen/code/jpjagt/july.dev/public/pager
SPARKLE_TOOLS := $(shell find .build/artifacts -path '*/Sparkle/bin' -type d 2>/dev/null | head -1)

.PHONY: build bundle zip clean test release

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
	mkdir -p $(DIST)/$(APP).app/Contents/Frameworks
	cp -R .build/apple/Products/Release/Sparkle.framework $(DIST)/$(APP).app/Contents/Frameworks/
	install_name_tool -add_rpath "@executable_path/../Frameworks" $(DIST)/$(APP).app/Contents/MacOS/$(APP) 2>/dev/null || true
	codesign --force --deep -s - $(DIST)/$(APP).app/Contents/Frameworks/Sparkle.framework
	codesign --force -s - $(DIST)/$(APP).app

zip: bundle
	cd $(DIST) && rm -f $(APP).zip && zip -qry $(APP).zip $(APP).app
	@echo "→ $(DIST)/$(APP).zip"

test:
	swift test

release: zip
	@test -n "$(SPARKLE_TOOLS)" || { echo "Sparkle tools not found — run swift build first"; exit 1; }
	$(SPARKLE_TOOLS)/generate_appcast --download-url-prefix "https://july.dev/pager/" $(DIST)/
	cp $(DIST)/$(APP).zip $(SITE)/Pager.zip
	cp $(DIST)/appcast.xml $(SITE)/appcast.xml
	@echo "→ copied Pager.zip + appcast.xml to $(SITE)"

clean:
	rm -rf .build $(DIST)
