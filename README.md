# hellopay

CLI **giả**, không làm gì có ích. Nó tồn tại để tập quy trình phát hành một CLI:
GitHub Releases → script cài `curl | bash` → Homebrew → Scoop → script cài PowerShell.

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

## Dùng

```bash
hellopay hello SePay
hellopay version --json
```

## Build từ nguồn

```bash
go build -o bin/hellopay ./cmd/hellopay
```
