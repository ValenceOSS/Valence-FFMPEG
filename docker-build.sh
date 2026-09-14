#!/bin/bash

# Builds the DEB inside the Docker container

set -o errexit
set -o xtrace

# Deliberately no pipefail.
#
# It was added here and reverted the same evening, which is worth recording. The
# fault it was meant to catch -- a failed download hidden by the pipeline
# reporting what the tool downstream said -- is already gone, because patches are
# fetched to a file and applied from it rather than piped in. Nothing left in
# this script relies on a pipeline to carry a fetch failure.
#
# What it did instead was break `yes | apt-get` and `yes | mk-build-deps`: when
# the consumer finishes, `yes` takes SIGPIPE and exits 141, and pipefail promotes
# that to the pipeline's status for errexit to abort on. Both arm64 builds died
# at the first, and both amd64 builds would have died at the second.
#
# There are 800 lines of inherited script here and no reason to believe those two
# were the only pipelines that assume the old behaviour.

DEBIAN_ADDR=http://deb.debian.org/debian/
UBUNTU_ARCHIVE_ADDR=http://archive.ubuntu.com/ubuntu/
UBUNTU_PORTS_ADDR=http://ports.ubuntu.com/ubuntu-ports/

# How hard to try before giving up on somebody else's server.
#
# Every source in this build is fetched from a host that owes us nothing, and a
# build that has already spent an hour compiling should not be thrown away
# because one of them was briefly busy. Measured cause: two consecutive builds
# died on two different downloads from github.com, one of them a 503 after
# wget's default three attempts.
#
# Eight attempts twenty seconds apart is a little over two minutes of patience
# against two and a half hours of rebuild.
FETCH_TRIES=8
FETCH_WAIT=20

# Where fetched sources are kept between builds.
#
# The container gets this as a bind mount, so a source fetched by one build is
# still on disk for the next. Retries were never the whole answer: the matrix
# runs four jobs at once and each was fetching all thirty-five dependencies
# from scratch, twenty-seven of them from github.com. That burst is what gets
# an unauthenticated runner throttled, and no amount of patience fixes it.
#
# Nothing depends on the directory existing. A build with no mount fetches from
# the network exactly as before.
SOURCE_CACHE="${SOURCE_CACHE:-/sources}"

cache_ready() {
    [[ -d "${SOURCE_CACHE}" ]]
}

# git refuses to work in a repository somebody else owns, and a restored cache
# is exactly that.
#
# The cache is chowned to the runner's own uid so actions/cache can read it, and
# comes back the same way. The build runs as root, so every cached clone arrives
# owned by 1001 and git declines to touch it:
#
#   fatal: detected dubious ownership in repository at '/ffmpeg/freetype'
#
# Root can still read and write those files; only git's own check objects. That
# is what made this quiet rather than obvious -- freetype's autogen.sh could not
# check out its `dlg` submodule, carried on regardless, and died two lines later
# copying files that were never fetched.
#
# It also passed once and failed every time after. The run that introduced the
# cache had nothing to restore and cloned fresh as root; the second run was the
# first to restore anything. A cache is only proved by the build after the one
# that fills it.
#
# This container builds one package and is then thrown away, so there is nothing
# here worth protecting from a repository it does not own.
git config --global --add safe.directory '*'

# A filesystem-safe name for a source, including its ref, so that moving a pin
# misses the cache rather than quietly reusing the tree from the old one.
cache_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Downloads a URL to a file, retrying, and says so when it cannot.
#
# `--retry-on-http-error` is the important part: wget does not treat a 503 as
# worth retrying unless told, and 503 and 429 are exactly what a busy or
# rate-limiting host answers with.
fetch() {
    local url="$1"
    local target="$2"
    local cached="${SOURCE_CACHE}/tarballs/$(cache_key "${url}")"

    if cache_ready && [[ -s "${cached}" ]]; then
        echo "fetch: ${url} served from cache"
        cp "${cached}" "${target}"
        return 0
    fi

    wget \
        --tries=${FETCH_TRIES} \
        --waitretry=${FETCH_WAIT} \
        --timeout=60 \
        --retry-connrefused \
        --retry-on-host-error \
        --retry-on-http-error=408,429,500,502,503,504 \
        -nv \
        -O "${target}" \
        "${url}" || return 1

    if cache_ready; then
        mkdir -p "${SOURCE_CACHE}/tarballs"
        cp "${target}" "${cached}" || true
    fi
}

