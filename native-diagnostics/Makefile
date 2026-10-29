TARGET = iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP = 127.0.0.1

INSTALL_TARGET_PROCESSES = ChatGPT
TWEAK_NAME = CGNativeDiag
CGNativeDiag_FILES = Tweak.m
CGNativeDiag_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CGNativeDiag_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
