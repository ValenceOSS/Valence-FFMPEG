#!/bin/bash
set -xe
cd "$(dirname "$0")"
export BUILDER_ROOT="$(pwd)"
export CMAKE_POLICY_VERSION_MINIMUM="3.5"

# One script for both Windows targets, told apart by the msys2 environment it runs in: CLANG64 on an
# x64 runner, CLANGARM64 on an ARM64 one. Upstream kept a second script for Windows on Arm, which
# had already drifted from this one by the time it was put back, so the differences live here.
#
# AMF and libvpl are x64 only. AMD and Intel ship no ARM64 runtime for either, and there is no AMD or
# Intel graphics in a Windows on Arm machine to drive; there, D3D11VA decodes and Media Foundation
# encodes, which is how a Qualcomm GPU is reached. NVENC stays: ffnvcodec's ARM64 patch loads the
# driver's ARM64 entry point, for NVIDIA's own Arm PCs.
case "${MSYSTEM:-}" in
    CLANG64)
        MINGW_PREFIX_DIR="/clang64"
        ARCH_FLAGS=()
        VENDOR_FLAGS=(--enable-amf --enable-libvpl)
        SKIPPED_PKGS=()
        TARGET="win64-clang"
        ;;
    CLANGARM64)
        MINGW_PREFIX_DIR="/clangarm64"
        ARCH_FLAGS=(--arch=arm64)
        VENDOR_FLAGS=()
        SKIPPED_PKGS=(50-mingw-w64-amf-headers 50-mingw-w64-libvpl)
        TARGET="winarm64-clang"
        ;;
    *)
        echo "Run this from msys2's CLANG64 or CLANGARM64 environment, not '${MSYSTEM:-none}'." >&2
        exit 1
        ;;
esac

MINGW_ARCH="${MSYSTEM,,}"
export FFBUILD_PREFIX="${MINGW_PREFIX_DIR}/ffbuild"
VARIANT="gpl"

# Copy libc++ & libunwind to our prefix folder
mkdir -p "$FFBUILD_PREFIX"/lib
cp "$MINGW_PREFIX_DIR"/lib/libc++.a "$FFBUILD_PREFIX"/lib/libc++.a
cp "$MINGW_PREFIX_DIR"/lib/libunwind.a "$FFBUILD_PREFIX"/lib/libunwind.a

# Skipped where CI restored the prefix they build into, which is the whole of the dependencies.
if [[ "${DEPS_CACHED:-}" != "true" ]]; then
    cd "$BUILDER_ROOT"/PKGBUILD
    for pkg in *; do
        if [[ " ${SKIPPED_PKGS[*]} " == *" $pkg "* ]]; then
            echo "Skipping $pkg, which nothing in this target's build links"
        elif [ -d "$pkg" ]; then
            echo "Installing $pkg"
            cd "$pkg"

            (MINGW_ARCH="$MINGW_ARCH" makepkg-mingw -sLfi --noconfirm --skippgpcheck) || exit $?

            cd ..
          fi
    done
