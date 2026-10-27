ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ChatGPTPrefs
ChatGPTPrefs_FILES = ChatGPTPrefs.m CGPClearDataController.m
ChatGPTPrefs_FRAMEWORKS = Foundation UIKit CoreFoundation QuartzCore
ChatGPTPrefs_LIBRARIES = sqlite3
ChatGPTPrefs_PRIVATE_FRAMEWORKS = Preferences
ChatGPTPrefs_INSTALL_PATH = /Library/PreferenceBundles
ChatGPTPrefs_INFOPLIST_FILE = Resources/Info.plist
ChatGPTPrefs_RESOURCE_FILES = Resources/icon.png Resources/Root.plist
ChatGPTPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
