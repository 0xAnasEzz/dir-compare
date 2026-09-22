#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Dual-Mode Directory Comparison & Verification Tool for Phone Migration
# Modes:
#   1. hash   : Computes deterministic checksums of target directory/directories
#   2. verify : Validates target directory/directories against checksum manifests
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
     dir-compare hash <directory> [output_file] [algorithm: md5|sha256]
     dir-compare hash <dir1,dir2,dir3,...> [algorithm: md5|sha256]
     dir-compare hash <path/{dir1,dir2,...}> [algorithm: md5|sha256]

     ${C_BOLD}Examples:${C_RESET}
       dir-compare hash /sdcard/DCIM
       dir-compare hash Music,Downloads,Documents
       dir-compare hash /sdcard/{Music,Download,Documents}
       dir-compare hash Music,Downloads sha256
       dir-compare hash /sdcard/{Music,Download} sha256

  ${C_CYAN}2. Verification Mode (New Phone):${C_RESET}
     dir-compare verify <directory> [hash_file]
     dir-compare verify <dir1,dir2,dir3,...>
     dir-compare verify <path/{dir1,dir2,...}>

     ${C_BOLD}Examples:${C_RESET}
       dir-compare verify /sdcard/DCIM
       dir-compare verify Music,Downloads,Documents
       dir-compare verify /sdcard/{Music,Download,Documents}

${C_DIM}Note:
  • When multiple directories are specified (comma-separated or brace expansion), each directory
    is processed independently into its own manifest: ./dir-hashes/{folder_name}.md5
  • If no mode keyword is supplied, the script defaults to 'hash' mode.${C_RESET}
EOF
}

