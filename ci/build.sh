#!/usr/bin/env bash
# Build AntiDLL for CS:S v34 (episode1 / "original" engine, Linux x86), two variants:
#   sm13: SourceMod 1.13 as shipped by fmu1337/sourcemod-css34 (pinned commit + patch
#         series of the release CSS34_TAG), CDetour on safetyhook -> AntiDLL.ext.2.ep1.so,
#         AntiDLL.smx by that release's spcomp
#   sm17: SourceMod 1.7 SDK (1.7-dev tip) + Metamod 1.10 core-legacy, CDetour on asm.c
#         -> AntiDLL.ext.1.ep1.so, AntiDLL.smx by spcomp 1.7.3
# Runs inside manylinux2014_i686 (devtoolset-10 GCC 10.2.1, glibc 2.17): see
# .github/workflows/css34.yml. Output: dist/antidll-<ver>-{sm13,sm17}-css34-linux.tar.gz
# (cstrike/ layout) + SHA256SUMS.
#
#   ci/build.sh [SRC=repo root] [DIST=SRC/dist]
set -euo pipefail

SRC="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
DIST="${2:-$SRC/dist}"
DEPS="${DEPS:-/tmp/antidll-deps}"
CC="${CC:-gcc}"
CXX="${CXX:-g++}"

# ---- pins ----
CSS34_TAG="1.13.0.7478-mm1.12.0-r7"
CSS34_SM_PKG="sourcemod-1.13.0-git7478-css34-linux.tar.gz"
CSS34_SM_PKG_SHA256="272108114f5862b36b37028ddeed3eade14eea20a204197196a816c83fe1a289"
MM112_COMMIT="4e031eb571f5978eea8207b5d915c9cd0e8d6c58"
HL2SDK_EPISODE1_COMMIT="4b0cde271be6806b95842e78348009712a8b3fbe"
SM17_COMMIT="09045f48978152381408c5f118e4895d2177604a"
SM17_PKG_URL="https://sm.alliedmods.net/smdrop/1.7/sourcemod-1.7.3-git5334-linux.tar.gz"
SM17_PKG_SHA256="1b661b251f716e745dd1c0b73717a4d7e384161d677d5d4c4d19efbbde0cf65f"
MM110_COMMIT="80e8ff0be3b62386bbd6f937e97b819ef8be6dd2"

die() { echo "FAIL: $*" >&2; exit 1; }
gcc_line="$("$CXX" --version | head -1)"
[[ "$(uname -m)" == i686 && "$("$CXX" -dumpmachine)" == i686-* ]] ||
  die "must build for i686 (uname=$(uname -m) dumpmachine=$("$CXX" -dumpmachine))"
VERSION="$(sed -nE 's/^#define SMEXT_CONF_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$SRC/smsdk_config.h")"
[[ -n "$VERSION" ]] || die "no SMEXT_CONF_VERSION in smsdk_config.h"
SRC_COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"

clone_at() { # DIR REPO COMMIT
  rm -rf "$1"; git init -q "$1"
  git -C "$1" remote add origin "$2"
  git -C "$1" fetch -q --depth 1 origin "$3"
  git -C "$1" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$1" rev-parse HEAD)" == "$3" ]] || die "$2: fetched the wrong commit"
}
fetch_sha() { # URL DEST SHA256
  local i
  for i in 1 2 3 4 5 6; do
    curl -fsSL --retry 3 -o "$2" "$1" && break
    [[ $i == 6 ]] && die "download failed: $1"
    echo "retry $i: $1" >&2; sleep 30
  done
  [[ "$(sha256sum "$2" | awk '{print $1}')" == "$3" ]] || die "sha256 mismatch: $1"
}
mkdir -p "$DEPS"

