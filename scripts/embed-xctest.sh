#!/bin/bash
set -euo pipefail

APP="${1:?usage: embed-xctest.sh /path/to/App.app}"
DEVELOPER_DIR="$(xcode-select -p)"
PLATFORM_DEV="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer"
DEST="$APP/Frameworks"

mkdir -p "$DEST"

QUEUE_FILE="$(mktemp)"
SEEN_FILE="$(mktemp)"
trap 'rm -f "$QUEUE_FILE" "$SEEN_FILE"' EXIT

framework_binary() {
  local fw="$1"
  local exe
  exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$fw/Info.plist" 2>/dev/null || basename "$fw" .framework)
  printf '%s/%s\n' "$fw" "$exe"
}

copy_framework() {
  local src="$1"
  local name
  name="$(basename "$src")"
  if grep -Fqx "$name" "$SEEN_FILE" 2>/dev/null; then return 0; fi
  printf "%s\n" "$name" >> "$SEEN_FILE"
  echo "Embedding framework: $name"
  rm -rf "$DEST/$name"
  /usr/bin/ditto "$src" "$DEST/$name"
  rm -rf "$DEST/$name/_CodeSignature" || true
  framework_binary "$DEST/$name" >> "$QUEUE_FILE"
}

copy_dylib() {
  local src="$1"
  local name
  name="$(basename "$src")"
  if grep -Fqx "$name" "$SEEN_FILE" 2>/dev/null; then return 0; fi
  printf "%s\n" "$name" >> "$SEEN_FILE"
  echo "Embedding dylib: $name"
  cp -f "$src" "$DEST/$name"
  chmod u+w "$DEST/$name"
  printf "%s\n" "$DEST/$name" >> "$QUEUE_FILE"
}

find_framework() {
  local name="$1"
  local p
  for p in "$PLATFORM_DEV/Library/Frameworks/$name" "$PLATFORM_DEV/Library/PrivateFrameworks/$name"; do
    [[ -d "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

find_dylib() {
  local name="$1"
  local p
  for p in "$PLATFORM_DEV/usr/lib/$name" "$PLATFORM_DEV/Library/PrivateFrameworks/$name"; do
    [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# Seed the XCTest/XCUI stack. Missing optional frameworks are ignored.
for fw in   XCTest.framework   XCTestCore.framework   XCTAutomationSupport.framework   XCUIAutomation.framework
do
  if src="$(find_framework "$fw")"; then
    copy_framework "$src"
  fi
done

# Walk developer-only dependencies recursively.
idx=1
while :; do
  bin="$(sed -n "${idx}p" "$QUEUE_FILE")"
  [[ -n "$bin" ]] || break
  idx=$((idx + 1))
  [[ -f "$bin" ]] || continue
  chmod u+w "$bin" || true

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    rel=""

    if [[ "$dep" =~ ^@rpath/(.+\.framework/.+)$ ]]; then
      rel="${BASH_REMATCH[1]}"
      fw="${rel%%.framework/*}.framework"
      if src="$(find_framework "$fw" 2>/dev/null)"; then
        copy_framework "$src"
      fi
    elif [[ "$dep" =~ ^/Developer/Library/(Frameworks|PrivateFrameworks)/(.+\.framework/.+)$ ]]; then
      rel="${BASH_REMATCH[2]}"
      fw="${rel%%.framework/*}.framework"
      if src="$(find_framework "$fw" 2>/dev/null)"; then
        copy_framework "$src"
        install_name_tool -change "$dep" "@rpath/$rel" "$bin" || true
      fi
    elif [[ "$dep" =~ ^/System/Developer/Library/(Frameworks|PrivateFrameworks)/(.+\.framework/.+)$ ]]; then
      rel="${BASH_REMATCH[2]}"
      fw="${rel%%.framework/*}.framework"
      if src="$(find_framework "$fw" 2>/dev/null)"; then
        copy_framework "$src"
        install_name_tool -change "$dep" "@rpath/$rel" "$bin" || true
      fi
    elif [[ "$dep" =~ ^@rpath/([^/]+\.dylib)$ ]]; then
      dylib="${BASH_REMATCH[1]}"
      if src="$(find_dylib "$dylib" 2>/dev/null)"; then
        copy_dylib "$src"
      fi
    elif [[ "$dep" =~ ^/Developer/usr/lib/([^/]+\.dylib)$ ]]; then
      dylib="${BASH_REMATCH[1]}"
      if src="$(find_dylib "$dylib" 2>/dev/null)"; then
        copy_dylib "$src"
        install_name_tool -change "$dep" "@rpath/$dylib" "$bin" || true
      fi
    fi
  done < <(otool -L "$bin" | tail -n +2 | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

echo "Embedded developer payload:"
du -sh "$DEST"
find "$DEST" -maxdepth 1 -mindepth 1 -print | sort

# Validate unresolved /Developer links. Weak load commands are intentionally
# tolerated by dyld when absent; only unresolved strong dependencies fail CI.
bad=0
while IFS= read -r bin; do
  [[ -f "$bin" ]] || continue
  if file "$bin" | grep -q 'Mach-O'; then
    deps="$(otool -L "$bin" | grep -E '[[:space:]]+/(System/)?Developer/' || true)"
    [[ -n "$deps" ]] || continue
    strong="$(printf '%s\n' "$deps" | grep -v ', weak)' || true)"
    weak="$(printf '%s\n' "$deps" | grep ', weak)' || true)"
    if [[ -n "$weak" ]]; then
      echo "WARN: unresolved weak Developer dependency in $bin"
      printf '%s\n' "$weak"
    fi
    if [[ -n "$strong" ]]; then
      echo "ERROR: unresolved strong Developer dependency in $bin"
      printf '%s\n' "$strong"
      bad=1
    fi
  fi
done < <(find "$DEST" -type f)

exit "$bad"
