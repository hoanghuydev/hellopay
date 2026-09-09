#!/usr/bin/env bash
# Ca test nâng cấp cho kênh npm. Cần một kho gói đã có SẴN HAI phiên bản.
#
#   bash npm/test-upgrade.sh http://localhost:4873 0.1.3 0.1.4
#
# Nâng cấp là chỗ cách làm "gói bọc + 6 gói nền tảng" dễ hỏng nhất, vì binary bị thay
# tại chỗ: cùng đường dẫn, nội dung khác. Bộ nhớ đệm kết quả so mã băm phải nhận ra
# điều đó, nếu không nó sẽ khẳng định một binary chưa từng kiểm là đã kiểm.

set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
REGISTRY=${1:?thiếu địa chỉ kho gói}
FROM=${2:?thiếu phiên bản cũ}
TO=${3:?thiếu phiên bản mới}

WORK=$(mktemp -d)
export XDG_CACHE_HOME=$WORK/cache
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; results=()
record() { results+=("$1|$2|$3|${4:-}"); case $3 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; esac; }
newproj() { rm -rf "$1"; mkdir -p "$1"; cd "$1"; npm init -y >/dev/null 2>&1; }
run() { ./node_modules/.bin/hellopay version 2>&1; }
key() { command -v "$1" >/dev/null 2>&1; }

# U1 — nâng cấp thẳng. Gói nền tảng phải bị thay theo, không phải chỉ gói bọc.
newproj "$WORK/u1"
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$FROM" >/dev/null 2>&1
before=$(run)
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$TO" >/dev/null 2>&1
after=$(run)
plat=$(node -p "require('./node_modules/@hellopay/cli-linux-x64/package.json').version" 2>/dev/null)
if [[ $before == *"$FROM"* && $after == *"$TO"* && $plat == "$TO" ]]; then
  record U1 "nâng cấp $FROM → $TO, gói nền tảng theo cùng" PASS "gói nền tảng: $plat"
else
  record U1 "nâng cấp $FROM → $TO, gói nền tảng theo cùng" FAIL "trước=$before sau=$after nền tảng=$plat"
fi