echo "==> HL2SDK episode1 ${HL2SDK_EPISODE1_COMMIT}" >&2
HL2SDK="$DEPS/hl2sdk-episode1"
clone_at "$HL2SDK" https://github.com/alliedmodders/hl2sdk "$HL2SDK_EPISODE1_COMMIT"
# modern GCC: <new.h> -> <new> (same fix as sourcemod-css34 builder/checkout-deps.sh)
sed -i 's|#include <new.h>|#if defined(_WIN32)\n#include <new.h>\n#else\n#include <new>\n#endif|' "$HL2SDK/public/tier0/platform.h"

echo "==> SourceMod 1.13 of sourcemod-css34 ${CSS34_TAG}" >&2
CSS34="$DEPS/sourcemod-css34"
rm -rf "$CSS34"
git clone -q --depth 1 -b "$CSS34_TAG" https://github.com/fmu1337/sourcemod-css34 "$CSS34"
SERIES="$CSS34/builder/patches/series/sm13-latest"
SOURCEMOD_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$SERIES/series.json")"
SOURCEMOD_DIR="$DEPS/sourcemod-1.13"
bash "$CSS34/builder/fetch-sourcemod.sh" "$SOURCEMOD_DIR" "$SOURCEMOD_COMMIT"
bash "$CSS34/builder/patches/apply-series.sh" "$SERIES" "$SOURCEMOD_DIR"
MMS_DIR="$DEPS/mmsource-1.12"
clone_at "$MMS_DIR" https://github.com/alliedmodders/metamod-source "$MM112_COMMIT"
SM13_PKG="$DEPS/sm13-pkg"
rm -rf "$SM13_PKG"; mkdir -p "$SM13_PKG"
fetch_sha "https://github.com/fmu1337/sourcemod-css34/releases/download/${CSS34_TAG}/${CSS34_SM_PKG}" "$DEPS/sm13.tgz" "$CSS34_SM_PKG_SHA256"
tar -xzf "$DEPS/sm13.tgz" -C "$SM13_PKG" addons/sourcemod/scripting
SPCOMP13="$SM13_PKG/addons/sourcemod/scripting/spcomp"

# safetyhook static library, as SourceMod's public/safetyhook/AMBuilder builds it
echo "==> safetyhook (SourceMod 1.13 public/safetyhook)" >&2
SH="$SOURCEMOD_DIR/public/safetyhook"; SHO="$DEPS/safetyhook-obj"
rm -rf "$SHO" "$DEPS/libsafetyhook.a"; mkdir -p "$SHO"
for f in allocator easy inline_hook mid_hook utility vmt_hook os.linux; do
  "$CXX" -m32 -O2 -fPIC -std=c++17 -I"$SH/include" -I"$SH/zydis" -c "$SH/src/$f.cpp" -o "$SHO/$f.o"
