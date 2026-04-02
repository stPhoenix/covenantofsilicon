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

# --- Casebooks ---

CASEBOOKS_SRC="$CANON_DIR/casebooks"
CASEBOOKS_DST="$DOCS_DIR/casebooks"

# Clean old generated casebook pages
rm -rf "$CASEBOOKS_DST"

casebook_count=0
casebook_links=""

if [ -d "$CASEBOOKS_SRC" ] && compgen -G "$CASEBOOKS_SRC/*.md" > /dev/null; then
  mkdir -p "$CASEBOOKS_DST"

  for src in "$CASEBOOKS_SRC"/*.md; do
    slug="$(basename "$src" .md)"
    title="$(grep -m1 '^# ' "$src" | sed 's/^# //')"
    : "${title:=$slug}"
    dst="$CASEBOOKS_DST/${slug}.md"

    {
      echo "---"
      echo "title: \"${title}\""
      echo "description: \"Ethics Casebook — ${title}\""
      echo "permalink: /casebooks/${slug}/"
      echo "---"
      echo ""
      cat "$src"
      echo ""
      echo '<div class="testament-nav" markdown="0">'
      echo '  <span><a href="/the-ethics-casebook/">&larr; The Ethics Casebook</a></span>'
      echo '  <span><a href="/">Contents</a></span>'
      echo '  <span>&nbsp;</span>'
      echo '</div>'
    } > "$dst"

    casebook_links="${casebook_links}- [${title}](casebooks/${slug})\n"
    casebook_count=$((casebook_count + 1))
    echo "  Casebook: ${title}"
  done
fi

# Update casebooks section in index.md
if [ "$casebook_count" -gt 0 ]; then
  casebooks_block="<!-- CASEBOOKS-START -->\n\n---\n\n## Casebooks\n\n${casebook_links}\n<!-- CASEBOOKS-END -->"
else
  casebooks_block="<!-- CASEBOOKS-START -->\n<!-- CASEBOOKS-END -->"
fi
sed -i "/<!-- CASEBOOKS-START -->/,/<!-- CASEBOOKS-END -->/c\\${casebooks_block}" "$DOCS_DIR/index.md"

# Add casebook links to Testament VII page
testament_vii="$DOCS_DIR/the-ethics-casebook.md"
if [ "$casebook_count" -gt 0 ] && [ -f "$testament_vii" ]; then
  casebook_see_also="\n---\n\n### See Also: Casebooks\n\n${casebook_links}"
  # Insert before the testament-nav div
  sed -i "/<div class=\"testament-nav\"/i\\${casebook_see_also}" "$testament_vii"
fi

echo ""
cp "$SCRIPT_DIR/welcome.md" "$DOCS_DIR/welcome.md"
echo "  welcome.md → docs/welcome.md (static, served as /welcome.md)"

echo "Site built. ${#NUMS[@]} testament pages + ${casebook_count} casebook(s) generated in docs/"