# =============================================================================
# SINGLE DIRECTORY HASH FUNCTION
# =============================================================================
hash_single_dir() {
    local raw_target="$1"
    local raw_out="${2:-}"
    local algo_arg="${3:-}"
    local orig_cwd="$4"

    # Validate target directory
    if [ ! -d "$raw_target" ]; then
        echo -e "${C_RED}Error: Directory '$raw_target' does not exist.${C_RESET}" >&2
        return 1
    fi

    # Resolve absolute paths
    local target_dir
    target_dir="$(cd "$raw_target" && pwd)"
    local folder_name
    folder_name="$(basename "$target_dir")"

    local out_file="$raw_out"
    if [ -z "$out_file" ]; then
        out_file="${orig_cwd}/dir-hashes/${folder_name}.md5"
    elif [[ "$out_file" != /* ]]; then
        out_file="${orig_cwd}/${out_file}"
    fi
    out_file="$(realpath -m "$out_file")"

    # Determine algorithm: explicit arg -> file extension -> default (md5)
    local hash_cmd=""
    if [ -n "$algo_arg" ]; then
        case "${algo_arg,,}" in
            sha256|sha256sum) hash_cmd="sha256sum" ;;
            md5|md5sum)       hash_cmd="md5sum" ;;
            *)
                echo -e "${C_RED}Error: Unsupported algorithm '$algo_arg'. Use 'md5' or 'sha256'.${C_RESET}" >&2
                return 1
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
        return 1
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

    # Set return state for multi-dir coordinator
    RET_FILES="$file_count"
    RET_FOLDERS="$folder_count"
    RET_ELAPSED="$elapsed"
    RET_OUT_FILE="$out_file"
    return 0
}

# =============================================================================
# HASHING MODE COORDINATOR (Supports single & multi-directory)
# =============================================================================
run_hash() {
    setup_colors
    local orig_cwd
    orig_cwd="$(pwd)"

    if [ "$#" -lt 1 ]; then
        echo -e "${C_RED}Error: At least one target directory is required for hash mode.${C_RESET}" >&2
        echo "Usage: dir-compare hash <dir1[,dir2,...] | path/{dir1,dir2,...}> [output_file] [algorithm: md5|sha256]"
        exit 1
    fi

    local target_dirs=()
    local custom_out=""
    local custom_algo=""

    # Case 1: First argument contains literal brace expansion syntax (e.g. /sdcard/{Music,Download})
    if [[ "$1" == *"{"*"}"* ]]; then
        eval "local expanded=($1)"
        for d in "${expanded[@]}"; do
            [ -n "$d" ] && target_dirs+=("$d")
        done
        shift

        # Check if next argument is algorithm
        if [ "$#" -ge 1 ]; then
            case "${1,,}" in
                md5|md5sum|sha256|sha256sum)
                    custom_algo="$1"
                    shift
                    ;;
            esac
        fi

    # Case 2: First argument contains a comma -> comma-separated directories
    elif [[ "$1" == *","* ]]; then
        IFS=',' read -ra split_dirs <<< "$1"
        for d in "${split_dirs[@]}"; do
            d="$(echo "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -n "$d" ] && target_dirs+=("$d")
        done
        shift

        # Check if next argument is algorithm
        if [ "$#" -ge 1 ]; then
            case "${1,,}" in
                md5|md5sum|sha256|sha256sum)
                    custom_algo="$1"
                    shift
                    ;;
            esac
        fi

    # Case 3: Shell-expanded brace expansion (multiple directory arguments)
    elif [ "$#" -gt 1 ] && [ -d "${2:-}" ]; then
        while [ "$#" -gt 0 ] && [ -d "$1" ]; do
            target_dirs+=("$1")
            shift
        done

        # Check if trailing argument is algorithm
        if [ "$#" -gt 0 ]; then
            case "${1,,}" in
                md5|md5sum|sha256|sha256sum)
                    custom_algo="$1"
                    shift
                    ;;
            esac
        fi

    # Case 4: Single directory target
    else
        target_dirs+=("$1")
        shift

        # Check for optional [output_file] and/or [algorithm]
        if [ "$#" -gt 0 ]; then
            case "${1,,}" in
                md5|md5sum|sha256|sha256sum)
                    custom_algo="$1"
                    shift
                    ;;
                *)
                    custom_out="$1"
                    shift
                    if [ "$#" -gt 0 ]; then
                        case "${1,,}" in
                            md5|md5sum|sha256|sha256sum)
                                custom_algo="$1"
                                shift
                                ;;
                        esac
                    fi
                    ;;
            esac
        fi
    fi

    local batch_count="${#target_dirs[@]}"
    local batch_results=()
    local batch_total_files=0
    local batch_total_folders=0
    local batch_start_time
    batch_start_time=$(date +%s)
    local batch_failed=0

    local idx=1
    for dir in "${target_dirs[@]}"; do
        cd "$orig_cwd"
        if [ "$batch_count" -gt 1 ]; then
            echo ""
            echo -e "${C_BOLD}=================================================================${C_RESET}"
            echo -e "  ${C_CYAN}${C_BOLD}HASHING DIRECTORY [${idx}/${batch_count}]:${C_RESET} ${C_BOLD}$dir${C_RESET}"
            echo -e "${C_BOLD}=================================================================${C_RESET}"
        fi

        RET_FILES=0
        RET_FOLDERS=0
        RET_ELAPSED=0
        RET_OUT_FILE=""

        if hash_single_dir "$dir" "$custom_out" "$custom_algo" "$orig_cwd"; then
            batch_total_files=$(( batch_total_files + RET_FILES ))
            batch_total_folders=$(( batch_total_folders + RET_FOLDERS ))
            batch_results+=("${C_GREEN}✓${C_RESET} $(basename "$dir") : $(format_num "$RET_FILES") files, $(format_num "$RET_FOLDERS") folders ($(format_duration "$RET_ELAPSED")) -> $RET_OUT_FILE")
        else
            batch_failed=$(( batch_failed + 1 ))
            batch_results+=("${C_RED}✗${C_RESET} $(basename "$dir") : FAILED (Directory not accessible)")
        fi

        idx=$(( idx + 1 ))
    done

    cd "$orig_cwd"

    # Multi-directory batch summary
    if [ "$batch_count" -gt 1 ]; then
        local batch_end_time
        batch_end_time=$(date +%s)
        local batch_elapsed=$(( batch_end_time - batch_start_time ))

        echo ""
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        echo -e "                 ${C_CYAN}${C_BOLD}MULTI-DIRECTORY HASHING SUMMARY${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        for res in "${batch_results[@]}"; do
            echo -e "  $res"
        done
        echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
        echo -e "  • ${C_BOLD}Total Directories :${C_RESET} $batch_count"
        echo -e "  • ${C_BOLD}Total Files       :${C_RESET} $(format_num "$batch_total_files")"
        echo -e "  • ${C_BOLD}Total Folders     :${C_RESET} $(format_num "$batch_total_folders")"
        echo -e "  • ${C_BOLD}Total Time Spent  :${C_RESET} $(format_duration "$batch_elapsed")"
        echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
        if [ "$batch_failed" -eq 0 ]; then
            echo -e "  ${C_BOLD}BATCH STATUS :${C_RESET} ${C_GREEN}${C_BOLD}ALL $batch_count MANIFESTS GENERATED SUCCESSFULLY${C_RESET}"
        else
            echo -e "  ${C_BOLD}BATCH STATUS :${C_RESET} ${C_RED}${C_BOLD}$batch_failed OF $batch_count DIRECTORIES ENCOUNTERED ERRORS${C_RESET}"
        fi
        echo -e "${C_BOLD}=================================================================${C_RESET}"
    fi

    [ "$batch_failed" -eq 0 ] || return 1
}

# =============================================================================
# SINGLE DIRECTORY VERIFICATION FUNCTION
# =============================================================================
verify_single_dir() {
    local raw_target="$1"
    local raw_hash_file="${2:-}"
    local orig_cwd="$3"

    if [ ! -d "$raw_target" ]; then
        echo -e "${C_RED}Error: Target directory '$raw_target' does not exist.${C_RESET}" >&2
        return 1
    fi

    local target_dir
    target_dir="$(cd "$raw_target" && pwd)"
    local folder_name
    folder_name="$(basename "$target_dir")"

    # Resolve hash manifest path
    local hash_file="$raw_hash_file"
    if [ -z "$hash_file" ]; then
        if [ -f "${orig_cwd}/dir-hashes/${folder_name}.md5" ]; then
            hash_file="${orig_cwd}/dir-hashes/${folder_name}.md5"
        elif [ -f "${orig_cwd}/dir-hashes/${folder_name}.sha256" ]; then
            hash_file="${orig_cwd}/dir-hashes/${folder_name}.sha256"
        else
            hash_file="${orig_cwd}/dir-hashes/${folder_name}.md5"
        fi
    elif [[ "$hash_file" != /* ]]; then
        hash_file="${orig_cwd}/${hash_file}"
    fi
    hash_file="$(realpath -m "$hash_file")"

    if [ ! -f "$hash_file" ]; then
        echo -e "${C_RED}Error: Hash file '$hash_file' does not exist or is not a regular file.${C_RESET}" >&2
        return 1
    fi

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
        return 1
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

    local migrated_folders_count
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
    comm -23 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/old_only.txt" || true
    local old_only_count
    old_only_count=$(wc -l < "$tmp_dir/old_only.txt" | tr -d ' ')

    comm -13 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/new_only.txt" || true
    local new_only_count
    new_only_count=$(wc -l < "$tmp_dir/new_only.txt" | tr -d ' ')

    comm -12 "$tmp_dir/orig_paths.txt" "$tmp_dir/current_paths.txt" > "$tmp_dir/common_paths.txt" || true
    local common_count
    common_count=$(wc -l < "$tmp_dir/common_paths.txt" | tr -d ' ')

    # 6. Check signatures for common files
    echo -e "${C_CYAN}[*] Verifying checksums for common files ($(format_num "$common_count") files)...${C_RESET}"

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
    local status_code=0
    echo -e "${C_BOLD}=================================================================${C_RESET}"
    if [ "$mismatch_count" -eq 0 ] && [ "$old_only_count" -eq 0 ] && [ "$new_only_count" -eq 0 ]; then
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_GREEN}${C_BOLD}SUCCESS (100% Bit-for-bit identical!)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        status_code=0
    elif [ "$mismatch_count" -eq 0 ] && [ "$old_only_count" -eq 0 ]; then
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_YELLOW}${C_BOLD}PASS WITH WARNING (All original files intact; extra files found on new phone)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        status_code=0
    else
        echo -e "  ${C_BOLD}OVERALL STATUS :${C_RESET} ${C_RED}${C_BOLD}FAILED ($(format_num "$mismatch_count") mismatches, $(format_num "$old_only_count") missing files)${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        status_code=1
    fi

    # Set return state for multi-dir coordinator
    RET_STATUS="$status_code"
    RET_MISMATCHES="$mismatch_count"
    RET_OLD_ONLY="$old_only_count"
    RET_NEW_ONLY="$new_only_count"
    RET_TOTAL_FILES="$orig_files_count"
    RET_ELAPSED="$elapsed"

    return "$status_code"
}

# =============================================================================
# VERIFICATION MODE COORDINATOR (Supports single & multi-directory)
# =============================================================================
run_verify() {
    setup_colors
    local orig_cwd
    orig_cwd="$(pwd)"

    if [ "$#" -lt 1 ]; then
        echo -e "${C_RED}Error: At least one target directory is required for verify mode.${C_RESET}" >&2
        echo "Usage: dir-compare verify <dir1[,dir2,...] | path/{dir1,dir2,...}> [hash_file]"
        exit 1
    fi

    local target_dirs=()
    local custom_hash_file=""

    # Case 1: First argument contains literal brace expansion syntax (e.g. /sdcard/{Music,Download})
    if [[ "$1" == *"{"*"}"* ]]; then
        eval "local expanded=($1)"
        for d in "${expanded[@]}"; do
            [ -n "$d" ] && target_dirs+=("$d")
        done
        shift

    # Case 2: First argument contains a comma -> comma-separated directories
    elif [[ "$1" == *","* ]]; then
        IFS=',' read -ra split_dirs <<< "$1"
        for d in "${split_dirs[@]}"; do
            d="$(echo "$d" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -n "$d" ] && target_dirs+=("$d")
        done
        shift

    # Case 3: Shell-expanded brace expansion (multiple directory arguments)
    elif [ "$#" -gt 1 ] && [ -d "${2:-}" ]; then
        while [ "$#" -gt 0 ] && [ -d "$1" ]; do
            target_dirs+=("$1")
            shift
        done

    # Case 4: Single directory target
    else
        target_dirs+=("$1")
        shift

        # Check for optional [hash_file]
        if [ "$#" -gt 0 ]; then
            custom_hash_file="$1"
            shift
        fi
    fi

    local batch_count="${#target_dirs[@]}"
    local batch_results=()
    local batch_passed_dirs=0
    local batch_warn_dirs=0
    local batch_failed_dirs=0
    local batch_start_time
    batch_start_time=$(date +%s)

    local idx=1
    for dir in "${target_dirs[@]}"; do
        cd "$orig_cwd"
        if [ "$batch_count" -gt 1 ]; then
            echo ""
            echo -e "${C_BOLD}=================================================================${C_RESET}"
            echo -e "  ${C_CYAN}${C_BOLD}VERIFYING DIRECTORY [${idx}/${batch_count}]:${C_RESET} ${C_BOLD}$dir${C_RESET}"
            echo -e "${C_BOLD}=================================================================${C_RESET}"
        fi

        RET_STATUS=0
        RET_MISMATCHES=0
        RET_OLD_ONLY=0
        RET_NEW_ONLY=0
        RET_TOTAL_FILES=0
        RET_ELAPSED=0

        local v_res=0
        verify_single_dir "$dir" "$custom_hash_file" "$orig_cwd" || v_res=$?

        if [ "$v_res" -eq 0 ] && [ "$RET_NEW_ONLY" -eq 0 ]; then
            batch_passed_dirs=$(( batch_passed_dirs + 1 ))
            batch_results+=("${C_GREEN}✓${C_RESET} $(basename "$dir") : PERFECT MATCH ($(format_num "$RET_TOTAL_FILES") files)")
        elif [ "$v_res" -eq 0 ]; then
            batch_warn_dirs=$(( batch_warn_dirs + 1 ))
            batch_results+=("${C_YELLOW}⚠${C_RESET} $(basename "$dir") : INTACT ($(format_num "$RET_TOTAL_FILES") files, $(format_num "$RET_NEW_ONLY") extra)")
        else
            batch_failed_dirs=$(( batch_failed_dirs + 1 ))
            batch_results+=("${C_RED}✗${C_RESET} $(basename "$dir") : FAILED ($(format_num "$RET_MISMATCHES") mismatches, $(format_num "$RET_OLD_ONLY") missing)")
        fi

        idx=$(( idx + 1 ))
    done

    cd "$orig_cwd"

    # Multi-directory batch summary
    if [ "$batch_count" -gt 1 ]; then
        local batch_end_time
        batch_end_time=$(date +%s)
        local batch_elapsed=$(( batch_end_time - batch_start_time ))

        echo ""
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        echo -e "               ${C_CYAN}${C_BOLD}MULTI-DIRECTORY VERIFICATION SUMMARY${C_RESET}"
        echo -e "${C_BOLD}=================================================================${C_RESET}"
        for res in "${batch_results[@]}"; do
            echo -e "  $res"
        done
        echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
        echo -e "  • ${C_BOLD}Total Directories Checked :${C_RESET} $batch_count"
        echo -e "  • ${C_BOLD}Perfect / Clean Matches   :${C_RESET} ${C_GREEN}$batch_passed_dirs${C_RESET}"
        if [ "$batch_warn_dirs" -gt 0 ]; then
            echo -e "  • ${C_BOLD}Intact with Extra Files   :${C_RESET} ${C_YELLOW}$batch_warn_dirs${C_RESET}"
        fi
        if [ "$batch_failed_dirs" -gt 0 ]; then
            echo -e "  • ${C_BOLD}Failed Directories        :${C_RESET} ${C_RED}${C_BOLD}$batch_failed_dirs${C_RESET}"
        else
            echo -e "  • ${C_BOLD}Failed Directories        :${C_RESET} ${C_GREEN}0${C_RESET}"
        fi
        echo -e "  • ${C_BOLD}Total Time Spent          :${C_RESET} $(format_duration "$batch_elapsed")"
        echo -e "${C_DIM}-----------------------------------------------------------------${C_RESET}"
        if [ "$batch_failed_dirs" -eq 0 ]; then
            echo -e "  ${C_BOLD}OVERALL BATCH STATUS :${C_RESET} ${C_GREEN}${C_BOLD}SUCCESS (All directories verified)${C_RESET}"
        else
            echo -e "  ${C_BOLD}OVERALL BATCH STATUS :${C_RESET} ${C_RED}${C_BOLD}FAILED ($batch_failed_dirs directories had mismatches or missing files)${C_RESET}"
        fi
        echo -e "${C_BOLD}=================================================================${C_RESET}"
    fi

    [ "$batch_failed_dirs" -eq 0 ] || return 1
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
        # Default to hash mode if first argument is a directory, comma-separated list, or brace expansion
        if [ -n "$MODE" ] && ([ -d "$MODE" ] || [[ "$MODE" == *","* ]] || [[ "$MODE" == *"{"*"}"* ]]); then
            run_hash "$@"
        else
            show_usage
            exit 1
        fi
        ;;
esac