else
    # The prefix comes back from the cache, but what makepkg installed from msys2's own repositories
    # to build it does not: it lives in the environment, not the prefix. pkg-config is among it, and
    # without it configure finds none of the libraries the cache did restore. So those are installed
    # here as makepkg's --syncdeps would have, from each package's own lists, leaving out the ones
    # this repository builds.
    repo_deps=()
    for pkg in "$BUILDER_ROOT"/PKGBUILD/*/; do
        pkg="$(basename "$pkg")"
        if [[ " ${SKIPPED_PKGS[*]} " == *" $pkg "* ]]; then
            continue
        fi
        while IFS= read -r dep; do
            dep="${dep%%[<>=]*}"
            if [[ -n "$dep" && "$dep" != *-jellyfin-* ]]; then
                repo_deps+=("$dep")
            fi
        done < <(bash -c 'source "$1" > /dev/null 2>&1; printf "%s\n" "${depends[@]}" "${makedepends[@]}"' _ "$BUILDER_ROOT/PKGBUILD/$pkg/PKGBUILD")
    done
    mapfile -t repo_deps < <(printf '%s\n' "${repo_deps[@]}" | sort -u)
    pacman -S --needed --noconfirm "${repo_deps[@]}"
fi

cd "$BUILDER_ROOT"
cd ..
# Not by linking debian/patches to ./patches, as upstream did: this repository keeps its own
# patches/ directory for the libraries the Debian build patches, so the link lands inside it and
# fails. QUILT_PATCHES points quilt at the series without touching the tree, as buildmac.sh does.
if [[ -f "debian/patches/series" ]]; then
    QUILT_PATCHES=debian/patches quilt push -a
fi

# On Windows, included headers are usually case-insensitive:
# ffmpeg's VERSION and libc++'s "#include <version>"
if [[ -f "VERSION" && -f "ffbuild/version.sh" ]]; then
    mv VERSION{,.bak}
    sed -i "s/cat VERSION/&.bak/g" ffbuild/version.sh
fi

PKG_CONFIG_PATH="$FFBUILD_PREFIX"/lib/pkgconfig ./configure \
    --cc=clang \
    --cxx=clang++ \
    "${ARCH_FLAGS[@]}" \
    --pkg-config-flags=--static \
    --extra-cflags=-I"$FFBUILD_PREFIX"/include \
    --extra-ldflags=-L"$FFBUILD_PREFIX"/lib \
    --prefix="$FFBUILD_PREFIX"/valence-ffmpeg \
    --extra-version=Valence \
    --disable-unstable \
    --disable-ffplay \
    --disable-debug \
    --disable-doc \
    --disable-sdl2 \
    --enable-lto=thin \
    --enable-gpl \
    --enable-version3 \
    --enable-schannel \
    --enable-iconv \
    --enable-libxml2 \
    --enable-zlib \
    --enable-lzma \
    --enable-gmp \
    --enable-chromaprint \
    --enable-libfreetype \
    --enable-libfribidi \
    --enable-libfontconfig \
    --enable-libharfbuzz \
    --enable-libass \
    --enable-libbluray \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libtheora \
    --enable-libvorbis \
    --enable-libopenmpt \
    --enable-libwebp \
    --enable-libvpx \
    --enable-libzimg \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libsvtav1 \
    --enable-libdav1d \
    --enable-libfdk-aac \
    --enable-libshaderc \
    --enable-libplacebo \
    --enable-vulkan \
    --enable-opencl \
    --enable-dxva2 \
    --enable-d3d11va \
    --enable-d3d12va \
    --enable-mediafoundation \
    "${VENDOR_FLAGS[@]}" \
    --enable-ffnvcodec \
    --enable-cuda \
    --enable-cuda-llvm \
    --enable-cuvid \
    --enable-nvdec \
    --enable-nvenc

make -j$(nproc) V=1

# We have to manually match lines to get version as there will be no dpkg-parsechangelog on msys2
#
# Matching `valence-ffmpeg` rather than upstream's `jellyfin-ffmpeg`, for the reason buildmac.sh
# gives: the changelog keeps upstream's history below Valence's own, and the Jellyfin match picks
# the newest Jellyfin entry, stamping the artefact with a real version that is not this one.
PKG_VER=0.0.0
while IFS= read -r line; do
    if [[ $line == valence-ffmpeg* ]]; then
        if [[ $line =~ \(([^\)]+)\) ]]; then
            PKG_VER="${BASH_REMATCH[1]}"
            break
        fi
    fi
done < "$BUILDER_ROOT"/../debian/changelog

PKG_NAME="valence-ffmpeg_${PKG_VER}_portable_${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"
ARTIFACTS_PATH="$BUILDER_ROOT"/artifacts
OUTPUT_FNAME="${PKG_NAME}.zip"
cd "$BUILDER_ROOT"
mkdir -p artifacts
mv ../ffmpeg.exe ./
mv ../ffprobe.exe ./
zip -9 -r "${ARTIFACTS_PATH}/${OUTPUT_FNAME}" ffmpeg.exe ffprobe.exe
cd "$BUILDER_ROOT"/..

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
