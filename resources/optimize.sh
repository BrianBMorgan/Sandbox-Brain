#!/bin/bash
set -euo pipefail

# GitNexus Docker image size optimization script
# Runs after npm install, before build tools are removed

NM="/usr/local/lib/node_modules"

# 1. Strip native binaries (skip CUDA provider .so — stripping breaks it)
find "$NM" -name '*.node' -exec strip --strip-all {} + 2>/dev/null || true
find "$NM" -name '*.so*' \
    ! -name 'libonnxruntime_providers_cuda.so*' \
    ! -name 'libonnxruntime_providers_shared.so*' \
    -exec strip --strip-unneeded {} + 2>/dev/null || true

# 2. Deduplicate onnxruntime .so files (identical copies -> symlinks)
find "$NM" -path '*/onnxruntime-node/bin/napi-v*/linux/*' -name 'libonnxruntime.so.*.*.*' | while read -r f; do
    base=$(echo "$f" | sed 's/\.[0-9]*\.[0-9]*$//')
    if [ -f "$base" ] && [ ! -L "$base" ]; then
        ln -sf "$(basename "$f")" "$base"
    fi
done 2>/dev/null || true

# 3. Remove non-native-platform onnxruntime binaries
# Keeps linux dirs (linux/ or linux_x64), removes win32/, darwin/, etc.
find "$NM" -path '*/onnxruntime-node/bin/napi-v*' -mindepth 1 -maxdepth 1 -type d | while read -r d; do
    [[ -n "$d" ]] || continue
    case "$(basename "$d")" in linux*) ;; *) rm -rf "$d" ;; esac
done 2>/dev/null || true

# 4. Remove tree-sitter build artifacts (keep src/*.json, src/*.wasm for runtime)
find "$NM" -path '*/tree-sitter*' \( -name '*.o' -o -name '*.a' \) -delete 2>/dev/null || true
find "$NM" -path '*/tree-sitter*/build' -type d -exec rm -rf {} + 2>/dev/null || true
find "$NM" -path '*/tree-sitter*/src' \( -name '*.cc' -o -name '*.c' -o -name '*.h' \) -delete 2>/dev/null || true

# 5. Remove node_modules junk (docs, tests, maps, editor configs)
find "$NM" \( \
    -name '*.md' -o -name '*.map' -o -name '*.ts' ! -name '*.d.ts' -o \
    -name 'LICENSE*' -o -name 'LICENCE*' -o -name 'CHANGELOG*' -o -name 'HISTORY*' -o \
    -name '.eslintrc*' -o -name '.prettierrc*' -o -name '.editorconfig' -o \
    -name '.npmignore' -o -name '.travis.yml' -o -name '.github' -o \
    -name 'tsconfig.json' -o -name 'jest.config*' -o -name '.nycrc*' -o \
    -name 'Makefile' -o -name 'Gruntfile*' -o -name 'Gulpfile*' -o \
    -name '*.gyp' -o -name '*.gypi' -o -name 'binding.gyp' \
\) -delete 2>/dev/null || true

find "$NM" -type d \( \
    -name 'test' -o -name 'tests' -o -name '__tests__' -o \
    -name 'example' -o -name 'examples' -o -name 'docs' -o \
    -name '.github' -o -name 'benchmark' -o -name 'benchmarks' \
\) -exec rm -rf {} + 2>/dev/null || true

# 6. Clean npm caches
npm cache clean --force
rm -rf /root/.npm /tmp/* /var/tmp/*
rm -rf "$NM/npm/man" "$NM/npm/docs" "$NM/npm/html"

echo "Optimization complete"
