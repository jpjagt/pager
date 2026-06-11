APP = Pager
DIST = dist

.PHONY: build bundle zip clean test

build:
	swift build -c release --arch arm64 --arch x86_64

bundle: build
	rm -rf $(DIST)/$(APP).app
	mkdir -p $(DIST)/$(APP).app/Contents/MacOS
	cp .build/apple/Products/Release/$(APP) $(DIST)/$(APP).app/Contents/MacOS/$(APP)
	cp packaging/Info.plist $(DIST)/$(APP).app/Contents/Info.plist
	codesign --force -s - $(DIST)/$(APP).app

zip: bundle
	cd $(DIST) && rm -f $(APP).zip && zip -qry $(APP).zip $(APP).app
	@echo "→ $(DIST)/$(APP).zip"

test:
	swift test

clean:
	rm -rf .build $(DIST)
