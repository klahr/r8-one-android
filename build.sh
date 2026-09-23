#!/usr/bin/env bash
#
# Build the native half of r8 One: QDOS, the Quadrate libraries and SDL3, all
# from the submodules under external/, for each ABI.
#
#   ./build.sh               # native libraries only; Gradle packages them
#   ./build.sh apk           # and a debug APK
#   ./build.sh install       # and install it over adb
#   R8_ABIS="arm64-v8a x86_64" ./build.sh apk   # the emulator too
#
# Nothing is downloaded: every source is a submodule, which is what F-Droid
# requires. Run `git submodule update --init` first.
#
# Output: build/native/jniLibs/<abi>/, which app/build.gradle packages.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QDOS_DIR="$ROOT/external/qdos"
QUADRATE_DIR="$ROOT/external/quadrate"
U8T_DIR="$ROOT/external/libu8t"
SDL_DIR="$ROOT/external/SDL"
OUT=${R8_BUILD_DIR:-$ROOT/build/native}
ABIS=${R8_ABIS:-arm64-v8a}
API=24
TARGET=${1:-}

for dir in "$QDOS_DIR" "$QUADRATE_DIR" "$U8T_DIR" "$SDL_DIR"; do
	if [ ! -f "$dir/README.md" ]; then
		echo "$0: $dir is empty; run git submodule update --init" >&2
		exit 1
	fi
done

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
	ANDROID_NDK_HOME=$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)
fi
if [ ! -d "$ANDROID_NDK_HOME" ]; then
	echo "$0: no NDK found; set ANDROID_NDK_HOME" >&2
	exit 1
fi
BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

# Android 15 devices can have 16 KB pages. r28 and later align for them by
# default; this says so for older NDKs too.
PAGE_ARGS="'-Wl,-z,max-page-size=16384'"

# Quadrate names u8t as a meson wrap, which would clone it. It is placed where
# the wrap would have put it instead, with the build file Quadrate overlays on
# it; the path is in Quadrate's .gitignore, so the submodule stays clean.
rm -rf "$QUADRATE_DIR/subprojects/u8t"
cp -r "$U8T_DIR" "$QUADRATE_DIR/subprojects/u8t"
rm -rf "$QUADRATE_DIR/subprojects/u8t/.git"
cp -r "$QUADRATE_DIR/subprojects/packagefiles/u8t/." "$QUADRATE_DIR/subprojects/u8t/"

mkdir -p "$OUT"

