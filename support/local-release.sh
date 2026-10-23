#!/usr/bin/env bash
# Local equivalent of .github/workflows/build-release.yml: builds Metamod:Source for
# Linux and Windows in Docker on this machine and, with --upload, publishes the
# packages to this fork's GitHub releases.
#
# Usage: support/local-release.sh [--upload] [--clobber] [--targets linux,windows] [--sdks cs2]
#
#   --upload    create/update the GitHub release for this version and attach the packages
#   --clobber   with --upload, replace assets that already exist on the release
#   --targets   comma list of linux,windows (default: both)
#   --sdks      comma list for configure.py --sdks (default: cs2)
#
# Linux builds in the same container the workflow uses (debian11-clang22). Windows builds
# with real MSVC under Wine (the msvc-wine image from cs2-build-system/msvc-wine-runner):
# AMBuild only picks MSVC on a Windows host, so it runs under a Windows Python there.
#
# Output: build-release/mmsource-<version>-git<rev>-{linux.tar.gz,windows.zip}
# Cache:  ${XDG_CACHE_HOME:-~/.cache}/mms-local-release (SDKs, AMBuild, Windows Python)
set -euo pipefail

UPLOAD=0
CLOBBER=0
TARGETS="linux,windows"
SDKS="cs2"
while [ $# -gt 0 ]; do
	case "$1" in
		--upload)  UPLOAD=1 ;;
		--clobber) CLOBBER=1 ;;
		--targets) TARGETS="$2"; shift ;;
		--sdks)    SDKS="$2"; shift ;;
		-h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "Unknown argument '$1' (see --help)" >&2; exit 1 ;;
	esac
	shift
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mms-local-release"
OUT="$REPO/build-release"
LINUX_IMAGE="${LINUX_IMAGE:-ghcr.io/alliedmodders/build-containers/debian11-clang22:latest}"
MSVC_IMAGE="${MSVC_IMAGE:-msvc-wine:latest}"
GH_REPO="${GH_REPO:-mrc4tt/metamod-source}"
WINPY_VERSION=3.12.7

# Same version scheme as the workflow's Package step.
version_base=$(cat "$REPO/product.version")
version_base=${version_base%-dev}
version_rev=$(git -C "$REPO" rev-list --count HEAD)
version="${version_base}.${version_rev}"
expanded_version="${version_base}-git${version_rev}"
commit=$(git -C "$REPO" rev-parse HEAD)
shorthash=$(git -C "$REPO" rev-parse --short HEAD)

echo "==> Metamod:Source $version ($shorthash), sdks=$SDKS targets=$TARGETS"

if [ "$UPLOAD" = "1" ]; then
	command -v gh >/dev/null || { echo "ERROR: --upload needs the gh CLI" >&2; exit 1; }
	# The release tag points at this commit, so GitHub has to know it.
	if [ -z "$(git -C "$REPO" branch -r --contains "$commit" 2>/dev/null)" ]; then
		echo "ERROR: $shorthash is not on any remote branch; push it before --upload" >&2
		exit 1
	fi
fi

git -C "$REPO" submodule update --init --recursive

# Dependencies: cs2 comes from our hl2sdk fork, the other Source 2 SDKs from s2sdk and the
# rest from hl2sdk, matching support/checkout-deps.sh otherwise.
mkdir -p "$CACHE/deps" "$OUT"
fetch_ref() {
	local repo="$1" ref="$2" dir="$3"
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$repo"
	fi
	git -C "$dir" fetch -q --depth 1 origin "$ref"
	git -C "$dir" checkout -q -f FETCH_HEAD
}
IFS=',' read -ra sdk_list <<< "$SDKS"
for sdk in "${sdk_list[@]}"; do
	case "$sdk" in
		cs2)           repo=https://github.com/mrc4tt/hl2sdk ;;
		dota|deadlock) repo=https://github.com/alliedmodders/s2sdk ;;
		*)             repo=https://github.com/alliedmodders/hl2sdk ;;
	esac
	echo "==> hl2sdk-$sdk ($repo $sdk)"
	fetch_ref "$repo" "$sdk" "$CACHE/deps/hl2sdk-$sdk"
done

# AMBuild from source for both platforms, so Linux and Windows run the same version.
if [ ! -d "$CACHE/ambuild/.git" ]; then
	git clone -q --depth 1 https://github.com/alliedmodders/ambuild "$CACHE/ambuild"
else
	git -C "$CACHE/ambuild" pull -q --ff-only
fi

# git cannot be run from the Windows Python, so generate_headers.py gets the values from here.
GIT_ENV=(
	-e MMS_GIT_REVISION_COUNT="$version_rev"
	-e MMS_GIT_SHORTHASH="$shorthash"
	-e MMS_GIT_LONGHASH="$commit"
)

