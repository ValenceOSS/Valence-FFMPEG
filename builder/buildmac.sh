#!/bin/bash
set -xe
cd "$(dirname "$0")"
export BUILDER_ROOT="$(pwd)"
export FFBUILD_PREFIX="/opt/ffbuild/prefix"

get_output() {
    (
        SELF="$1"
        source $1
        if ffbuild_enabled; then
            ffbuild_$2 || exit 0
        else
            ffbuild_un$2 || exit 0
        fi
    )
}

# Accept architecture as first argument, fallback to uname -m if not provided
if [ -n "$1" ]; then
    arch="$1"
else
    arch=$(uname -m)
fi
TARGET="macarm64"
VARIANT="gpl"
if [ "$arch" = "arm64" ]; then
    TARGET="macarm64"
elif [ "$arch" = "x86_64" ]; then
    TARGET="mac64"
else
    echo "Unknown architecture"
    exit 1
fi

source "variants/${TARGET}-gpl.sh"

for addin in ${ADDINS[*]}; do
    source "addins/${addin}.sh"
done

for script in scripts.d/*.sh; do
    FF_CONFIGURE+=" $(get_output $script configure)"
    FF_CFLAGS+=" $(get_output $script cflags)"
    FF_CXXFLAGS+=" $(get_output $script cxxflags)"
    FF_LDFLAGS+=" $(get_output $script ldflags)"
    FF_LDEXEFLAGS+=" $(get_output $script ldexeflags)"
    FF_LIBS+=" $(get_output $script libs)"
done

FF_CONFIGURE="$(xargs <<< "$FF_CONFIGURE")"
FF_CFLAGS="$(xargs <<< "$FF_CFLAGS")"
FF_CXXFLAGS="$(xargs <<< "$FF_CXXFLAGS")"
FF_LDFLAGS="$(xargs <<< "$FF_LDFLAGS")"
FF_LDEXEFLAGS="$(xargs <<< "$FF_LDEXEFLAGS")"
FF_LIBS="$(xargs <<< "$FF_LIBS")"
FF_HOST_CFLAGS="$(xargs <<< "$FF_HOST_CFLAGS")"
FF_HOST_LDFLAGS="$(xargs <<< "$FF_HOST_LDFLAGS")"
FFBUILD_TARGET_FLAGS="$(xargs <<< "$FFBUILD_TARGET_FLAGS")"

mkdir -p build
for macbase in images/macos/*.sh; do
    cd "$BUILDER_ROOT"/build
    source "$BUILDER_ROOT"/"$macbase"
    ffbuild_macbase || exit $?
done

cd "$BUILDER_ROOT"
for lib in scripts.d/*.sh; do
    cd "$BUILDER_ROOT"/build
    source "$BUILDER_ROOT"/"$lib"
    ffbuild_enabled || continue
    ffbuild_dockerbuild || exit $?
done

cd "$BUILDER_ROOT"
cd ..
# quilt reads its series from `patches` unless told otherwise, and upstream
# pointed it there with a symlink. That worked while `patches` did not exist.
# It does here -- it holds the third-party patches the Linux build applies --
# so `ln` quietly succeeded by creating the link *inside* it, as a dangling
# `patches/patches`. quilt then found no series and the build stopped before it
# had applied a single one of the ninety-seven FFmpeg patches, the VideoToolbox
# filters this target exists for among them.
#
# QUILT_PATCHES says the same thing without touching the working tree, so the
# two directories stop competing for one name.
if [[ -f "debian/patches/series" ]]; then
    QUILT_PATCHES=debian/patches quilt push -a
fi

./configure --prefix=/ffbuild/prefix \
    $FFBUILD_TARGET_FLAGS \
    --host-cflags="$FF_HOST_CFLAGS" \
    --host-ldflags="$FF_HOST_LDFLAGS" \
    --extra-version="Valence" \
    --extra-cflags="$FF_CFLAGS" \
    --extra-cxxflags="$FF_CXXFLAGS" \
    --extra-ldflags="$FF_LDFLAGS" \
    --extra-ldexeflags="$FF_LDEXEFLAGS" \
    --extra-libs="$FF_LIBS" \
    $FF_CONFIGURE
# nproc is coreutils, and Homebrew installs those commands prefixed with `g`.
# Whether a bare `nproc` resolves depends on what else is on the runner's PATH,
# which is not something a build should be deciding by accident. sysctl is in
# the base system and answers the same question.
make -j"$(sysctl -n hw.ncpu)" V=1

# We have to manually match lines to get version as there will be no dpkg-parsechangelog on macOS
#
# Matching `jellyfin-ffmpeg` here no longer picked the top entry, because the
# changelog keeps upstream's history below Valence's own. It matched the newest
# *Jellyfin* entry instead and stamped the artefact 8.1.2-2 -- a real version,
# just not this one, which is the kind of wrong that survives review.
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
OUTPUT_FNAME="${PKG_NAME}.tar.xz"
cd "$BUILDER_ROOT"
mkdir -p artifacts
# bsdtar can add files in parent dir, but macOS's native archive utility won't be able to unzip it by double clicking, we have to move it to current dir as a workaround
mv ../ffmpeg ./
mv ../ffprobe ./
tar -cJf "${ARTIFACTS_PATH}/${OUTPUT_FNAME}" ffmpeg ffprobe
cd "$BUILDER_ROOT"/..

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
