#!/bin/bash
set -eo pipefail
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
export CFLAGS="-fPIC"
export CXXFLAGS="-fPIC"

# ---- NDK Download (MUST be before using CC) ----
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

echo "=== NDK toolchain ==="
$CC --version | head -1 || echo "(version check skipped)"
echo "CC=$CC"
echo "SYSROOT=$SYSROOT"

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
        -DENABLE_ASSEMBLY=OFF
    make $MAKEFLAGS && make install
    # x265 cmake doesn't install headers, do it manually
    cp ../source/x265.h $PREFIX/include/
    [ -f x265_config.h ] && cp x265_config.h $PREFIX/include/
    echo "x265 headers installed"
    touch $SRC/x265_done
fi
# x265 cmake doesn't create .pc, do it manually
# Ensure lib built and installed
echo "=== x265 .a files ==="
find $SRC/x265 -name "*.a" 2>/dev/null || echo "No .a found in build dir"
echo "=== PREFIX lib ==="
ls -la $PREFIX/lib/*.a 2>/dev/null || echo "No .a in PREFIX/lib"

# If libx265.a not in PREFIX, find and copy it
if [ ! -f $PREFIX/lib/libx265.a ]; then
    LIB265=$(find $SRC/x265 -name "libx265.a" -type f 2>/dev/null | head -1)
    if [ -n "$LIB265" ]; then
        echo "Copying $LIB265 to $PREFIX/lib/"
        cp "$LIB265" $PREFIX/lib/libx265.a
    else
        echo "FATAL: libx265.a not found anywhere!"
        exit 1
    fi
fi

# Use absolute path to avoid any linker search issues
cat > $PREFIX/lib/pkgconfig/x265.pc << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: 4.1
Libs: \${libdir}/libx265.a
Libs.private: -lstdc++ -lm -ldl
Cflags: -I\${includedir}
EOF
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

# LAME doesn't create .pc, do it manually
cat > $PREFIX/lib/pkgconfig/libmp3lame.pc << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libmp3lame
Description: MP3 encoding library
Version: 3.100
Libs: -L\${libdir} -lmp3lame
Cflags: -I\${includedir}
EOF

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

# --- freetype (cmake, needed by harfbuzz, fontconfig, libass) ---
build_lib freetype
cd $SRC
if [ ! -f freetype_done ]; then
    rm -rf freetype
    git clone --depth 1 https://github.com/freetype/freetype.git freetype
    mkdir -p freetype/build
    cd freetype/build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF
    make $MAKEFLAGS && make install
    touch $SRC/freetype_done
fi
echo "freetype DONE"
# verify freetype .pc exists
ls -la $PREFIX/lib/pkgconfig/freetype* 2>/dev/null || echo "WARN: no freetype.pc"

# --- fribidi ---
build_lib fribidi
cd $SRC
if [ ! -f fribidi_done ]; then
    rm -rf fribidi
    git clone --depth 1 https://github.com/fribidi/fribidi.git fribidi
    cd fribidi
    autoreconf -fi 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/fribidi_done
fi
echo "fribidi DONE"

# --- harfbuzz (cmake, needs freetype) ---
build_lib harfbuzz
cd $SRC
if [ ! -f harfbuzz_done ]; then
    rm -rf harfbuzz
    git clone --depth 1 https://github.com/harfbuzz/harfbuzz.git harfbuzz
    mkdir -p harfbuzz/build
    cd harfbuzz/build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DCMAKE_PREFIX_PATH=$PREFIX \
        -DCMAKE_FIND_ROOT_PATH=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DHB_HAVE_FREETYPE=ON \
        -DHB_BUILD_TESTS=OFF \
        -DHB_BUILD_UTILS=OFF
    make $MAKEFLAGS && make install
    touch $SRC/harfbuzz_done
fi
echo "harfbuzz DONE"

# --- expat (needed by fontconfig) ---
build_lib expat
cd $SRC
if [ ! -f expat_done ]; then
    rm -rf expat
    git clone --depth 1 https://github.com/libexpat/libexpat.git expat
    cd expat/expat
    ./buildconf.sh 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/expat_done
fi
echo "expat DONE"

# --- fontconfig (meson) ---
build_lib fontconfig
cd $SRC
if [ ! -f fontconfig_done ]; then
    rm -rf fontconfig
    git clone --depth 1 https://gitlab.freedesktop.org/fontconfig/fontconfig.git fontconfig
    cd fontconfig
    # meson cross file for Android
    cat > cross.txt << XEOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkgconfig = '/usr/bin/pkg-config'

[built-in options]
default_library = 'static'
pkg_config_path = '${PREFIX}/lib/pkgconfig'

[properties]
pkg_config_libdir = '${PREFIX}/lib/pkgconfig'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
XEOF
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    meson setup build --prefix=$PREFIX --cross-file cross.txt \
        -Ddoc=disabled -Dtests=disabled -Dtools=disabled \
        -Dcache-build=disabled -Ddefault-hinting=slight
    ninja -C build install
    touch $SRC/fontconfig_done
fi
echo "fontconfig DONE"

# --- libass ---
build_lib libass
cd $SRC
if [ ! -f libass_done ]; then
    rm -rf libass
    git clone --depth 1 https://github.com/libass/libass.git libass
    cd libass
    autoreconf -fi 2>/dev/null || true
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/libass_done
fi
echo "libass DONE"

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
    export CFLAGS="-I$PREFIX/include -fPIC -DPIC"
    export LDFLAGS="-L$PREFIX/lib -lm -lz -ldl -static-libstdc++"
    export ASFLAGS="-DPIC"

    echo "=== PKG-CONFIG DEBUG ==="
    which pkg-config
    for pkg in aom x264 x265 opus ogg vorbis vpx libmp3lame SvtAv1Enc; do
        echo -n "  $pkg: "
        PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --modversion $pkg 2>&1 || echo "MISSING"
    done
    echo "=== HEADER CHECK ==="
    find $PREFIX/include -name "x265*.h" -o -name "x264*.h" -o -name "aom*.h" 2>/dev/null | head -20
    echo "=== opus .pc ==="
    cat $PREFIX/lib/pkgconfig/opus.pc 2>&1 || echo "NO opus.pc"
    echo "=== x265 .pc ==="
    cat $PREFIX/lib/pkgconfig/x265.pc 2>&1 || echo "NO x265.pc"
    echo "=== END DEBUG ==="

    set +e
    ./configure \
        --cross-prefix=${TARGET}${API}- \
        --cc=${CC} --cxx=${CXX} --ld=${CC} \
        --ar=${AR} --nm=${NM} --ranlib=${RANLIB} \
        --pkg-config=/usr/bin/pkg-config \
        --pkg-config-flags=--static \
        --extra-cflags="-fPIC -DPIC" \
        --enable-cross-compile --target-os=android --arch=aarch64 \
        --enable-gpl --enable-version3 \
        --enable-libx264 --enable-libx265 --enable-libvpx \
        --enable-libopus --enable-libmp3lame --enable-libvorbis \
        --enable-libaom --enable-libsvtav1 \
        --enable-libass --enable-libfontconfig --enable-libfreetype \
        --enable-libfribidi --enable-libharfbuzz \
        --enable-mediacodec --enable-jni \
        --enable-small \
        --enable-static --disable-shared \
        --disable-asm \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --disable-doc --disable-debug \
        --prefix=$PREFIX
    cfg_rc=$?
    if [ $cfg_rc -ne 0 ]; then
        echo "=== CONFIG FAILED ==="
        echo "=== config.log tail ==="
        tail -50 ffbuild/config.log
        exit $cfg_rc
    fi
    set -e

    echo "=== Config exit code: $? ==="
    echo "=== Config done, starting make ==="
    make $MAKEFLAGS
    echo "=== Make exit code: $? ==="
    make install
    touch $SRC/ffmpeg_done
fi
echo "FFmpeg DONE"

# ==================== CREATE standalone EXECUTABLE ====================

echo ""
echo "========== Creating standalone ffmpeg executable =========="

# ffmpeg binary (built by make install) already has ALL libs statically linked
# Just rename to libffmpeg.so for APK compatibility
$STRIP --strip-unneeded $PREFIX/bin/ffmpeg
cp $PREFIX/bin/ffmpeg $PREFIX/lib/libffmpeg.so

echo ""
echo "=== RESULT ==="
ls -lh $PREFIX/lib/libffmpeg.so
echo ""
echo "=== ENCODERS ==="
$PREFIX/bin/ffmpeg -encoders 2>/dev/null | grep -E 'libx264|libx265|svt_av1|libaom|libopus|libmp3lame|libvorbis|libvpx|libass' || true

echo ""
echo "=== BUILD COMPLETE ==="
echo "libffmpeg.so is at: $PREFIX/lib/libffmpeg.so"
