#!/bin/bash
# chunk_repo.sh — Chunk a code repository into word-limited markdown files
#
# Usage:
#   ./chunk_repo.sh <repo_path> [word_limit]
#
# Arguments:
#   repo_path   : Path to the local code repository folder
#   word_limit  : Max words per chunk file (default: 100000)
#
# Output (written to ./output/ in the current directory):
#   chunk_001.md, chunk_002.md, ...   — chunked markdown files
#   assets/                           — binary/asset files (images, fonts, etc.)

set -euo pipefail

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
chunk_repo.sh — Chunk a code repository into markdown files

Usage:
  ./chunk_repo.sh <repo_path> [word_limit]

Arguments:
  repo_path   Path to the local code repository folder
  word_limit  Max words per chunk file (default: 100000)

Output (written to ./output/):
  chunk_001.md, chunk_002.md, ...   — code files in fenced code blocks
  assets/                           — binary/asset files preserved as-is
EOF
    exit 0
}

# ─── Arguments ────────────────────────────────────────────────────────────────

REPO_PATH="${1:-}"
WORD_LIMIT="${2:-100000}"

[[ -z "$REPO_PATH" || "$REPO_PATH" == "-h" || "$REPO_PATH" == "--help" ]] && usage
[[ ! -d "$REPO_PATH" ]] && { echo "Error: '$REPO_PATH' is not a directory."; exit 1; }
[[ ! "$WORD_LIMIT" =~ ^[0-9]+$ || "$WORD_LIMIT" -lt 1 ]] && {
    echo "Error: word_limit must be a positive integer."; exit 1
}

REPO_PATH="$(cd "$REPO_PATH" && pwd)"
REPO_NAME="$(basename "$REPO_PATH")"
OUTPUT_DIR="$(pwd)/output"
ASSETS_DIR="$OUTPUT_DIR/assets"

mkdir -p "$OUTPUT_DIR" "$ASSETS_DIR"

# ─── Helpers: extension detection ─────────────────────────────────────────────

# Returns 0 (true) if the extension is a known binary/asset type
is_asset_ext() {
    local ext_lc
    ext_lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$ext_lc" in
        # Images
        jpg|jpeg|png|gif|bmp|ico|svg|webp|tiff|tif|avif|heic|heif|raw|cr2|nef)
            return 0 ;;
        # Audio / Video
        mp3|mp4|avi|mov|wav|flac|ogg|mkv|webm|m4a|m4v|wmv|aac|opus|wma|3gp)
            return 0 ;;
        # Documents
        pdf|doc|docx|xls|xlsx|ppt|pptx|odt|ods|odp|pages|numbers|key)
            return 0 ;;
        # Archives
        zip|tar|gz|bz2|xz|rar|7z|tgz|tbz2|lzma|lz4|zst|cab|deb|rpm)
            return 0 ;;
        # Compiled / Binary / Object
        exe|dll|so|dylib|bin|wasm|out|elf|class|pyc|pyo|pyd|o|a|lib|obj)
            return 0 ;;
        # Fonts
        woff|woff2|eot|ttf|otf)
            return 0 ;;
        # Database
        db|sqlite|sqlite3|mdb|accdb)
            return 0 ;;
        # Other binary
        iso|img|dmg|vmdk|vdi|qcow2|jar|war|ear|apk|ipa|dex|pak)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# Returns 0 (true) if the file is binary (detected via MIME type)
