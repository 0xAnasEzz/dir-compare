#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Dual-Mode Directory Comparison & Verification Tool for Phone Migration
# Modes:
#   1. hash   : Computes deterministic checksums of target directory
#   2. verify : Validates target directory against checksum manifest and reports
# -----------------------------------------------------------------------------

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

setup_colors() {
    if [ -t 1 ]; then
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_GREEN="\033[1;32m"
        C_RED="\033[1;31m"
        C_YELLOW="\033[1;33m"
        C_BLUE="\033[1;34m"
        C_CYAN="\033[1;36m"
        C_MAGENTA="\033[1;35m"
    else
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_GREEN=""
        C_RED=""
        C_YELLOW=""
        C_BLUE=""
        C_CYAN=""
        C_MAGENTA=""
    fi
}

format_num() {
    local num="$1"
    echo "$num" | awk '{
        len = length($0)
        res = ""
        for (i = len; i > 0; i--) {
            res = substr($0, i, 1) res
            if ((len - i + 1) % 3 == 0 && i > 1) res = "," res
        }
        print res
    }'
}

format_duration() {
    local total_sec="$1"
    if [ "$total_sec" -lt 60 ]; then
        echo "${total_sec}s"
    elif [ "$total_sec" -lt 3600 ]; then
        local m=$(( total_sec / 60 ))
        local s=$(( total_sec % 60 ))
        echo "${m}m ${s}s (${total_sec}s)"
    else
        local h=$(( total_sec / 3600 ))
        local m=$(( (total_sec % 3600) / 60 ))
        local s=$(( total_sec % 60 ))
        echo "${h}h ${m}m ${s}s (${total_sec}s)"
    fi
}

show_usage() {
    setup_colors
    cat << EOF
${C_BOLD}Usage:${C_RESET}
  ${C_CYAN}1. Hashing Mode (Old Phone):${C_RESET}
     dir-compare hash <directory_path> [output_file] [algorithm: md5|sha256]
     Example: dir-compare hash /sdcard/DCIM /sdcard/Download/dcim_old_phone.md5

  ${C_CYAN}2. Verification Mode (New Phone):${C_RESET}
     dir-compare verify <directory_path> <hash_file>
     Example: dir-compare verify /sdcard/DCIM /sdcard/Download/dcim_old_phone.md5

${C_DIM}Note:
  If no mode keyword is supplied, the script defaults to 'hash' mode
  for backward compatibility if the first argument is a directory.${C_RESET}
EOF
}

