#!/usr/bin/env bash
set -euo pipefail

# Check for directory argument
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <directory_path> [output_file.sha256]"
    echo "Example: $0 /sdcard/DCIM dcim_old.sha256"
    exit 1
fi

TARGET_DIR="$1"
OUT_FILE="${2:-manifest.sha256}"

# Resolve absolute path
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist." >&2
    exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
OUT_FILE="$(realpath -m "$OUT_FILE")"

echo "[*] Scanning: $TARGET_DIR"
echo "[*] Writing manifest to: $OUT_FILE"

# Change into target directory so all paths in the manifest are relative (./file.ext)
cd "$TARGET_DIR"

# Compute SHA-256 for all regular files, sorted for clean deterministic diffs
find . -type f ! -name ".*" -print0 | sort -z | xargs -0 -r md5sum > "$OUT_FILE"

FILE_COUNT=$(wc -l < "$OUT_FILE")
echo "[+] Done. Hashed $FILE_COUNT files."