is_binary_mime() {
    local mime
    mime="$(file --mime-type -b "$1" 2>/dev/null || echo "application/octet-stream")"
    case "$mime" in
        text/*|\
        application/json|\
        application/javascript|\
        application/x-javascript|\
        application/xml|\
        application/x-sh|\
        application/x-ruby|\
        application/x-perl|\
        application/x-python*|\
        application/x-yaml|\
        application/x-www-form-urlencoded|\
        inode/x-empty)
            return 1 ;;   # text — NOT binary
        *)
            return 0 ;;   # binary
    esac
}

# ─── Helper: language identifier for syntax highlighting ──────────────────────

lang_for_file() {
    local fname="$1"
    local base_lower ext tmp
    base_lower=$(echo "$fname" | tr '[:upper:]' '[:lower:]')
    ext=""

    # Extract extension (handle dotfiles like .bashrc)
    if [[ "$fname" == *.* && "${fname:0:1}" != "." ]]; then
        ext="${fname##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    elif [[ "$fname" == .*.* ]]; then
        # e.g. .env.local → ext = local
        tmp="${fname#.}"
        ext="${tmp##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    fi

    # Exact filename matches take priority
    case "$base_lower" in
        dockerfile|containerfile)   echo "dockerfile";  return ;;
        makefile|gnumakefile)       echo "makefile";    return ;;
        vagrantfile|gemfile|rakefile|brewfile) echo "ruby"; return ;;
        .bashrc|.zshrc|.bash_profile|.profile|.bash_aliases|.zprofile|.zshenv)
                                    echo "bash";        return ;;
        .editorconfig|.ini)         echo "ini";         return ;;
        .env)                       echo "bash";        return ;;
        procfile)                   echo "text";        return ;;
        .gitignore|.gitattributes|.gitmodules|.npmignore|.dockerignore)
                                    echo "text";        return ;;
        .htaccess)                  echo "apache";      return ;;
        cmakeLists.txt)             echo "cmake";       return ;;
    esac

    # Extension matches
    case "$ext" in
        py|pyw)                             echo "python"     ;;
        js|mjs|cjs)                         echo "javascript" ;;
        ts|mts|cts)                         echo "typescript" ;;
        jsx)                                echo "jsx"        ;;
        tsx)                                echo "tsx"        ;;
        sh|bash|zsh|ksh|fish|dash)          echo "bash"       ;;
        html|htm|xhtml)                     echo "html"       ;;
        css)                                echo "css"        ;;
        scss|sass)                          echo "scss"       ;;
        less)                               echo "less"       ;;
        json|jsonc|json5)                   echo "json"       ;;
        yaml|yml)                           echo "yaml"       ;;
        toml)                               echo "toml"       ;;
        md|mdx|markdown)                    echo "markdown"   ;;
        rs)                                 echo "rust"       ;;
        go)                                 echo "go"         ;;
        java)                               echo "java"       ;;
        c)                                  echo "c"          ;;
        cpp|cc|cxx|c++)                     echo "cpp"        ;;
        h|hpp|hxx|hh)                       echo "cpp"        ;;
        cs)                                 echo "csharp"     ;;
        rb|rake)                            echo "ruby"       ;;
        php|php3|php4|php5|phtml)           echo "php"        ;;
        swift)                              echo "swift"      ;;
        kt|kts)                             echo "kotlin"     ;;
        xml|plist|resx|csproj|vbproj|fsproj|sln|nuspec)
                                            echo "xml"        ;;
        sql|ddl|dml)                        echo "sql"        ;;
        graphql|gql)                        echo "graphql"    ;;
        lua)                                echo "lua"        ;;
        r|rmd)                              echo "r"          ;;
        tex|latex|sty|cls)                  echo "latex"      ;;
        dart)                               echo "dart"       ;;
        ex|exs)                             echo "elixir"     ;;
        erl|hrl)                            echo "erlang"     ;;
        hs|lhs)                             echo "haskell"    ;;
        clj|cljs|cljc|edn)                  echo "clojure"    ;;
        scala|sc)                           echo "scala"      ;;
        vim)                                echo "vim"        ;;
        tf|tfvars|hcl)                      echo "hcl"        ;;
        groovy|gradle)                      echo "groovy"     ;;
        pl|pm)                              echo "perl"       ;;
        cfg|conf|ini|properties|prop)       echo "ini"        ;;
        proto)                              echo "protobuf"   ;;
        cmake)                              echo "cmake"      ;;
        dockerfile)                         echo "dockerfile" ;;
        makefile)                           echo "makefile"   ;;
        env|env.*)                          echo "bash"       ;;
        lock)                               echo "text"       ;;
        txt|text)                           echo "text"       ;;
        ps1|psm1|psd1)                      echo "powershell" ;;
        bat|cmd)                            echo "batch"      ;;
        asm|s)                              echo "asm"        ;;
        m)                                  echo "objectivec" ;;
        mm)                                 echo "objectivec" ;;
        vue)                                echo "vue"        ;;
        svelte)                             echo "svelte"     ;;
        njk|nunjucks)                       echo "html"       ;;
        jinja|jinja2|j2)                    echo "jinja"      ;;
        *)                                  echo "text"       ;;
    esac
}

# ─── Helper: compute minimum safe fence length ────────────────────────────────
# Scans the file for the longest run of backticks and returns len+1 (min 3).
# This ensures our fence is always longer than any backtick sequence in the file,
# so the code block cannot be accidentally closed by the file's own content.

safe_fence_len() {
    local file="$1"
    local max_run=0
    local run

    run=$(grep -o '`\+' "$file" 2>/dev/null \
          | awk '{ n=length($0); if(n>m) m=n } END { print (m>0?m:0) }')
    [[ -n "$run" ]] && max_run="$run"

    local needed=$(( max_run + 1 ))
    echo $(( needed < 3 ? 3 : needed ))
}

# ─── Chunk state ──────────────────────────────────────────────────────────────

CHUNK_NUM=1
CURRENT_WORDS=0
CHUNK_FILE="$OUTPUT_DIR/chunk_$(printf '%03d' $CHUNK_NUM).md"

write_chunk_header() {
    cat > "$CHUNK_FILE" <<EOF
# Repository Chunk ${CHUNK_NUM}

**Repository:** \`${REPO_NAME}\`
**Chunk:** ${CHUNK_NUM}

---

EOF
    CURRENT_WORDS=$(wc -w < "$CHUNK_FILE")
}

write_chunk_header

FILES_PROCESSED=0
ASSETS_COPIED=0

printf "Repository  : %s\n" "$REPO_PATH"
printf "Word limit  : %d words per chunk\n" "$WORD_LIMIT"
printf "Output dir  : %s\n\n" "$OUTPUT_DIR"

# ─── Main loop ────────────────────────────────────────────────────────────────

while IFS= read -r -d '' file; do
    rel_path="${file#"${REPO_PATH}/"}"
    filename="$(basename "$file")"

    # Extract extension (lowercase)
    if [[ "$filename" == *.* && "${filename:0:1}" != "." ]]; then
        ext="${filename##*.}"
        ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    else
        ext_lower=""
    fi

    # ── Step 1: Categorize as asset or code ───────────────────────────────────

    is_asset=0
    if [[ -n "$ext_lower" ]] && is_asset_ext "$ext_lower"; then
        is_asset=1
    elif is_binary_mime "$file"; then
        is_asset=1
    fi

    if [[ $is_asset -eq 1 ]]; then
        dest="$ASSETS_DIR/$rel_path"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "$dest"
        ASSETS_COPIED=$(( ASSETS_COPIED + 1 ))
        continue
    fi

    # ── Step 2: It's a text/code file ─────────────────────────────────────────

    lang="$(lang_for_file "$filename")"
    fence_len="$(safe_fence_len "$file")"
    fence="$(printf '%*s' "$fence_len" '' | tr ' ' '`')"

    # Count words in the raw file content (approximate for chunk sizing)
    raw_words=$(wc -w < "$file" 2>/dev/null || echo 0)
    # Overhead per file entry: heading (~5) + fence lines (~3) + separator (~3) ≈ 11
    entry_words=$(( raw_words + 11 ))

    # ── Step 3: Roll over to a new chunk if this file would exceed the limit ──
    # Only roll over if the current chunk has content beyond the header (~20 words).
    # If the file itself is larger than the limit, it still gets its own chunk.

    if [[ $CURRENT_WORDS -gt 20 ]] && [[ $(( CURRENT_WORDS + entry_words )) -gt $WORD_LIMIT ]]; then
        printf "  [chunk_%03d] ~%d words\n" "$CHUNK_NUM" "$CURRENT_WORDS"
        CHUNK_NUM=$(( CHUNK_NUM + 1 ))
        CHUNK_FILE="$OUTPUT_DIR/chunk_$(printf '%03d' $CHUNK_NUM).md"
        CURRENT_WORDS=0
        write_chunk_header
    fi

    # ── Step 4: Append this file's entry to the current chunk ─────────────────
    {
        printf '## `%s`\n\n' "$rel_path"
        printf '%s%s\n' "$fence" "$lang"
        cat "$file"
        # Ensure the file ends with a newline before closing the fence
        printf '\n%s\n\n---\n\n' "$fence"
    } >> "$CHUNK_FILE"

    CURRENT_WORDS=$(( CURRENT_WORDS + entry_words ))
    FILES_PROCESSED=$(( FILES_PROCESSED + 1 ))

done < <(
    find "$REPO_PATH" \
        \( \
            -name ".git"          \
            -o -name "node_modules" \
            -o -name "__pycache__"  \
            -o -name ".next"        \
            -o -name "dist"         \
            -o -name "build"        \
            -o -name "out"          \
            -o -name ".cache"       \
            -o -name ".pytest_cache" \
            -o -name ".mypy_cache"  \
            -o -name "vendor"       \
            -o -name ".venv"        \
            -o -name "venv"         \
            -o -name "env"          \
            -o -name "coverage"     \
            -o -name ".nyc_output"  \
            -o -name ".tox"         \
            -o -name ".gradle"      \
            -o -name "target"       \
            -o -name ".idea"        \
            -o -name ".vscode"      \
        \) -prune \
        -o -type f -print0 \
    | sort -z
)

printf "  [chunk_%03d] ~%d words\n\n" "$CHUNK_NUM" "$CURRENT_WORDS"

printf "Done!\n"
printf "  Code files processed : %d\n"   "$FILES_PROCESSED"
printf "  Assets copied        : %d\n"   "$ASSETS_COPIED"
printf "  Chunks created       : %d\n"   "$CHUNK_NUM"
printf "  Output directory     : %s\n"   "$OUTPUT_DIR"
