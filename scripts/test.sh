#!/bin/bash

# Copyright (c) 2025 Ercin Dedeoglu
# Licensed under CC BY-NC 4.0 (Attribution-NonCommercial)
# https://github.com/ErcinDedeoglu/cloudflare-warp-docker
#
# Local development test script
# Run this before committing to ensure everything works

set -e

# Navigate to project root directory (parent of scripts/)
cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="cloudflare-warp-test"
CONTAINER_NAME="warp-test"
GOST_VERSION="3.2.4"
WARP_SLEEP=5
INIT_WAIT=15
PROXY_PORT=1080

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=""

# Cleanup function
cleanup() {
    echo -e "\n${BLUE}🧹 Cleaning up...${NC}"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

# Always cleanup on exit
trap cleanup EXIT

# Log functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS\n  - $1"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Spinner function for long-running operations
spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BLUE}${spin:i++%10:1}${NC} %s" "$msg"
        sleep 0.1
    done
    printf "\r%60s\r" " "  # Clear the line
}

# Print header
echo -e "${BLUE}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         Cloudflare WARP Docker - Local Test Suite          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Test 1: Build Docker image
echo -e "\n${YELLOW}[1/8] Building Docker image...${NC}"
BUILD_LOG=$(mktemp)
docker build \
    --build-arg GOST_VERSION="$GOST_VERSION" \
    --build-arg COMMIT_SHA="local-test" \
    -t "$IMAGE_NAME:latest" . > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!
spinner $BUILD_PID "Building image (this may take a while)..."
wait $BUILD_PID
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
    log_success "Docker image built successfully"
    rm -f "$BUILD_LOG"
else
    log_error "Docker image build failed"
    echo -e "\n${RED}Build output:${NC}"
    cat "$BUILD_LOG"
    rm -f "$BUILD_LOG"
    exit 1
fi

# Test 2: Start container
echo -e "\n${YELLOW}[2/8] Starting container...${NC}"

# Clean up any existing container
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add NET_ADMIN \
    --cap-add MKNOD \
    --cap-add AUDIT_WRITE \
    --device-cgroup-rule='c 10:200 rwm' \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -e WARP_SLEEP="$WARP_SLEEP" \
    -p "$PROXY_PORT:1080" \
    "$IMAGE_NAME:latest" > /dev/null 2>&1; then
    log_success "Container started"
else
    log_error "Container failed to start"
    exit 1
fi

# Test 3: Wait for WARP initialization
echo -e "\n${YELLOW}[3/8] Waiting for WARP to initialize (${INIT_WAIT}s)...${NC}"
sleep "$INIT_WAIT"

# Test 4: Check container is running
echo -e "\n${YELLOW}[4/8] Checking container status...${NC}"
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
    log_success "Container is running"
else
    log_error "Container is not running"
    echo -e "\n${RED}Container logs:${NC}"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -50
    exit 1
fi

# Test 5: Check WARP connection status
echo -e "\n${YELLOW}[5/8] Checking WARP connection status...${NC}"
WARP_STATUS=$(docker exec "$CONTAINER_NAME" warp-cli --accept-tos status 2>&1)
if echo "$WARP_STATUS" | grep -q "Connected"; then
    log_success "WARP is connected"
else
    log_error "WARP is not connected"
    echo -e "${RED}Status: $WARP_STATUS${NC}"
fi

# Test 6: Check SOCKS5 proxy is listening
echo -e "\n${YELLOW}[6/8] Checking SOCKS5 proxy...${NC}"
sleep 2  # Give gost a moment to start
if nc -z localhost "$PROXY_PORT" 2>/dev/null; then
    log_success "SOCKS5 proxy is listening on port $PROXY_PORT"
else
    log_error "SOCKS5 proxy is not listening on port $PROXY_PORT"
fi

# Test 7: Test WARP trace (verify traffic goes through WARP)
echo -e "\n${YELLOW}[7/8] Testing WARP traffic routing...${NC}"
TRACE=$(curl -x "socks5h://localhost:$PROXY_PORT" -s --max-time 30 https://cloudflare.com/cdn-cgi/trace 2>/dev/null)
if [ -n "$TRACE" ]; then
    WARP_FLAG=$(echo "$TRACE" | grep "^warp=" | cut -d= -f2)
    if [ "$WARP_FLAG" = "on" ] || [ "$WARP_FLAG" = "plus" ]; then
        log_success "Traffic is routed through WARP (warp=$WARP_FLAG)"
    else
        log_error "WARP routing not active (warp=$WARP_FLAG)"
    fi
else
    log_error "Failed to get trace from Cloudflare"
fi

# Test 8: Verify IP masking
echo -e "\n${YELLOW}[8/8] Verifying IP masking...${NC}"
REAL_IP=$(curl -s --max-time 15 https://ifconfig.me 2>/dev/null || curl -s --max-time 15 https://api.ipify.org 2>/dev/null)
WARP_IP=$(curl -x "socks5h://localhost:$PROXY_PORT" -s --max-time 30 https://ifconfig.me 2>/dev/null || \
          curl -x "socks5h://localhost:$PROXY_PORT" -s --max-time 30 https://api.ipify.org 2>/dev/null)

if [ -n "$REAL_IP" ] && [ -n "$WARP_IP" ]; then
    if [ "$REAL_IP" != "$WARP_IP" ]; then
        log_success "IP masking works (Real: $REAL_IP → WARP: $WARP_IP)"
    else
        log_error "IP masking failed - IPs are the same: $REAL_IP"
    fi
else
    log_error "Failed to retrieve IP addresses"
fi

# Print summary
echo -e "\n${BLUE}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                      Test Summary                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ✅ ALL TESTS PASSED                      ║${NC}"
    echo -e "${GREEN}║                   Ready to commit! 🚀                       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "\n${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ❌ TESTS FAILED                          ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}Failed tests:$FAILED_TESTS${NC}"
    echo -e "\n${YELLOW}Check container logs for more details:${NC}"
    echo "  docker logs $CONTAINER_NAME"
    exit 1
fi
