APP = Pager
DIST = dist
VERSION := $(shell git describe --tags --always 2>/dev/null || echo 0.0.0)
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
SITE := /Users/jeroen/code/jpjagt/july.dev/public/pager
SPARKLE_TOOLS := $(shell find .build/artifacts -path '*/Sparkle/bin' -type d 2>/dev/null | head -1)

.PHONY: build bundle zip clean test release \
        release-patch release-minor release-major _tag

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
	@echo "→ released $(VERSION)"

# Bump the version, tag it, then release. The tag has to exist before the build
# starts — VERSION is expanded when Make parses this file, so tagging inside a
# single invocation would stamp the bundle with the *previous* version. Hence
# the re-entry into a fresh Make.
release-patch release-minor release-major:
	@$(MAKE) --no-print-directory _tag BUMP=$(@:release-%=%)
	@$(MAKE) --no-print-directory release

_tag:
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	test "$$branch" = "main" || { echo "✗ on branch $$branch — releases are cut from main"; exit 1; }
	@git diff --quiet HEAD -- || { \
	  echo "✗ uncommitted changes — commit or stash first:"; \
	  git diff --name-only HEAD -- | sed 's/^/    /'; exit 1; }
	@existing=$$(git tag --points-at HEAD --list 'v[0-9]*'); \
	test -z "$$existing" || { \
	  echo "✗ HEAD is already tagged $$existing — commit first, or use bare 'make release'"; \
	  exit 1; }
	@last=$$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0); \
	v=$${last#v}; \
	maj=$$(echo $$v | cut -d. -f1); maj=$${maj:-0}; \
	min=$$(echo $$v | cut -d. -f2); min=$${min:-0}; \
	pat=$$(echo $$v | cut -d. -f3); pat=$${pat:-0}; \
	case "$(BUMP)" in \
	  major) maj=$$((maj + 1)); min=0; pat=0 ;; \
	  minor) min=$$((min + 1)); pat=0 ;; \
	  patch) pat=$$((pat + 1)) ;; \
	  *) echo "✗ BUMP must be patch, minor or major"; exit 1 ;; \
	esac; \
	new="v$$maj.$$min.$$pat"; \
	git tag -a "$$new" -m "Pager $$new"; \
	echo "→ tagged $$last → $$new"

clean:
	rm -rf .build $(DIST)
