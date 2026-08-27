#!/bin/bash

set -e

echo "🔍 Checking C core..."

mkdir -p lib

NEED_REBUILD=false

if [ ! -f "lib/libmojelly.a" ]; then
    echo "📦 libmojelly.a not found, building..."
    NEED_REBUILD=true
else
    for src in src_c/*.c; do
        if [ -f "$src" ] && [ "$src" -nt "lib/libmojelly.a" ]; then
            echo "📦 $src changed, rebuilding..."
            NEED_REBUILD=true
            break
        fi
    done
fi

if [ "$NEED_REBUILD" = true ]; then
    echo "🔨 Building C core..."

    cd src_c

    gcc -c bridge.c -o bridge.o \
        -I/usr/include \
        -I/usr/include/llhttp \
        -fPIC -pthread \
        -O3 -march=native -mtune=native -pipe \
        -funroll-loops -ffast-math

    gcc -c bridge_ssl.c -O3 -o bridge_ssl.o \
        -I/usr/include \
        -I/usr/include/openssl \
        -fPIC \
        2>/dev/null || echo "⚠️ bridge_ssl.c not found or failed to compile"

    ar rcs ../lib/libmojelly.a bridge.o bridge_ssl.o 2>/dev/null || ar rcs ../lib/libmojelly.a bridge.o
    rm -f bridge.o bridge_ssl.o 2>/dev/null
    cd ..

    echo "✅ libmojelly.a rebuilt!"
else
    echo "✅ libmojelly.a is up to date"
fi

ls -la lib/libmojelly.a 2>/dev/null || echo "⚠️ libmojelly.a not found!"

echo ""
echo "📢 Calling for server-code generator..."
mkdir -p build
mojo run generator.mojo

echo ""
echo "📦 Building server..."

if [ ! -f "build/app_generated.mojo" ]; then
    echo "❌ build/app_generated.mojo not found! Run generator first."
    exit 1
fi

mojo build -I. build/app_generated.mojo -O3 -o server \
    -Xlinker -L./lib \
    -Xlinker -lmojelly \
    -Xlinker -luv \
    -Xlinker -lllhttp \
    -Xlinker -lssl \
    -Xlinker -lcrypto \
    -Xlinker -lpthread \
    -Xlinker -ldl

echo "✅ Server built! Run ./server"
