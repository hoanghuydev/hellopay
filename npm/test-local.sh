#!/usr/bin/env bash
# Chạy các ca test của HUONG-DAN-PHAT-HANH-CLI.md §5.9.5 làm được trên máy Linux, rồi in bảng
# đạt/không đạt. Ca 1 (macOS) và ca 9-10 (Windows) không chạy được ở đây — script in
# chúng là SKIP để bảng không bao giờ trông như đã đủ.
#
#   node npm/build-packages.js && bash npm/test-local.sh
#   node npm/build-packages.js && bash npm/test-local.sh http://localhost:4873
#
# Truyền địa chỉ một kho gói đã có sẵn 7 gói này thì ca 4-7 (pnpm/yarn/bun) chạy được;
# không truyền thì chúng là SKIP. Đừng lắp .tgz bằng tay cho các trình đó: mỗi trình có
# một khuôn "overrides" riêng, và test qua khuôn đó là test cái khuôn chứ không phải
# test cách chúng xử lý optionalDependencies — đúng thứ cần biết ở đây.
#
# Không dùng `npm install ./thư-mục`: npm tạo liên kết tới thư mục rồi để 6 gói nền
# tảng ở trạng thái chưa cài mà KHÔNG BÁO GÌ. Mọi ca đều cài từ file .tgz đã đóng gói.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=$ROOT/dist/npm
REGISTRY=${1:-}
WORK=$(mktemp -d)
TGZ=$WORK/tgz
mkdir -p "$TGZ"
trap 'rm -rf "$WORK"; rm -rf "$HOME/.cache/hellopay"' EXIT

pass=0
fail=0
results=()

# `out` phải được xoá trước mỗi ca: nếu một ca thất bại trước khi gán lại nó, ghi chú
# in ra sẽ là kết quả ĐÚNG của ca trước đó, và bảng báo sai chỗ hỏng.
reset() { out=""; }

record() { # record <mã> <tên ca> <PASS|FAIL|SKIP> [ghi chú]
  results+=("$1|$2|$3|${4:-}")
  case $3 in
  PASS) pass=$((pass + 1)) ;;
  FAIL) fail=$((fail + 1)) ;;
  esac
}

[ -d "$OUT" ] || {
  echo "Error: dist/npm/ không tồn tại. Chạy: node npm/build-packages.js" >&2
  exit 1
}

