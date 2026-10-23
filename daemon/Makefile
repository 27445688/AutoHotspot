TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk
TOOL_NAME = autohotspotd
autohotspotd_FILES = main.m AHSController.m AHSScanner.m AHSSystem.m AHSLog.m
autohotspotd_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
autohotspotd_FRAMEWORKS = Foundation CoreBluetooth SystemConfiguration
autohotspotd_LDFLAGS = -lroothide
autohotspotd_INSTALL_PATH = /usr/libexec
autohotspotd_CODESIGN_FLAGS = -S$(CURDIR)/entitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
