#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Dual-Mode Hash & Verification Tool for Phone Migration
# Modes:
#   1. hash   : Computes deterministic checksums of target directory
#   2. verify : Validates files in target directory against checksum file
# -----------------------------------------------------------------------------

show_usage() {
    cat << EOF
Usage:
  1. Hashing Mode (Old Phone):
     dir-compare hash <directory_path> [output_file] [algorithm: md5|sha256]
     Example: dir-compare hash /sdcard/DCIM /sdcard/Download/dcim_old_phone.md5

  2. Verification Mode (New Phone):
     dir-compare verify <directory_path> <hash_file>
     Example: dir-compare verify /sdcard/DCIM /sdcard/Download/dcim_old_phone.md5

Note:
  If no mode keyword is supplied, the script defaults to 'hash' mode
  for backward compatibility if the first argument is a directory.
EOF
}

# =============================================================================
# HASHING MODE
# =============================================================================
run_hash() {
    if [ "$#" -lt 1 ]; then
        echo "Error: Target directory required for hash mode." >&2
        echo "Usage: dir-compare hash <directory_path> [output_file] [algorithm: md5|sha256]"
        exit 1
    fi

    local target_dir="$1"
    local out_file="${2:-hashes.md5}"
    local algo_arg="${3:-}"

    # Validate target directory
    if [ ! -d "$target_dir" ]; then
        echo "Error: Directory '$target_dir' does not exist." >&2
        exit 1
    fi

    # Resolve absolute paths
    target_dir="$(cd "$target_dir" && pwd)"
    out_file="$(realpath -m "$out_file")"

    # Determine algorithm: explicit arg -> file extension -> default (md5)
    local hash_cmd=""
    if [ -n "$algo_arg" ]; then
        case "${algo_arg,,}" in
            sha256|sha256sum) hash_cmd="sha256sum" ;;
            md5|md5sum)       hash_cmd="md5sum" ;;
            *)
                echo "Error: Unsupported algorithm '$algo_arg'. Use 'md5' or 'sha256'." >&2
                exit 1
                ;;
        esac
    else
        case "${out_file,,}" in
            *.sha256|*.sha256sum) hash_cmd="sha256sum" ;;
            *.md5|*.md5sum)       hash_cmd="md5sum" ;;
            *)                    hash_cmd="md5sum" ;;
        esac
    fi

    # Verify checksum utility exists in PATH
    command -v "$hash_cmd" >/dev/null 2>&1 || {
        echo "Error: Required utility '$hash_cmd' not found in PATH." >&2
        exit 1
    }

    # Ensure destination directory for output file exists
    mkdir -p "$(dirname "$out_file")"

    echo "================================================================="
    echo "  MODE: GENERATE HASHES (OLD PHONE)"
    echo "================================================================="
    echo "[*] Target Directory : $target_dir"
    echo "[*] Output File      : $out_file"
    echo "[*] Hash Engine      : $hash_cmd"
    echo "[*] Scanning and computing hashes..."

    # Change into target directory so hash output contains relative paths (./file.ext)
    cd "$target_dir"

    # Handle self-exclusion if out_file is inside target_dir
    local exclude_out=""
    if [[ "$out_file" == "$target_dir/"* ]]; then
        exclude_out="./${out_file#$target_dir/}"
        echo "[*] Notice: Output file is inside target directory. Excluding '$exclude_out' from scan."
    fi

    local start_time
    start_time=$(date +%s)

    export LC_ALL=C

    # Find & Hash pipeline:
    # 1. '! -name . -name ".*" -prune': Prunes hidden directories/files safely without pruning '.'
    # 2. Excludes out_file if within target_dir
    # 3. '2>/dev/null || true': Ignores Android scoped-storage permission errors without breaking pipefail
    # 4. 'sort -z': Deterministic sorting across different ROMs
    # 5. 'xargs -0 -r "$hash_cmd"': Computes hashes with null-termination
    if [ -n "$exclude_out" ]; then
        (find . ! -name . -name ".*" -prune -o -path "$exclude_out" -prune -o -type f -print0 2>/dev/null || true) \
            | sort -z \
            | xargs -0 -r "$hash_cmd" > "$out_file"
    else
        (find . ! -name . -name ".*" -prune -o -type f -print0 2>/dev/null || true) \
            | sort -z \
            | xargs -0 -r "$hash_cmd" > "$out_file"
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    local file_count
    file_count=$(wc -l < "$out_file" | tr -d ' ')

    echo "[+] Done in ${elapsed}s. Hashed $file_count files."
    echo ""
    echo "================================================================="
    echo "  VERIFICATION ON NEW PHONE:"
    echo "================================================================="
    echo "  1. Transfer '$out_file' to the new phone"
    echo "  2. Run this script in verify mode on the new phone:"
    echo "     dir-compare verify \"$target_dir\" \"$out_file\""
    echo "================================================================="
}

