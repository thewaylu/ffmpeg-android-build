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

# ---- NDK Download (cached) ----
mkdir -p $BUILD_ROOT
if [ ! -d "$NDK_ROOT" ]; then
    echo "=== Downloading Android NDK r27c ==="
    cd $BUILD_ROOT
    wget -q https://dl.google.com/android/repository/android-ndk-r27c-linux.zip -O ndk.zip
    unzip -q ndk.zip
    mv android-ndk-r27c $NDK_ROOT
    rm ndk.zip
    echo "NDK ready"
fi

mkdir -p $SRC $PREFIX

# ==================== EXTERNAL LIBS ====================

build_lib() {
    local name=$1
    echo ""
    echo "========== BUILDING $name =========="
}

# --- x264 ---
build_lib x264
cd $SRC
if [ ! -f x264_done ]; then
    rm -rf x264
    git clone --depth 1 https://code.videolan.org/videolan/x264.git x264 2>/dev/null || true
    cd x264
    ./configure \
        --host=$TARGET --cross-prefix=${TARGET}${API}- \
        --sysroot=$SYSROOT \
        --enable-static --enable-pic --disable-cli --disable-opencl \
        --prefix=$PREFIX 2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/x264_done
fi
echo "x264 DONE"

# --- x265 ---
build_lib x265
cd $SRC
if [ ! -f x265_done ]; then
    rm -rf x265
    git clone --depth 1 --branch master https://bitbucket.org/multicoreware/x265_git.git x265 2>/dev/null || true
    mkdir -p x265/build
    cd x265/build
    cmake ../source \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
        -DCMAKE_ANDROID_STANDALONE_TOOLCHAIN= \
        2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/x265_done
fi
echo "x265 DONE"

# --- SVT-AV1 ---
build_lib SVT-AV1
cd $SRC
if [ ! -f svtav1_done ]; then
    rm -rf svt-av1
    git clone --depth 1 https://gitlab.com/AOMediaCodec/SVT-AV1.git svt-av1 2>/dev/null || true
    mkdir -p svt-av1/build
    cd svt-av1/build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_ENC=ON -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DBUILD_APPS=OFF \
        2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/svtav1_done
fi
echo "SVT-AV1 DONE"

# --- libopus ---
build_lib opus
cd $SRC
if [ ! -f opus_done ]; then
    rm -rf opus
    git clone --depth 1 https://github.com/xiph/opus.git opus 2>/dev/null || true
    cd opus
    ./autogen.sh 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB 2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/opus_done
fi
echo "opus DONE"

# --- libogg ---
build_lib ogg
cd $SRC
if [ ! -f ogg_done ]; then
    rm -rf ogg
    git clone --depth 1 https://github.com/xiph/ogg.git ogg 2>/dev/null || true
    cd ogg
    ./autogen.sh 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB 2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/ogg_done
fi
echo "ogg DONE"

# --- libvorbis ---
build_lib vorbis
cd $SRC
if [ ! -f vorbis_done ]; then
    rm -rf vorbis
    git clone --depth 1 https://github.com/xiph/vorbis.git vorbis 2>/dev/null || true
    cd vorbis
    ./autogen.sh 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        --with-ogg=$PREFIX \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB 2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/vorbis_done
fi
echo "vorbis DONE"

# --- mp3lame ---
build_lib mp3lame
cd $SRC
if [ ! -f lame_done ]; then
    rm -rf lame
    git clone --depth 1 https://github.com/nu774/lame.git lame 2>/dev/null || true
    cd lame
    autoreconf -fi 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        --disable-frontend \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB 2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/lame_done
fi
echo "mp3lame DONE"

# --- libvpx ---
build_lib vpx
cd $SRC
if [ ! -f vpx_done ]; then
    rm -rf libvpx
    git clone --depth 1 https://chromium.googlesource.com/webm/libvpx.git libvpx 2>/dev/null || true
    cd libvpx
    ./configure --target=arm64-android-gcc --prefix=$PREFIX \
        --enable-static --disable-shared --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests --as=yasm \
        --extra-cflags="-fPIC" \
        2>&1 | tail -5
    make $MAKEFLAGS && make install
    touch $SRC/vpx_done
fi
echo "vpx DONE"

# --- libaom ---
build_lib aom
cd $SRC
if [ ! -f aom_done ]; then
    rm -rf aom
    git clone --depth 1 https://aomedia.googlesource.com/aom aom 2>/dev/null || true
    mkdir -p aom/build
    cd aom/build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_TESTDATA=OFF \
        2>&1 | tail -5
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
        wget -q https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz
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
        --prefix=$PREFIX \
        2>&1 | tail -20

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

# List what we have
echo "Available static libs:"
ls -la *.a 2>/dev/null

# Merge all static libs into one shared library
# Order matters: FFmpeg libs first, then external libs (dependencies last)
$CC -shared -o libffmpeg.so \
    -Wl,--whole-archive \
    libavcodec.a libavformat.a libavutil.a libavfilter.a \
    libswresample.a libswscale.a \
    libx264.a libx265.a libSvtAv1Enc.a libaom.a \
    libopus.a libmp3lame.a libvorbis.a libogg.a libvpx.a \
    -Wl,--no-whole-archive \
    -lz -lm -ldl -llog -landroid -lmediandk \
    -static-libstdc++ \
    -Wl,-soname,libffmpeg.so \
    -Wl,--version-script=$PREFIX/lib/libavcodec.ver 2>/dev/null || \
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
