# ASRs-R-US — build helpers.
# The .xcodeproj is generated from project.yml; edit the YAML, not the project.

PROJECT := ASRs-R-US.xcodeproj
SCHEME  := ASRs-R-US
CONFIG  ?= Debug

APP_PATH = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	-showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$$2} / FULL_PRODUCT_NAME/{n=$$2} END{print d"/"n}')

.PHONY: project build run stop clean path

## Regenerate ASRs-R-US.xcodeproj from project.yml
project:
	xcodegen generate

## Build the app
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination 'platform=macOS' build

## Build, then relaunch (kills any running copy first)
run: build stop
	open "$(APP_PATH)"

## Quit a running copy
stop:
	-@pkill -x ASRs-R-US 2>/dev/null || true

## Print the built .app path
path:
	@echo "$(APP_PATH)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(PROJECT)
