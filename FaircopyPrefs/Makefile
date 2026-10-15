ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES := Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := FaircopyPrefs

FaircopyPrefs_FILES += $(wildcard *.mm)
FaircopyPrefs_FILES += $(wildcard *.swift)

FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/AddEndpointView.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/CommonProvider.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/EndpointButton.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/TestTextView.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/FaircopyRootView.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Editor/CustomPromptsView.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Extension/Color+Accent.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Extension/GateSessionDelegate.mm
FaircopyPrefs_FILES += ../AIGate/AIGate/Extension/FaircopyAppModel+Ext.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Loader/Configuration.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Loader/Configuration+Endpoint.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Service/Client/AIGateClient.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Service/Client/AIGateConfiguration.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Service/Server/UsageStatistics.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Storage/GlobalStorage.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Storage/CustomPrompt.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Storage/Persist.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Storage/PersistProvider.swift
FaircopyPrefs_FILES += ../AIGate/AIGate/Storage/PublishedPersist.swift

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
FaircopyPrefs_FILES += ../libroot/dyn.c
endif

FaircopyPrefs_CFLAGS += -fobjc-arc
FaircopyPrefs_CFLAGS += -I..
FaircopyPrefs_CFLAGS += -I../AIGate/AIGate/Extension
FaircopyPrefs_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"

FaircopyPrefs_LDFLAGS += -F../Frameworks



FaircopyPrefs_LDFLAGS += -FLibrary

FaircopyPrefs_LDFLAGS += -FLibrary/SwiftUIIntrospect.xcframework/ios-arm64_arm64e -framework SwiftUIIntrospect
FaircopyPrefs_SWIFTFLAGS += -FLibrary/SwiftUIIntrospect.xcframework/ios-arm64_arm64e -framework SwiftUIIntrospect

FaircopyPrefs_FRAMEWORKS += CoreTelephony
FaircopyPrefs_FRAMEWORKS += UIKit
FaircopyPrefs_PRIVATE_FRAMEWORKS += Preferences

FaircopyPrefs_SWIFT_BRIDGING_HEADER += FaircopyPrefs-Bridging-Header.h
FaircopyPrefs_INSTALL_PATH += /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	devkit/copy-resources.sh
