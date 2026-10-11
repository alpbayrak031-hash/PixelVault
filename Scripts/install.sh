#!/bin/zsh
# Builds PixelVault and installs it in /Applications, which is what makes macOS
#   - open .pixv files in PixelVault when they are double-clicked,
#   - show each .pixv file's picture as its icon in Finder and on the Desktop,
#   - preview .pixv files with Quick Look (space bar).
# Run it again after changing the code.
set -euo pipefail

PROJECT="${0:A:h:h}"
BUILD="$PROJECT/build/DerivedData"
PRODUCT="$BUILD/Build/Products/Release/PixelVault.app"
DESTINATION="/Applications/PixelVault.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "Building PixelVault (Release)…"
xcodebuild -project "$PROJECT/PixelVault.xcodeproj" -scheme PixelVault -configuration Release \
    -derivedDataPath "$BUILD" build -quiet

# Quit a running copy so its files can be replaced.
osascript -e 'tell application id "com.pixelvault.PixelVault" to quit' >/dev/null 2>&1 || true

echo "Installing to $DESTINATION…"
rm -rf "$DESTINATION"
ditto "$PRODUCT" "$DESTINATION"

# Make the installed copy the only one LaunchServices knows. Build products left registered
# would compete with it for .pixv files and for the Quick Look extensions.
for configuration in Debug Release; do
    "$LSREGISTER" -u "$BUILD/Build/Products/$configuration/PixelVault.app" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f -R "$DESTINATION"

# Enable the Quick Look extensions and drop thumbnails cached before they existed.
pluginkit -e use -i com.pixelvault.PixelVault.Thumbnail >/dev/null 2>&1 || true
pluginkit -e use -i com.pixelvault.PixelVault.Preview >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo "Done. Double-click any .pixv file to open it in PixelVault."
