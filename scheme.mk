# Package scheme shared by every Makefile. Override with THEOS_PACKAGE_SCHEME=rootless.
THEOS_PACKAGE_SCHEME ?= roothide
TARGET = iphone:clang:latest:15.0

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
# palera1n rootless also runs on A8–A11 (arm64).
ARCHS = arm64 arm64e
ROOTHIDE_LDFLAGS =
else
ARCHS = arm64e
ROOTHIDE_LDFLAGS = -lroothide
endif
