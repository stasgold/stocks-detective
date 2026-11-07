#!/usr/bin/env bash
# Select the newest installed Xcode (needed for the iOS 27 SDK / Private Cloud Compute).
set -e
echo "Installed:"; ls -d /Applications/Xcode*.app
XCODE=$(ls -d /Applications/Xcode_*.app | python3 -c "
import sys, re
paths = [p.strip() for p in sys.stdin if p.strip()]
def key(p):
    v = re.search(r'Xcode_([0-9.]+)', p)
    return [int(x) for x in v.group(1).split('.') if x] if v else [0]
stable = [p for p in paths if 'beta' not in p.lower() and 'release_candidate' not in p.lower()] or paths
print(max(stable, key=key))")
echo "Using $XCODE"
sudo xcode-select -s "$XCODE/Contents/Developer"
xcodebuild -version
xcodebuild -showsdks | grep -i iphoneos || true
