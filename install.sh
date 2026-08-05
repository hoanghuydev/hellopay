#!/bin/sh
# Script cài hellopay cho macOS / Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.sh | bash
#
# Biến môi trường tuỳ chọn:
#   HELLOPAY_VERSION=v0.1.0   cài đúng phiên bản này (mặc định: bản mới nhất)
#   HELLOPAY_INSTALL_DIR=...  thư mục đích (mặc định: ~/.local/bin, hoặc /usr/local/bin nếu chạy root)
#   HELLOPAY_NO_MODIFY_PATH=1 không tự ghi PATH vào file cấu hình shell
#
# Viết bằng POSIX sh (không dùng cú pháp riêng của bash) để chạy được cả với `sh`.
set -eu

REPO="hoanghuydev/hellopay"
BIN="hellopay"

# ─── in ra cho người dùng ────────────────────────────────────────────────────
info()  { printf '\033[1;34m==>\033[0m %s\n' "$1" >&2; }
warn()  { printf '\033[1;33mCẢNH BÁO:\033[0m %s\n' "$1" >&2; }
fail()  { printf '\033[1;31mLỖI:\033[0m %s\n' "$1" >&2; exit 1; }

# ─── 1. cần có curl (hoặc wget) và tar ───────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
  dl_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
  dl_stdout() { wget -qO- "$1"; }
else
  fail "cần curl hoặc wget"
fi
command -v tar >/dev/null 2>&1 || fail "cần tar"

# ─── 2. nhận diện hệ điều hành và CPU ────────────────────────────────────────
# Tên ở đây phải khớp đúng với name_template trong .goreleaser.yaml.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  linux)  os=linux ;;
  darwin) os=darwin ;;
  *)      fail "hệ điều hành chưa hỗ trợ: $os (chỉ có Linux và macOS)" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64)  arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)               fail "CPU chưa hỗ trợ: $arch (chỉ có amd64 và arm64)" ;;
esac

# ─── 3. chọn phiên bản ───────────────────────────────────────────────────────
version="${HELLOPAY_VERSION:-}"
if [ -z "$version" ]; then
  info "đang tìm phiên bản mới nhất..."
  # Đọc tag_name từ API GitHub mà không cần jq.
  version=$(dl_stdout "https://api.github.com/repos/$REPO/releases/latest" \
    | tr ',' '\n' | grep '"tag_name"' | head -n1 | cut -d'"' -f4)
  [ -n "$version" ] || fail "không đọc được phiên bản mới nhất (repo đã có bản phát hành nào chưa?)"
fi
# Bỏ chữ "v" ở đầu: tag là v0.1.0 nhưng tên file dùng 0.1.0.
num="${version#v}"

archive="${BIN}_${num}_${os}_${arch}.tar.gz"
# HELLOPAY_BASE_URL chỉ dùng khi tập/thử với server nội bộ. Người dùng thật không đặt biến này.
base="${HELLOPAY_BASE_URL:-https://github.com/$REPO/releases/download/$version}"

# ─── 4. tải về thư mục tạm rồi tự dọn ────────────────────────────────────────
tmp=$(mktemp -d)
# Dọn thư mục tạm dù script thành công, lỗi, hay bị Ctrl-C.
trap 'rm -rf "$tmp"' EXIT INT TERM

info "đang tải $archive ($version)"
dl "$base/$archive"      "$tmp/$archive"      || fail "không tải được $base/$archive"
dl "$base/checksums.txt" "$tmp/checksums.txt" || fail "không tải được checksums.txt"

# ─── 5. đối chiếu SHA256 ─────────────────────────────────────────────────────
# Bước này chống file bị sửa trên đường truyền hoặc tải hỏng. Không được bỏ.
if command -v sha256sum >/dev/null 2>&1; then
  sum=$(sha256sum "$tmp/$archive" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  sum=$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)
else
  fail "cần sha256sum hoặc shasum để kiểm tra file tải về"
fi
want=$(grep " $archive\$" "$tmp/checksums.txt" | cut -d' ' -f1)
[ -n "$want" ] || fail "checksums.txt không có dòng nào cho $archive"
[ "$sum" = "$want" ] || fail "SHA256 không khớp
  file tải về: $sum
  công bố:     $want
Đừng cài. Hãy báo cho SePay."
info "SHA256 khớp"

# ─── 6. giải nén và đặt vào thư mục đích ─────────────────────────────────────
tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/$BIN" ] || fail "trong gói không thấy file $BIN"

if [ -n "${HELLOPAY_INSTALL_DIR:-}" ]; then
  dir="$HELLOPAY_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
  dir="/usr/local/bin"
else
  dir="$HOME/.local/bin"
fi
mkdir -p "$dir" 2>/dev/null || true

if [ -w "$dir" ]; then
  install -m 0755 "$tmp/$BIN" "$dir/$BIN"
elif command -v sudo >/dev/null 2>&1; then
  info "$dir không ghi được — dùng sudo"
  sudo install -m 0755 "$tmp/$BIN" "$dir/$BIN"
else
  fail "$dir không ghi được và không có sudo. Đặt HELLOPAY_INSTALL_DIR sang thư mục khác."
fi

info "đã cài $dir/$BIN"

# ─── 7. đưa thư mục đích vào PATH ────────────────────────────────────────────
# Giới hạn không lách được: script chạy trong tiến trình con nên KHÔNG sửa được
# PATH của terminal đang gọi nó. Việc duy nhất làm được là ghi vào file cấu hình
# shell để các terminal mở sau này có sẵn. Vì thế vẫn phải nhắc mở shell mới.
case ":$PATH:" in
  *":$dir:"*)
    # Đã có trong PATH — chạy luôn để người dùng thấy bản vừa cài.
    "$dir/$BIN" version || true
    exit 0
    ;;
esac

if [ "${HELLOPAY_NO_MODIFY_PATH:-}" = "1" ]; then
  warn "$dir chưa có trong PATH. Thêm dòng này vào file cấu hình shell của bạn:"
  printf '\n    export PATH="%s:$PATH"\n\n' "$dir" >&2
  exit 0
fi

# Chọn file cấu hình theo shell đang dùng. Mỗi shell đọc một file khác nhau, và
# đoán sai thì ghi xong vẫn không có tác dụng.
shell_name=$(basename "${SHELL:-/bin/sh}")
case "$shell_name" in
  bash) rc="$HOME/.bashrc"; line="export PATH=\"$dir:\$PATH\"" ;;
  zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc"; line="export PATH=\"$dir:\$PATH\"" ;;
  fish) rc="$HOME/.config/fish/config.fish"; line="fish_add_path $dir" ;;
  *)    rc="$HOME/.profile"; line="export PATH=\"$dir:\$PATH\"" ;;
esac

marker="# added by hellopay installer"

if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
  # Đã ghi ở lần cài trước — không ghi thêm, tránh trùng dòng.
  info "$rc đã có sẵn cấu hình PATH của hellopay"
else
  mkdir -p "$(dirname "$rc")" 2>/dev/null || true
  if { printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"; } 2>/dev/null; then
    info "đã thêm $dir vào PATH trong $rc"
  else
    warn "không ghi được vào $rc. Thêm tay dòng này:"
    printf '\n    %s\n\n' "$line" >&2
    exit 0
  fi
fi

warn "PATH chỉ có hiệu lực ở terminal MỚI. Dùng ngay trong terminal này thì chạy:"
printf '\n    source %s\n\n' "$rc" >&2
info "hoặc gọi bằng đường dẫn đầy đủ: $dir/$BIN version"
