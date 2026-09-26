#!/bin/sh
# Prints a directory holding a `ucode` that runs the runtime's .uc scripts
# with the fs module. A ucode already on PATH is used as is; otherwise the
# pinned release is built once into the cache. Building needs git, cmake, a C
# compiler and the json-c headers.

set -eu

version='v0.0.20250529'
commit='be92ebd706339fd4a848b88ee516b1ac4eb62ef8'
cache="${IKEV2_UCODE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ikev2-openwrt/ucode-$version}"

works() {
	printf '%s\n' "import { stdin } from 'fs'; print(type(stdin));" |
		"$1" - 2>/dev/null | grep -qx resource
}

if command -v ucode >/dev/null 2>&1 && works ucode; then
	dirname "$(command -v ucode)"
	exit 0
fi
if [ -x "$cache/bin/ucode" ] && works "$cache/bin/ucode"; then
	printf '%s\n' "$cache/bin"
	exit 0
fi

build="$cache/src"
rm -rf "$build"
mkdir -p "$build" "$cache/bin"
git -C "$build" init -q
git -C "$build" fetch -q --depth 1 https://github.com/jow-/ucode.git "$commit"
git -C "$build" checkout -q FETCH_HEAD
cmake -S "$build" -B "$build/out" -DCMAKE_BUILD_TYPE=Release \
	-DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF \
	-DULOOP_SUPPORT=OFF -DDEBUG_SUPPORT=OFF -DLOG_SUPPORT=OFF -DDIGEST_SUPPORT=OFF \
	-DZLIB_SUPPORT=OFF -DSOCKET_SUPPORT=OFF -DRESOLV_SUPPORT=OFF -DSTRUCT_SUPPORT=OFF \
	-DMATH_SUPPORT=OFF >/dev/null
cmake --build "$build/out" -j 4 >/dev/null
# The interpreter looks for modules beside itself only when told to.
cp "$build/out/ucode" "$cache/bin/ucode.real"
cp "$build/out/fs.so" "$cache/bin/fs.so"
printf '#!/bin/sh\nexec "%s/ucode.real" -L "%s" "$@"\n' "$cache/bin" "$cache/bin" >"$cache/bin/ucode"
chmod 755 "$cache/bin/ucode"
works "$cache/bin/ucode" || {
	printf '%s\n' 'the ucode build does not load the fs module' >&2
	exit 1
}
printf '%s\n' "$cache/bin"
