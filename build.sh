
echo "🔨 Building Mojelly C core..."

cd src_c

gcc -c bridge.c -o bridge.o -I/usr/include -I/usr/include/llhttp
gcc -c bridge_ssl.c -o bridge_ssl.o -I/usr/include -I/usr/include/openssl
gcc -c bridge_shm.c -o bridge_shm.o -I/usr/include

ar rcs ../lib/libmojelly.a bridge.o bridge_ssl.o bridge_shm.o

rm -f bridge.o bridge_ssl.o bridge_shm.o

cd ..

echo "✅ libmojelly.a rebuilt!"
ls -la lib/libmojelly.a