# =============================================================================
# VERIFICATION MODE
# =============================================================================
run_verify() {
    if [ "$#" -lt 2 ]; then
        echo "Error: Both target directory and hash file are required for verify mode." >&2
        echo "Usage: dir-compare verify <directory_path> <hash_file>"
        exit 1
    fi

    local target_dir="$1"
    local hash_file="$2"

    if [ ! -d "$target_dir" ]; then
        echo "Error: Target directory '$target_dir' does not exist." >&2
        exit 1
    fi

    if [ ! -f "$hash_file" ]; then
        echo "Error: Hash file '$hash_file' does not exist or is not a regular file." >&2
        exit 1
    fi

    target_dir="$(cd "$target_dir" && pwd)"
    hash_file="$(realpath "$hash_file")"

    # Auto-detect hash algorithm: check first hash string length in file
    local hash_cmd=""
    local sample_hash
    sample_hash="$(awk 'NR==1 {print $1}' "$hash_file" 2>/dev/null || true)"
    local hash_len="${#sample_hash}"

    if [ "$hash_len" -eq 32 ]; then
        hash_cmd="md5sum"
    elif [ "$hash_len" -eq 64 ]; then
        hash_cmd="sha256sum"
    else
        case "${hash_file,,}" in
            *.sha256|*.sha256sum) hash_cmd="sha256sum" ;;
            *.md5|*.md5sum)       hash_cmd="md5sum" ;;
            *)                    hash_cmd="md5sum" ;;
        esac
    fi

    command -v "$hash_cmd" >/dev/null 2>&1 || {
        echo "Error: Required utility '$hash_cmd' not found in PATH." >&2
        exit 1
    }

    local total_in_file
    total_in_file=$(wc -l < "$hash_file" | tr -d ' ')

    echo "================================================================="
    echo "  MODE: VERIFY INTEGRITY (NEW PHONE)"
    echo "================================================================="
    echo "[*] Target Directory : $target_dir"
    echo "[*] Hash File        : $hash_file"
    echo "[*] Detected Engine  : $hash_cmd"
    echo "[*] Signatures Count : $total_in_file"
    echo "[*] Checking files (only mismatches and missing files will be shown)..."
    echo "-----------------------------------------------------------------"

    cd "$target_dir"
    export LC_ALL=C

    local start_time
    start_time=$(date +%s)
    local verify_failed=0

    # Execute check with --quiet so only failures/corrupted files are displayed
    if ! "$hash_cmd" --quiet -c "$hash_file"; then
        verify_failed=1
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    echo "-----------------------------------------------------------------"
    if [ "$verify_failed" -eq 0 ]; then
        echo "[+] SUCCESS: All $total_in_file files verified perfectly bit-for-bit! (${elapsed}s)"
    else
        echo "[-] FAILED: Checksum mismatches or missing files detected! (${elapsed}s)"
    fi

    # Extra safety audit: count regular non-hidden files in target_dir to check for unlisted files
    local current_count
    current_count=$(find . ! -name . -name ".*" -prune -o -path "./$(basename "$hash_file")" -prune -o -type f -print0 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')

    if [ "$current_count" -gt "$total_in_file" ]; then
        local diff_count=$(( current_count - total_in_file ))
        echo "[!] Warning: Found $diff_count extra unlisted file(s) in target directory ($current_count present vs $total_in_file in hash file)."
    fi
    echo "================================================================="

    return "$verify_failed"
}

# =============================================================================
# CLI DISPATCHER
# =============================================================================
MODE="${1:-}"

case "${MODE,,}" in
    hash|create|generate)
        shift
        run_hash "$@"
        ;;
    verify|check)
        shift
        run_verify "$@"
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    *)
        # Default to hash mode if first argument is an existing directory (backward compatibility)
        if [ -n "$MODE" ] && [ -d "$MODE" ]; then
            run_hash "$@"
        else
            show_usage
            exit 1
        fi
        ;;
esac
