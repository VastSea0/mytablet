#!/bin/zsh
# Builds the Android receiver and the signed macOS app into ./build/MyTablet.app
set -euo pipefail
ROOT=${0:A:h}; cd $ROOT
SDK=$HOME/Library/Android/sdk
BT=$SDK/build-tools/35.0.0; JAR=$SDK/platforms/android-34/android.jar
OUT=$ROOT/build; A=$OUT/android; rm -rf $A; mkdir -p $A/classes $A/dex

# Android: plain javac/d8, no Gradle needed.
$BT/aapt2 link -o $A/base.apk -I $JAR --manifest android/AndroidManifest.xml
javac -nowarn -Xlint:-options --release 11 -cp $JAR -d $A/classes $(find android/src -name '*.java')
$BT/d8 --release --lib $JAR --min-api 30 --output $A/dex $(find $A/classes -name '*.class')
(cd $A/dex && zip -qj ../base.apk classes.dex)
$BT/zipalign -f 4 $A/base.apk $A/aligned.apk
KS=$OUT/debug.keystore
[[ -f $KS ]] || keytool -genkeypair -keystore $KS -storepass android -keypass android -alias mytablet -keyalg RSA -keysize 2048 -validity 10000 -dname CN=MyTablet 2>/dev/null
$BT/apksigner sign --ks $KS --ks-pass pass:android --out $OUT/MyTabletReceiver.apk $A/aligned.apk

# macOS
(cd mac && swift build -c release 2>&1 | tail -3)
APP=$OUT/MyTablet.app; rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp mac/.build/release/MyTablet $APP/Contents/MacOS/
cp mac/Info.plist $APP/Contents/
cp $OUT/MyTabletReceiver.apk $APP/Contents/Resources/
# A stable identity keeps Screen Recording / Accessibility grants across rebuilds.
# Override with MYTABLET_SIGN_IDENTITY; without a certificate the app is ad-hoc signed and must be re-granted after each build.
IDENTITY=${MYTABLET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
codesign --force --options runtime --sign "${IDENTITY:--}" $APP
echo "Built $APP"
