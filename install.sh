#!/bin/sh
# Script cài hellopay cho macOS và Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.sh | bash
#
# Biến môi trường tuỳ chọn:
#   HELLOPAY_VERSION=v0.1.0    cài đúng phiên bản này (mặc định: bản mới nhất)
#   HELLOPAY_INSTALL_DIR=...   thư mục đích (mặc định: ~/.local/bin, hoặc /usr/local/bin nếu là root)
#   HELLOPAY_NO_MODIFY_PATH=1  không ghi PATH vào file cấu hình shell
#
# Viết bằng POSIX sh (không dùng cú pháp riêng của bash) để chạy được cả với `sh`.
set -eu

REPO="hoanghuydev/hellopay"
BIN="hellopay"

# Thông báo không màu, một dòng một việc — chạy trong CI hay ghi ra log đều đọc được.
say()  { printf '%s\n' "$1"; }
fail() { printf 'Error: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

# ─── 1. công cụ cần có ───────────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
  dl_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
  dl_stdout() { wget -qO- "$1"; }
else
  fail "curl or wget is required but neither is installed."
fi
command -v tar >/dev/null 2>&1 || fail "tar is required but is not installed."

# ─── 2. nhận diện hệ điều hành và CPU ────────────────────────────────────────
# Tên ở đây phải khớp đúng với name_template trong .goreleaser.yaml.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  linux)  os=linux ;;
  darwin) os=darwin ;;
  *)      fail "unsupported operating system: $os" "Supported: macOS, Linux." ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64 | amd64)  arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)               fail "unsupported architecture: $arch" "Supported: x86_64, arm64." ;;
esac

say "Detected: $os $arch"

# ─── 3. chọn phiên bản ───────────────────────────────────────────────────────
version="${HELLOPAY_VERSION:-}"
if [ -z "$version" ]; then
  # Đọc tag_name từ API GitHub mà không cần jq.
  version=$(dl_stdout "https://api.github.com/repos/$REPO/releases/latest" \
    | tr ',' '\n' | grep '"tag_name"' | head -n1 | cut -d'"' -f4)
  [ -n "$version" ] || fail "could not determine the latest version." \
    "Check your internet connection, or the repository may have no releases yet."
fi
num="${version#v}"   # tag là v0.1.0 nhưng tên file dùng 0.1.0

archive="${BIN}_${num}_${os}_${arch}.tar.gz"
# HELLOPAY_BASE_URL chỉ dùng khi thử với server nội bộ. Người dùng thật không đặt biến này.
base="${HELLOPAY_BASE_URL:-https://github.com/$REPO/releases/download/$version}"

# ─── 4. tải về thư mục tạm rồi tự dọn ────────────────────────────────────────
tmp=$(mktemp -d)
# Dọn thư mục tạm dù script thành công, lỗi, hay bị Ctrl-C.
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading $BIN $version..."
dl "$base/$archive"      "$tmp/$archive"      || fail "could not download $base/$archive"
dl "$base/checksums.txt" "$tmp/checksums.txt" || fail "could not download $base/checksums.txt"

# ─── 5. đối chiếu mã băm ─────────────────────────────────────────────────────
# Chống file bị sửa trên đường truyền hoặc tải hỏng. Không được bỏ bước này.
say "Verifying checksum..."
expected=$(sed -n "s/^\([a-f0-9]*\)  *${archive}\$/\1/p" "$tmp/checksums.txt")
[ -n "$expected" ] || fail "checksum entry not found for $archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$archive" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)
else
  fail "no sha256sum or shasum available to verify the download." \
    "Install one and re-run. Do not skip verification."
fi

if [ "$actual" != "$expected" ]; then
  fail "checksum verification failed." \
    "Expected: $expected" \
    "Actual:   $actual" \
    "The downloaded file may be corrupted. Please try again."
fi
say "Checksum verified."