done
"$CC" -m32 -O2 -fPIC -I"$SH/include" -I"$SH/zydis" -c "$SH/zydis/Zydis.c" -o "$SHO/Zydis.o"
ar rcs "$DEPS/libsafetyhook.a" "$SHO"/*.o

echo "==> SourceMod 1.7 SDK ${SM17_COMMIT}, Metamod 1.10 ${MM110_COMMIT}, spcomp 1.7.3" >&2
SM17="$DEPS/sourcemod-1.7"
clone_at "$SM17" https://github.com/alliedmodders/sourcemod "$SM17_COMMIT"
MM110="$DEPS/mmsource-1.10"
clone_at "$MM110" https://github.com/alliedmodders/metamod-source "$MM110_COMMIT"
SM17_PKG="$DEPS/sm17-pkg"
rm -rf "$SM17_PKG"; mkdir -p "$SM17_PKG"
fetch_sha "$SM17_PKG_URL" "$DEPS/sm17.tgz" "$SM17_PKG_SHA256"
tar -xzf "$DEPS/sm17.tgz" -C "$SM17_PKG" addons/sourcemod/scripting
SPCOMP17="$SM17_PKG/addons/sourcemod/scripting/spcomp"

# -DSE_<NAME>=<code> for every engine: SourceMod headers compare SOURCE_ENGINE
# against them, and an undefined SE_* would silently be 0.
se_defines_13() {
  python3 - "$SOURCEMOD_DIR/hl2sdk-manifests/manifests" <<'PY'
import json, pathlib, sys
for m in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    d = json.loads(m.read_text())
    if "define" in d and "code" in d:
        print("-DSE_{}={}".format(d["define"], d["code"]))
PY
}
se_defines_17() {
  python3 - "$SM17/AMBuildScript" <<'PY'
import re, sys
for code, define in re.findall(r"SDK\('[^']*',\s*'[^']*',\s*'(\d+)',\s*'(\w+)'", open(sys.argv[1]).read()):
    print("-DSE_{}={}".format(define, code))
PY
}

COMMON=(
  -m32 -O2 -pipe -fPIC -msse -mfpmath=sse -mstackrealign
  -fno-strict-aliasing -fvisibility=hidden -Wall -Wno-unused -Wno-switch
  -Wno-array-bounds -Wno-unknown-pragmas -Wno-narrowing -Wno-unused-result
  -Dstricmp=strcasecmp -D_stricmp=strcasecmp -D_snprintf=snprintf -D_vsnprintf=vsnprintf
  -DHAVE_STDINT_H -DGNUC -DLINUX -D_LINUX -DPOSIX -DCOMPILER_GCC -DNDEBUG
  -DSOURCE_ENGINE=1 -DGAME_DLL
  -I"$SRC"
)
for p in public public/engine public/mathlib public/vstdlib public/tier0 public/tier1 \
         public/toolframework public/dlls game_shared; do
  COMMON+=(-I"$HL2SDK/$p")
done
CXXONLY=(
  -fvisibility-inlines-hidden -fno-threadsafe-statics -Wno-non-virtual-dtor
  -Wno-overloaded-virtual -Wno-delete-non-virtual-dtor -Wno-class-memaccess
  -Wno-packed-not-aligned -Wno-deprecated-declarations -Wno-register
)

# Link: static libstdc++/libgcc, only GetSMExtAPI and the Metamod entry (CreateInterface_MMS on
# MM 1.12 headers, CreateInterface on 1.10 core-legacy) of an SMEXT_CONF_METAMOD extension) exported, everything resolved
# against libc/libm/libdl/libpthread and the server's tier0/vstdlib (-z defs).
link_ext() { # OUT OBJ...
  local out="$1"; shift
  printf '{\n  global: GetSMExtAPI; CreateInterface; CreateInterface_MMS;\n  local: *;\n};\n' >"$(dirname "$out")/exports.map"
  "$CXX" -m32 -shared -o "$out" "$@" \
    -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL \
    -Wl,--version-script="$(dirname "$out")/exports.map" -Wl,-z,defs \
    -Wl,--as-needed -L"$HL2SDK/linux_sdk" -l:tier0_i486.so -l:vstdlib_i486.so \
    -ldl -lpthread -lm
}

# ELF rules of testing/scripts/check-third-party.sh for a standalone .so.
check_elf() { # SO
  local so="$1"
  readelf -h "$so" | grep -q 'Machine:.*80386' || die "$so is not i386"
  if readelf -d "$so" | grep -E 'NEEDED.*(libstdc\+\+|libgcc_s)'; then die "$so needs libstdc++/libgcc_s"; fi
  if readelf -d "$so" | grep -q TEXTREL; then die "$so has DT_TEXTREL"; fi
  local exports
  exports="$(readelf -W --dyn-syms "$so" | awk '$5=="GLOBAL" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u | tr '\n' ' ')"
  [[ "$exports" == "CreateInterface GetSMExtAPI " || "$exports" == "CreateInterface_MMS GetSMExtAPI " ]] ||
    die "$so exports [${exports}], want GetSMExtAPI + the Metamod entry (CreateInterface or CreateInterface_MMS)"
  local maxg
  maxg="$(readelf -W --dyn-syms "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)"
  [[ "$(printf '%s\n2.17\n' "$maxg" | sort -V | tail -1)" == 2.17 ]] || die "$so needs GLIBC_${maxg} > 2.17"
  if readelf -W --dyn-syms "$so" | grep -E 'GLIBCXX_|CXXABI_'; then die "$so imports libstdc++ symbols"; fi
  echo "OK: $(basename "$so"): i386, exports [${exports% }] only, glibc <= 2.17, needs: $(readelf -d "$so" | grep NEEDED | grep -o '\[.*\]' | tr '\n' ' ')" >&2
}

api_of() { sed -nE 's/^[[:space:]]*#define[[:space:]]+SMINTERFACE_EXTENSIONAPI_VERSION[[:space:]]+([0-9]+).*/\1/p' "$1/public/IExtensionSys.h"; }

