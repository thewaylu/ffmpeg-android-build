#!/bin/bash
set -e
# ============================================
# FFmpeg Static Merge Build for Android ARM64
# Produces a single libffmpeg.so with:
#   x264, x265, SVT-AV1, libaom, opus, mp3lame,
#   vorbis, ogg, vpx + MediaCodec HW decode
# ============================================

MAKEFLAGS="-j$(nproc)"
export MAKEFLAGS

# --- paths ---
BUILD_ROOT=/tmp/ffbuild
SRC=$BUILD_ROOT/src
PREFIX=$BUILD_ROOT/install
NDK_ROOT=$BUILD_ROOT/ndk
TOOLCHAIN=$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TOOLCHAIN/sysroot
TARGET=aarch64-linux-android
API=21

export CC=${TOOLCHAIN}/bin/${TARGET}${API}-clang
export CXX=${TOOLCHAIN}/bin/${TARGET}${API}-clang++
export AR=${TOOLCHAIN}/bin/llvm-ar
export NM=${TOOLCHAIN}/bin/llvm-nm
export RANLIB=${TOOLCHAIN}/bin/llvm-ranlib
export STRIP=${TOOLCHAIN}/bin/llvm-strip
export LD=${TOOLCHAIN}/bin/ld.lld
export PATH=$TOOLCHAIN/bin:$PATH

echo "=== NDK toolchain ==="
$CC --version | head -1
echo "CC=$CC"
echo "SYSROOT=$SYSROOT"

# ---- NDK Download ----
mkdir -p $BUILD_ROOT
if [ ! -d "$NDK_ROOT" ]; then
    echo "=== Downloading Android NDK r27c ==="
    cd $BUILD_ROOT
    wget -q --timeout=300 https://dl.google.com/android/repository/android-ndk-r27c-linux.zip -O ndk.zip
    unzip -q ndk.zip
    mv android-ndk-r27c $NDK_ROOT
    rm ndk.zip
    echo "NDK ready"
fi

mkdir -p $SRC $PREFIX

# ---- Create missing symlinks for cross-prefix tools (NDK r27+ only has llvm-* variants)
for tool in strings strip ar nm ranlib readelf objdump addr2line; do
    if [ -f "$TOOLCHAIN/bin/llvm-$tool" ] && [ ! -f "$TOOLCHAIN/bin/${TARGET}${API}-$tool" ]; then
        ln -sf "llvm-$tool" "$TOOLCHAIN/bin/${TARGET}${API}-$tool"
    fi
done
echo "Tool symlinks created."

# ---- helper: clone or fail ----
clone_or_fail() {
    local url=$1 dir=$2 name=$3
    echo "  cloning $name..."
    git clone --depth 1 "$url" "$dir" || { echo "FATAL: clone failed for $name ($url)"; exit 1; }
    cd "$dir" || { echo "FATAL: cd $dir failed"; exit 1; }
}

# ---- helper: download and extract tarball ----
fetch_tar() {
    local url=$1 name=$2
    echo "  downloading $name..."
    wget -q --timeout=300 "$url" -O "$name.tar.gz" || { echo "FATAL: download $name failed"; exit 1; }
    tar xzf "$name.tar.gz" || { echo "FATAL: extract $name failed"; exit 1; }
    rm "$name.tar.gz"
}

# ==================== EXTERNAL LIBS ====================

build_lib() {
    echo ""
    echo "========== BUILDING $1 =========="
}

# --- x264 ---
build_lib x264
cd $SRC
if [ ! -f x264_done ]; then
    rm -rf x264
    clone_or_fail https://code.videolan.org/videolan/x264.git x264 x264
    ./configure \
        --host=$TARGET --cross-prefix=${TARGET}${API}- \
        --sysroot=$SYSROOT \
        --enable-static --enable-pic --disable-cli --disable-opencl \
        --prefix=$PREFIX
    make $MAKEFLAGS && make install
    touch $SRC/x264_done
fi
echo "x264 DONE"

# --- x265 ---
build_lib x265
cd $SRC
if [ ! -f x265_done ]; then
    rm -rf x265
    clone_or_fail https://bitbucket.org/multicoreware/x265_git.git x265 x265
    mkdir -p build
    cd build
    cmake ../source \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
        -DCMAKE_ANDROID_STANDALONE_TOOLCHAIN=
    make $MAKEFLAGS && make install
    touch $SRC/x265_done
fi
echo "x265 DONE"

# --- SVT-AV1 ---
build_lib SVT-AV1
cd $SRC
if [ ! -f svtav1_done ]; then
    rm -rf svt-av1
    clone_or_fail https://gitlab.com/AOMediaCodec/SVT-AV1.git svt-av1 SVT-AV1
    mkdir -p build
    cd build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_ENC=ON -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DBUILD_APPS=OFF
    make $MAKEFLAGS && make install
    touch $SRC/svtav1_done
fi
echo "SVT-AV1 DONE"

# --- libopus ---
build_lib opus
cd $SRC
if [ ! -f opus_done ]; then
    rm -rf opus
    clone_or_fail https://github.com/xiph/opus.git opus opus
    ./autogen.sh
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/opus_done
fi
echo "opus DONE"

