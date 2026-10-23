THEOS ?= $(HOME)/Documents/theos-roothide

TARGET = iphone:clang:latest:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += daemon prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