OUT="$DEPS/antidll-build"
rm -rf "$OUT"; mkdir -p "$OUT/sm13" "$OUT/sm17"

# ---- sm13: this line's SourceMod ----
safetyhook="$(find "$DEPS" -maxdepth 1 -name 'libsafetyhook.a' -o -name 'safetyhook.a' | head -1)"
[[ -n "$safetyhook" ]] || die "no safetyhook static library"
mapfile -t SE13 < <(se_defines_13)
[[ "${#SE13[@]}" -gt 10 ]] || die "cannot read SE_* codes from hl2sdk-manifests"
api13="$(api_of "$SOURCEMOD_DIR")"
echo "==> Compiling AntiDLL.ext.2.ep1.so (SourceMod 1.13 css34 ${CSS34_TAG}, extension API ${api13})" >&2
F13=(
  "${COMMON[@]}" "${SE13[@]}" -D_FILE_OFFSET_BITS=64 -DRAD_TELEMETRY_DISABLED
  -I"$SOURCEMOD_DIR/public" -I"$SOURCEMOD_DIR/public/extensions"
  -I"$SOURCEMOD_DIR/sourcepawn/include" -I"$SOURCEMOD_DIR/public/amtl/amtl"
  -I"$SOURCEMOD_DIR/public/amtl" -I"$SOURCEMOD_DIR/public/safetyhook/include"
  -I"$MMS_DIR/core" -I"$MMS_DIR/core/sourcehook"
)
o13=()
for src in "$SRC/extension.cpp" "$SOURCEMOD_DIR/public/smsdk_ext.cpp" "$SOURCEMOD_DIR/public/CDetour/detours.cpp"; do
  o="$OUT/sm13/$(basename "${src%.cpp}").o"
  "$CXX" "${F13[@]}" "${CXXONLY[@]}" -std=c++20 -c "$src" -o "$o"
  o13+=("$o")
done
link_ext "$OUT/sm13/AntiDLL.ext.2.ep1.so" "${o13[@]}" "$safetyhook"
check_elf "$OUT/sm13/AntiDLL.ext.2.ep1.so"

# ---- sm17: SourceMod 1.7 SDK, Metamod 1.10 core-legacy (1.ep1) ----
# core-legacy/ISmmPlugin.h gives SMM_API default visibility only on GCC 4.x.
# On our GCC 10 it becomes plain extern "C", hiding CreateInterface under
# -fvisibility=hidden. Supply the supported override so Metamod can attach it.
mapfile -t SE17 < <(se_defines_17)
[[ "${#SE17[@]}" -gt 5 ]] || die "cannot read SE_* codes from SM 1.7 AMBuildScript"
api17="$(api_of "$SM17")"
echo "==> Compiling AntiDLL.ext.1.ep1.so (SourceMod 1.7 SDK, extension API ${api17})" >&2
F17=(
  "${COMMON[@]}" "${SE17[@]}"
  '-DSMM_API=extern "C" __attribute__((visibility("default")))'
  -I"$SM17/public" -I"$SM17/public/extensions" -I"$SM17/public/sourcepawn"
  -I"$SM17/public/amtl" -I"$SM17/public/jit" -I"$SM17/public/jit/x86"
  -I"$MM110/core-legacy" -I"$MM110/core-legacy/sourcehook"
)
o17=()
for src in "$SRC/extension.cpp" "$SM17/public/smsdk_ext.cpp" "$SM17/public/CDetour/detours.cpp"; do
  o="$OUT/sm17/$(basename "${src%.cpp}").o"
  "$CXX" "${F17[@]}" "${CXXONLY[@]}" -std=c++14 -fno-exceptions -c "$src" -o "$o"
  o17+=("$o")