# --- libogg ---
build_lib ogg
cd $SRC
if [ ! -f ogg_done ]; then
    rm -rf ogg
    clone_or_fail https://github.com/xiph/ogg.git ogg ogg
    ./autogen.sh
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/ogg_done
fi
echo "ogg DONE"

# --- libvorbis ---
build_lib vorbis
cd $SRC
if [ ! -f vorbis_done ]; then
    rm -rf vorbis
    clone_or_fail https://github.com/xiph/vorbis.git vorbis vorbis
    ./autogen.sh
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        --with-ogg=$PREFIX \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/vorbis_done
fi
echo "vorbis DONE"

# --- mp3lame (SourceForge tarball, more reliable than git clone) ---
build_lib mp3lame
cd $SRC
if [ ! -f lame_done ]; then
    rm -rf lame-3.100
    echo "  downloading LAME 3.100..."
    wget -q --timeout=300 "https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz/download" -O lame.tar.gz || \
    wget -q --timeout=300 "https://netix.dl.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" -O lame.tar.gz || \
    { echo "FATAL: failed to download LAME"; exit 1; }
    tar xzf lame.tar.gz && rm lame.tar.gz
    cd lame-3.100
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        --disable-frontend \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/lame_done
fi
echo "mp3lame DONE"

# --- libvpx ---
build_lib vpx
cd $SRC
if [ ! -f vpx_done ]; then
    rm -rf libvpx
    clone_or_fail https://chromium.googlesource.com/webm/libvpx libvpx libvpx
    ./configure --target=arm64-android-gcc --prefix=$PREFIX \
        --enable-static --disable-shared --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests --as=yasm \
        --extra-cflags="-fPIC"
    make $MAKEFLAGS && make install
    touch $SRC/vpx_done
fi
echo "vpx DONE"

# --- libaom ---
build_lib aom
cd $SRC
if [ ! -f aom_done ]; then
    rm -rf aom
    clone_or_fail https://aomedia.googlesource.com/aom aom aom
    mkdir -p build
    cd build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_TESTDATA=OFF
    make $MAKEFLAGS && make install
    touch $SRC/aom_done
fi
echo "aom DONE"

# ==================== FFMPEG ====================

build_lib FFmpeg
cd $SRC
FFMPEG_VER=8.1.1
if [ ! -f ffmpeg_done ]; then
    rm -rf ffmpeg-$FFMPEG_VER
    if [ ! -f ffmpeg-$FFMPEG_VER.tar.xz ]; then
        wget -q --timeout=300 https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz
    fi
    tar xf ffmpeg-$FFMPEG_VER.tar.xz
    cd ffmpeg-$FFMPEG_VER

    export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
    export CFLAGS="-I$PREFIX/include -fPIC"
    export LDFLAGS="-L$PREFIX/lib -lm -lz -ldl"

    ./configure \
        --cross-prefix=${TARGET}${API}- \
        --cc=${CC} --cxx=${CXX} --ld=${CC} \
        --ar=${AR} --nm=${NM} --ranlib=${RANLIB} \
        --enable-cross-compile --target-os=android --arch=aarch64 \
        --sysroot=$SYSROOT \
        --enable-gpl --enable-version3 \
        --enable-libx264 --enable-libx265 --enable-libvpx \
        --enable-libopus --enable-libmp3lame --enable-libvorbis \
        --enable-libaom --enable-libsvtav1 \
        --enable-mediacodec --enable-jni \
        --enable-small \
        --enable-static --disable-shared \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --disable-doc --disable-debug --disable-postproc \
        --pkg-config-flags=--static \
        --prefix=$PREFIX 2>&1 | tail -20

    echo "=== Config done, starting make ==="
    make $MAKEFLAGS 2>&1 | tail -10
    make install
    touch $SRC/ffmpeg_done
fi
echo "FFmpeg DONE"

# ==================== MERGE INTO SINGLE .so ====================

echo ""
echo "========== MERGING INTO SINGLE libffmpeg.so =========="

cd $PREFIX/lib
echo "Available static libs:"
ls -lh *.a 2>/dev/null || true

echo "=== Linking libffmpeg.so ==="
$CC -shared -o libffmpeg.so \
    -Wl,--whole-archive \
    libavcodec.a libavformat.a libavutil.a libavfilter.a \
    libswresample.a libswscale.a \
    libx264.a libx265.a libSvtAv1Enc.a libaom.a \
    libopus.a libmp3lame.a libvorbis.a libogg.a libvpx.a \
    -Wl,--no-whole-archive \
    -lz -lm -ldl -llog -landroid -lmediandk \
    -static-libstdc++ \
    -Wl,-soname,libffmpeg.so

echo "=== Stripping ==="
$STRIP --strip-unneeded libffmpeg.so

echo ""
echo "=== RESULT ==="
ls -lh libffmpeg.so
echo ""
echo "=== ENCODERS ==="
LD_LIBRARY_PATH=$PREFIX/lib $PREFIX/bin/ffmpeg -encoders 2>/dev/null | grep -E 'libx264|libx265|svt_av1|libaom|libopus|libmp3lame|libvorbis|libvpx' || true

echo ""
echo "=== BUILD COMPLETE ==="
echo "libffmpeg.so is at: $PREFIX/lib/libffmpeg.so"