# Clones a pinned ref, retrying, and reusing a cached tree when there is one.
#
# Until now the twenty-nine clones here had no retry whatsoever. The hardening
# that followed the failed release builds covered the wget fetches and stopped
# there, which was the smaller half of the problem: the clones are twenty-seven
# of the thirty-five things this build pulls from github.com.
#
#   clone <ref> <url> [directory]
#   CLONE_RECURSIVE=1 clone <ref> <url>     when submodules are wanted
clone() {
    local ref="$1"
    local url="$2"
    local target="${3:-}"
    local destination="${target:-$(basename "${url}" .git)}"
    local cached="${SOURCE_CACHE}/git/$(cache_key "${url}@${ref}")"

    if cache_ready && [[ -d "${cached}" ]]; then
        echo "clone: ${url}@${ref} served from cache"
        cp -a "${cached}" "${destination}"
        return 0
    fi

    local -a options=(-b "${ref}" --depth=1)
    [[ -n "${CLONE_RECURSIVE:-}" ]] && options+=(--recursive)

    local attempt=1
    while true; do
        if git clone "${options[@]}" "${url}" "${destination}"; then
            break
        fi

        if (( attempt >= FETCH_TRIES )); then
            echo "clone: gave up on ${url}@${ref} after ${attempt} attempts" >&2
            return 1
        fi

        echo "clone: ${url}@${ref} failed, retrying in ${FETCH_WAIT}s (${attempt}/${FETCH_TRIES})" >&2
        rm -rf "${destination}"
        attempt=$(( attempt + 1 ))
        sleep "${FETCH_WAIT}"
    done

    if cache_ready; then
        mkdir -p "${SOURCE_CACHE}/git"
        cp -a "${destination}" "${cached}" || true
    fi
}

# Applies a patch shipped in this repository, using whatever tool is named
# after it.
#
# These were fetched from github.com and gitlab.freedesktop.org mid-build until
# two consecutive builds died on two different downloads, forty minutes and two
# hours in. Retries were added and did not settle it: the AMF tarball had
# already failed after three attempts, because being rate limited is not a blip
# to wait out. A file already in the repository cannot fail to download.
#
# Vendoring also pins what the Mesa patches contain. Those were fetched by merge
# request number, and a merge request is not immutable -- the build could have
# changed under us with no commit to point at.
#
# See patches/README.md for provenance and how to refresh one.
#
#   apply_local_patch theora/3ae2669.patch git apply
#   apply_local_patch mesa/41090.patch patch -p1 -d some-directory
#   apply_local_patch mesa/42408.patch sh -c "sed 's#a#b#' | patch -p1 -d dir"
apply_local_patch() {
    local name="$1"
    shift

    local patch_file="${SOURCE_DIR}/patches/${name}"

    if [[ ! -s "${patch_file}" ]]; then
        echo "apply_local_patch: ${patch_file} is missing or empty" >&2
        return 1
    fi

    local outcome=0

    "$@" < "${patch_file}" || outcome=$?

    if [[ ${outcome} -ne 0 ]]; then
        echo "apply_local_patch: ${name} would not apply" >&2
    fi

    return ${outcome}
}

