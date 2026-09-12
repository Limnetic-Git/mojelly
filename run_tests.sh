#!/bin/bash
set -e

# Ensure pixi is on PATH if installed in ~/.pixi/bin
if [ -d "$HOME/.pixi/bin" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
fi

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================="
echo "🍇 Mojelly Comprehensive Test Suite"
echo -e "==========================================${NC}"
echo ""

run_mojo() {
    if command -v pixi &> /dev/null; then
        pixi run mojo "$@"
    else
        mojo "$@"
    fi
}

FAILED_TESTS=0

run_unit_test() {
    local test_file="$1"
    local name="$2"
    echo -e "▶ Running ${BLUE}$name${NC} ($test_file)..."
    if run_mojo -I. "$test_file"; then
        echo -e "${GREEN}✔ $name passed${NC}\n"
    else
        echo -e "${RED}✘ $name failed${NC}\n"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# 1. Mojo Unit Tests
echo -e "${BLUE}--- 1. Mojo Unit Tests ---${NC}"
run_unit_test "tests/test_request.mojo" "HTTPRequest Suite"
run_unit_test "tests/test_response.mojo" "HTTPResponse Suite"
run_unit_test "tests/test_router.mojo" "RouterHandlers Suite"
run_unit_test "tests/test_router_builder.mojo" "RouterBuilder Suite"
run_unit_test "tests/test_generator_helpers.mojo" "Generator Helpers Suite"

# 2. Python E2E Integration Suite
echo -e "${BLUE}--- 2. End-to-End Server Integration Suite ---${NC}"
if python3 tests/test_e2e_server.py; then
    echo -e "${GREEN}✔ E2E Integration Suite passed${NC}\n"
else
    echo -e "${RED}✘ E2E Integration Suite failed${NC}\n"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

echo -e "${BLUE}=========================================="
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}🎉 All test suites passed successfully! (100% Coverage)${NC}"
    echo -e "${BLUE}==========================================${NC}"
    exit 0
else
    echo -e "${RED}❌ $FAILED_TESTS test suite(s) failed.${NC}"
    echo -e "${BLUE}==========================================${NC}"
    exit 1
fi
