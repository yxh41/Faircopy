ARCHS := arm64
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES := AIGate

include $(THEOS)/makefiles/common.mk

XCODEPROJ_NAME := AIGate
AIGate_XCODEFLAGS += -onlyUsePackageVersionsFromResolvedFile

include $(THEOS_MAKE_PATH)/xcodeproj.mk
