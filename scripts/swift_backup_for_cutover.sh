#!/usr/bin/env bash
# Create an explicit, non-destructive pre-cutover backup from a chosen data source.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIRECTORY=""
DATASET_FILE=""
DESTINATION=""
CANDIDATE_VERSION=""

usage() {
    echo "Usage: $0 --source-dir PATH --destination PATH --candidate-version VERSION [--dataset PATH]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-dir)
            SOURCE_DIRECTORY="${2:-}"
            shift 2
            ;;
        --dataset)
            DATASET_FILE="${2:-}"
            shift 2
            ;;
        --destination)
            DESTINATION="${2:-}"
            shift 2
            ;;
        --candidate-version)
            CANDIDATE_VERSION="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$SOURCE_DIRECTORY" ] || [ -z "$DESTINATION" ] || [ -z "$CANDIDATE_VERSION" ]; then
    usage
    exit 2
fi
[ -d "$SOURCE_DIRECTORY" ] || { echo "Source directory does not exist." >&2; exit 2; }
[ ! -e "$DESTINATION" ] || { echo "Destination already exists; refusing to overwrite it." >&2; exit 2; }

SOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd -P)"
SOURCE_PARENT="$(cd "$(dirname "$SOURCE_DIRECTORY")" && pwd -P)"
DESTINATION_PARENT="$(cd "$(dirname "$DESTINATION")" && pwd -P)"
DESTINATION="$DESTINATION_PARENT/$(basename "$DESTINATION")"

case "$SOURCE_DIRECTORY" in
    /|"$HOME"|"$REPO_ROOT")
        echo "Refusing an unsafe broad source directory." >&2
        exit 2
        ;;
esac
if [ "$DESTINATION" = "/" ] || [ "$DESTINATION" = "$HOME" ] || [ "$DESTINATION" = "$REPO_ROOT" ]; then
    echo "Refusing an unsafe broad destination." >&2
    exit 2
fi
if [ "$DESTINATION_PARENT" = "$SOURCE_DIRECTORY" ] || [ "$SOURCE_PARENT" = "$DESTINATION" ]; then
    echo "Source and destination must be separate directories." >&2
    exit 2
fi

mkdir -m 0700 "$DESTINATION"
for name in \
    config.json \
    phrase_history.txt \
    corrections.json \
    metrics_history.jsonl \
    setup_done; do
    if [ -f "$SOURCE_DIRECTORY/$name" ]; then
        cp -p "$SOURCE_DIRECTORY/$name" "$DESTINATION/$name"
    fi
done
while IFS= read -r prompt_file; do
    cp -p "$prompt_file" "$DESTINATION/$(basename "$prompt_file")"
done < <(find "$SOURCE_DIRECTORY" -maxdepth 1 -type f -name 'initial_prompt_*.txt' -print)

if [ -n "$DATASET_FILE" ]; then
    [ -f "$DATASET_FILE" ] || { echo "Dataset file does not exist." >&2; exit 2; }
    cp -p "$DATASET_FILE" "$DESTINATION/dataset.jsonl"
fi

HASH_LINES="$(mktemp "${TMPDIR:-/tmp}/click-n-speak-backup-hashes.XXXXXX")"
cleanup() { rm -f "$HASH_LINES"; }
trap cleanup EXIT
while IFS= read -r file; do
    base="$(basename "$file")"
    size="$(stat -f '%z' "$file")"
    digest="$(shasum -a 256 "$file" | awk '{print $1}')"
    jq -cn --arg name "$base" --arg sha256 "$digest" --argjson size "$size" \
        '{name: $name, sha256: $sha256, size: $size}' >> "$HASH_LINES"
done < <(find "$DESTINATION" -maxdepth 1 -type f ! -name backup_manifest.json -print | sort)

jq -s \
    --arg candidate_version "$CANDIDATE_VERSION" \
    --arg source_basename "$(basename "$SOURCE_DIRECTORY")" \
    '{schema_version: 1, candidate_version: $candidate_version, source_basename: $source_basename, files: .}' \
    "$HASH_LINES" > "$DESTINATION/backup_manifest.json"
chmod -R go-rwx "$DESTINATION"
echo "Created cutover backup: $DESTINATION"
