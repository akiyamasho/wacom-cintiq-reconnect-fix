PRODUCT := wacom-recovery
SOURCE := Sources/WacomRecovery/main.swift
BUILD_DIR := .build
DEPLOYMENT_TARGET := 13.0
SWIFTC := $(shell xcrun --find swiftc)
# Some Command Line Tools updates briefly ship a newer Swift compiler beside a
# mismatched newest SDK. Prefer the stable CLT 15.4 SDK when present; all APIs
# used here substantially predate it. Full Xcode and CI use their selected SDK.
SDK ?= $(shell if test -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; then echo /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; else xcrun --sdk macosx --show-sdk-path; fi)
MODULE_CACHE := $(BUILD_DIR)/module-cache

.PHONY: all release universal clean

all: release

release: $(BUILD_DIR)/release/$(PRODUCT)

$(BUILD_DIR)/release/$(PRODUCT): $(SOURCE)
	@mkdir -p $(BUILD_DIR)/release
	$(SWIFTC) -O -whole-module-optimization \
		-sdk $(SDK) \
		-module-cache-path $(MODULE_CACHE) \
		-target $(shell uname -m)-apple-macosx$(DEPLOYMENT_TARGET) \
		-framework IOKit \
		-o $@ $(SOURCE)

universal: $(BUILD_DIR)/release/$(PRODUCT)-universal

$(BUILD_DIR)/release/$(PRODUCT)-universal: $(SOURCE)
	@mkdir -p $(BUILD_DIR)/arm64 $(BUILD_DIR)/x86_64 $(BUILD_DIR)/release
	$(SWIFTC) -O -whole-module-optimization -sdk $(SDK) \
		-module-cache-path $(MODULE_CACHE) \
		-target arm64-apple-macosx$(DEPLOYMENT_TARGET) -framework IOKit \
		-o $(BUILD_DIR)/arm64/$(PRODUCT) $(SOURCE)
	$(SWIFTC) -O -whole-module-optimization -sdk $(SDK) \
		-module-cache-path $(MODULE_CACHE) \
		-target x86_64-apple-macosx$(DEPLOYMENT_TARGET) -framework IOKit \
		-o $(BUILD_DIR)/x86_64/$(PRODUCT) $(SOURCE)
	lipo -create $(BUILD_DIR)/arm64/$(PRODUCT) $(BUILD_DIR)/x86_64/$(PRODUCT) -output $@

clean:
	rm -rf $(BUILD_DIR)
