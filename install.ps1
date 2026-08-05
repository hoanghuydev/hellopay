# Script cài hellopay cho Windows.
#
#   irm https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.ps1 | iex
#
# Không cần quyền Administrator: mặc định cài vào thư mục của chính người dùng.
#
# Biến môi trường tuỳ chọn:
#   $env:HELLOPAY_VERSION     = 'v0.1.0'   cài đúng phiên bản này
#   $env:HELLOPAY_INSTALL_DIR = 'C:\tools' thư mục đích

$ErrorActionPreference = 'Stop'

$Repo = 'hoanghuydev/hellopay'
$Bin  = 'hellopay'

function Write-Info { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "CẢNH BÁO: $m" -ForegroundColor Yellow }

# PowerShell 5.1 (bản có sẵn trong Windows 10/11) mặc định vẫn dùng TLS cũ,
# GitHub sẽ từ chối. Dòng này bắt nó dùng TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─── 1. nhận diện CPU ────────────────────────────────────────────────────────
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "CPU chưa hỗ trợ: $env:PROCESSOR_ARCHITECTURE" }
}

# ─── 2. chọn phiên bản ───────────────────────────────────────────────────────
$version = $env:HELLOPAY_VERSION
if (-not $version) {
    Write-Info 'đang tìm phiên bản mới nhất...'
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers @{ 'User-Agent' = 'hellopay-installer' }
    $version = $rel.tag_name
}
if (-not $version) { throw 'không đọc được phiên bản mới nhất' }
$num = $version.TrimStart('v')   # tag v0.1.0 -> tên file 0.1.0

$archive = "${Bin}_${num}_windows_${arch}.zip"
$base    = "https://github.com/$Repo/releases/download/$version"

# ─── 3. tải về thư mục tạm ───────────────────────────────────────────────────
$tmp = Join-Path $env:TEMP ("hellopay-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Write-Info "đang tải $archive ($version)"
    Invoke-WebRequest "$base/$archive"      -OutFile (Join-Path $tmp $archive)      -UseBasicParsing
    Invoke-WebRequest "$base/checksums.txt" -OutFile (Join-Path $tmp 'checksums.txt') -UseBasicParsing

    # ─── 4. đối chiếu SHA256 ─────────────────────────────────────────────────
    $got = (Get-FileHash (Join-Path $tmp $archive) -Algorithm SHA256).Hash.ToLower()
    $line = Get-Content (Join-Path $tmp 'checksums.txt') |
            Where-Object { $_ -match [regex]::Escape($archive) + '$' } |
            Select-Object -First 1
    if (-not $line) { throw "checksums.txt không có dòng nào cho $archive" }
    $want = ($line -split '\s+')[0].ToLower()
    if ($got -ne $want) {
        throw "SHA256 không khớp`n  file tải về: $got`n  công bố:     $want`nĐừng cài. Hãy báo cho SePay."
    }
    Write-Info 'SHA256 khớp'

    # ─── 5. giải nén và đặt vào thư mục đích ─────────────────────────────────
    Expand-Archive -Path (Join-Path $tmp $archive) -DestinationPath (Join-Path $tmp 'x') -Force

    $dir = $env:HELLOPAY_INSTALL_DIR
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA "Programs\$Bin" }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # Không ghi đè được nếu bản cũ đang chạy — nói rõ thay vì để lỗi khó hiểu.
    try {
        Copy-Item (Join-Path $tmp "x\$Bin.exe") (Join-Path $dir "$Bin.exe") -Force
    } catch {
        throw "không ghi được $dir\$Bin.exe — đóng mọi cửa sổ đang chạy $Bin rồi thử lại"
    }
    Write-Info "đã cài $dir\$Bin.exe"

    # ─── 6. thêm vào PATH của người dùng (một lần) ───────────────────────────
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$dir*") {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User')
        Write-Warn "đã thêm $dir vào PATH — MỞ CỬA SỔ TERMINAL MỚI để dùng được lệnh $Bin"
    } else {
        $env:Path = "$env:Path;$dir"
        & (Join-Path $dir "$Bin.exe") version
    }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
