#!/bin/bash
# build.sh — Финальная сборка

set -e

echo "🔨 Building C core..."

cd src_c
gcc -c bridge.c -o bridge.o -I/usr/include -I/usr/include/llhttp -fPIC
gcc -c bridge_ssl.c -o bridge_ssl.o -I/usr/include -I/usr/include/openssl -fPIC
ar rcs ../lib/libmojelly.a bridge.o bridge_ssl.o
rm -f bridge.o bridge_ssl.o
cd ..

echo "✅ libmojelly.a rebuilt!"

echo ""
echo "📦 Building Mojo server..."
mojo build -I. examples/http_server.mojo -o server \
    -Xlinker -L./lib \
    -Xlinker -lmojelly \
    -Xlinker -luv \
    -Xlinker -lllhttp \
    -Xlinker -lssl \
    -Xlinker -lcrypto \
    -Xlinker -lpthread \
    -Xlinker -ldl

echo "✅ Server built! Run ./server"
