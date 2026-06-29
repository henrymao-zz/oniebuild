#!/bin/bash
set -euo pipefail

# Generate cloud-init NoCloud datasource config at build time.
# Reads source files from files/etc/ and produces a cloud.cfg.d drop-in
# with embedded user-data (write_files) so cloud-init writes them on
# first boot.

FILES_DIR=""
OUTPUT=""
NOS_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --files-dir) FILES_DIR="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --nos-name) NOS_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${FILES_DIR:?--files-dir is required}"
: "${OUTPUT:?--output is required}"
: "${NOS_NAME:=ubuntu}"

FILES_DIR="$(readlink -f "$FILES_DIR")"
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

# Collect (path, source-file) pairs to embed as write_files entries.
# Each entry: target path inside rootfs | source file relative to FILES_DIR
ENTRIES=(
    "/etc/bird/bird.conf|etc/bird/bird.conf"
)

# Generate YAML for a single write_files entry, indenting file content.
write_entry() {
    local target="$1"
    local src="$2"

    if [[ ! -f "$src" ]]; then
        echo "WARNING: source file not found: $src (skipping)" >&2
        return 0
    fi

    echo "        - path: $target"
    echo "          permissions: '0644'"
    echo "          owner: root:root"
    echo "          content: |"
    # Indent each line of the source file by 12 spaces
    while IFS= read -r line || [[ -n "$line" ]]; do
        echo "            $line"
    done < "$src"
}

{
    echo "datasource:"
    echo "  NoCloud:"
    echo "    user-data: |"
    echo "      #cloud-config"
    echo "      write_files:"

    for entry in "${ENTRIES[@]}"; do
        target="${entry%%|*}"
        rel="${entry#*|}"
        src="$FILES_DIR/$rel"
        write_entry "$target" "$src"
    done

    echo "    meta-data: |"
    echo "      instance-id: ${NOS_NAME,,}"
    echo "      local-hostname: ${NOS_NAME,,}"
} > "$OUTPUT"

echo "Generated cloud-init config: $OUTPUT"