# U2 — nâng cấp DỞ DANG: gói bọc vẫn là bản cũ, binary đã là bản mới.
# Cài thất bại giữa chừng, mạng đứt, hay Ctrl-C đúng lúc npm đang giải nén đều tạo ra
# trạng thái này. Gói bọc bản cũ mang bảng mã băm của bản cũ, nên nó PHẢI DỪNG.
#
# Ca này cố ý làm nóng đệm trước, trên đúng binary cũ, rồi mới tráo. Nếu chỉ so số
# phiên bản in ra thì không phân biệt được "đã kiểm lại" với "tin đệm rồi chạy bừa" —
# cả hai đều in ra cùng một dòng. Chỉ có trạng thái lệch này mới tách được hai trường
# hợp đó ra.
newproj "$WORK/u2"
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$FROM" >/dev/null 2>&1
run >/dev/null                                   # làm nóng đệm trên binary CŨ
bin=node_modules/@hellopay/cli-linux-x64/bin/hellopay
newbin=$WORK/u2-new/node_modules/@hellopay/cli-linux-x64/bin/hellopay
( newproj "$WORK/u2-new" >/dev/null 2>&1
  npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$TO" >/dev/null 2>&1 )
cd "$WORK/u2"
cp -p "$newbin" "$bin"                           # binary bản mới, gói bọc vẫn bản cũ
out=$(run); code=$?
if [ "$code" != "0" ] && [[ $out == *"checksum verification failed"* ]]; then
  record U2 "nâng cấp dở dang (bọc cũ + binary mới) phải DỪNG" PASS "thoát $code, đệm không che được"
else
  record U2 "nâng cấp dở dang (bọc cũ + binary mới) phải DỪNG" FAIL "exit=$code $out"
fi

# U3 — hạ cấp. Cùng cơ chế, chiều ngược lại; một khoá đệm chỉ dựa vào mtime sẽ trượt
# ở đây, vì file cũ có thể mang lại đúng mtime cũ.
newproj "$WORK/u3"
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$TO" >/dev/null 2>&1
run >/dev/null
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$FROM" >/dev/null 2>&1
out=$(run); code=$?
if [ "$code" = "0" ] && [[ $out == *"$FROM"* ]]; then
  record U3 "hạ cấp $TO → $FROM" PASS "$out"
else
  record U3 "hạ cấp $TO → $FROM" FAIL "exit=$code $out"
fi

# U4 — `npm update` trong khoảng semver.
newproj "$WORK/u4"
npm install --ignore-scripts --registry "$REGISTRY" "hellopay@$FROM" >/dev/null 2>&1
npm update --ignore-scripts --registry "$REGISTRY" hellopay >/dev/null 2>&1
out=$(run)
[[ $out == *"$TO"* ]] && record U4 "npm update đi tới $TO" PASS "$out" \
  || record U4 "npm update đi tới $TO" FAIL "$out"

# U5 — file khoá phiên bản: sau nâng cấp phải chỉ còn mã băm của bản mới.
if grep -q "$TO" package-lock.json && ! grep -q "cli-linux-x64/-/cli-linux-x64-$FROM" package-lock.json; then
  record U5 "file khoá chỉ còn bản mới, không sót bản cũ" PASS "$(grep -c integrity package-lock.json) mục integrity"
else
  record U5 "file khoá chỉ còn bản mới, không sót bản cũ" FAIL "còn sót $FROM"
fi

# U6 — npx không ghi phiên bản phải lấy bản mới nhất.
cd "$WORK"
out=$(npx --yes --registry "$REGISTRY" hellopay version 2>&1 | tail -1)
[[ $out == *"$TO"* ]] && record U6 "npx không ghi phiên bản → lấy bản mới nhất" PASS "$out" \
  || record U6 "npx không ghi phiên bản → lấy bản mới nhất" FAIL "$out"

# U7 — ghim phiên bản phải CHỐNG lại việc bị kéo lên bản mới. Đây là lý do duy nhất
# đáng mở kênh này, nên nó phải có một ca test riêng.
cd "$WORK"
out=$(npx --yes --registry "$REGISTRY" "hellopay@$FROM" version 2>&1 | tail -1)
[[ $out == *"$FROM"* ]] && record U7 "ghim @$FROM vẫn ra $FROM dù đã có $TO" PASS "$out" \
  || record U7 "ghim @$FROM vẫn ra $FROM dù đã có $TO" FAIL "$out"

# U8-U10 — nâng cấp trên pnpm / yarn 1 / bun.
if key pnpm; then
  newproj "$WORK/u8"
  pnpm add "hellopay@$FROM" --registry "$REGISTRY" >/dev/null 2>&1
  pnpm add "hellopay@$TO" --registry "$REGISTRY" >/dev/null 2>&1
  out=$(run)
  [[ $out == *"$TO"* ]] && record U8 "pnpm nâng cấp" PASS "$out" || record U8 "pnpm nâng cấp" FAIL "$out"
else record U8 "pnpm nâng cấp" SKIP "chưa cài pnpm"; fi

if key yarn && [[ $(yarn --version) == 1.* ]]; then
  newproj "$WORK/u9"
  yarn add "hellopay@$FROM" --registry "$REGISTRY" --silent >/dev/null 2>&1
  yarn add "hellopay@$TO" --registry "$REGISTRY" --silent >/dev/null 2>&1
  out=$(run)
  [[ $out == *"$TO"* ]] && record U9 "Yarn 1 nâng cấp" PASS "$out" || record U9 "Yarn 1 nâng cấp" FAIL "$out"
else record U9 "Yarn 1 nâng cấp" SKIP "chưa cài yarn 1"; fi

if key bun; then
  newproj "$WORK/u10"
  bun add "hellopay@$FROM" --registry "$REGISTRY" >/dev/null 2>&1
  bun add "hellopay@$TO" --registry "$REGISTRY" >/dev/null 2>&1
  out=$(run)
  [[ $out == *"$TO"* ]] && record U10 "bun nâng cấp" PASS "$out" || record U10 "bun nâng cấp" FAIL "$out"
else record U10 "bun nâng cấp" SKIP "chưa cài bun"; fi

cd "$ROOT"
printf '\n%-5s %-50s %-6s %s\n' "CA" "NỘI DUNG" "KẾT QUẢ" "GHI CHÚ"
printf '%.0s─' {1..112}; printf '\n'
for r in "${results[@]}"; do
  IFS='|' read -r id name verdict note <<<"$r"
  printf '%-5s %-50s %-6s %s\n' "$id" "$name" "$verdict" "$note"
done
printf '\nnâng cấp %s → %s: %d đạt, %d không đạt, %d bỏ qua\n' \
  "$FROM" "$TO" "$pass" "$fail" "$((${#results[@]}-pass-fail))"
[ "$fail" -eq 0 ] || exit 1
