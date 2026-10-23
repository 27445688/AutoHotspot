THEOS ?= $(HOME)/Documents/theos-roothide

include scheme.mk
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += daemon prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

# launchd needs the absolute path; rootless installs under /var/jb, roothide patches it at install time.
after-stage::
	$(ECHO_NOTHING)/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec/autohotspotd" \
		"$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.xcode.autohotspot.plist"$(ECHO_END)