for abi in $ABIS; do
	case "$abi" in
	arm64-v8a) triple=aarch64-linux-android cpu_family=aarch64 cpu=armv8-a ;;
	x86_64) triple=x86_64-linux-android cpu_family=x86_64 cpu=x86_64 ;;
	*)
		echo "Unknown ABI '$abi' (expected arm64-v8a or x86_64)" >&2
		exit 1
		;;
	esac

	echo "=== $abi ==="
	work="$OUT/$abi"
	mkdir -p "$work"

	cat > "$work/cross.ini" <<-EOF
		[binaries]
		c = '$BIN/$triple$API-clang'
		cpp = '$BIN/$triple$API-clang++'
		ar = '$BIN/llvm-ar'
		strip = '$BIN/llvm-strip'
		pkg-config = 'pkg-config'

		[built-in options]
		c_link_args = [$PAGE_ARGS]
		cpp_link_args = [$PAGE_ARGS]

		[host_machine]
		system = 'android'
		cpu_family = '$cpu_family'
		cpu = '$cpu'
		endian = 'little'
	EOF

	echo "--- SDL3"
	cmake -S "$SDL_DIR" -B "$work/sdl-build" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="$abi" \
		-DANDROID_PLATFORM="android-$API" \
		-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON \
		-DCMAKE_BUILD_TYPE=Release \
		-DSDL_SHARED=ON \
		-DSDL_STATIC=OFF \
		-DSDL_TEST_LIBRARY=OFF \
		-DCMAKE_INSTALL_PREFIX="$work/sdl" >/dev/null
	cmake --build "$work/sdl-build"
	cmake --install "$work/sdl-build" >/dev/null

	echo "--- Quadrate"
	# Only math of the standard library is linked, and the others would want
	# OpenSSL and friends built for Android
	quadrate_opts=(
		--cross-file "$work/cross.ini"
		--buildtype=release
		--wrap-mode=nodownload
		-Dbuild_tests=false
		-Dbuild_tools=false
		-Dbuild_compiler=false
		-Dstdlib_modules=math
		-Dwerror=false
	)
	meson setup "$work/quadrate" "$QUADRATE_DIR" "${quadrate_opts[@]}" --reconfigure >/dev/null 2>&1 ||
		meson setup "$work/quadrate" "$QUADRATE_DIR" "${quadrate_opts[@]}" --wipe
	meson compile -C "$work/quadrate" interp qc math rt_static u8t

	# Staged under the names and layout qdos's meson.build links against.
	# Some are thin archives, which point into the build tree, so each is
	# repacked whole.
	stage="$work/quadrate-dist"
	rm -rf "$stage"
	mkdir -p "$stage/lib/quadrate" "$stage/include/quadrate"
	repack() {
		local archive="$1" name="$2"
		local members
		members=$("$BIN/llvm-ar" t "$archive")
		(cd "$(dirname "$archive")" && "$BIN/llvm-ar" rcs "$stage/lib/quadrate/lib$name.a" $members)
	}
	repack "$work/quadrate/lib/interp/libinterp.a" interp
	repack "$work/quadrate/lib/qc/libqc.a" qc
	repack "$work/quadrate/lib/rt/librt_static.a" rt
	repack "$work/quadrate/stdlib/math/libmath.a" math
	repack "$work/quadrate/subprojects/u8t/libu8t.a" u8t
	for mod in lib/interp lib/qc lib/rt stdlib/math; do
		cp -r "$QUADRATE_DIR/$mod/include/quadrate/$(basename "$mod")" "$stage/include/quadrate/"
	done

	echo "--- QDOS"
	qdos_opts=(
		--cross-file "$work/cross.ini"
		--buildtype=release
		-Dsim=true
		-Ddevice=false
		-Dquadrate_src="$QUADRATE_DIR"
		-Dquadrate_dist="$stage"
	)
	export PKG_CONFIG_LIBDIR="$work/sdl/lib/pkgconfig"
	meson setup "$work/qdos" "$QDOS_DIR" "${qdos_opts[@]}" --reconfigure >/dev/null 2>&1 ||
		meson setup "$work/qdos" "$QDOS_DIR" "${qdos_opts[@]}" --wipe
	meson compile -C "$work/qdos" main
	unset PKG_CONFIG_LIBDIR

	libs="$OUT/jniLibs/$abi"
	mkdir -p "$libs"
	cp "$work/sdl/lib/libSDL3.so" "$libs/"
	# Shipped rather than linked in: meson names -lc++ itself, and on the NDK
	# that is the shared one whatever the driver is told
	cp "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$triple/libc++_shared.so" "$libs/"
	"$BIN/llvm-strip" -o "$libs/libmain.so" "$work/qdos/libmain.so"
done

# Only the ABIs asked for this time, or a stale one rides along in the APK
for dir in "$OUT"/jniLibs/*/; do
	case " $ABIS " in
	*" $(basename "$dir") "*) ;;
	*) rm -rf "$dir" ;;
	esac
done

case "$TARGET" in
"") exit 0 ;;
apk) task=assembleDebug ;;
install) task=installDebug ;;
*)
	echo "Unknown target '$TARGET' (expected apk or install)" >&2
	exit 1
	;;
esac

# Gradle 8 runs on neither 11 nor 21+ with this plugin; take 17 when it is there
if [ -z "${JAVA_HOME:-}" ] && [ -d /usr/lib/jvm/java-17-openjdk ]; then
	export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
fi

cd "$ROOT"
./gradlew --no-daemon "-Pr8Native=$OUT" "$task"
