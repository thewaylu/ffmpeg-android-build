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

# Ensure freetype2.pc exists NOW (before fontconfig needs it)
mkdir -p $PREFIX/lib/pkgconfig
cat > $PREFIX/lib/pkgconfig/freetype2.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: FreeType 2
Version: 27.0.20
Libs: -L${libdir} -l:libfreetype.a
Cflags: -I${includedir}/freetype2
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/freetype2.pc

# --- fribidi ---
build_lib fribidi
cd $SRC
if [ ! -f fribidi_done ]; then
    rm -rf fribidi
    git clone --depth 1 https://github.com/fribidi/fribidi.git fribidi
    cd fribidi
    autoreconf -fi 2>/dev/null || true
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        --disable-docs \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install || true  # man pages may fail without c2man
    touch $SRC/fribidi_done
fi
# fribidi autotools may generate broken .pc, force-overwrite
echo "=== fribidi lib check ==="
find $SRC/fribidi -name "*.a" -o -name "*.la" 2>/dev/null
ls -la $PREFIX/lib/libfribidi* 2>/dev/null || echo "WARN: libfribidi not in prefix"
# If libfribidi not installed, copy from build dir
if [ ! -f $PREFIX/lib/libfribidi.a ]; then
    FRIBIDI_LIB=$(find $SRC/fribidi -name "libfribidi*.a" -type f 2>/dev/null | head -1)
    if [ -n "$FRIBIDI_LIB" ]; then
        cp "$FRIBIDI_LIB" $PREFIX/lib/libfribidi.a
        echo "Copied: $FRIBIDI_LIB"
    else
        echo "FATAL: libfribidi.a not found in build dir either"
        exit 1
    fi
fi
mkdir -p $PREFIX/lib/pkgconfig
cat > $PREFIX/lib/pkgconfig/fribidi.pc << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: fribidi
Version: 1.0.16
Libs: -L\${libdir} -lfribidi
Cflags: -I\${includedir}
EOF
echo "fribidi DONE"

# --- libpng (needed by freetype for PNG font glyphs) ---
build_lib libpng
cd $SRC
if [ ! -f libpng_done ]; then
    rm -rf libpng
    git clone --depth 1 https://github.com/pnggroup/libpng.git libpng
    mkdir -p libpng/build
    cd libpng/build
    cmake .. \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_ANDROID_NDK=$NDK_ROOT \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_API=$API \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=$PREFIX \
        -DBUILD_SHARED_LIBS=OFF \
        -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
    make $MAKEFLAGS && make install
    touch $SRC/libpng_done
fi
echo "libpng DONE"

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

# --- libass (fontconfig is optional, libass works without it for subtitle burn) ---
build_lib libass
cd $SRC
if [ ! -f libass_done ]; then
    rm -rf libass
    git clone --depth 1 https://github.com/libass/libass.git libass
    cd libass
    autoreconf -fi
    # Find where fribidi.h actually is
    FRIBIDI_H=$(find $PREFIX/include $SRC/fribidi -name fribidi.h -type f 2>/dev/null | head -1)
    if [ -z "$FRIBIDI_H" ]; then
        echo "FATAL: fribidi.h not found in prefix or source"
        exit 1
    fi
    FRIBIDI_CFLAGS="-I$(dirname $FRIBIDI_H)"
    echo "FRIBIDI header: $FRIBIDI_H"
    # Copy header to prefix if not already there
    if [[ "$FRIBIDI_H" != "$PREFIX/include"* ]]; then
        mkdir -p $PREFIX/include/fribidi
        find $SRC/fribidi -name "*.h" -exec cp {} $PREFIX/include/fribidi/ \;
    fi
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    FRIBIDI_CFLAGS="-I${FRIBIDI_CFLAGS#-I}" \
    FRIBIDI_LIBS="-L$PREFIX/lib -lfribidi" \
    FREETYPE_CFLAGS="-I$PREFIX/include/freetype2" \
    FREETYPE_LIBS="-L$PREFIX/lib -l:libfreetype.a" \
    HARFBUZZ_CFLAGS="-I$PREFIX/include/harfbuzz" \
    HARFBUZZ_LIBS="-L$PREFIX/lib -l:libharfbuzz.a" \
    ./configure --host=$TARGET --prefix=$PREFIX --enable-static --disable-shared \
        CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB
    make $MAKEFLAGS && make install
    touch $SRC/libass_done
fi
echo "libass DONE"

# --- Ensure ALL subtitle .pc files are PERFECT ---
echo "=== Creating/verifying all .pc files ==="
mkdir -p $PREFIX/lib/pkgconfig

cat > $PREFIX/lib/pkgconfig/freetype2.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: 27.0.20
Libs: -L${libdir} -l:libfreetype.a
Cflags: -I${includedir}/freetype2
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/freetype2.pc

cat > $PREFIX/lib/pkgconfig/fribidi.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: fribidi
Description: GNU FriBidi
Version: 1.0.16
Libs: -L${libdir} -l:libfribidi.a
Cflags: -I${includedir}
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/fribidi.pc

cat > $PREFIX/lib/pkgconfig/harfbuzz.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: harfbuzz
Description: HarfBuzz text shaping library
Version: 11.2.0
Libs: -L${libdir} -l:libharfbuzz.a
Cflags: -I${includedir}/harfbuzz
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/harfbuzz.pc

cat > $PREFIX/lib/pkgconfig/fontconfig.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: Fontconfig
Description: Font configuration and customization library
Version: 2.16.0
Requires: freetype2
Libs: -L${libdir} -l:libfontconfig.a
Cflags: -I${includedir}
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/fontconfig.pc

cat > $PREFIX/lib/pkgconfig/libass.pc << 'EOF2'
prefix=/tmp/ffbuild/install
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include
Name: libass
Description: LibASS is an SSA/ASS subtitles rendering library
Version: 0.17.3
Requires: fribidi >= 0.19.0, freetype2 >= 9.17.3
Libs: -L${libdir} -l:libass.a
Cflags: -I${includedir}
EOF2
sed -i "s|/tmp/ffbuild/install|$PREFIX|g" $PREFIX/lib/pkgconfig/libass.pc

echo "Checking .pc files:"
PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --modversion fribidi 2>&1
PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --modversion libass 2>&1
echo "=== .pc files OK ==="

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
        --enable-libass --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
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
