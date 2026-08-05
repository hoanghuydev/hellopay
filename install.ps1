# Script cài hellopay cho Windows.
#
#   irm https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.ps1 | iex
#
# Không cần quyền Administrator: mặc định cài vào thư mục của chính người dùng.
#
# Biến môi trường tuỳ chọn:
#   $env:HELLOPAY_VERSION         = 'v0.1.0'   cài đúng phiên bản này
#   $env:HELLOPAY_INSTALL_DIR     = 'C:\tools' thư mục đích
#   $env:HELLOPAY_NO_MODIFY_PATH  = '1'        không ghi PATH vào tài khoản người dùng

$ErrorActionPreference = 'Stop'

# Bọc trong một hàm để khi chạy qua `irm | iex` thì lỗi chỉ dừng script, không
# đóng cả cửa sổ PowerShell của người dùng như `exit` sẽ làm.
function Install-Hellopay {
    $repo = 'hoanghuydev/hellopay'
    $bin  = 'hellopay'

    function Say  { param($m) Write-Host $m }
    function Fail { param($m, [string[]]$detail = @())
        Write-Host "Error: $m"
        foreach ($d in $detail) { Write-Host "  $d" }
    }

    # PowerShell 5.1 (bản có sẵn trong Windows 10/11) mặc định dùng giao thức cũ,
    # GitHub từ chối kết nối. Dòng này bắt nó dùng TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # ─── 1. nhận diện CPU ────────────────────────────────────────────────────
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default {
            Fail "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" @('Supported: AMD64, ARM64.')
            return
        }
    }
    Say "Detected: windows $arch"

    # ─── 2. chọn phiên bản ───────────────────────────────────────────────────
    $version = $env:HELLOPAY_VERSION
    if (-not $version) {
        try {
            $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" `
                -Headers @{ 'User-Agent' = "$bin-installer" } -TimeoutSec 60
            $version = $rel.tag_name
        } catch {
            Fail 'could not determine the latest version.' `
                 @('Check your internet connection, or the repository may have no releases yet.')
            return
        }
    }
    # Tag có tiền tố "v", tên file thì không. Chuẩn hoá để HELLOPAY_VERSION nhận
    # được cả "v0.1.0" lẫn "0.1.0".
    $num = $version.TrimStart('v')
    $tag = "v$num"

    $archive = "${bin}_${num}_windows_${arch}.zip"
    $base    = "https://github.com/$repo/releases/download/$tag"

    # ─── 3. tải về thư mục tạm ───────────────────────────────────────────────
    $tmp = Join-Path $env:TEMP ("$bin-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Say "Downloading $bin $tag..."
        try {
            Invoke-WebRequest "$base/$archive"      -OutFile (Join-Path $tmp $archive)        -UseBasicParsing -TimeoutSec 600
            Invoke-WebRequest "$base/checksums.txt" -OutFile (Join-Path $tmp 'checksums.txt') -UseBasicParsing -TimeoutSec 60
        } catch {
            Fail "could not download $base/$archive" @($_.Exception.Message)
            return
        }

        # ─── 4. đối chiếu mã băm ─────────────────────────────────────────────
        # Chống file bị sửa trên đường truyền hoặc tải hỏng. Không được bỏ bước này.
        Say 'Verifying checksum...'
        $actual = (Get-FileHash (Join-Path $tmp $archive) -Algorithm SHA256).Hash.ToLower()
        $line = Get-Content (Join-Path $tmp 'checksums.txt') |
                Where-Object { $_ -match ('\s' + [regex]::Escape($archive) + '$') } |
                Select-Object -First 1
        if (-not $line) {
            Fail "checksum entry not found for $archive"
            return
        }
        $expected = ($line -split '\s+')[0].ToLower()
        if ($actual -ne $expected) {
            Fail 'checksum verification failed.' @(
                "Expected: $expected",
                "Actual:   $actual",
                'The downloaded file may be corrupted. Please try again.')
            return
        }
        Say 'Checksum verified.'

        # ─── 5. giải nén và đặt vào thư mục đích ─────────────────────────────
        Expand-Archive -Path (Join-Path $tmp $archive) -DestinationPath (Join-Path $tmp 'x') -Force

        $dir = $env:HELLOPAY_INSTALL_DIR
        if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA "Programs\$bin" }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        # Bản đang nằm trên PATH trước khi cài — dùng để cảnh báo trùng ở cuối.
        # Lấy qua biến trung gian: dưới StrictMode, đọc .Source trên null là lỗi.
        $found    = Get-Command $bin -CommandType Application -ErrorAction SilentlyContinue
        $existing = if ($found) { $found.Source } else { $null }

        $target = Join-Path $dir "$bin.exe"
        try {
            Copy-Item (Join-Path $tmp "x\$bin.exe") $target -Force
        } catch {
            Fail "could not write to $target" @("Close any running $bin windows and try again.")
            return
        }

        # ─── 6. đưa thư mục đích vào PATH ────────────────────────────────────
        # Windows có đúng một chỗ chính thức cho PATH của người dùng, nên không
        # phải đoán file cấu hình như bên Unix. Nhưng cửa sổ terminal đang mở đã
        # nạp PATH cũ, nên vẫn phải mở cửa sổ mới.
        # Khởi tạo trước: nếu người dùng bật Set-StrictMode trong $PROFILE thì đọc
        # một biến chưa gán sẽ làm script chết.
        $needsRestart = $false
        $manual       = $false
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $onPath   = ($env:Path -split ';') -contains $dir

        if (-not $onPath) {
            if ($env:HELLOPAY_NO_MODIFY_PATH -eq '1') {
                $manual = $true
            } elseif (($userPath -split ';') -notcontains $dir) {
                [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User')
                $needsRestart = $true
            } else {
                $needsRestart = $true
            }
        }

        # ─── 7. tóm tắt và bước tiếp theo ────────────────────────────────────
        Say ''
        Say "$bin $tag installed to $target"
        Say ''

        if ($existing -and $existing -ne $target) {
            Say "Note: another $bin is already on your PATH at $existing"
            Say "It will take precedence. Remove it, or put $dir earlier in PATH."
            Say ''
        }

        if ($manual) {
            Say "$dir is not on your PATH. Add it with:"
            Say "  [Environment]::SetEnvironmentVariable('Path', `$env:Path + ';$dir', 'User')"
            Say ''
        }

        if ($needsRestart) {
            Say "Added $dir to your user PATH."
            Say 'Open a new terminal, then:'
        } else {
            Say 'Get started:'
        }
        Say "  $bin hello     — print a greeting"
        Say "  $bin version   — show version information"
        Say "  $bin help      — list all commands"
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Install-Hellopay
