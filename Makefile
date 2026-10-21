export PACKAGE_VERSION := 3.0.55

ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0
GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += AIGate
SUBPROJECTS += FaircopyPrefs

include $(THEOS_MAKE_PATH)/aggregate.mk

TWEAK_NAME := Faircopy

Faircopy_FILES += Faircopy.xm
Faircopy_FILES += FaircopyStub.swift

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
Faircopy_FILES += libroot/dyn.c
endif

Faircopy_CFLAGS += -fobjc-arc
Faircopy_CFLAGS += -fvisibility=hidden
Faircopy_CFLAGS += -I.
Faircopy_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"

Faircopy_CFLAGS += -Wno-unused-variable
Faircopy_CFLAGS += -Wno-unused-function

Faircopy_LDFLAGS += -Wl,-all_load

Faircopy_LDFLAGS += -FFrameworks/OpenAI.xcframework/ios-arm64_arm64e -framework OpenAI
Faircopy_SWIFTFLAGS += -FFrameworks/OpenAI.xcframework/ios-arm64_arm64e -framework OpenAI

Faircopy_CFLAGS += -FFrameworks/WritingTools.xcframework/ios-arm64_arm64e -framework WritingTools
Faircopy_LDFLAGS += -FFrameworks/WritingTools.xcframework/ios-arm64_arm64e -framework WritingTools
Faircopy_SWIFTFLAGS += -FFrameworks/WritingTools.xcframework/ios-arm64_arm64e -framework WritingTools

Faircopy_LDFLAGS += -FFrameworks/WritingToolsLocalizable.xcframework/ios-arm64_arm64e -framework WritingToolsLocalizable
Faircopy_SWIFTFLAGS += -FFrameworks/WritingToolsLocalizable.xcframework/ios-arm64_arm64e -framework WritingToolsLocalizable

Faircopy_CFLAGS += -FFrameworks/WritingToolsInjector.xcframework/ios-arm64_arm64e -framework WritingToolsInjector
Faircopy_LDFLAGS += -FFrameworks/WritingToolsInjector.xcframework/ios-arm64_arm64e -framework WritingToolsInjector
Faircopy_SWIFTFLAGS += -FFrameworks/WritingToolsInjector.xcframework/ios-arm64_arm64e -framework WritingToolsInjector

Faircopy_LDFLAGS += -FFrameworks/ColorfulX.xcframework/ios-arm64_arm64e -framework ColorfulX
Faircopy_SWIFTFLAGS += -FFrameworks/ColorfulX.xcframework/ios-arm64_arm64e -framework ColorfulX

Faircopy_LDFLAGS += -FFrameworks/ColorVector.xcframework/ios-arm64_arm64e -framework ColorVector
Faircopy_SWIFTFLAGS += -FFrameworks/ColorVector.xcframework/ios-arm64_arm64e -framework ColorVector

Faircopy_LDFLAGS += -FFrameworks/SpringInterpolation.xcframework/ios-arm64_arm64e -framework SpringInterpolation
Faircopy_SWIFTFLAGS += -FFrameworks/SpringInterpolation.xcframework/ios-arm64_arm64e -framework SpringInterpolation

Faircopy_LDFLAGS += -FFrameworks/MSDisplayLink.xcframework/ios-arm64_arm64e -framework MSDisplayLink
Faircopy_SWIFTFLAGS += -FFrameworks/MSDisplayLink.xcframework/ios-arm64_arm64e -framework MSDisplayLink

include $(THEOS_MAKE_PATH)/tweak.mk

export DEBUG
before-all::
	devkit/print-version.sh
	devkit/standardize-entitlements.sh
	devkit/build-spm.sh OpenAI

export THEOS_OBJ_DIR
export THEOS_STAGING_DIR
before-package::
	$(ECHO_NOTHING)ldid -SAIGate/AIGate/AIGatePrivileged.entitlements $(THEOS_STAGING_DIR)/Applications/AIGate.app$(ECHO_END)

clean::
	$(ECHO_NOTHING)rm -rf Frameworks/WritingTools.xcframework || true$(ECHO_END)
	$(ECHO_NOTHING)rm -rf Frameworks/WritingToolsLocalizable.xcframework || true$(ECHO_END)
	$(ECHO_NOTHING)rm -rf Frameworks/WritingToolsInjector.xcframework || true$(ECHO_END)

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
stage::
	plutil -replace Program -string $(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/AIGate.app/AIGate $(THEOS_STAGING_DIR)/Library/LaunchDaemons/wiki.qaq.faircopyservices.plist
endif
