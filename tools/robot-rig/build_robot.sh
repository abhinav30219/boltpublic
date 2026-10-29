#!/bin/bash
# Rebuild App/Resources/Robot.usdz from the Tripo FBX, verify the asset contract, check that SceneKit loads it,
# and render check poses to out/. Any failing step stops the build with a non-zero exit and the log tail.
# Usage: build_robot.sh [fbx] [usdz]   (defaults: assets/robot/source/robot.fbx App/Resources/Robot.usdz)
set -euo pipefail
cd "$(dirname "$0")/../.."
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
R=tools/robot-rig
FBX="${1:-assets/robot/source/robot.fbx}"
USDZ="${2:-App/Resources/Robot.usdz}"
VERIFY_TARGET="${VERIFY_TARGET:-$USDZ}"      # override only to prove verify.py fails the build
mkdir -p $R/out

run() {   # run <name> <cmd...>: log to out/<name>.log, fail loudly with the tail
    local name=$1; shift
    local log=$R/out/$name.log
    local rc=0
    "$@" > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAILED: $name exited with status $rc; tail of $log:" >&2; tail -n 40 "$log" >&2; exit 1
    fi
    if grep -q "Traceback" "$log"; then echo "FAILED: $name raised a Python error; tail of $log:" >&2; tail -n 40 "$log" >&2; exit 1; fi
}

run rig "$BLENDER" -b --factory-startup -P $R/rig.py -- "$FBX" "$USDZ"
grep -E "ROD-DELETE|DELETED|SECTION|DONE" $R/out/rig.log || true
run verify "$BLENDER" -b --factory-startup -P $R/verify.py -- "$VERIFY_TARGET"
grep -E "^OK" $R/out/verify.log
run scenekit xcrun swift $R/scenekit_check.swift "$USDZ"
cat $R/out/scenekit.log
run poses "$BLENDER" -b --factory-startup -P $R/poses.py -- $R/out/robot_rigged.blend $R/out
ls $R/out/pose_*_color.png
