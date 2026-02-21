#!/usr/bin/env bash
# Renders docs/diagrams/*.md into a single PDF with Mermaid diagrams as SVGs.
# Requirements: node, @mermaid-js/mermaid-cli (mmdc), chromium, pandoc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIAGRAMS_DIR="$SCRIPT_DIR/diagrams"
OUTPUT_PDF="$SCRIPT_DIR/architecture-diagrams.pdf"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Extracting and rendering Mermaid diagrams..."

# Concatenate all diagram files in order
COMBINED="$WORK_DIR/combined.md"
for f in "$DIAGRAMS_DIR"/[0-9]*.md; do
  cat "$f" >> "$COMBINED"
  printf "\n\n---\n\n" >> "$COMBINED"
done

# Extract each mermaid code block, render to SVG, replace in markdown
COUNTER=0
OUTPUT_MD="$WORK_DIR/output.md"
IN_MERMAID=false
MERMAID_BUF=""

while IFS= read -r line; do
  if [[ "$line" =~ ^\`\`\`mermaid ]]; then
    IN_MERMAID=true
    MERMAID_BUF=""
    continue
  fi

  if $IN_MERMAID; then
    if [[ "$line" =~ ^\`\`\` ]]; then
      IN_MERMAID=false
      COUNTER=$((COUNTER + 1))
      MMD_FILE="$WORK_DIR/diagram-${COUNTER}.mmd"
      SVG_FILE="$WORK_DIR/diagram-${COUNTER}.svg"

      echo "$MERMAID_BUF" > "$MMD_FILE"

      echo "    Rendering diagram $COUNTER..."
      if npx --yes @mermaid-js/mermaid-cli \
        -i "$MMD_FILE" \
        -o "$SVG_FILE" \
        -b transparent \
        --puppeteerConfigFile <(echo '{"args":["--no-sandbox"]}') \
        2>/dev/null && [ -f "$SVG_FILE" ]; then
        # Embed SVG inline for best PDF quality
        echo '<div style="text-align:center; margin: 1em 0;">' >> "$OUTPUT_MD"
        cat "$SVG_FILE" >> "$OUTPUT_MD"
        echo '</div>' >> "$OUTPUT_MD"
        echo "" >> "$OUTPUT_MD"
      else
        echo "    WARNING: Diagram $COUNTER failed to render, embedding as code block"
        echo '```' >> "$OUTPUT_MD"
        cat "$MMD_FILE" >> "$OUTPUT_MD"
        echo '```' >> "$OUTPUT_MD"
        echo "" >> "$OUTPUT_MD"
      fi
    else
      MERMAID_BUF+="$line"$'\n'
    fi
  else
    echo "$line" >> "$OUTPUT_MD"
  fi
done < "$COMBINED"

echo "==> Rendering $COUNTER diagrams complete."
echo "==> Converting to PDF..."

# Step 1: Markdown with inline SVGs → standalone HTML via pandoc
HTML_FILE="$WORK_DIR/output.html"

CSS_FILE="$WORK_DIR/style.css"
cat > "$CSS_FILE" <<'CSSEOF'
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  max-width: 900px;
  margin: 0 auto;
  padding: 2em;
  color: #1a1a1a;
  line-height: 1.6;
}
h1 { color: #1e3a5f; border-bottom: 2px solid #1e3a5f; padding-bottom: 0.3em; margin-top: 1.5em; }
h2 { color: #2c5282; margin-top: 1.2em; }
hr { border: none; border-top: 1px solid #ccc; margin: 2em 0; page-break-after: avoid; }
code { background: #f0f0f0; padding: 0.2em 0.4em; border-radius: 3px; font-size: 0.9em; }
pre { background: #f6f6f6; padding: 1em; border-radius: 6px; overflow-x: auto; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; }
th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; }
th { background: #f0f4f8; }
svg { max-width: 100%; height: auto; }
@media print {
  body { padding: 0; }
  h1 { page-break-before: auto; }
}
CSSEOF

pandoc "$OUTPUT_MD" \
  -f markdown+raw_html \
  -t html5 \
  --standalone \
  --metadata title="Ollama Chat — Architecture Diagrams" \
  --css "$CSS_FILE" \
  --embed-resources \
  -o "$HTML_FILE"

# Step 2: HTML → PDF via chromium headless
chromium \
  --headless \
  --no-sandbox \
  --disable-gpu \
  --run-all-compositor-stages-before-draw \
  --print-to-pdf="$OUTPUT_PDF" \
  --print-to-pdf-no-header \
  "$HTML_FILE" \
  2>/dev/null

echo "==> Done: $OUTPUT_PDF"
echo "    Rendered $COUNTER diagrams into PDF."
