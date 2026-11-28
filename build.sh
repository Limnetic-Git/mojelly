#!/bin/bash

set -e

USE_PIXI=true
MOJO_VERSION="1.2.0"
SHOW_WARNINGS=false

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
mojo = "==1.2.0"
emberjson = { git = "https://github.com/bgreni/EmberJson.git", tag = "0.5.0" }

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

CC="${CC:-gcc}"
ARCH_FLAGS="${MOJELLY_ARCH_FLAGS:--march=native -mtune=native}"
COMMON_CFLAGS="-O3 $ARCH_FLAGS -pipe -fPIC -ftls-model=initial-exec -fno-plt -pthread"

NEED_REBUILD=false

if [ ! -f "lib/libmojelly.a" ]; then
    echo "📦 libmojelly.a not found, building..."
    NEED_REBUILD=true
elif [ "build.sh" -nt "lib/libmojelly.a" ]; then
    echo "📦 build.sh changed, rebuilding C core..."
    NEED_REBUILD=true
else
    for src in src_c/*.c src_c/*.h; do
        if [ -f "$src" ] && [ "$src" -nt "lib/libmojelly.a" ]; then
            echo "📦 $src changed, rebuilding..."
            NEED_REBUILD=true
            break
        fi
    done
fi

if [ "$NEED_REBUILD" = true ]; then
    echo "🔨 Building C core with $CC ($COMMON_CFLAGS)..."

    cd src_c

    "$CC" -c bridge.c -o bridge.o \
        -I/usr/include \
        -I/usr/include/llhttp \
        -I/usr/local/include \
        -I/usr/local/include/llhttp \
        $COMMON_CFLAGS
    echo "✅ bridge.o built"

    if [ -f "multipart_parser.c" ]; then
        "$CC" -c multipart_parser.c -o multipart_parser.o \
            -I/usr/include \
            $COMMON_CFLAGS
        echo "✅ multipart_parser.o built"
    else
        echo "⚠️ multipart_parser.c not found, streaming multipart disabled"
    fi

    "$CC" -c bridge_ssl.c -o bridge_ssl.o \
        -I/usr/include \
        -I/usr/include/openssl \
        -I/usr/local/include \
        $COMMON_CFLAGS \
        2>/dev/null || echo "⚠️ bridge_ssl.c not found or failed to compile"

    OBJ_FILES="bridge.o"
    if [ -f "multipart_parser.o" ]; then
        OBJ_FILES="$OBJ_FILES multipart_parser.o"
    fi
    if [ -f "bridge_ssl.o" ]; then
        OBJ_FILES="$OBJ_FILES bridge_ssl.o"
    fi

    rm -f ../lib/libmojelly.a
    ar rcs ../lib/libmojelly.a $OBJ_FILES
    rm -f bridge.o multipart_parser.o bridge_ssl.o 2>/dev/null
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
    -Xlinker -L/usr/local/lib \
    -Xlinker -lmojelly \
    -Xlinker -luv \
    -Xlinker -lllhttp \
    -Xlinker -lssl \
    -Xlinker -lcrypto \
    -Xlinker -lpthread \
    -Xlinker -ldl"

if [ "$SHOW_WARNINGS" = true ]; then
    run_mojo build -I. -I examples build/app_generated.mojo -O3 -o server $LINK_FLAGS
else
    run_mojo build --disable-warnings -I. -I examples build/app_generated.mojo -O3 -o server $LINK_FLAGS
fi

echo ""
echo "✅ Server built! Run ./server"
echo ""
echo "   To run:"
echo "   ./server"
