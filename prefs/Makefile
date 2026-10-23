TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AutoHotspotPrefs
AutoHotspotPrefs_FILES = AHSPrefsListController.m AHSRootListController.m AHSWeekdaysController.m AHSTimeCell.m AHSLogViewController.m
AutoHotspotPrefs_FRAMEWORKS = UIKit
AutoHotspotPrefs_INSTALL_PATH = /Library/PreferenceBundles
AutoHotspotPrefs_CFLAGS = -fobjc-arc -Wall
# Preferences.framework has no stub in the Xcode SDK; resolve it at load time.
AutoHotspotPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup -lroothide

include $(THEOS_MAKE_PATH)/bundle.mk