VERSION=$(node -p "require('$OUT/hellopay/package.json').version")
for d in "$OUT"/*/; do (cd "$d" && npm pack --pack-destination "$TGZ" --silent >/dev/null); done

# Mọi project thử nghiệm đều trỏ 6 gói nền tảng về file .tgz nội bộ, vì chúng chưa
# tồn tại trên kho gói thật.
write_project() {
  mkdir -p "$1" && cd "$1"
  node -e "
const fs=require('fs');
const keys=['linux-x64','linux-arm64','darwin-x64','darwin-arm64','win32-x64','win32-arm64'];
const o={};
for(const k of keys) o['@hellopay/cli-'+k]='file:$TGZ/hellopay-cli-'+k+'-$VERSION.tgz';
fs.writeFileSync('package.json', JSON.stringify(
  {name:'t',version:'1.0.0',private:true,overrides:o,resolutions:o}, null, 2));
"
}

# Project rỗng, không khai overrides — dùng cho các ca lấy gói từ kho gói thật.
write_plain_project() {
  mkdir -p "$1" && cd "$1"
  node -e "require('fs').writeFileSync('package.json', JSON.stringify(
    {name:'t',version:'1.0.0',private:true},null,2))"
}

# ca 3: --ignore-scripts (điểm mấu chốt của cách làm B)
write_project "$WORK/c3"
npm install --ignore-scripts "$TGZ/hellopay-$VERSION.tgz" --silent >/dev/null 2>&1
if out=$(./node_modules/.bin/hellopay version 2>&1) && [[ $out == *"$VERSION"* ]]; then
  record 3 "cài với --ignore-scripts" PASS "$out"
else
  record 3 "cài với --ignore-scripts" FAIL "$out"
fi

# npm chỉ tải gói khớp máy
n=$(ls node_modules/@hellopay | wc -l)
[ "$n" = "1" ] && record "3b" "chỉ tải 1/6 gói nền tảng" PASS "$(du -sh node_modules | cut -f1)" ||
  record "3b" "chỉ tải 1/6 gói nền tảng" FAIL "$n gói"

# ca 14: quyền chạy còn nguyên sau đóng gói → giải nén
# Hai phép kiểm khác nhau, đừng gộp:
#   (a) BÊN TRONG file .tgz phải là 0755 — đây là thứ bản phát hành quyết định, và là
#       thứ duy nhất tới được máy khách hàng.
#   (b) Sau khi cài, bit chạy phải còn và binary phải chạy được. KHÔNG so đúng "755":
#       mode trên đĩa còn phụ thuộc umask của máy (máy này umask 002 nên ra 775). Bắt
#       đúng 755 là bắt sai chỗ — nó biến cấu hình cục bộ của lập trình viên thành một
#       lần đỏ CI, và che mất lỗi thật là "mất bit chạy".
BIN=$PWD/node_modules/@hellopay/cli-linux-x64/bin/hellopay
intgz=$(tar -tvzf "$TGZ/hellopay-cli-linux-x64-$VERSION.tgz" | awk '/bin\/hellopay$/{print $1}')
mode=$(stat -c '%a' "$BIN")
if [ "$intgz" = "-rwxr-xr-x" ] && [ -x "$BIN" ]; then
  record 14 "bit chạy còn nguyên (--ignore-scripts)" PASS "trong .tgz=$intgz, trên đĩa=$mode (umask $(umask))"
else
  record 14 "bit chạy còn nguyên (--ignore-scripts)" FAIL "trong .tgz=$intgz, trên đĩa=$mode"
fi

# ca 11: lệnh sai phải thoát khác 0
./node_modules/.bin/hellopay khong-co-lenh-nay >/dev/null 2>&1
code=$?
[ "$code" != "0" ] && record 11 "lệnh sai → mã thoát khác 0" PASS "exit=$code" ||
  record 11 "lệnh sai → mã thoát khác 0" FAIL "exit=0"

# ca 9 (phần làm được trên Linux): đối số đi nguyên vẹn
expected=$'a & b\n|pipe|\n^caret^\n"quoted"\n$(echo pwned)\n*'
actual=$(./node_modules/.bin/hellopay echo 'a & b' '|pipe|' '^caret^' '"quoted"' '$(echo pwned)' '*')
[ "$actual" = "$expected" ] && record "9-linux" "đối số có & | ^ \" \$() đi nguyên vẹn" PASS ||
  record "9-linux" "đối số có & | ^ \" \$() đi nguyên vẹn" FAIL "$(echo "$actual" | tr '\n' '/')"

# ca 10 (phần làm được trên Linux): chuyển tiếp tín hiệu dừng
log=$WORK/listen.log
./node_modules/.bin/hellopay listen >"$log" 2>&1 &
shim=$!
for _ in $(seq 1 50); do grep -q listening "$log" && break; sleep 0.1; done
kill -INT $shim 2>/dev/null
wait $shim
code=$?
if grep -q "shutting down cleanly" "$log" && [ "$code" = "0" ]; then
  record "10-linux" "Ctrl-C tới được binary, dừng sạch" PASS "exit=$code"
else
  record "10-linux" "Ctrl-C tới được binary, dừng sạch" FAIL "exit=$code $(tr '\n' ' ' <"$log")"
fi

# tiến trình con bị kill cứng → mã thoát phải là 128+9
./node_modules/.bin/hellopay listen >/dev/null 2>&1 &
shim=$!
sleep 0.5
pkill -KILL -P $shim 2>/dev/null
wait $shim
code=$?
[ "$code" = "137" ] && record "10b" "binary bị kill -9 → mã thoát 137" PASS ||
  record "10b" "binary bị kill -9 → mã thoát 137" FAIL "exit=$code"

# ca 12: sửa 1 byte trong gói nền tảng
printf 'X' | dd of="$BIN" bs=1 seek=100 conv=notrunc status=none
if out=$(./node_modules/.bin/hellopay version 2>&1); then
  record 12 "sửa 1 byte → phải DỪNG" FAIL "vẫn chạy: $out"
else
  [[ $out == *"checksum verification failed"* ]] &&
    record 12 "sửa 1 byte → phải DỪNG" PASS "thoát 1, có Expected/Actual" ||
    record 12 "sửa 1 byte → phải DỪNG" FAIL "$out"
fi

# ca 2: --omit=optional
write_project "$WORK/c2"
npm install --ignore-scripts --omit=optional "$TGZ/hellopay-$VERSION.tgz" --silent >/dev/null 2>&1
if [ -x ./node_modules/.bin/hellopay ]; then
  out=$(./node_modules/.bin/hellopay version 2>&1)
  code=$?
  [ "$code" != "0" ] && [[ $out == *"is not installed"* ]] &&
    record 2 "--omit=optional → lỗi rõ ràng" PASS "exit=$code" ||
    record 2 "--omit=optional → lỗi rõ ràng" FAIL "exit=$code $out"
else
  record 2 "--omit=optional → lỗi rõ ràng" PASS "npm xoá luôn lệnh khỏi .bin/ (đã biết trước)"
fi

# ca 8: monorepo (gói con, node_modules bị gom lên gốc)
write_project "$WORK/c8"
node -e "
const fs=require('fs'),p=require('./package.json');
p.workspaces=['packages/*']; fs.writeFileSync('package.json',JSON.stringify(p,null,2));
fs.mkdirSync('packages/app',{recursive:true});
fs.writeFileSync('packages/app/package.json', JSON.stringify(
  {name:'app',version:'1.0.0',dependencies:{hellopay:'file:$TGZ/hellopay-$VERSION.tgz'}},null,2));
"
npm install --ignore-scripts --silent >/dev/null 2>&1
if out=$(./node_modules/.bin/hellopay version 2>&1) && [[ $out == *"$VERSION"* ]]; then
  record 8 "monorepo (workspaces, gói gom lên gốc)" PASS
else
  record 8 "monorepo (workspaces, gói gom lên gốc)" FAIL "$out"
fi

# ca 13: preferUnplugged có trên MỌI gói nền tảng
missing=""
for d in "$OUT"/cli-*/; do
  node -e "process.exit(require('$d/package.json').preferUnplugged === true ? 0 : 1)" ||
    missing="$missing $(basename "$d")"