# ─── 6. giải nén và đặt vào thư mục đích ─────────────────────────────────────
tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/$BIN" ] || fail "the archive does not contain $BIN"

if [ -n "${HELLOPAY_INSTALL_DIR:-}" ]; then
  dir="$HELLOPAY_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
  dir="/usr/local/bin"
else
  dir="$HOME/.local/bin"
fi
mkdir -p "$dir" 2>/dev/null || true

# Bản đang nằm trên PATH trước khi cài — dùng để cảnh báo trùng ở cuối.
existing=$(command -v "$BIN" 2>/dev/null || true)

if [ -w "$dir" ]; then
  install -m 0755 "$tmp/$BIN" "$dir/$BIN"
elif command -v sudo >/dev/null 2>&1; then
  say "Requesting sudo to write to $dir..."
  sudo install -m 0755 "$tmp/$BIN" "$dir/$BIN"
else
  fail "cannot write to $dir and sudo is not available." \
    "Set HELLOPAY_INSTALL_DIR to a directory you can write to."
fi

# ─── 7. đưa thư mục đích vào PATH ────────────────────────────────────────────
# Giới hạn không lách được: script chạy trong tiến trình con nên không sửa được
# PATH của terminal đang gọi nó. Việc làm được là ghi vào file cấu hình shell để
# các terminal mở sau này có sẵn — nên vẫn phải nhắc source hoặc mở shell mới.
needs_source=false
rc=""

case ":$PATH:" in
  *":$dir:"*) ;;   # đã có trong PATH, không cần làm gì
  *)
    if [ "${HELLOPAY_NO_MODIFY_PATH:-}" = "1" ]; then
      rc="__skip__"
    else
      # Mỗi shell đọc một file khác nhau; đoán sai thì ghi xong vẫn vô tác dụng.
      case "$(basename "${SHELL:-/bin/sh}")" in
        bash)
          if [ -f "$HOME/.bashrc" ]; then rc="$HOME/.bashrc"; else rc="$HOME/.bash_profile"; fi
          line="export PATH=\"$dir:\$PATH\"" ;;
        zsh)
          rc="${ZDOTDIR:-$HOME}/.zshrc"
          line="export PATH=\"$dir:\$PATH\"" ;;
        fish)
          rc="$HOME/.config/fish/config.fish"
          line="fish_add_path $dir" ;;
        *)
          rc="$HOME/.profile"
          line="export PATH=\"$dir:\$PATH\"" ;;
      esac

      # Bỏ qua nếu file đã nhắc tới thư mục này — dù do lần cài trước hay do
      # người dùng tự thêm. Tránh ghi trùng khi cài lại nhiều lần.
      if [ -f "$rc" ] && grep -qF "$dir" "$rc" 2>/dev/null; then
        needs_source=true
      elif { printf '\n# hellopay\n%s\n' "$line" >> "$rc"; } 2>/dev/null; then
        needs_source=true
      else
        rc="__unwritable__"
      fi
    fi
    ;;
esac

# ─── 8. tóm tắt và bước tiếp theo ────────────────────────────────────────────
say ""
say "$BIN $version installed to $dir/$BIN"
say ""

if [ -n "$existing" ] && [ "$existing" != "$dir/$BIN" ]; then
  say "Note: another $BIN is already on your PATH at $existing"
  say "It will take precedence. Remove it, or put $dir earlier in PATH."
  say ""
fi

case "$rc" in
  __skip__)
    say "$dir is not on your PATH. Add this line to your shell config:"
    say "  export PATH=\"$dir:\$PATH\""
    say "" ;;
  __unwritable__)
    say "Could not write to your shell config. Add this line manually:"
    say "  $line"
    say "" ;;
esac

if [ "$needs_source" = true ]; then
  say "Added $dir to PATH in $rc"
  say "Run 'source $rc' or open a new terminal, then:"
else
  say "Get started:"
fi
say "  $BIN hello     — print a greeting"
say "  $BIN version   — show version information"
say "  $BIN help      — list all commands"