# Prepare common extra libs for amd64 and arm64
prepare_extra_common() {
    case ${ARCH} in
        'amd64')
            CROSS_PREFIX_OPT=""
            CROSS_OPT=""
            CMAKE_TOOLCHAIN_OPT=""
            MESON_CROSS_OPT=""
        ;;
        'arm64')
            CROSS_PREFIX_OPT="aarch64-linux-gnu-"
            CROSS_OPT="--host=aarch64-linux-gnu CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++"
            CMAKE_TOOLCHAIN_OPT="-DCMAKE_TOOLCHAIN_FILE=${SOURCE_DIR}/toolchain-${ARCH}.cmake"
            MESON_CROSS_OPT="--cross-file=${SOURCE_DIR}/cross-${ARCH}.meson"
        ;;
    esac

    # ICONV
    pushd ${SOURCE_DIR}
    mkdir iconv
    pushd iconv
    iconv_ver="1.19"
    iconv_link="https://mirrors.edge.kernel.org/gnu/libiconv/libiconv-${iconv_ver}.tar.gz"
    fetch ${iconv_link} iconv.tar.gz
    tar xaf iconv.tar.gz
    pushd libiconv-${iconv_ver}
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-static \
        --enable-{shared,extra-encodings} \
        --with-pic
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/iconv
    echo "iconv${TARGET_DIR}/lib/libiconv.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # ZLIB
    pushd ${SOURCE_DIR}
    clone v1.3.2 https://github.com/madler/zlib.git
    pushd zlib
    CROSS_PREFIX=${CROSS_PREFIX_OPT} ./configure \
        --prefix=${TARGET_DIR} \
        --shared
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/zlib
    echo "zlib${TARGET_DIR}/lib/libz.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # LIBXML2
    pushd ${SOURCE_DIR}
    libxml2_ver="v2.15.3"
    clone ${libxml2_ver} https://github.com/GNOME/libxml2.git
    pushd libxml2
    ./autogen.sh \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-{static,maintainer-mode} \
        --enable-shared \
        --without-python
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/libxml2
    echo "libxml2${TARGET_DIR}/lib/libxml2.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # FRIBIDI
    pushd ${SOURCE_DIR}
    clone v1.0.16 https://github.com/fribidi/fribidi.git
    meson setup fribidi fribidi_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        --default-library=shared \
        -D{bin,docs,tests}=false
    meson configure fribidi_build
    ninja -j$(nproc) -C fribidi_build install
    cp -a ${TARGET_DIR}/lib/libfribidi.so* ${SOURCE_DIR}/fribidi
    echo "fribidi/libfribidi.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd

    # FREETYPE
    pushd ${SOURCE_DIR}
    clone VER-2-14-3 https://github.com/freetype/freetype.git
    pushd freetype
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --enable-shared \
        --disable-static
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/freetype
    echo "freetype${TARGET_DIR}/lib/libfreetype.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # FONTCONFIG
    pushd ${SOURCE_DIR}
    clone 2.17.1 https://chromium.googlesource.com/external/fontconfig
    meson setup fontconfig fontconfig_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --libdir=lib \
        --buildtype=release \
        --wrap-mode=nofallback \
        --default-library=shared \
        -Diconv=enabled \
        -Dxml-backend=libxml2 \
        -D{cache-build,doc,tests,tools}=disabled
    meson configure fontconfig_build
    ninja -j$(nproc) -C fontconfig_build install
    cp -a ${TARGET_DIR}/lib/libfontconfig.so* ${SOURCE_DIR}/fontconfig
    echo "fontconfig/libfontconfig.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd

    # HARFBUZZ
    pushd ${SOURCE_DIR}
    clone 14.2.1 https://github.com/harfbuzz/harfbuzz.git
    meson setup harfbuzz harfbuzz_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        --default-library=shared \
        -Dfreetype=enabled \
        -D{gpu,glib,gobject,cairo,chafa,icu}=disabled \
        -D{tests,introspection,docs,utilities}=disabled
    meson configure harfbuzz_build
    ninja -j$(nproc) -C harfbuzz_build install
    cp -a ${TARGET_DIR}/lib/libharfbuzz.so* ${SOURCE_DIR}/harfbuzz
    echo "harfbuzz/libharfbuzz.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd

    # UNIBREAK
    pushd ${SOURCE_DIR}
    clone libunibreak_7_0 https://github.com/adah1972/libunibreak.git
    pushd libunibreak
    ./bootstrap
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --enable-shared \
        --disable-static \
        --with-pic
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/libunibreak
    echo "libunibreak${TARGET_DIR}/lib/libunibreak.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # LIBASS
    pushd ${SOURCE_DIR}
    clone 0.17.5 https://github.com/libass/libass.git
    pushd libass
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-static \
        --enable-{shared,libunibreak} \
        --with-pic
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/libass
    echo "libass${TARGET_DIR}/lib/libass.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # OGG
    pushd ${SOURCE_DIR}
    clone v1.3.6 https://github.com/xiph/ogg.git
    pushd ogg
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-static \
        --enable-shared \
        --with-pic
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/ogg
    echo "ogg${TARGET_DIR}/lib/libogg.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # THEORA
    pushd ${SOURCE_DIR}
    clone v1.2.0 https://github.com/xiph/theora.git
    pushd theora
    # autotools: relax autoconf requirement to 2.69
    apply_local_patch theora/3ae2669.patch git apply
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-{static,examples,extra-programs,oggtest,vorbistest,spec,doc} \
        --enable-shared \
        --with-pic
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/theora
    echo "theora${TARGET_DIR}/lib/libtheora{enc,dec}.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # FFTW3
    pushd ${SOURCE_DIR}
    mkdir fftw3
    pushd fftw3
    fftw3_ver="3.3.11"
    fftw3_link="https://fftw.org/fftw-${fftw3_ver}.tar.gz"
    fetch ${fftw3_link} fftw3.tar.gz
    tar xaf fftw3.tar.gz
    pushd fftw-${fftw3_ver}
    if [ "${ARCH}" = "amd64" ]; then
        fftw3_optimizations="--enable-sse2 --enable-avx --enable-avx-128-fma --enable-avx2 --enable-avx512"
    else
        fftw3_optimizations="--enable-neon"
    fi
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --disable-{static,doc} \
        --enable-{shared,single,threads,fortran} \
        $fftw3_optimizations \
        --with-our-malloc \
        --with-combined-threads \
        --with-incoming-stack-boundary=2
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/fftw3
    echo "fftw3${TARGET_DIR}/lib/libfftw3f.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # CHROMAPRINT
    pushd ${SOURCE_DIR}
    clone v1.6.0 https://github.com/acoustid/chromaprint.git
    pushd chromaprint
    echo "Libs.private: -lfftw3f -lstdc++" >> libchromaprint.pc.cmake
    echo "Cflags.private: -DCHROMAPRINT_NODLL" >> libchromaprint.pc.cmake
    mkdir build
    pushd build
    cmake \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_{TOOLS,TESTS}=OFF \
        -DFFT_LIB=fftw3f \
        ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/chromaprint
    echo "chromaprint${TARGET_DIR}/lib/libchromaprint.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # ZIMG
    pushd ${SOURCE_DIR}
    CLONE_RECURSIVE=1 clone release-3.0.6 https://github.com/sekrit-twc/zimg.git
    pushd zimg
    ./autogen.sh
    ./configure --prefix=${TARGET_DIR} ${CROSS_OPT}
    make -j $(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/zimg
    echo "zimg${TARGET_DIR}/lib/libzimg.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # DAV1D
    pushd ${SOURCE_DIR}
    clone 1.5.3 https://code.videolan.org/videolan/dav1d.git
    meson setup dav1d dav1d_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        -Ddefault_library=shared \
        -Denable_asm=true \
        -Denable_{tools,tests,examples}=false
    meson configure dav1d_build
    ninja -j$(nproc) -C dav1d_build install
    cp -a ${TARGET_DIR}/lib/libdav1d.so* ${SOURCE_DIR}/dav1d
    echo "dav1d/libdav1d.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd

    # SVT-AV1
    pushd ${SOURCE_DIR}
    clone v4.1.0 https://gitlab.com/AOMediaCodec/SVT-AV1.git
    pushd SVT-AV1
    mkdir build
    pushd build
    cmake \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_{TESTING,APPS,DEC}=OFF \
        ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/SVT-AV1
    echo "SVT-AV1${TARGET_DIR}/lib/libSvtAv1Enc.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # FDK-AAC-STRIPPED
    pushd ${SOURCE_DIR}
    mkdir fdk-aac-stripped
    pushd fdk-aac-stripped
    fdk_aac_ver="stripped5"
    fdk_aac_link="https://gitlab.freedesktop.org/wtaymans/fdk-aac-stripped/-/archive/${fdk_aac_ver}/fdk-aac-stripped-${fdk_aac_ver}.tar.gz"
    fetch ${fdk_aac_link} fdk-aac-stripped.tar.gz
    tar xaf fdk-aac-stripped.tar.gz
    pushd fdk-aac-stripped-${fdk_aac_ver}
    ./autogen.sh
    ./configure \
        --disable-{static,silent-rules} \
        --prefix=${TARGET_DIR} CFLAGS="-O3 -DNDEBUG" CXXFLAGS="-O3 -DNDEBUG" ${CROSS_OPT}
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/fdk-aac-stripped
    echo "fdk-aac-stripped${TARGET_DIR}/lib/libfdk-aac.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # FFNVCODEC
    pushd ${SOURCE_DIR}
    clone n12.0.16.1 https://github.com/FFmpeg/nv-codec-headers.git
    pushd nv-codec-headers
    make PREFIX=${TARGET_DIR} install
    popd
    popd

    # Install crossbuild dependencies
    apt-get install -y lib{udev,pciaccess,zstd,elf,expat1}-dev:${ARCH}

    # LIBDRM
    pushd ${SOURCE_DIR}
    mkdir libdrm
    pushd libdrm
    libdrm_ver="libdrm-2.4.131"
    libdrm_link="https://gitlab.freedesktop.org/mesa/libdrm/-/archive/${libdrm_ver}/libdrm-${libdrm_ver}.tar.gz"
    fetch ${libdrm_link} libdrm.tar.gz
    tar xaf libdrm.tar.gz
    meson setup libdrm-${libdrm_ver} drm_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        -D{udev,tests,install-test-programs}=false \
        -D{amdgpu,radeon,intel}=enabled \
        -D{etnaviv,valgrind,freedreno,vc4,vmwgfx,nouveau,man-pages}=disabled
    meson configure drm_build
    ninja -j$(nproc) -C drm_build install
    cp -a ${TARGET_DIR}/lib/libdrm*.so* ${SOURCE_DIR}/libdrm
    cp ${TARGET_DIR}/share/libdrm/*.ids ${SOURCE_DIR}/libdrm
    echo "libdrm/libdrm*.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    echo "libdrm/*.ids usr/lib/valence-ffmpeg/share/libdrm" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # LIBVA
    pushd ${SOURCE_DIR}
    clone 2.24.1 https://github.com/intel/libva.git
    pushd libva
    if [ "${ARCH}" = "arm64" ]; then
        libva_drv_arch_path="/usr/lib/aarch64-linux-gnu/dri"
    else
        libva_drv_arch_path="/usr/lib/x86_64-linux-gnu/dri"
    fi
    sed -i "s#secure_getenv(\"LIBVA_DRIVERS_PATH\")#\"/usr/lib/valence-ffmpeg/lib/dri:${libva_drv_arch_path}:/usr/lib/dri:/usr/local/lib/dri\"#g" va/va.c
    sed -i "s#secure_getenv(\"LIBVA_DRIVER_NAME\")#secure_getenv(\"LIBVA_DRIVER_NAME_VALENCE\")#g" va/va.c
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --enable-drm \
        --disable-{glx,x11,wayland,docs}
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/lib/libva.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    echo "intel${TARGET_DIR}/lib/libva-drm.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # LIBVA-UTILS
    pushd ${SOURCE_DIR}
    clone 2.24.0 https://github.com/intel/libva-utils.git
    pushd libva-utils
    ./autogen.sh
    ./configure \
        ${CROSS_OPT} \
        --prefix=${TARGET_DIR}
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/bin/vainfo usr/lib/valence-ffmpeg" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # Vulkan Headers
    pushd ${SOURCE_DIR}
    clone v1.4.355 https://github.com/KhronosGroup/Vulkan-Headers.git
    pushd Vulkan-Headers
    mkdir build && pushd build
    cmake \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} ..
    make -j$(nproc) && make install
    popd
    popd
    popd

    # Vulkan ICD Loader
    pushd ${SOURCE_DIR}
    clone v1.4.355 https://github.com/KhronosGroup/Vulkan-Loader.git
    pushd Vulkan-Loader
    sed -i 's/memset(disable_struct, 0, sizeof.*);/& disable_struct->disable_all_implicit = 1;/' loader/loader_environment.c
    mkdir build && pushd build
    cmake \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
        -DVULKAN_HEADERS_INSTALL_DIR="${TARGET_DIR}" \
        -DCMAKE_INSTALL_SYSCONFDIR=${TARGET_DIR}/share \
        -DCMAKE_INSTALL_DATADIR=${TARGET_DIR}/share \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_TESTS=OFF \
        -DBUILD_WSI_{XCB,XLIB,XLIB_XRANDR,WAYLAND}_SUPPORT=OFF ..
    make -j$(nproc) && make install
    cp -a ${TARGET_DIR}/lib/libvulkan.so* ${SOURCE_DIR}/Vulkan-Loader
    echo "Vulkan-Loader/libvulkan.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # SHADERC
    shaderc_ver="v2026.2"
    pushd ${SOURCE_DIR}
    clone ${shaderc_ver} https://github.com/google/shaderc.git
    pushd shaderc
    ./utils/git-sync-deps
    shaderc_conf=$(echo -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSHADERC_SKIP_{TESTS,EXAMPLES,COPYRIGHT_CHECK}=ON \
        -DENABLE_EXCEPTIONS=ON \
        -DSPIRV_SKIP_EXECUTABLES=ON \
        -DSPIRV_TOOLS_BUILD_STATIC=ON \
        -DBUILD_SHARED_LIBS=OFF)
    # Build native glslangValidator for crossbuild
    if [ "${ARCH}" != "amd64" ]; then
        mkdir glslang_build && pushd glslang_build
        cmake $shaderc_conf \
            -DENABLE_GLSLANG_BINARIES=ON ..
        ninja -j$(nproc) third_party/glslang/StandAlone/glslang
        cp third_party/glslang/StandAlone/glslangValidator ${TARGET_DIR}/bin
        popd
    fi
    # Build target shaderc
    mkdir shaderc_build && pushd shaderc_build
    cmake $shaderc_conf \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DENABLE_GLSLANG_BINARIES=$([ "${ARCH}" = "amd64" ] && echo "ON" || echo "OFF") \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} ..
    ninja -j$(nproc)
    ninja install
    cp -a ${TARGET_DIR}/lib/libshaderc_shared.so* ${SOURCE_DIR}/shaderc
    echo "shaderc/libshaderc_shared* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # MESA
    # Minimal libs for AMD VAAPI, AMD RADV and Intel ANV
    if [[ ${LLVM_VER} -ge 15 ]]; then
        if [[ "${ARCH}" = "amd64" && ${LLVMSPIRVLIB_VER} -ge 15 && ${LLVMSPIRVLIB_VER} -le 21 ]]; then
            # Intel ANV requires llvmspirvlib >= 15 (and <= 21 in mesa 26.0)
            mesa_vk_drv="amd,intel"
            mesa_llvm_clc="enabled"
            apt-get install -y {llvm-,libllvmspirvlib-,libclc-,libclang-,libclang-cpp}${LLVMSPIRVLIB_VER}-dev
        else
            mesa_vk_drv="amd"
            mesa_llvm_clc="disabled"
        fi
        pushd ${SOURCE_DIR}
        mkdir mesa
        pushd mesa
        mesa_ver="26.0-backport"
        mesa_link="https://gitlab.freedesktop.org/nyanmisaka/mesa/-/archive/${mesa_ver}/mesa-${mesa_ver}.tar.gz"
        fetch ${mesa_link} mesa.tar.gz
        tar xaf mesa.tar.gz
        meson setup mesa-${mesa_ver} mesa_build \
            ${MESON_CROSS_OPT} \
            --prefix=${TARGET_DIR} \
            --libdir=lib \
            --buildtype=release \
            --wrap-mode=nofallback \
            -Db_ndebug=true \
            -Db_lto=false \
            -Dplatforms=[] \
            -Dgallium-drivers=radeonsi \
            -Dvulkan-drivers=${mesa_vk_drv} \
            -Dvulkan-layers=[] \
            -Dvulkan-manifest-per-architecture=true \
            -Degl=disabled \
            -Dgallium-{extra-hud,rusticl}=false \
            -Dgallium-mediafoundation=disabled \
            -Dgallium-va=enabled \
            -Dvideo-codecs=all \
            -Dgbm=disabled \
            -Dgles1=disabled \
            -Dgles2=disabled \
            -Dopengl=false \
            -Dglvnd=disabled \
            -Dglx=disabled \
            -Dlibunwind=disabled \
            -Dllvm=${mesa_llvm_clc} \
            -Damd-use-llvm=false \
            -Dlmsensors=disabled \
            -Dvalgrind=disabled \
            -Dtools=[] \
            -Dzstd=enabled \
            -Dmicrosoft-clc=disabled \
            -Dintel-elk=false
        meson configure mesa_build
        ninja -j$(nproc) -C mesa_build install
        cp -a ${TARGET_DIR}/lib/libvulkan_*.so ${SOURCE_DIR}/mesa
        # radeonsi_drv_video.so -> libgallium_drv_video.so is soft link
        cp ${TARGET_DIR}/lib/dri/radeonsi_drv_video.so ${SOURCE_DIR}/mesa
        echo "mesa/lib*.so usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
        echo "mesa/radeonsi_drv_video.so usr/lib/valence-ffmpeg/lib/dri" >> ${DPKG_INSTALL_LIST}
        cp ${TARGET_DIR}/share/drirc.d/*.conf ${SOURCE_DIR}/mesa
        echo "mesa/*defaults.conf usr/lib/valence-ffmpeg/share/drirc.d" >> ${DPKG_INSTALL_LIST}
        cp ${TARGET_DIR}/share/vulkan/icd.d/*.json ${SOURCE_DIR}/mesa
        echo "mesa/*icd.*.json usr/lib/valence-ffmpeg/share/vulkan/icd.d" >> ${DPKG_INSTALL_LIST}
        popd
        popd
    fi

    # LIBPLACEBO
    pushd ${SOURCE_DIR}
    CLONE_RECURSIVE=1 clone v7.360.1 https://github.com/haasn/libplacebo.git
    # Fix bit shift when importing P01x non-multiplane image
    git -C libplacebo apply ${SOURCE_DIR}/builder/patches/libplacebo/*.patch
    sed -i 's/env: python_env,//g' libplacebo/src/vulkan/meson.build
    meson setup libplacebo placebo_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        --default-library=shared \
        -Dvulkan=enabled \
        -Dvk-proc-addr=enabled \
        -Dvulkan-registry=${TARGET_DIR}/share/vulkan/registry/vk.xml \
        -Dshaderc=enabled \
        -Dglslang=disabled \
        -D{demos,tests,bench,fuzz}=false
    meson configure placebo_build
    ninja -j$(nproc) -C placebo_build install
    cp -a ${TARGET_DIR}/lib/libplacebo.so* ${SOURCE_DIR}/libplacebo
    echo "libplacebo/libplacebo* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
}

# Prepare extra headers, libs and drivers for x86_64-linux-gnu
prepare_extra_amd64() {
    # AMF
    # https://www.ffmpeg.org/general.html#AMD-AMF_002fVCE
    pushd ${SOURCE_DIR}
    mkdir amf-headers
    pushd amf-headers
    amf_ver="1.5.2"
    amf_link="https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v${amf_ver}/AMF-headers-v${amf_ver}.tar.gz"
    fetch ${amf_link} amf.tar.gz
    tar xaf amf.tar.gz
    pushd amf-headers-v${amf_ver}/AMF
    mkdir -p /usr/include/AMF
    mv * /usr/include/AMF
    popd
    popd
    popd

    # INTEL-VAAPI-DRIVER
    pushd ${SOURCE_DIR}
    clone master https://github.com/intel/intel-vaapi-driver.git
    pushd intel-vaapi-driver
    ./autogen.sh
    ./configure LIBVA_DRIVERS_PATH=${TARGET_DIR}/lib/dri
    make -j$(nproc) && make install
    mkdir -p ${SOURCE_DIR}/intel/dri
    cp -a ${TARGET_DIR}/lib/dri/i965*.so ${SOURCE_DIR}/intel/dri
    echo "intel/dri/i965*.so usr/lib/valence-ffmpeg/lib/dri" >> ${DPKG_INSTALL_LIST}
    popd
    popd

    # GMMLIB
    pushd ${SOURCE_DIR}
    clone intel-gmmlib-22.10.0 https://github.com/intel/gmmlib.git
    pushd gmmlib
    mkdir build && pushd build
    cmake -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/lib/libigdgmm.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # MediaSDK (RT only)
    # Provides MSDK runtime (libmfxhw64.so.1) for 11th Gen Rocket Lake and older
    pushd ${SOURCE_DIR}
    clone intel-mediasdk-23.2.2 https://github.com/Intel-Media-SDK/MediaSDK.git
    pushd MediaSDK
    # Fix build in gcc 13
    apply_local_patch mediasdk/8fb9f5f.patch git apply
    # Fix ADI issue with VPL patch
    apply_local_patch vpl-gpu-rt/e025c82.patch git apply
    # Fix missing entries in PicStruct validation with VPL patch
    apply_local_patch vpl-gpu-rt/c7eb030.patch git apply
    sed -i 's|MFX_PLUGINS_CONF_DIR "/plugins.cfg"|"/usr/lib/valence-ffmpeg/lib/mfx/plugins.cfg"|g' api/mfx_dispatch/linux/mfxloader.cpp
    mkdir build && pushd build
    cmake -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
          -DBUILD_RUNTIME=ON \
          -DBUILD_{SAMPLES,TUTORIALS,OPENCL}=OFF \
          -DBUILD_TUTORIALS=OFF \
          ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/lib/libmfxhw64.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # LIBVPL (dispatcher + header)
    # Provides VPL header and dispatcher (libvpl.so.2) for FFmpeg
    # Both MSDK and VPL runtime can be loaded by VPL dispatcher
    pushd ${SOURCE_DIR}
    clone v2.17.0 https://github.com/intel/libvpl.git
    pushd libvpl
    sed -i 's|ParseEnvSearchPaths(ONEVPL_PRIORITY_PATH_VAR, searchDirList)|searchDirList.push_back("/usr/lib/valence-ffmpeg/lib")|g' libvpl/src/mfx_dispatcher_vpl_loader.cpp
    mkdir build && pushd build
    cmake -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
          -DCMAKE_INSTALL_BINDIR=${TARGET_DIR}/bin \
          -DCMAKE_INSTALL_LIBDIR=${TARGET_DIR}/lib \
          -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_SHARED_LIBS=ON \
          -DINSTALL_{DEV,LIB}=ON \
          -DINSTALL_EXAMPLES=OFF \
          -DBUILD_{TESTS,EXAMPLES,EXPERIMENTAL}=OFF \
          ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "Libs.private: -lstdc++" >> ${TARGET_DIR}/lib/pkgconfig/vpl.pc
    echo "intel${TARGET_DIR}/lib/libvpl.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # VPL-GPU-RT (RT only)
    # Provides VPL runtime (libmfx-gen.so.1.2) for 11th Gen Tiger Lake and newer
    pushd ${SOURCE_DIR}
    clone intel-onevpl-26.2.4 https://github.com/intel/vpl-gpu-rt.git
    pushd vpl-gpu-rt
    # Fix missing entries in PicStruct validation
    apply_local_patch vpl-gpu-rt/c7eb030.patch git apply
    mkdir build && pushd build
    cmake -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
          -DCMAKE_INSTALL_LIBDIR=${TARGET_DIR}/lib \
          -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_RUNTIME=ON \
          -DBUILD_{TESTS,TOOLS}=OFF \
          -DMFX_ENABLE_{KERNELS,ENCTOOLS,AENC}=ON \
          ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/lib/libmfx-gen* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # MEDIA-DRIVER
    # Full Feature Build: ENABLE_KERNELS=ON(Default) ENABLE_NONFREE_KERNELS=ON(Default)
    # Free Kernel Build: ENABLE_KERNELS=ON ENABLE_NONFREE_KERNELS=OFF
    pushd ${SOURCE_DIR}
    clone intel-media-26.2.4 https://github.com/intel/media-driver.git
    pushd media-driver
    # Enable VC1 decode on DG2 (note that MTL+ is not supported)
    apply_local_patch media-driver/e47702f.patch git apply
    # Fix iHD crashes when used with Xe KMD on small BAR systems
    apply_local_patch media-driver/6fd4037.patch git apply
    mkdir build && pushd build
    cmake -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
          -DCMAKE_C_FLAGS="${CFLAGS} -Wno-error=array-bounds" \
          -DCMAKE_CXX_FLAGS="${CXXFLAGS} -Wno-error=array-bounds" \
          -DENABLE_KERNELS=ON \
          -DENABLE_NONFREE_KERNELS=ON \
          LIBVA_DRIVERS_PATH=${TARGET_DIR}/lib/dri \
          ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/intel
    echo "intel${TARGET_DIR}/lib/libigfxcmrt.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    mkdir -p ${SOURCE_DIR}/intel/dri
    cp -a ${TARGET_DIR}/lib/dri/iHD*.so ${SOURCE_DIR}/intel/dri
    echo "intel/dri/iHD*.so usr/lib/valence-ffmpeg/lib/dri" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd
}

# Prepare extra headers, libs and drivers for {arm,aarch64}-linux-gnu*
prepare_extra_arm() {
    # RKMPP
    pushd ${SOURCE_DIR}
    clone jellyfin-mpp-next https://github.com/nyanmisaka/rk-mirrors.git rkmpp
    pushd rkmpp
    mkdir rkmpp_build
    pushd rkmpp_build
    cmake \
        ${CMAKE_TOOLCHAIN_OPT} \
        -DCMAKE_INSTALL_PREFIX=${TARGET_DIR} \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TEST=OFF \
        ..
    make -j$(nproc) && make install && make install DESTDIR=${SOURCE_DIR}/rkmpp
    echo "rkmpp${TARGET_DIR}/lib/librockchip_mpp.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
    popd
    popd

    # RKRGA
    pushd ${SOURCE_DIR}
    clone jellyfin-rga-next https://github.com/nyanmisaka/rk-mirrors.git rkrga
    meson setup rkrga rkrga_build \
        ${MESON_CROSS_OPT} \
        --prefix=${TARGET_DIR} \
        --libdir=lib \
        --buildtype=release \
        --default-library=shared \
        -Dcpp_args=-fpermissive \
        -Dlibdrm=false \
        -Dlibrga_demo=false
    meson configure rkrga_build
    ninja -j$(nproc) -C rkrga_build install
    cp -a ${TARGET_DIR}/lib/librga.so* ${SOURCE_DIR}/rkrga
    echo "rkrga/librga.so* usr/lib/valence-ffmpeg/lib" >> ${DPKG_INSTALL_LIST}
    popd
}

# Prepare the cross-toolchain
prepare_crossbuild_env_arm64() {
    # Prepare the Ubuntu-specific cross-build requirements
    if [[ $( lsb_release -i -s ) == "Debian" ]]; then
        CODENAME="$( lsb_release -c -s )"
        echo "deb [arch=amd64] ${DEBIAN_ADDR} ${CODENAME}-backports main restricted universe multiverse" >> /etc/apt/sources.list
        echo "deb [arch=arm64] ${DEBIAN_ADDR} ${CODENAME}-backports main restricted universe multiverse" >> /etc/apt/sources.list
    fi
    if [[ $( lsb_release -i -s ) == "Ubuntu" ]]; then
        CODENAME="$( lsb_release -c -s )"
        # Remove the default sources
        rm -f /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources
        # Add arch-specific list files
        cat <<EOF > /etc/apt/sources.list.d/amd64.list
deb [arch=amd64] ${UBUNTU_ARCHIVE_ADDR} ${CODENAME} main restricted universe multiverse
deb [arch=amd64] ${UBUNTU_ARCHIVE_ADDR} ${CODENAME}-updates main restricted universe multiverse
deb [arch=amd64] ${UBUNTU_ARCHIVE_ADDR} ${CODENAME}-backports main restricted universe multiverse
deb [arch=amd64] ${UBUNTU_ARCHIVE_ADDR} ${CODENAME}-security main restricted universe multiverse
EOF
        cat <<EOF > /etc/apt/sources.list.d/arm64.list
deb [arch=arm64] ${UBUNTU_PORTS_ADDR} ${CODENAME} main restricted universe multiverse
deb [arch=arm64] ${UBUNTU_PORTS_ADDR} ${CODENAME}-updates main restricted universe multiverse
deb [arch=arm64] ${UBUNTU_PORTS_ADDR} ${CODENAME}-backports main restricted universe multiverse
deb [arch=arm64] ${UBUNTU_PORTS_ADDR} ${CODENAME}-security main restricted universe multiverse
EOF
    fi
    # Add arm64 architecture
    dpkg --add-architecture arm64
    apt-get update && apt-get dist-upgrade -y
    # Install dependencies
    ln -fs /usr/share/zoneinfo/America/Toronto /etc/localtime
    yes | apt-get install -y -o Dpkg::Options::="--force-overwrite" -o APT::Immediate-Configure=0 gcc-${GCC_VER}-source gcc-${GCC_VER}-aarch64-linux-gnu g++-${GCC_VER}-aarch64-linux-gnu libstdc++6-arm64-cross binutils-aarch64-linux-gnu bison flex libtool gdb sharutils netbase libmpc-dev libmpfr-dev systemtap-sdt-dev autogen expect chrpath zip libc6-dev:arm64 linux-libc-dev:arm64 libgcc1:arm64 libstdc++6:arm64
    # Create symlinks for versioned toolchains
    for tool in {gcc,g++,gcc-ar,gcc-ranlib,gcc-nm}; do
        ln -sf "/usr/bin/aarch64-linux-gnu-$tool-${GCC_VER}" "/usr/bin/aarch64-linux-gnu-$tool"
    done
    # Update pkgconfig search path
    export PKG_CONFIG_PATH=${PKG_CONFIG_PATH}:/usr/lib/aarch64-linux-gnu/pkgconfig
}

# Set the architecture-specific options
case ${ARCH} in
    'amd64')
        prepare_extra_common
        prepare_extra_amd64
        CONFIG_SITE=""
        DEP_ARCH_OPT=""
        BUILD_ARCH_OPT=""
    ;;
    'arm64')
        prepare_crossbuild_env_arm64
        prepare_extra_common
        prepare_extra_arm
        CONFIG_SITE="/etc/dpkg-cross/cross-config.${ARCH}"
        DEP_ARCH_OPT="--host-arch arm64"
        BUILD_ARCH_OPT="-aarm64"
    ;;
esac

# Move to source directory
pushd ${SOURCE_DIR}

# Install dependencies and build the deb
yes | mk-build-deps -i ${DEP_ARCH_OPT}
dpkg-buildpackage -b -rfakeroot -us -uc ${BUILD_ARCH_OPT}

popd

# Move the artifacts out
mkdir -p ${ARTIFACT_DIR}/deb
mv /valence-ffmpeg_* ${ARTIFACT_DIR}/deb/
chown -Rc $(stat -c %u:%g ${ARTIFACT_DIR}) ${ARTIFACT_DIR}