done
[ -z "$missing" ] && record 13 "preferUnplugged: true trên cả 6 gói" PASS ||
  record 13 "preferUnplugged: true trên cả 6 gói" FAIL "thiếu:$missing"

# ca 4-7: pnpm / Yarn 1 / Yarn mới / bun
# Chỉ chạy khi có kho gói thật để trỏ vào. Mỗi trình xử lý optionalDependencies một
# kiểu và đó chính là thứ cần đo.
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "$REGISTRY" ]; then
  record 4 "pnpm" SKIP "không có kho gói — chạy lại kèm địa chỉ kho"
  record 5 "Yarn bản 1" SKIP "không có kho gói"
  record 6 "Yarn bản mới" SKIP "không có kho gói"
  record 7 "bun" SKIP "không có kho gói"
else
  # ca 4 — pnpm
  if have pnpm; then
    reset; write_plain_project "$WORK/c4"
    if pnpm add "hellopay@$VERSION" --registry "$REGISTRY" >/dev/null 2>&1 &&
      out=$(./node_modules/.bin/hellopay version 2>&1) && [[ $out == *"$VERSION"* ]]; then
      record 4 "pnpm $(pnpm --version)" PASS "$(du -sh node_modules | cut -f1)"
    else
      record 4 "pnpm $(pnpm --version)" FAIL "${out:-cài thất bại}"
    fi
  else
    record 4 "pnpm" SKIP "chưa cài pnpm"
  fi

  # ca 5 — Yarn 1. Đo cả lượng TẢI VỀ, không chỉ lượng cài vào: Yarn 1 chỉ đặt gói
  # khớp máy vào node_modules nhưng vẫn kéo đủ 6 gói xuống bộ nhớ đệm.
  if have yarn && [[ $(yarn --version) == 1.* ]]; then
    reset; write_plain_project "$WORK/c5"
    cachedir=$(yarn cache dir 2>/dev/null)
    before=$(ls "$cachedir" 2>/dev/null | grep -c 'hellopay' || true)
    if yarn add "hellopay@$VERSION" --registry "$REGISTRY" --silent >/dev/null 2>&1 &&
      out=$(./node_modules/.bin/hellopay version 2>&1) && [[ $out == *"$VERSION"* ]]; then
      pulled=$(ls "$cachedir" 2>/dev/null | grep -c 'hellopay' || true)
      record 5 "Yarn $(yarn --version) (bản cổ)" PASS \
        "cài $(ls node_modules/@hellopay | wc -l)/6 gói, nhưng TẢI VỀ $((pulled - before)) gói"
    else
      record 5 "Yarn $(yarn --version) (bản cổ)" FAIL "${out:-cài thất bại}"
    fi
  else
    record 5 "Yarn bản 1" SKIP "chưa cài yarn 1"
  fi

  # ca 6 — Yarn bản mới. preferUnplugged phải bung binary ra thành file thật.
  if have yarn; then
    reset; write_plain_project "$WORK/c6"
    yarn set version berry >/dev/null 2>&1
    yarn config set npmRegistryServer "$REGISTRY" >/dev/null 2>&1
    yarn config set unsafeHttpWhitelist localhost >/dev/null 2>&1
    yarn config set enableGlobalCache false >/dev/null 2>&1
    gate=$(yarn config npmMinimalAgeGate 2>/dev/null | awk '/Value:/{print $NF}')
    yarn config set npmMinimalAgeGate 0 >/dev/null 2>&1
    if yarn add "hellopay@$VERSION" >/dev/null 2>&1 &&
      out=$(yarn hellopay version 2>&1 | tail -1) && [[ $out == *"$VERSION"* ]] &&
      unplugged=$(find .yarn/unplugged -type f -name hellopay 2>/dev/null | head -1) &&
      [ -x "$unplugged" ]; then
      record 6 "Yarn $(yarn --version) (bản mới)" PASS "preferUnplugged bung ra file thật; hàng rào tuổi gói mặc định ${gate}p"
    else
      record 6 "Yarn $(yarn --version) (bản mới)" FAIL "${out:-cài thất bại}"
    fi
  else
    record 6 "Yarn bản mới" SKIP "chưa cài yarn"
  fi

  # ca 7 — bun
  if have bun; then
    reset; write_plain_project "$WORK/c7"
    if bun add "hellopay@$VERSION" --registry "$REGISTRY" >/dev/null 2>&1 &&
      out=$(./node_modules/.bin/hellopay version 2>&1) && [[ $out == *"$VERSION"* ]]; then
      n=$(ls node_modules/@hellopay | wc -l)
      # Chạy được là một chuyện; kéo cả 6 gói về là chuyện khác và phải hiện ra bảng.
      # Đây là cái giá người dùng bun phải trả, không phải chi tiết vặt.
      if [ "$n" = "1" ]; then
        record 7 "bun $(bun --version)" PASS "cài $n/6 gói, $(du -sh node_modules | cut -f1)"
      else
        record 7 "bun $(bun --version)" FAIL "chạy được nhưng cài $n/6 gói ($(du -sh node_modules | cut -f1)) — không lọc theo hệ/CPU"
      fi
    else
      record 7 "bun $(bun --version)" FAIL "${out:-cài thất bại}"
    fi
  else
    record 7 "bun" SKIP "chưa cài bun"
  fi
fi

# các ca không chạy được ở đây
record 1 "file khoá tạo trên macOS, cài trên Linux" SKIP "cần máy macOS"
record 9 "Windows: đối số đặc biệt" SKIP "cần máy Windows"
record 10 "Windows: Ctrl-C khi đang chạy lệnh dài" SKIP "cần máy Windows"

# bảng kết quả
cd "$ROOT"
printf '\n%-9s %-46s %-6s %s\n' "CA" "NỘI DUNG" "KẾT QUẢ" "GHI CHÚ"
printf '%.0s─' {1..110}
printf '\n'
for r in "${results[@]}"; do
  IFS='|' read -r id name verdict note <<<"$r"
  printf '%-9s %-46s %-6s %s\n' "$id" "$name" "$verdict" "$note"
done
printf '\nphiên bản %s — %d đạt, %d không đạt, %d bỏ qua\n' \
  "$VERSION" "$pass" "$fail" "$((${#results[@]} - pass - fail))"
[ "$fail" -eq 0 ] || exit 1
