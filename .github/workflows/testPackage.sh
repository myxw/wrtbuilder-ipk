name: Test Package Build

on:
  workflow_dispatch:
    inputs:
      PACKAGE_NAME:
        description: 'Package to test (e.g. luci-app-tailscale)'
        required: false
        default: 'luci-app-tailscale'
      SOURCE_REPO:
        description: 'Source repository'
        required: false
        default: 'VIKINGYFY/immortalwrt'
      SOURCE_BRANCH:
        description: 'Source branch'
        required: false
        default: 'main'

env:
  GITHUB_TOKEN: ${{secrets.GITHUB_TOKEN}}

jobs:
  test-package:
    name: Test ${{ github.event.inputs.PACKAGE_NAME }}
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Build Scripts
        uses: actions/checkout@main

      - name: Initialization Environment
        env:
          DEBIAN_FRONTEND: noninteractive
        run: |
          sudo -E apt-get -yqq update
          sudo -E apt-get -yqq full-upgrade
          sudo -E apt-get -yqq install build-essential libncurses5-dev libncursesw5-dev zlib1g-dev gawk git gettext libssl-dev xsltproc rsync wget unzip python3 dos2unix
          sudo timedatectl set-timezone "Asia/Shanghai"
          mkdir -p ~/wrt
          cd ~/wrt

      - name: Clone OpenWrt Source
        run: |
          git clone --depth=1 --single-branch --branch ${{ github.event.inputs.SOURCE_BRANCH }} https://github.com/${{ github.event.inputs.SOURCE_REPO }}.git ./wrt/
          cd ./wrt/
          # Remove domestic mirrors
          if [ -f "./scripts/projectsmirrors.json" ]; then
            sed -i '/.cn\//d; /tencent/d; /aliyun/d' "./scripts/projectsmirrors.json"
          fi

      - name: Update Feeds
        run: |
          cd ~/wrt/wrt/
          ./scripts/feeds update -a
          ./scripts/feeds install -a

      - name: Apply Custom Patches
        run: |
          cd ~/wrt/wrt/package/
          bash $GITHUB_WORKSPACE/scripts/packages.sh
          bash $GITHUB_WORKSPACE/scripts/handles.sh

      - name: Test Package Compilation
        run: |
          cd ~/wrt/wrt/
          PACKAGE="${{ github.event.inputs.PACKAGE_NAME }}"
          
          echo "=========================================="
          echo "Testing package compilation: $PACKAGE"
          echo "=========================================="
          
          # Find the package
          PKG_DIR=$(find . -maxdepth 3 -type d -name "$PACKAGE" | head -1)
          if [ -z "$PKG_DIR" ]; then
            echo "ERROR: Package $PACKAGE not found!"
            echo "Available packages:"
            find ./feeds/*/luci* -maxdepth 1 -type d | head -20
            exit 1
          fi
          
          echo "Found package at: $PKG_DIR"
          
          # Show Makefile
          if [ -f "$PKG_DIR/Makefile" ]; then
            echo ""
            echo "========== Package Makefile =========="
            head -50 "$PKG_DIR/Makefile"
            echo ""
            echo "========== Checking for conflicting files =========="
            grep -E "etc/config|etc/init.d" "$PKG_DIR/Makefile" || echo "No conflicting files found in Makefile"
          fi
          
          # Compile the package
          echo ""
          echo "========== Starting package compilation =========="
          make package/$PACKAGE/download V=s 2>&1 | tail -20
          make package/$PACKAGE/prepare V=s 2>&1 | tail -20
          make package/$PACKAGE/compile V=s 2>&1 | tail -100 || {
            echo ""
            echo "========== Compilation failed! Showing full log =========="
            find ./build_dir -name "*.log" -exec cat {} \; 2>/dev/null | tail -200
            exit 1
          }
          
          echo ""
          echo "========== Package compilation successful! =========="

      - name: Verify Package
        if: success()
        run: |
          cd ~/wrt/wrt/
          PACKAGE="${{ github.event.inputs.PACKAGE_NAME }}"
          
          echo "========== Checking compiled files =========="
          find ./build_dir -type f -path "*$PACKAGE*" -name "*.ipk" 2>/dev/null || echo "No .ipk files found (expected for LuCI apps)"
          
          echo ""
          echo "========== Package files installed =========="
          find ./build_dir -type d -path "*$PACKAGE*" -exec find {} -type f \; 2>/dev/null | head -50

      - name: Check for File Conflicts
        if: always()
        run: |
          cd ~/wrt/wrt/
          PACKAGE="${{ github.event.inputs.PACKAGE_NAME }}"
          
          echo "========== Searching for conflicting files =========="
          
          # Look for the problematic files in package directories
          echo "Looking for etc/config/tailscale..."
          find ./build_dir -type f -path "*/etc/config/tailscale" 2>/dev/null && echo "FOUND!" || echo "Not found (good)"
          
          echo "Looking for etc/init.d/tailscale..."
          find ./build_dir -type f -path "*/etc/init.d/tailscale" 2>/dev/null && echo "FOUND!" || echo "Not found (good)"
          
          # Check what files the package is trying to install
          echo ""
          echo "========== Files in package build =========="
          find ./build_dir -type d -name "$PACKAGE" | while read dir; do
            echo "In: $dir"
            find "$dir" -type f | head -20
          done