# =============================================================================
# HASHING MODE
# =============================================================================
run_hash() {
    setup_colors

    if [ "$#" -lt 1 ]; then
        echo -e "${C_RED}Error: Target directory required for hash mode.${C_RESET}" >&2
        echo "Usage: dir-compare hash <directory_path> [output_file] [algorithm: md5|sha256]"
        exit 1
    fi

    local target_dir="$1"
    local out_file="${2:-hashes.md5}"
    local algo_arg="${3:-}"

    # Validate target directory
    if [ ! -d "$target_dir" ]; then
        echo -e "${C_RED}Error: Directory '$target_dir' does not exist.${C_RESET}" >&2
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
                echo -e "${C_RED}Error: Unsupported algorithm '$algo_arg'. Use 'md5' or 'sha256'.${C_RESET}" >&2
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
        echo -e "${C_RED}Error: Required utility '$hash_cmd' not found in PATH.${C_RESET}" >&2
        exit 1
    }

    # Ensure destination directory for output file exists
    mkdir -p "$(dirname "$out_file")"

    echo -e "${C_CYAN}[*] Target Directory :${C_RESET} $target_dir"
    echo -e "${C_CYAN}[*] Output File      :${C_RESET} $out_file"
    echo -e "${C_CYAN}[*] Hash Engine      :${C_RESET} $hash_cmd"

    # Change into target directory so hash output contains relative paths (./file.ext)
    cd "$target_dir"

    # Handle self-exclusion if out_file is inside target_dir
    local exclude_out=""
    if [[ "$out_file" == "$target_dir/"* ]]; then
        exclude_out="./${out_file#$target_dir/}"
        echo -e "${C_YELLOW}[*] Notice: Output file is inside target directory. Excluding '$exclude_out' from scan.${C_RESET}"
    fi

    echo -e "${C_CYAN}[*] Scanning files and computing hashes...${C_RESET}"
    local start_time
    start_time=$(date +%s)

    export LC_ALL=C

    # Compute hashes for all regular files (including hidden dot-files and folders)
    if [ -n "$exclude_out" ]; then
        (find . -path "$exclude_out" -prune -o -type f -print0 2>/dev/null || true) \
            | sort -z \
            | xargs -0 -r "$hash_cmd" > "$out_file"
    else
        (find . -type f -print0 2>/dev/null || true) \
            | sort -z \
            | xargs -0 -r "$hash_cmd" > "$out_file"
    fi

    # Count total directories in target_dir
    local folder_count
    if [ -n "$exclude_out" ]; then
        folder_count=$(find . ! -name . -path "$exclude_out" -prune -o -type d -print 2>/dev/null | wc -l | tr -d ' ')
    else
        folder_count=$(find . ! -name . -type d -print 2>/dev/null | wc -l | tr -d ' ')
    fi

    local file_count
    file_count=$(grep -c -v '^#' "$out_file" 2>/dev/null || true)

    # Append metadata comment to hash file for verification reference
    echo "# dir-compare-metadata: folders=$folder_count files=$file_count" >> "$out_file"

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # -------------------------------------------------------------------------
    # HASHING REPORT
    # -------------------------------------------------------------------------
    echo ""
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    echo -e "                 ${C_CYAN}${C_BOLD}DIR-COMPARE: HASHING REPORT${C_RESET}"
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    echo -e "  ${C_BOLD}Target Directory :${C_RESET} $target_dir"
    echo -e "  ${C_BOLD}Output File      :${C_RESET} $out_file"
    echo -e "  ${C_BOLD}Hash Engine      :${C_RESET} $hash_cmd"
    echo -e "  ${C_BOLD}Time Spent       :${C_RESET} $(format_duration "$elapsed")"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}RESULTS SUMMARY${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  • ${C_BOLD}Total Files Hashed :${C_RESET} $(format_num "$file_count")"
    echo -e "  • ${C_BOLD}Total Folders      :${C_RESET} $(format_num "$folder_count")"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}STATUS :${C_RESET} ${C_GREEN}SUCCESS (Manifest generated successfully)${C_RESET}"
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    echo -e "  ${C_BOLD}NEXT STEPS (VERIFICATION ON NEW PHONE):${C_RESET}"
    echo -e "  1. Transfer the hash file to the new phone:"
    echo -e "     ${C_CYAN}$out_file${C_RESET}"
    echo -e "  2. In Termux on the new phone, run:"
    echo -e "     ${C_CYAN}dir-compare verify \"$target_dir\" \"$out_file\"${C_RESET}"
    echo -e "${C_BOLD}=================================================================${C_RESET}"
}

