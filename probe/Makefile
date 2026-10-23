THEOS ?= $(HOME)/Documents/theos-roothide

TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk
TOOL_NAME = ahsprobe
ahsprobe_FILES = main.m
ahsprobe_CFLAGS = -fobjc-arc -Wall
ahsprobe_FRAMEWORKS = Foundation CoreBluetooth SystemConfiguration
ahsprobe_CODESIGN_FLAGS = -Sentitlements.plist
include $(THEOS_MAKE_PATH)/tool.mk