build_linux() {
	local file="mmsource-${expanded_version}-linux.tar.gz"
	echo "==> Building linux"
	docker run --rm \
		-v "$REPO:/src:ro" \
		-v "$CACHE/deps:/deps:ro" \
		-v "$CACHE/ambuild:/ambuild:ro" \
		-v "$OUT:/out" \
		"${GIT_ENV[@]}" \
		"$LINUX_IMAGE" \
		bash -euo pipefail -c "
			export PYTHONPATH=/ambuild
			rm -rf /work && cp -r /src /work && mkdir /work/build && cd /work/build
			python3 ../configure.py --enable-optimize --sdks=$SDKS --targets=x86_64 --hl2sdk-root=/deps
			python3 -c 'import ambuild2.run as r; r.cli_run()'
			cd package && tar zcf /out/$file addons
			chown $(id -u):$(id -g) /out/$file"
	echo "==> linux OK: $OUT/$file"
}

build_windows() {
	local file="mmsource-${expanded_version}-windows.zip"
	docker image inspect "$MSVC_IMAGE" >/dev/null 2>&1 || {
		echo "ERROR: $MSVC_IMAGE not found; build it from cs2-build-system/msvc-wine-runner (docker build -t msvc-wine .)" >&2
		exit 1
	}
	if [ ! -f "$CACHE/winpy/tools/python.exe" ]; then
		echo "==> Fetching Windows Python $WINPY_VERSION"
		mkdir -p "$CACHE/winpy"
		curl -fsSL -o "$CACHE/winpy/python.nupkg" "https://www.nuget.org/api/v2/package/python/$WINPY_VERSION"
		python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
			"$CACHE/winpy/python.nupkg" "$CACHE/winpy"
	fi
	echo "==> Building windows"
	# Wine's Python cannot open its standard streams when they are redirected to a file,
	# so its output always goes through a pipe.
	docker run --rm \
		-v "$REPO:/src:ro" \
		-v "$CACHE/deps:/deps:ro" \
		-v "$CACHE/ambuild:/ambuild:ro" \
		-v "$CACHE/winpy:/winpy:ro" \
		-v "$OUT:/out" \
		"${GIT_ENV[@]}" \
		"$MSVC_IMAGE" \
		bash -euo pipefail -c "
			. /opt/msvc/bin/x64/msvcenv.sh
			export WINEDEBUG=-all PYTHONPATH='Z:\\ambuild' CC=cl CXX=cl
			rm -rf /work && cp -r /src /work && mkdir /work/build && cd /work/build
			wine /winpy/tools/python.exe 'Z:\\work\\configure.py' --enable-optimize --sdks=$SDKS --targets=x86_64 '--hl2sdk-root=Z:\\deps' 2>&1 | cat
			wine /winpy/tools/python.exe -c 'import ambuild2.run as r; r.cli_run()' 2>&1 | cat
			test -d package/addons
			rm -rf /out/win-package && cp -r package /out/win-package
			chown -R $(id -u):$(id -g) /out/win-package"
	rm -f "$OUT/$file"
	(cd "$OUT/win-package" && python3 -c 'import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
	for root, _, files in os.walk("addons"):
		for f in files:
			z.write(os.path.join(root, f))' "$OUT/$file")
	rm -rf "$OUT/win-package"
	echo "==> windows OK: $OUT/$file"
}

files=()
IFS=',' read -ra target_list <<< "$TARGETS"
for target in "${target_list[@]}"; do
	case "$target" in
		linux)   build_linux;   files+=("$OUT/mmsource-${expanded_version}-linux.tar.gz") ;;
		windows) build_windows; files+=("$OUT/mmsource-${expanded_version}-windows.zip") ;;
		*) echo "Unknown target '$target' (use linux, windows)" >&2; exit 1 ;;
	esac
done

if [ "$UPLOAD" = "1" ]; then
	branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
	if gh release view "$version" --repo "$GH_REPO" >/dev/null 2>&1; then
		echo "==> Release $version exists, uploading assets"
	else
		# Like the workflow: master builds are prereleases, x.y-dev branches are marked latest.
		flags=(--generate-notes --target "$commit")
		if [ "$branch" = "master" ]; then flags+=(--prerelease --latest=false); fi
		echo "==> Creating release $version on $GH_REPO"
		gh release create "$version" --repo "$GH_REPO" --title "$version" "${flags[@]}"
	fi
	upload_flags=()
	[ "$CLOBBER" = "1" ] && upload_flags+=(--clobber)
	gh release upload "$version" --repo "$GH_REPO" "${upload_flags[@]}" "${files[@]}"
	echo "==> Uploaded to https://github.com/$GH_REPO/releases/tag/$version"
fi

echo "==> Done:"
printf '    %s\n' "${files[@]}"
