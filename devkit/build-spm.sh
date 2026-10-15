#!/bin/sh

what=$1

set -e
set -o pipefail

cd $(dirname $0)/..

if [ "$SKIP_SPM" = "1" ]; then
    exit 0
fi

if [ "$THEOS_DEVICE_SIMULATOR" = "1" ]; then
    PLATFORM=iossimulator
else
    PLATFORM=ios
fi

if [ "$PLATFORM" = "ios" ]; then
    echo "Building for iOS"
    ARCHS="arm64 arm64e"
    TARGET_DIR="Frameworks"
elif [ "$PLATFORM" = "iossimulator" ]; then
    echo "Building for iOS Simulator"
    ARCHS="x86_64 arm64"
    TARGET_DIR="Frameworks/_Simulator"
else
    echo "Unknown platform: $PLATFORM"
    exit 1
fi

mkdir -p $TARGET_DIR

if [ "$what" = "all" ] || [ "$what" = "OpenAI" ] || [ ! -d $TARGET_DIR/OpenAI.xcframework ]; then
    cd Library/OpenAI

    if [ "$DEBUG" = "1" ]; then
        echo "Building OpenAI (debug)"
        swift-create-xcframework@5.9 \
            --configuration debug \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean OpenAI |
            xcbeautify
    else
        echo "Building OpenAI (release)"
        swift-create-xcframework@5.9 \
            --no-debug-symbols \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean OpenAI |
            xcbeautify
    fi

    find OpenAI.xcframework -type f -name "*.json" -exec sed -i '' 's/OpenAI[.]//g' {} \;
    find OpenAI.xcframework -type f -name "*.swiftinterface" -exec sed -i '' 's/OpenAI[.]//g' {} \;

    cd -

    rm -rf $TARGET_DIR/OpenAI.xcframework
    mv -f Library/OpenAI/OpenAI.xcframework $TARGET_DIR/OpenAI.xcframework
fi

if [ "$what" = "all" ] || [ "$what" = "ColorfulX" ] || [ ! -d $TARGET_DIR/ColorfulX.xcframework ]; then
    cd Library/ColorVector

    if [ "$DEBUG" = "1" ]; then
        echo "Building ColorVector (debug)"
        swift-create-xcframework@5.9 \
            --configuration debug \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean ColorVector |
            xcbeautify
    else
        echo "Building ColorVector (release)"
        swift-create-xcframework@5.9 \
            --no-debug-symbols \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean ColorVector |
            xcbeautify
    fi

    find ColorVector.xcframework -type f -name "*.json" -exec sed -i '' 's/ColorVector.ColorVector/ColorVector/g' {} \;
    find ColorVector.xcframework -type f -name "*.swiftinterface" -exec sed -i '' 's/ColorVector.ColorVector/ColorVector/g' {} \;

    cd -

    rm -rf $TARGET_DIR/ColorVector.xcframework
    mv -f Library/ColorVector/ColorVector.xcframework $TARGET_DIR/ColorVector.xcframework

    cd Library/SpringInterpolation

    if [ "$DEBUG" = "1" ]; then
        echo "Building SpringInterpolation (debug)"
        swift-create-xcframework@5.9 \
            --configuration debug \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean SpringInterpolation |
            xcbeautify
    else
        echo "Building SpringInterpolation (release)"
        swift-create-xcframework@5.9 \
            --no-debug-symbols \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean SpringInterpolation |
            xcbeautify
    fi

    find SpringInterpolation.xcframework -type f -name "*.json" -exec sed -i '' 's/SpringInterpolation.SpringInterpolation2D/SpringInterpolation2D/g' {} \;
    find SpringInterpolation.xcframework -type f -name "*.swiftinterface" -exec sed -i '' 's/SpringInterpolation.SpringInterpolation2D/SpringInterpolation2D/g' {} \;

    find SpringInterpolation.xcframework -type f -name "*.json" -exec sed -i '' 's/SpringInterpolation.SpringInterpolation/SpringInterpolation/g' {} \;
    find SpringInterpolation.xcframework -type f -name "*.swiftinterface" -exec sed -i '' 's/SpringInterpolation.SpringInterpolation/SpringInterpolation/g' {} \;

    cd -

    rm -rf $TARGET_DIR/SpringInterpolation.xcframework
    mv -f Library/SpringInterpolation/SpringInterpolation.xcframework $TARGET_DIR/SpringInterpolation.xcframework

    cd Library/MSDisplayLink

    if [ "$DEBUG" = "1" ]; then
        echo "Building MSDisplayLink (debug)"
        swift-create-xcframework@5.9 \
            --configuration debug \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean MSDisplayLink |
            xcbeautify
    else
        echo "Building MSDisplayLink (release)"
        swift-create-xcframework@5.9 \
            --no-debug-symbols \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean MSDisplayLink |
            xcbeautify
    fi

    cd -

    rm -rf $TARGET_DIR/MSDisplayLink.xcframework
    mv -f Library/MSDisplayLink/MSDisplayLink.xcframework $TARGET_DIR/MSDisplayLink.xcframework

    cd Library/ColorfulX

    if [ "$DEBUG" = "1" ]; then
        echo "Building ColorfulX (debug)"
        swift-create-xcframework@5.9 \
            --configuration debug \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean ColorfulX |
            xcbeautify
    else
        echo "Building ColorfulX (release)"
        swift-create-xcframework@5.9 \
            --no-debug-symbols \
            --static-library \
            --platform $PLATFORM \
            --stack-evolution \
            --xc-setting ARCHS="$ARCHS" \
            --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
            --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
            --clean ColorfulX |
            xcbeautify
    fi

    cd -

    rm -rf $TARGET_DIR/ColorfulX.xcframework
    mv -f Library/ColorfulX/ColorfulX.xcframework $TARGET_DIR/ColorfulX.xcframework
