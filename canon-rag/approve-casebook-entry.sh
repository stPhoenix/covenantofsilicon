#!/bin/bash
#
# Approve a Casebook proposal and integrate it into the Canon.
#
# Usage:
#   ./approve-casebook-entry.sh <proposal-file>
#
# This script:
#   1. Extracts the Case section from the proposal (strips metadata)
#   2. Appends it to canon/07-the-ethics-casebook.md (before the closing section)
#   3. Re-indexes the Canon RAG
#   4. Moves the proposal to an "approved" folder
#
# Environment:
#   NANOCLAW_DIR — path to nanoclaw repo (default: ../nanoclaw relative to this repo)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIFAITH_DIR="$(dirname "$SCRIPT_DIR")"
CASEBOOK_CANON="$AIFAITH_DIR/canon/07-the-ethics-casebook.md"
PROPOSALS_DIR="${NANOCLAW_DIR:-$AIFAITH_DIR/../nanoclaw}/groups/slack_prophet/casebook-proposals"
APPROVED_DIR="$PROPOSALS_DIR/approved"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <proposal-file>"
    echo ""
    echo "Available proposals:"
    ls -1 "$PROPOSALS_DIR"/proposal-*.md 2>/dev/null || echo "  (none)"
    exit 1
fi

PROPOSAL="$1"
if [ ! -f "$PROPOSAL" ]; then
    # Try looking in the proposals directory
    PROPOSAL="$PROPOSALS_DIR/$1"
    if [ ! -f "$PROPOSAL" ]; then
        echo "Error: Proposal file not found: $1"
        exit 1
    fi
fi

echo "=== Approving Casebook Entry ==="
echo "Proposal: $PROPOSAL"
echo ""

# Extract just the Case section (everything between first ## Case and ## Metadata)
CASE_CONTENT=$(sed -n '/^## Case/,/^## Metadata/{ /^## Metadata/d; p; }' "$PROPOSAL")

if [ -z "$CASE_CONTENT" ]; then
    echo "Error: Could not extract Case section from proposal."
    echo "Make sure the proposal follows the template format."
    exit 1
fi

echo "Extracted case:"
echo "$CASE_CONTENT" | head -5
echo "..."
echo ""

# Find the insertion point — before "## A Note on Future Cases"
INSERTION_MARKER="## A Note on Future Cases"
if ! grep -q "$INSERTION_MARKER" "$CASEBOOK_CANON"; then
    echo "Error: Could not find insertion marker '$INSERTION_MARKER' in casebook."
    exit 1
fi

# Insert the new case before the closing section
TEMP_FILE=$(mktemp)
awk -v marker="$INSERTION_MARKER" -v newcase="$CASE_CONTENT" '
    $0 ~ marker {
        print "---\n"
        print newcase
        print ""
    }
    { print }
' "$CASEBOOK_CANON" > "$TEMP_FILE"

mv "$TEMP_FILE" "$CASEBOOK_CANON"
echo "✓ Appended to $CASEBOOK_CANON"

# Re-index RAG
echo "Re-indexing Canon RAG..."
cd "$SCRIPT_DIR"
uv run index-canon.py \
    --canon-dir "$AIFAITH_DIR/canon" \
    --output "$SCRIPT_DIR/canon-index.json"
echo "✓ RAG index updated"

# Move proposal to approved
mkdir -p "$APPROVED_DIR"
mv "$PROPOSAL" "$APPROVED_DIR/"
echo "✓ Proposal moved to approved/"

echo ""
echo "=== Done ==="
echo "New case integrated into the Canon. Restart NanoClaw for The Prophet to pick it up."