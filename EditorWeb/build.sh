#!/bin/sh
# Builds the note editor page into App/Editor from the web client's sources.
#
#   EditorWeb/build.sh            # expects the ivynote repository next to this one
#   IVYNOTE_DIR=/path/to/ivynote EditorWeb/build.sh
#
# Needs `npm install` in ivynote (esbuild and tailwindcss come from there).
# The output is committed, so building the app needs neither node nor ivynote.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
ivy=$(cd "${IVYNOTE_DIR:-$root/../ivynote}" && pwd)
client="$ivy/client"
bin="$ivy/node_modules/.bin"
out="$root/App/Editor"
cd "$root" # the output directory is recreated; never stand in it
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -x "$bin/esbuild" ] || { echo "run npm install in $ivy first" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

# Script: our bridge plus @ivynote/editor and @ivynote/core/markdown, with
# mermaid split into its own chunk that loads only when a diagram appears.
NODE_PATH="$ivy/node_modules" "$bin/esbuild" "$here/main.ts" \
	--bundle --format=esm --splitting --minify --target=safari17 \
	--alias:@ivynote/editor="$client/packages/editor/src" \
	--alias:@ivynote/core="$client/packages/core/src" \
	--chunk-names=chunks/[name]-[hash] \
	--legal-comments=none --log-level=warning \
	--outdir="$out"

# Styles: the web's design tokens and prose styles, the editor's own styles
# lifted from Editor.svelte (":global(x)" -> "x"), and the native page frame.
sed -n '/<style>/,/<\/style>/p' "$client/packages/editor/src/Editor.svelte" \
	| sed '1d;$d' | sed 's/:global(\([^)]*\))/\1/g' > "$tmp/editor-svelte.css"
cat > "$tmp/input.css" <<CSS
@import "$client/packages/ui/src/app.css";
@import "$tmp/editor-svelte.css";
@import "$here/native.css";
CSS
cat > "$tmp/tailwind.config.mjs" <<JS
import preset from '$client/packages/ui/tailwind.preset.js';
export default {
	presets: [preset],
	content: ['$here/*.{ts,html}', '$client/packages/editor/src/*.ts', '$client/packages/core/src/markdown/*.ts']
};
JS
"$bin/tailwindcss" -c "$tmp/tailwind.config.mjs" -i "$tmp/input.css" -o "$out/editor.css" --minify 2>&1 \
	| grep -vi -e 'browserslist' -e 'update-browserslist' -e '^$' -e 'Rebuilding' -e 'Done in' >&2 || true
[ -s "$out/editor.css" ] || { echo "tailwind produced no CSS" >&2; exit 1; }

cp "$here/index.html" "$out/index.html"
echo "built $(du -sh "$out" | cut -f1) into ${out#$root/}"
