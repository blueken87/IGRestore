export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless

INSTALL_TARGET_PROCESSES := Instagram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IGRestore

IGRestore_FILES = Tweak.xm
IGRestore_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
IGRestore_FRAMEWORKS = Foundation UIKit
IGRestore_LIBRARIES = z

before-package::
	chmod 0755 layout/DEBIAN/* 2>/dev/null || true

include $(THEOS_MAKE_PATH)/tweak.mk
