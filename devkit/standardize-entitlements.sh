#!/bin/sh

cd $(dirname $0)/..

plutil -convert xml1 AIGate/AIGate/Info.plist
plutil -convert xml1 AIGate/AIGate/AIGate.entitlements
plutil -convert xml1 AIGate/AIGate/AIGatePrivileged.entitlements

plutil -convert xml1 FaircopyPrefs/Resources/Info.plist
plutil -convert xml1 FaircopyPrefs/layout/Library/PreferenceLoader/Preferences/FaircopyPrefs/Root.plist
