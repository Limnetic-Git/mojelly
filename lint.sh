#!/bin/bash
set -e

if [ -d "$HOME/.pixi/bin" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
fi

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=========================================="
echo "🔍 Running Mojelly Linters & Code Checks"
echo -e "==========================================${NC}\n"

run_mojo() {
    if command -v pixi &> /dev/null; then
        pixi run mojo "$@"
    else
        mojo "$@"
    fi
}

ERRORS=0

# 1. Mojo Formatting Check
echo -e "▶ Checking Mojo code formatting..."
run_mojo format mojelly examples tests generator.mojo --quiet

if git diff --exit-code mojelly examples tests generator.mojo > /dev/null; then
    echo -e "${GREEN}✔ Mojo code formatting clean${NC}\n"
else
    echo -e "${RED}✘ Mojo code formatting diffs detected! Run 'pixi run fmt' to fix.${NC}"
    git diff mojelly examples tests generator.mojo
    echo ""
    ERRORS=$((ERRORS + 1))
fi

# 2. C Syntax & Warnings as Errors
echo -e "▶ Checking C source syntax and warnings..."
if gcc -fsyntax-only -Wall -Wextra -Werror -pedantic src_c/bridge.c -I/usr/include -I/usr/include/llhttp; then
    echo -e "${GREEN}✔ src_c/bridge.c passes strict C checks${NC}\n"
else
    echo -e "${RED}✘ src_c/bridge.c has compiler warnings or syntax errors${NC}\n"
    ERRORS=$((ERRORS + 1))
fi

# 3. Python Test Syntax Check
echo -e "▶ Checking Python test suite syntax..."
if python3 -m py_compile tests/test_e2e_server.py; then
    echo -e "${GREEN}✔ Python test syntax valid${NC}\n"
else
    echo -e "${RED}✘ Python test syntax errors detected${NC}\n"
    ERRORS=$((ERRORS + 1))
fi

echo -e "${BLUE}=========================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}🎉 All linter checks passed!${NC}"
    echo -e "${BLUE}==========================================${NC}"
    exit 0
else
    echo -e "${RED}❌ $ERRORS linter check(s) failed.${NC}"
    echo -e "${BLUE}==========================================${NC}"
    exit 1
fi
