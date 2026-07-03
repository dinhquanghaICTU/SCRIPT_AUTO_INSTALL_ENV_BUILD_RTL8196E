#!/usr/bin/env bash

set -Eeuo pipefail

REPO_URL="https://github.com/dinhquanghaICTU/SDK_KERNEL_ROOTFS_BOOTLOADER_RTL8196E.git"
DEFAULT_PROJECT_DIR="${HOME}/SDK_KERNEL_ROOTFS_BOOTLOADER_RTL8196E"
LINUX_ARCHIVE_URL="https://github.com/torvalds/linux/archive/refs/tags/v6.16.tar.gz"
BOARD_IP="192.168.1.88"
DEPLOY=0

usage() {
    echo "Cách dùng:"
    echo "  $0 [--project-dir THU_MUC] [--deploy] [--board-ip IP]"
    echo ""
    echo "Ví dụ:"
    echo "  $0"
    echo "  $0 --project-dir \"$HOME/SDK_KERNEL_ROOTFS_BOOTLOADER_RTL8196E\""
    echo "  $0 --deploy --board-ip 192.168.1.88"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-dir)
            [ "$#" -ge 2 ] || { echo "Thiếu giá trị cho --project-dir" >&2; exit 1; }
            PROJECT_DIR="$2"
            shift 2
            ;;
        --deploy)
            DEPLOY=1
            shift
            ;;
        --board-ip)
            [ "$#" -ge 2 ] || { echo "Thiếu giá trị cho --board-ip" >&2; exit 1; }
            BOARD_IP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Tham số không hợp lệ: $1" >&2
            usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Nếu script đang nằm trong chính repository thì sử dụng repository hiện tại.
if git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    PROJECT_DIR="${PROJECT_DIR:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)}"
else
    PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
fi

echo "========================================="
echo "  CLONE SOURCE"
echo "========================================="

if [ -d "$PROJECT_DIR/.git" ]; then
    echo "Source đã tồn tại: $PROJECT_DIR"
else
    if [ -e "$PROJECT_DIR" ] && [ "$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        echo "ERROR: Thư mục đã tồn tại và không rỗng: $PROJECT_DIR" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$PROJECT_DIR")"
    git clone "$REPO_URL" "$PROJECT_DIR"
fi

TOOLCHAIN_DIR="$PROJECT_DIR/1-Build-Environment/10-lexra-toolchain"
BUILD_SCRIPT="$TOOLCHAIN_DIR/build_toolchain.sh"
CT_CONFIG="$TOOLCHAIN_DIR/crosstool-ng.config"
DOWNLOAD_DIR="$PROJECT_DIR/downloads"
LINUX_ARCHIVE="$DOWNLOAD_DIR/linux-6.16.tar.gz"
COMPILER="$PROJECT_DIR/x-tools/mips-lexra-linux-musl/bin/mips-lexra-linux-musl-g++"

echo ""
echo "========================================="
echo "  CHUẨN BỊ CACHE LINUX 6.16"
echo "========================================="

# Giữ cache tải về trong repository thay vì xóa nó ở mỗi thư mục build tạm.
sed -i \
    's|^sed -i .*CT_LOCAL_TARBALLS_DIR=.*|sed -i "s@CT_LOCAL_TARBALLS_DIR=.*@CT_LOCAL_TARBALLS_DIR=\\"${PROJECT_ROOT}/downloads\\"@" .config|' \
    "$BUILD_SCRIPT"

# Archive GitHub có checksum khác archive đóng gói của kernel.org.
sed -i \
    -e 's/^CT_VERIFY_DOWNLOAD_DIGEST=y/# CT_VERIFY_DOWNLOAD_DIGEST is not set/' \
    -e 's/^CT_VERIFY_DOWNLOAD_DIGEST_SHA512=y/# CT_VERIFY_DOWNLOAD_DIGEST_SHA512 is not set/' \
    -e 's/^CT_VERIFY_DOWNLOAD_DIGEST_ALG=.*/CT_VERIFY_DOWNLOAD_DIGEST_ALG=""/' \
    "$CT_CONFIG"

mkdir -p "$DOWNLOAD_DIR"

if [ -f "$LINUX_ARCHIVE" ] && gzip -t "$LINUX_ARCHIVE" 2>/dev/null; then
    echo "Đã có cache hợp lệ: $LINUX_ARCHIVE"
else
    rm -f "$LINUX_ARCHIVE"
    curl -L --fail --retry 3 --progress-bar \
        "$LINUX_ARCHIVE_URL" \
        -o "$LINUX_ARCHIVE"
    gzip -t "$LINUX_ARCHIVE"
fi

# Xóa output dang dở để build_toolchain.sh không hiểu nhầm là đã cài xong.
if [ -d "$PROJECT_DIR/x-tools/mips-lexra-linux-musl" ] && [ ! -x "$COMPILER" ]; then
    echo "Xóa toolchain build dang dở..."
    rm -rf "$PROJECT_DIR/x-tools/mips-lexra-linux-musl"
fi

echo ""
echo "========================================="
echo "  CÀI MÔI TRƯỜNG VÀ TOOLCHAIN"
echo "========================================="

cd "$PROJECT_DIR/1-Build-Environment"
sudo ./install_deps.sh

if [ ! -x "$COMPILER" ]; then
    echo "ERROR: Không tìm thấy compiler sau khi cài: $COMPILER" >&2
    exit 1
fi

echo ""
echo "========================================="
echo "  BUILD APP LED BLINK"
echo "========================================="

cd "$PROJECT_DIR/APP_EXAMPLE"
"$COMPILER" \
    -Os -Wall -Wextra -static -pthread \
    -o led_blink main.cpp

file led_blink
echo "Build app thành công: $PROJECT_DIR/APP_EXAMPLE/led_blink"

if [ "$DEPLOY" -eq 1 ]; then
    echo ""
    echo "========================================="
    echo "  DEPLOY LÊN BOARD $BOARD_IP"
    echo "========================================="

    SSH_OPTIONS=(-o StrictHostKeyChecking=accept-new)
    sshpass -p root scp "${SSH_OPTIONS[@]}" \
        led_blink "root@${BOARD_IP}:/tmp/led_blink"

    sshpass -p root ssh "${SSH_OPTIONS[@]}" "root@${BOARD_IP}" \
        'chmod +x /tmp/led_blink; echo none > /sys/class/leds/status/trigger; killall led_blink 2>/dev/null || true; nohup /tmp/led_blink >/tmp/led_blink.log 2>&1 &'

    echo "Đã chạy /tmp/led_blink trên board $BOARD_IP"
fi
