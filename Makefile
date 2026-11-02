# NitroSense for macOS (Hackintosh, Acer Nitro 5 AN515-57)
# Needs Command Line Tools (clang, swiftc, MacOSX.sdk with Kernel.framework) and iasl.

SDK      := $(shell xcrun --show-sdk-path)
CLANGRT  := $(shell dirname $$(xcrun -f clang))/../lib/clang/$(shell xcrun clang -dumpversion | cut -d. -f1)/lib/darwin
IASL     ?= $(CURDIR)/.tools/iasl
BUILD    := build

KEXT     := $(BUILD)/NitroEC.kext
KEXT_SRC := Kext/NitroEC.cpp Kext/NitroEC_info.c
KEXT_HDR := Kext/NitroEC.hpp Kext/NitroECShared.h

KFLAGS := -arch x86_64 -mmacosx-version-min=15.5 -isysroot $(SDK) \
	-I$(SDK)/System/Library/Frameworks/Kernel.framework/Headers \
	-mkernel -nostdlib -fno-builtin -fno-common -fno-stack-protector \
	-DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -O2 -Wall
KCXXFLAGS := -fapple-kext -std=gnu++17 -fno-rtti -fno-exceptions -fno-asynchronous-unwind-tables
KLDFLAGS  := -Xlinker -kext -L$(SDK)/usr/lib -lkmodc++ -lkmod $(CLANGRT)/libclang_rt.cc_kext.a

.PHONY: all kext ssdt cli daemon app release clean

all: ssdt kext cli daemon app

ssdt: $(BUILD)/SSDT-NITRO.aml
$(BUILD)/SSDT-NITRO.aml: ACPI/SSDT-NITRO.dsl
	@mkdir -p $(BUILD)
	"$(IASL)" -p $(BUILD)/SSDT-NITRO $<

kext: $(KEXT)/Contents/MacOS/NitroEC $(KEXT)/Contents/Info.plist
	codesign -f -s - $(KEXT)
$(KEXT)/Contents/MacOS/NitroEC: $(KEXT_SRC) $(KEXT_HDR)
	@mkdir -p $(BUILD)/obj $(dir $@)
	clang $(KFLAGS) -c Kext/NitroEC_info.c -o $(BUILD)/obj/NitroEC_info.o
	clang++ $(KFLAGS) $(KCXXFLAGS) -c Kext/NitroEC.cpp -o $(BUILD)/obj/NitroEC.o
	clang++ $(KFLAGS) $(BUILD)/obj/NitroEC.o $(BUILD)/obj/NitroEC_info.o $(KLDFLAGS) -o $@
$(KEXT)/Contents/Info.plist: Kext/Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

cli: $(BUILD)/nitroctl
$(BUILD)/nitroctl: CLI/main.swift Core/NitroCore.swift Core/NitroConfig.swift Core/GPUStats.swift Kext/NitroECShared.h
	@mkdir -p $(BUILD)
	swiftc -O -target x86_64-apple-macos15.0 -import-objc-header Kext/NitroECShared.h Core/NitroCore.swift Core/NitroConfig.swift Core/GPUStats.swift CLI/main.swift -o $@

clean:
	rm -rf $(BUILD)

daemon: $(BUILD)/nitrod
$(BUILD)/nitrod: Daemon/main.swift Core/NitroCore.swift Core/NitroConfig.swift Core/GPUStats.swift Kext/NitroECShared.h
	@mkdir -p $(BUILD)
	swiftc -O -target x86_64-apple-macos15.0 -import-objc-header Kext/NitroECShared.h Core/NitroCore.swift Core/NitroConfig.swift Core/GPUStats.swift Daemon/main.swift -o $@

APP     := $(BUILD)/NitroSense.app
APP_SRC := App/NitroSenseApp.swift App/Model.swift App/Theme.swift App/Views.swift App/Dialogs.swift Core/NitroCore.swift Core/NitroConfig.swift Core/GPUStats.swift

app: $(APP)/Contents/MacOS/NitroSense $(APP)/Contents/Info.plist $(APP)/Contents/Resources/AppIcon.icns \
		$(APP)/Contents/Library/LaunchAgents/com.nitrosense.app.agent.plist
	codesign -f -s - $(APP)
$(APP)/Contents/Library/LaunchAgents/com.nitrosense.app.agent.plist: App/LaunchAgents/com.nitrosense.app.agent.plist
	@mkdir -p $(dir $@)
	cp $< $@
$(APP)/Contents/Resources/AppIcon.icns: App/Resources/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@
$(APP)/Contents/MacOS/NitroSense: $(APP_SRC) Kext/NitroECShared.h
	@mkdir -p $(dir $@)
	swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos15.0 \
		-import-objc-header Kext/NitroECShared.h $(APP_SRC) -o $@
$(APP)/Contents/Info.plist: App/Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

# Release zip: the build/ outputs plus the scripts, laid out so the scripts work as-is.
VERSION ?= 1.1.0
REL     := dist/NitroSense-macOS-$(VERSION)
release: all
	rm -rf $(REL) $(REL).zip
	mkdir -p $(REL)/build $(REL)/Scripts
	cp -R $(BUILD)/NitroSense.app $(BUILD)/NitroEC.kext $(BUILD)/SSDT-NITRO.aml $(BUILD)/nitrod $(BUILD)/nitroctl $(REL)/build/
	cp Scripts/install-all.sh Scripts/install.sh Scripts/install-daemon.sh Scripts/install-app.sh \
	   Scripts/uninstall.sh Scripts/uninstall-daemon.sh Scripts/check-reapply.sh $(REL)/Scripts/
	cp README.md LICENSE $(REL)/
	cd dist && ditto -c -k --keepParent NitroSense-macOS-$(VERSION) NitroSense-macOS-$(VERSION).zip
	shasum -a 256 $(REL).zip
