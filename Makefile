# ASRs-R-US — build helpers.
# The .xcodeproj is generated from project.yml; edit the YAML, not the project.

PROJECT := ASRs-R-US.xcodeproj
SCHEME  := ASRs-R-US
CONFIG  ?= Debug

APP_PATH = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	-showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$$2} / FULL_PRODUCT_NAME/{n=$$2} END{print d"/"n}')

.PHONY: project build run stop clean path asr-setup

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

ASR_DIR = $(HOME)/Library/Application Support/ASRs-R-US/asr

## Install the sidecar recogniser environment and download its model (~460 MB)
asr-setup:
	@command -v uv >/dev/null || { echo "uv is required:  brew install uv"; exit 1; }
	mkdir -p "$(ASR_DIR)/models"
	uv venv --python 3.12 "$(ASR_DIR)/venv"
	uv pip install --python "$(ASR_DIR)/venv/bin/python" sherpa-onnx websockets numpy
	@cd "$(ASR_DIR)/models" && \
	  M=sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-1040ms; \
	  [ -d "$$M" ] || { echo "fetching $$M"; \
	    curl -sSL -o "$$M.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$$M.tar.bz2" && \
	    tar xjf "$$M.tar.bz2" && rm "$$M.tar.bz2"; }
	@echo "ready."