done
"$CC" "${F17[@]}" -std=gnu99 -c "$SM17/public/asm/asm.c" -o "$OUT/sm17/asm.o"
o17+=("$OUT/sm17/asm.o")
link_ext "$OUT/sm17/AntiDLL.ext.1.ep1.so" "${o17[@]}"
check_elf "$OUT/sm17/AntiDLL.ext.1.ep1.so"


# ---- plugins ----
echo "==> Compiling AntiDLL.smx (spcomp 1.13 css34 and 1.7.3)" >&2
"$SPCOMP13" -i"$SM13_PKG/addons/sourcemod/scripting/include" -i"$SRC/scripting/include" \
  -o"$OUT/sm13/AntiDLL.smx" "$SRC/scripting/AntiDLL.sp"
"$SPCOMP17" -i"$SM17_PKG/addons/sourcemod/scripting/include" -i"$SRC/scripting/include" \
  -o"$OUT/sm17/AntiDLL.smx" "$SRC/scripting/AntiDLL.sp"

# ---- archives (cstrike/ layout) ----
rm -rf "$DIST"; mkdir -p "$DIST"
for v in sm13 sm17; do
  st="$OUT/stage-$v"; sm="$st/addons/sourcemod"
  rm -rf "$st"; mkdir -p "$sm"/{extensions,plugins,scripting/include,licenses/antidll}
  cp "$OUT/$v"/AntiDLL.ext.*.so "$sm/extensions/"
  cp "$OUT/$v/AntiDLL.smx" "$sm/plugins/"
  cp -r "$SRC/gamedata" "$SRC/configs" "$SRC/data" "$SRC/translations" "$sm/"
  cp "$SRC/scripting/AntiDLL.sp" "$sm/scripting/"
  cp "$SRC/scripting/include/antidll.inc" "$sm/scripting/include/"
  cp "$SRC/LICENSE" "$sm/licenses/antidll/"
  if [[ "$v" == sm13 ]]; then api="$api13"; smc="$SOURCEMOD_COMMIT ($CSS34_TAG)"; else api="$api17"; smc="$SM17_COMMIT"; fi
  python3 - "$sm/licenses/antidll/build.json" "$st" "$v" "$VERSION" "$SRC_COMMIT" "$smc" "$api" "$gcc_line" <<'PY'
import json, os, sys
out, root, v, ver, commit, smc, api, cc = sys.argv[1:9]
files = sorted(os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs)
json.dump({
    "name": "AntiDLL", "variant": v, "version": ver,
    "source": "https://github.com/fmu1337/AntiDLL", "source_commit": commit,
    "sm_commit": smc, "extension_api": int(api), "compiler": cc,
    "files": files + ["addons/sourcemod/licenses/antidll/build.json"],
}, open(out, "w"), indent=2, sort_keys=True)
PY
  tar --owner=0 --group=0 -czf "$DIST/antidll-${VERSION}-${v}-css34-linux.tar.gz" -C "$st" addons
done
(cd "$DIST" && sha256sum -- *.tar.gz > SHA256SUMS && cat SHA256SUMS)