# =============================================================================
# VERIFICATION MODE
# =============================================================================
run_verify() {
    setup_colors

    if [ "$#" -lt 2 ]; then
        echo -e "${C_RED}Error: Both target directory and hash file are required for verify mode.${C_RESET}" >&2
        echo "Usage: dir-compare verify <directory_path> <hash_file>"
        exit 1
    fi

    local target_dir="$1"
    local hash_file="$2"

    if [ ! -d "$target_dir" ]; then
        echo -e "${C_RED}Error: Target directory '$target_dir' does not exist.${C_RESET}" >&2
        exit 1
    fi

    if [ ! -f "$hash_file" ]; then
        echo -e "${C_RED}Error: Hash file '$hash_file' does not exist or is not a regular file.${C_RESET}" >&2
        exit 1
    fi

    target_dir="$(cd "$target_dir" && pwd)"
    hash_file="$(realpath "$hash_file")"

    # Auto-detect hash algorithm: check first signature length in file
    local hash_cmd=""
    local sample_hash
    sample_hash="$(grep -v '^#' "$hash_file" | head -n 1 | awk '{print $1}' | sed 's/^\\//' 2>/dev/null || true)"
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
        echo -e "${C_RED}Error: Required utility '$hash_cmd' not found in PATH.${C_RESET}" >&2
        exit 1
    }

    echo -e "${C_CYAN}[*] Target Directory :${C_RESET} $target_dir"
    echo -e "${C_CYAN}[*] Hash Manifest    :${C_RESET} $hash_file"
    echo -e "${C_CYAN}[*] Hash Engine      :${C_RESET} $hash_cmd"
    echo -e "${C_CYAN}[*] Scanning filesystem and comparing structures...${C_RESET}"

    local start_time
    start_time=$(date +%s)

    export LC_ALL=C

    # Create temporary working directory for intermediate lists
    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'dircompare.XXXXXX')
    trap 'rm -rf "$tmp_dir"' EXIT

    # 1. Clean manifest (strip comment/metadata lines)
    grep -v '^#' "$hash_file" > "$tmp_dir/orig_manifest.txt" || true
    local orig_files_count
    orig_files_count=$(wc -l < "$tmp_dir/orig_manifest.txt" | tr -d ' ')

    # 2. Extract original folders count from metadata comment or derive from file paths
    local orig_folders_count
    orig_folders_count=$(grep -m1 '^# dir-compare-metadata:.*folders=' "$hash_file" 2>/dev/null | sed -E 's/.*folders=([0-9]+).*/\1/' || true)

    if [ -z "$orig_folders_count" ]; then
        orig_folders_count=$(awk '{
            sub(/^\\?[a-fA-F0-9]{32,64} [* ]/, "")
            d = $0
            while (sub(/\/[^\/]*$/, "", d) && d != "" && d != ".") {
                dirs[d] = 1
            }
        }
        END {
            cnt = 0
            for (d in dirs) cnt++
            print cnt
        }' "$tmp_dir/orig_manifest.txt")
    fi

    # 3. Extract and sort original relative file paths
    awk '{
        sub(/^\\?[a-fA-F0-9]{32,64} [* ]/, "")
        if ($0 !~ /^\.\// && $0 !~ /^\//) {
            $0 = "./" $0
        }
        print
    }' "$tmp_dir/orig_manifest.txt" | sort > "$tmp_dir/orig_paths.txt"

    # 4. Scan current filesystem in target_dir
    cd "$target_dir"

    local exclude_verify_hash=""
    if [[ "$hash_file" == "$target_dir/"* ]]; then
        exclude_verify_hash="./${hash_file#$target_dir/}"
    fi

    if [ -n "$exclude_verify_hash" ]; then
        (find . -path "$exclude_verify_hash" -prune -o -type f -print 2>/dev/null || true) | sort > "$tmp_dir/current_paths.txt"
        migrated_folders_count=$(find . ! -name . -path "$exclude_verify_hash" -prune -o -type d -print 2>/dev/null | wc -l | tr -d ' ')
    else
        (find . -type f -print 2>/dev/null || true) | sort > "$tmp_dir/current_paths.txt"
        migrated_folders_count=$(find . ! -name . -type d -print 2>/dev/null | wc -l | tr -d ' ')
    fi

    local migrated_files_count
    migrated_files_count=$(wc -l < "$tmp_dir/current_paths.txt" | tr -d ' ')

    # 5. Determine sets via comm
    # Files in old phone only (missing on new phone)
    comm -23 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/old_only.txt" || true
    local old_only_count
    old_only_count=$(wc -l < "$tmp_dir/old_only.txt" | tr -d ' ')

    # Files in new phone only (extra on new phone)
    comm -13 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/new_only.txt" || true
    local new_only_count
    new_only_count=$(wc -l < "$tmp_dir/new_only.txt" | tr -d ' ')

    # Files existing in both phones
    comm -12 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/common_paths.txt" || true
    local common_count
    common_count=$(wc -l < "$tmp_dir/common_paths.txt" | tr -d ' ')

    # 6. Check signatures for common files
    echo -e "${C_CYAN}[*] Verifying checksums for common files ($(format_num "$common_count") files)...${C_RESET}"

    # Build manifest containing only common files to verify
    awk 'NR==FNR { common[$0]=1; next }
    {
        line = $0
        sub(/^\\?[a-fA-F0-9]{32,64} [* ]/, "")
        if ($0 !~ /^\.\// && $0 !~ /^\//) {
            $0 = "./" $0
        }
        if ($0 in common) print line
    }' "$tmp_dir/common_paths.txt" "$tmp_dir/orig_manifest.txt" > "$tmp_dir/common_manifest.txt"

    # Suppress raw hashing mismatch errors from terminal by redirecting to temporary log
    touch "$tmp_dir/mismatches.txt"
    touch "$tmp_dir/matches.txt"

    if [ "$common_count" -gt 0 ]; then
        "$hash_cmd" -c "$tmp_dir/common_manifest.txt" > "$tmp_dir/check_raw.txt" 2>&1 || true

        # Extract mismatches and matches cleanly
        grep ': FAILED$' "$tmp_dir/check_raw.txt" | sed 's/: FAILED$//' > "$tmp_dir/mismatches.txt" || true
        grep ': OK$' "$tmp_dir/check_raw.txt" | sed 's/: OK$//' > "$tmp_dir/matches.txt" || true
    fi

    local mismatch_count
    mismatch_count=$(wc -l < "$tmp_dir/mismatches.txt" | tr -d ' ')

    local perfect_count
    perfect_count=$(wc -l < "$tmp_dir/matches.txt" | tr -d ' ')

    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # -------------------------------------------------------------------------
    # VERIFICATION REPORT
    # -------------------------------------------------------------------------
    echo ""
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    echo -e "               ${C_CYAN}${C_BOLD}DIR-COMPARE: VERIFICATION REPORT${C_RESET}"
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    echo -e "  ${C_BOLD}Target Directory :${C_RESET} $target_dir"
    echo -e "  ${C_BOLD}Hash Manifest    :${C_RESET} $hash_file"
    echo -e "  ${C_BOLD}Hash Engine      :${C_RESET} $hash_cmd"
    echo -e "  ${C_BOLD}Time Spent       :${C_RESET} $(format_duration "$elapsed")"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}ORIGINAL VS MIGRATED FILESYSTEM${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}Original State (Old Phone) :${C_RESET}"
    echo -e "    • Total Hashed Files     : $(format_num "$orig_files_count")"
    echo -e "    • Total Folders          : $(format_num "$orig_folders_count")"
    echo ""
    echo -e "  ${C_BOLD}Migrated State (New Phone) :${C_RESET}"
    echo -e "    • Total Migrated Files   : $(format_num "$migrated_files_count")"
    echo -e "    • Total Migrated Folders : $(format_num "$migrated_folders_count")"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}INTEGRITY COMPARISON BREAKDOWN${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"

    if [ "$perfect_count" -gt 0 ]; then
        echo -e "  • ${C_BOLD}Perfect Matches          :${C_RESET} ${C_GREEN}$(format_num "$perfect_count")${C_RESET}"
    else
        echo -e "  • ${C_BOLD}Perfect Matches          :${C_RESET} $(format_num "$perfect_count")"
    fi

    if [ "$mismatch_count" -gt 0 ]; then
        echo -e "  • ${C_BOLD}Signature Mismatches     :${C_RESET} ${C_RED}${C_BOLD}$(format_num "$mismatch_count")${C_RESET}"
    else
        echo -e "  • ${C_BOLD}Signature Mismatches     :${C_RESET} ${C_GREEN}0${C_RESET}"
    fi

    if [ "$old_only_count" -gt 0 ]; then
        echo -e "  • ${C_BOLD}Old Phone Only (Missing) :${C_RESET} ${C_RED}${C_BOLD}$(format_num "$old_only_count")${C_RESET}"
    else
        echo -e "  • ${C_BOLD}Old Phone Only (Missing) :${C_RESET} ${C_GREEN}0${C_RESET}"
    fi

    if [ "$new_only_count" -gt 0 ]; then
        echo -e "  • ${C_BOLD}New Phone Only (Extra)   :${C_RESET} ${C_YELLOW}$(format_num "$new_only_count")${C_RESET}"
    else
        echo -e "  • ${C_BOLD}New Phone Only (Extra)   :${C_RESET} ${C_GREEN}0${C_RESET}"
    fi

    # -------------------------------------------------------------------------
    # DETAILED FILE LISTS
    # -------------------------------------------------------------------------
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
    echo -e "  ${C_BOLD}DETAILED FILE LISTS${C_RESET}"
    echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"

    # 1. Signature Mismatches
    if [ "$mismatch_count" -gt 0 ]; then
        echo -e "  ${C_RED}${C_BOLD}[!] SIGNATURE MISMATCHES ($(format_num "$mismatch_count") files):${C_RESET}"
        echo -e "      ${C_DIM}(Files exist on both phones, but checksums do not match)${C_RESET}"
        echo -e "      ${C_DIM}---------------------------------------------------------${C_RESET}"
        while IFS= read -r file; do
            echo -e "      ${C_RED}• $file${C_RESET}"
        done < "$tmp_dir/mismatches.txt"
    else
        echo -e "  ${C_GREEN}[✓] SIGNATURE MISMATCHES : None (All common files match bit-for-bit)${C_RESET}"
    fi
    echo ""

    # 2. Old Phone Only (Missing)
    if [ "$old_only_count" -gt 0 ]; then
        echo -e "  ${C_RED}${C_BOLD}[!] OLD PHONE ONLY / MISSING ($(format_num "$old_only_count") files):${C_RESET}"
        echo -e "      ${C_DIM}(Files recorded in manifest but missing on new phone)${C_RESET}"
        echo -e "      ${C_DIM}---------------------------------------------------------${C_RESET}"
        while IFS= read -r file; do
            echo -e "      ${C_RED}• $file${C_RESET}"
        done < "$tmp_dir/old_only.txt"
    else
        echo -e "  ${C_GREEN}[✓] OLD PHONE ONLY / MISSING : None (No files were lost in transit)${C_RESET}"
    fi
    echo ""

    # 3. New Phone Only (Extra)
    if [ "$new_only_count" -gt 0 ]; then
        echo -e "  ${C_YELLOW}${C_BOLD}[?] NEW PHONE ONLY / EXTRA ($(format_num "$new_only_count") files):${C_RESET}"
        echo -e "      ${C_DIM}(Files present on new phone but absent from original manifest)${C_RESET}"
        echo -e "      ${C_DIM}---------------------------------------------------------${C_RESET}"
        while IFS= read -r file; do
            echo -e "      ${C_YELLOW}• $file${C_RESET}"
        done < "$tmp_dir/new_only.txt"
    else
        echo -e "  ${C_GREEN}[✓] NEW PHONE ONLY / EXTRA : None (No untracked extra files)${C_RESET}"
    fi

    # -------------------------------------------------------------------------
    # OVERALL STATUS BANNER
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    if [ "$mismatch_count" -eq 0 ] && [ "$old_only_count" -eq 0 ] && [ "$new_only_count" -eq 0 ]; then
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_GREEN}${C_BOLD}SUCCESS (100% Bit-for-bit identical!)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        return 0
    elif [ "$mismatch_count" -eq 0 ] && [ "$old_only_count" -eq 0 ]; then
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_YELLOW}${C_BOLD}PASS WITH WARNING (All original files intact; extra files found on new phone)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        return 0
    else
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_RED}${C_BOLD}FAILED ($(format_num "$mismatch_count") mismatches, $(format_num "$old_only_count") missing files)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        return 1
    fi
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
