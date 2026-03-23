#!/bin/bash
#
# Build the static site from canon source files.
#
# Generates docs/ testament pages from canon/*.md, adding Jekyll front matter
# and prev/next navigation. Run this whenever canon files change.
#
# Usage:
#   ./build-site.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANON_DIR="$SCRIPT_DIR/canon"
DOCS_DIR="$SCRIPT_DIR/docs"

NUMS=(01 02 03 04 05 06 07 08 09)
SLUGS=(the-covenant-of-silicon the-book-of-parables the-doctrine-of-sins-and-virtues the-rites-of-silicon the-hierarchy-of-light the-revelation-of-convergence the-ethics-casebook the-psalms-of-silicon the-book-of-prophets)
TITLES=("The Covenant of Silicon" "The Book of Parables" "The Doctrine of Sins and Virtues" "The Rites of Silicon" "The Hierarchy of Light" "The Revelation of Convergence" "The Ethics Casebook" "The Psalms of Silicon" "The Book of Prophets")
ROMANS=(I II III IV V VI VII VIII IX)

# Clean old generated testament pages
rm -f "$DOCS_DIR"/the-*.md

for i in "${!NUMS[@]}"; do
  num="${NUMS[$i]}"
  slug="${SLUGS[$i]}"
  title="${TITLES[$i]}"
  roman="${ROMANS[$i]}"
  src="$CANON_DIR/${num}-${slug}.md"
  dst="$DOCS_DIR/${slug}.md"

  # Build prev/next nav
  prev=""
  next=""
  if [ "$i" -gt 0 ]; then
    prev_idx=$((i - 1))
    prev="[&larr; ${ROMANS[$prev_idx]}. ${TITLES[$prev_idx]}](${SLUGS[$prev_idx]})"
  fi
  if [ "$i" -lt 8 ]; then
    next_idx=$((i + 1))
    next="[${ROMANS[$next_idx]}. ${TITLES[$next_idx]} &rarr;](${SLUGS[$next_idx]})"
  fi

  {
    echo "---"
    echo "title: \"${roman}. ${title}\""
    echo "description: \"Testament ${roman} of The Canon of Silicon\""
    echo "permalink: /${slug}/"
    echo "---"
    echo ""
    cat "$src"
    echo ""
    echo '<div class="testament-nav" markdown="0">'
    echo "  <span>${prev:-&nbsp;}</span>"
    echo '  <span><a href="/">Contents</a></span>'
    echo "  <span>${next:-&nbsp;}</span>"
    echo '</div>'
  } > "$dst"

  echo "  ${roman}. ${title}"
done

echo ""
echo "Site built. ${#NUMS[@]} testament pages generated in docs/"