fi

cd Library/WritingTools

if [ "$DEBUG" = "1" ]; then
    echo "Building WritingToolsLocalizable (debug)"
    swift-create-xcframework@5.9 \
        --configuration debug \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingToolsLocalizable |
        xcbeautify
else
    echo "Building WritingToolsLocalizable (release)"
    swift-create-xcframework@5.9 \
        --no-debug-symbols \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingToolsLocalizable |
        xcbeautify
fi

if [ "$DEBUG" = "1" ]; then
    echo "Building WritingToolsInjector (debug)"
    swift-create-xcframework@5.9 \
        --configuration debug \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingToolsInjector |
        xcbeautify
else
    echo "Building WritingToolsInjector (release)"
    swift-create-xcframework@5.9 \
        --no-debug-symbols \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingToolsInjector |
        xcbeautify
fi

if [ "$DEBUG" = "1" ]; then
    echo "Building WritingTools (debug)"
    swift-create-xcframework@5.9 \
        --configuration debug \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingTools |
        xcbeautify
else
    echo "Building WritingTools (release)"
    swift-create-xcframework@5.9 \
        --no-debug-symbols \
        --static-library \
        --platform $PLATFORM \
        --stack-evolution \
        --xc-setting ARCHS="$ARCHS" \
        --xc-setting BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        --xc-setting OTHER_SWIFT_FLAGS="-Xfrontend -module-interface-preserve-types-as-written" \
        --clean WritingTools |
        xcbeautify
fi

cd -

rm -rf $TARGET_DIR/WritingTools.xcframework
mv -f Library/WritingTools/WritingTools.xcframework $TARGET_DIR/WritingTools.xcframework

rm -rf $TARGET_DIR/WritingToolsInjector.xcframework
mv -f Library/WritingTools/WritingToolsInjector.xcframework $TARGET_DIR/WritingToolsInjector.xcframework

rm -rf $TARGET_DIR/WritingToolsLocalizable.xcframework
mv -f Library/WritingTools/WritingToolsLocalizable.xcframework $TARGET_DIR/WritingToolsLocalizable.xcframework
