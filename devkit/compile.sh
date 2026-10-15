#!/bin/sh

set -e

cd "$(dirname "$0")/.."

rm -rf build || true
mkdir -p build/Payload
mkdir -p packages

THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1 make clean package

cp -rp .theos/_/var/jb/Applications/AIGate.app build/Payload/
cp -p .theos/_/var/jb/Library/MobileSubstrate/DynamicLibraries/Faircopy.dylib build/Payload/AIGate.app/

plutil -convert xml1 build/Payload/AIGate.app/Info.plist
plutil -remove SBAppTags build/Payload/AIGate.app/Info.plist
# CFBundleURLTypes is now declared in AIGate/AIGate/Info.plist; drop it first so
# the Lite-specific scheme block below can be re-inserted without a duplicate key.
plutil -remove CFBundleURLTypes build/Payload/AIGate.app/Info.plist || true
plutil -insert CFBundleURLTypes -array build/Payload/AIGate.app/Info.plist
plutil -insert CFBundleURLTypes -dictionary -append build/Payload/AIGate.app/Info.plist
plutil -insert CFBundleURLTypes.0.CFBundleURLName -string wiki.qaq.faircopy build/Payload/AIGate.app/Info.plist
plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes -array build/Payload/AIGate.app/Info.plist
plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes -string faircopy -append build/Payload/AIGate.app/Info.plist

cp -p AIGate/AIGate/AIGatePrivileged.entitlements build/

cd build
install_name_tool -change @rpath/CydiaSubstrate.framework/CydiaSubstrate /System/Library/Frameworks/UIKit.framework/UIKit Payload/AIGate.app/Faircopy.dylib
insert_dylib --weak --no-strip-codesig --inplace @executable_path/Faircopy.dylib Payload/AIGate.app/AIGate
codesign --remove-signature Payload/AIGate.app
ldid -SAIGatePrivileged.entitlements Payload/AIGate.app
7z a -tzip -mm=LZMA FaircopyLite.tipa Payload
cd -
mkdir -p packages

if [ ! -z "$DEBUG" ]; then
XCCONFIG_NAME=AIGate/AIGate/Version.Debug.xcconfig
if [ ! -f $XCCONFIG_NAME ]; then
  echo "Versioning configuration not found!"
  exit 1
fi
previous_version=$(awk -F "=" '/DEBUG_VERSION/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
previous_build_number=$(awk -F "=" '/DEBUG_BUILD_NUMBER/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
else
XCCONFIG_NAME=AIGate/AIGate/Version.xcconfig
if [ ! -f $XCCONFIG_NAME ]; then
  echo "Versioning configuration not found!"
  exit 1
fi
previous_version=$(awk -F "=" '/VERSION/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
previous_build_number=$(awk -F "=" '/BUILD_NUMBER/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
fi

mv build/FaircopyLite.tipa packages/FaircopyLite_$previous_version.$previous_build_number.tipa
