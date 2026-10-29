#!/bin/bash
# Build helpers for Bolt. Usage: scripts/mac_build.sh gen|resolve|build|install|test
# Set DEVICE_ID to your connected iPhone's identifier (xcrun devicectl list devices).
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${DEVICE_ID:-}"
cd "$ROOT" || exit 1
mkdir -p build
run() {
  local step=$1; shift
  echo "RUNNING" > "build/$step.status"
  "$@" > "build/$step.log" 2>&1
  local rc=$?
  echo "DONE $rc" > "build/$step.status"
  return $rc
}
case "$1" in
  gen) run gen xcodegen generate ;;
  resolve) run resolve env GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies -project Bolt.xcodeproj -scheme Bolt -clonedSourcePackagesDirPath build/spm ;;
  build) run build xcodebuild -project Bolt.xcodeproj -scheme Bolt -configuration Debug -destination "id=$DEVICE_ID" -allowProvisioningDeviceRegistration -clonedSourcePackagesDirPath build/spm -derivedDataPath build/dd -allowProvisioningUpdates build ;;
  install) run install xcrun devicectl device install app --device "$DEVICE_ID" build/dd/Build/Products/Debug-iphoneos/Bolt.app ;;
  test) run test bash -c "cd Packages/BoltCore && swift test --scratch-path ../../build/coretest" ;;
  all) "$0" gen && "$0" resolve && "$0" build && "$0" install ;;
  *) echo "Usage: $0 gen|resolve|build|install|test|all" ;;
esac
