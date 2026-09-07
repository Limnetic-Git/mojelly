#!/bin/bash

set -e

USE_PIXI=true
MOJO_VERSION="1.0.0"


run_mojo() {
    if [ "$USE_PIXI" = true ]; then
        pixi run mojo "$@"
    else
        mojo "$@"
    fi
}

check_mojo_version() {
    if [ "$USE_PIXI" = true ]; then
        local version=$(pixi run mojo --version 2>/dev/null || echo "unknown")
        echo "🔥 Mojo version (pixi): $version"
    else
        local version=$(mojo --version 2>/dev/null || echo "unknown")
        echo "🔥 Mojo version (system): $version"
    fi
}

if [ "$USE_PIXI" = true ]; then
    echo "🔧 Using pixi environment..."

    if ! command -v pixi &> /dev/null; then
        echo "❌ pixi not found! Please install it first:"
        echo "   curl -fsSL https://pixi.sh/install.sh | bash"
        exit 1
    fi
    if [ ! -f "pixi.toml" ]; then
        echo "⚠️ pixi.toml not found, creating minimal configuration..."
        cat > pixi.toml << 'EOF'
[workspace]
name = "mojelly"
channels = [
    "https://conda.modular.com/max-nightly",
    "https://repo.prefix.dev/modular-community",
    "conda-forge",
]
platforms = ["linux-64"]

[dependencies]
mojo = "==1.0.0"
emberjson = ">=0.3.0"

[tasks]
build = "bash build.sh"
run = "./server"
EOF
        echo "✅ pixi.toml created"
    fi
    if ! pixi list 2>/dev/null | grep -q "mojo"; then
        echo "📦 Installing Mojo $MOJO_VERSION via pixi..."
        pixi add mojo=$MOJO_VERSION
        pixi add emberjson -c https://repo.prefix.dev/modular-community
    fi

    echo "🔥 Using Mojo via pixi:"
    pixi run mojo --version
else
    echo "🔧 Using system Mojo..."
    if ! command -v mojo &> /dev/null; then
        echo "❌ Mojo not found in system PATH!"
        echo "   Please install Mojo or set USE_PIXI=true"
        exit 1
    fi
    mojo --version
fi

echo ""
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
    echo "🔨 Building C core with -O3..."

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

run_mojo run generator.mojo

echo ""
echo "📦 Building server..."

if [ ! -f "build/app_generated.mojo" ]; then
    echo "❌ build/app_generated.mojo not found! Run generator first."
    exit 1
fi

LINK_FLAGS="-Xlinker -L./lib \
    -Xlinker -lmojelly \
    -Xlinker -luv \
    -Xlinker -lllhttp \
    -Xlinker -lssl \
    -Xlinker -lcrypto \
    -Xlinker -lpthread \
    -Xlinker -ldl"

run_mojo build -I. build/app_generated.mojo -O3 -o server $LINK_FLAGS

echo ""
echo "✅ Server built! Run ./server"
echo ""
echo "   To run:"
echo "   ./server"
