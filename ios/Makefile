TARGET = iphone:clang:latest:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Walink

APPLICATION_NAME = Walink
Walink_FILES = $(wildcard Sources/*.m)
Walink_FRAMEWORKS = UIKit CoreGraphics CoreImage
Walink_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/../vendor
Walink_LDFLAGS = -F$(THEOS_PROJECT_DIR)/../vendor -framework NodeMobile -Wl,-rpath,@executable_path/Frameworks
Walink_RESOURCE_DIRS = Resources
Walink_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/Walink.entitlements

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk

# The NodeMobile.framework dynamic framework is built separately and lives in vendor/.
# Before the .deb is assembled we copy it into the app bundle so the linker/loader
# can resolve @rpath/NodeMobile.framework/NodeMobile at launch.
before-package::
	mkdir -p "$(THEOS_STAGING_DIR)/Applications/Walink.app/Frameworks"
	cp -R "$(THEOS_PROJECT_DIR)/../vendor/NodeMobile.framework" "$(THEOS_STAGING_DIR)/Applications/Walink.app/Frameworks/"

# On the jailbroken device: ad-hoc sign the embedded framework dylib, refresh the
# SpringBoard icon cache for /Applications, then restart Walink so the new build runs.
after-install::
	install.exec "ldid -S /Applications/Walink.app/Frameworks/NodeMobile.framework/NodeMobile || true"
	install.exec "uicache -p /Applications/Walink.app"
	install.exec "killall -9 Walink || true"
