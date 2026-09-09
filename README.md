# hellopay

CLI **giả**, không làm gì có ích. Nó tồn tại để tập quy trình phát hành một CLI:
GitHub Releases → script cài `curl | bash` → Homebrew → Scoop → script cài PowerShell → npm.

Hướng dẫn từng bước: xem `../HUONG-DAN-PHAT-HANH-CLI.md`.

## Cài đặt

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.ps1 | iex
```

Homebrew:

```bash
brew install hoanghuydev/tap/hellopay
```

Scoop:

```powershell
scoop bucket add hoanghuydev https://github.com/hoanghuydev/scoop-bucket
scoop install hellopay
```

npm — **chưa publish**, lệnh dưới đây sẽ chạy được sau khi kênh này lên:

```bash
npx hellopay@0.1.3 version
npm install --save-dev hellopay@0.1.3
```

Luôn ghi rõ số phiên bản. `@latest` và `npx hellopay` để trống sẽ lấy bất kỳ bản nào đang là mới
nhất lúc đó — đúng thứ mà file khoá phiên bản sinh ra để tránh.

Ba điều khác biệt của kênh npm so với bốn kênh trên:

- **Không có gợi ý lệnh** (tab completion). Gói npm cố ý không chạy script nào lúc cài, mà cài gợi ý
  lệnh thì bắt buộc phải có script. Cần gợi ý lệnh thì dùng `install.sh`, Homebrew hoặc Scoop.
- **Kiểm tra yếu hơn `install.sh`.** `install.sh` kiểm chữ ký cosign; npm không có cơ chế tương
  đương lúc cài. Gói npm bù bằng cách so mã băm trước mỗi lần chạy, nhưng đó không phải thứ thay thế
  được chữ ký.
- **`--omit=optional` làm hỏng.** Binary nằm trong một phụ thuộc tuỳ chọn.

Kiểm xuất xứ — hai bước, không có đường tắt nào tin được một cái huy hiệu:

```bash
npm audit signatures
npm view hellopay repository.url   # phải là github.com/hoanghuydev/hellopay
```

## Dùng

```bash
hellopay hello SePay
hellopay version --json
hellopay echo 'giữ nguyên & mọi ký tự'
hellopay listen                     # chạy tới khi bấm Ctrl-C
```

## Build từ nguồn

```bash
go build -o bin/hellopay ./cmd/hellopay
```
