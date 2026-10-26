#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
src_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out_dir=${1:-/private/tmp/a5mali-device-resources}
mkdir -p "$out_dir"
for test_name in test_device_resources test_no_copy_buffer test_linear_buffer_texture; do
clang -fobjc-arc -fblocks -DA5_MALI_HOST_TEST -Wall -Wextra -Werror \
    "$src_dir/A5MaliBridge.c" "$src_dir/A5MaliNative.c" "$src_dir/A5MaliNativeUpload.c" "$src_dir/A5MaliCommandBuffer.m" \
    "$src_dir/A5MaliRestrictedDevice.m" "$src_dir/A5MaliMetalAPI.m" "$src_dir/A5MaliMetalTexture.m" "$src_dir/A5MaliNativeTextureOps.m" \
    "$src_dir/A5MaliShaderCompiledCache.m" "$src_dir/A5MaliDynamicShaderCache.m" "$src_dir/A5MaliDynamicPipeline.m" "$src_dir/A5MaliShaderCompileRequest.m" "$src_dir/A5MaliMetalLibrary.m" "$src_dir/A5MaliMetalDeviceResources.m" "$src_dir/A5MaliResourceDependencies.m" \
    "$src_dir/$test_name.m" \
    -framework Foundation -framework IOSurface -framework IOKit -framework Metal \
    -o "$out_dir/$test_name"
"$out_dir/$test_name"
done
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror -c \
    "$src_dir/A5MaliMetalDeviceResources.m" -o "$out_dir/A5MaliMetalDeviceResources.o"
