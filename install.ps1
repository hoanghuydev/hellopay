# Install hellopay on Windows.
#
#   irm https://raw.githubusercontent.com/hoanghuydev/hellopay/main/install.ps1 | iex
#
# No Administrator rights needed: installs under the current user's profile.
#
# Optional environment variables:
#   $env:HELLOPAY_VERSION        = 'v1.2.3'   install this exact version
#   $env:HELLOPAY_INSTALL_DIR    = 'C:\tools' target directory
#   $env:HELLOPAY_NO_MODIFY_PATH = '1'        do not touch the user PATH
#   $env:HELLOPAY_SKIP_SIGNATURE = '1'        skip the cosign signature check

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Everything lives in a function so a failure stops the script instead of closing
# the caller's session, which `exit` would do under `irm | iex`.
function Install-Hellopay {
    $repo = 'hoanghuydev/hellopay'
    $bin  = 'hellopay'

    function Say { param($m) Write-Host $m }
    function Fail {
        param($m, [string[]]$detail = @())
        # stderr, so a caller can separate diagnostics from output. `throw` gives a
        # non-zero exit code under `powershell -File`, which a plain `return` does not.
        [Console]::Error.WriteLine("Error: $m")
        foreach ($d in $detail) { [Console]::Error.WriteLine("  $d") }
        throw [System.Exception]::new($m)
    }

    # Windows PowerShell 5.1 still defaults to older TLS and GitHub refuses it.
    # Restore afterwards: under `irm | iex` this runs in the caller's session.
    $tlsBefore = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        # OSArchitecture, not $env:PROCESSOR_ARCHITECTURE: the latter reports x86
        # for a 32-bit PowerShell on 64-bit Windows.
        $arch = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'X64'   { 'amd64' }
            'Arm64' { 'arm64' }
            default { Fail "unsupported architecture: $_" @('Supported: x64, arm64.') }
        }
        Say "Detected: windows $arch"

        $version = if ($env:HELLOPAY_VERSION) { $env:HELLOPAY_VERSION } else { '' }
        if (-not $version) {
            try {
                $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" `
                    -Headers @{ 'User-Agent' = "$bin-installer" } -TimeoutSec 60
                $version = $rel.tag_name
            } catch {
                Fail 'could not determine the latest version.' `
                    @('Check your internet connection, or the repository may have no releases yet.')
            }
        }
        # Tags carry a leading v, filenames do not. Normalize so both forms work.
        $num = $version.TrimStart('v')
        $tag = "v$num"

        $archive = "${bin}_${num}_windows_${arch}.zip"
        # Fixed origin - see the note in install.sh on why this is not overridable.
        $base = "https://github.com/$repo/releases/download/$tag"

        $tmp = Join-Path $env:TEMP ("$bin-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            Say "Downloading $bin $tag..."
            try {
                Invoke-WebRequest "$base/$archive" -OutFile (Join-Path $tmp $archive) -UseBasicParsing -TimeoutSec 600
                Invoke-WebRequest "$base/checksums.txt" -OutFile (Join-Path $tmp 'checksums.txt') -UseBasicParsing -TimeoutSec 60
            } catch {
                Fail "could not download $base/$archive" @($_.Exception.Message)
            }

            # See install.sh: the checksum proves the archive matches checksums.txt,
            # the signature proves checksums.txt came from our release workflow.
            if ($env:HELLOPAY_SKIP_SIGNATURE -ne '1' -and (Get-Command cosign -CommandType Application -ErrorAction SilentlyContinue)) {
                Say 'Verifying signature...'
                try {
                    Invoke-WebRequest "$base/checksums.txt.sig" -OutFile (Join-Path $tmp 'checksums.txt.sig') -UseBasicParsing -TimeoutSec 60
                    Invoke-WebRequest "$base/checksums.txt.pem" -OutFile (Join-Path $tmp 'checksums.txt.pem') -UseBasicParsing -TimeoutSec 60
                } catch {
                    Fail 'this release is not signed.' `
                        @("Install a newer version, or set `$env:HELLOPAY_SKIP_SIGNATURE='1' to continue with SHA256 only.")
                }

                & cosign verify-blob `
                    --certificate (Join-Path $tmp 'checksums.txt.pem') `
                    --signature (Join-Path $tmp 'checksums.txt.sig') `
                    --certificate-identity-regexp "^https://github\.com/$repo/\.github/workflows/" `
                    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
                    (Join-Path $tmp 'checksums.txt') 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Fail 'signature verification failed.' @(
                        "checksums.txt was not signed by the release workflow of $repo.",
                        'Do not install. Please report this to SePay.')
                }
                Say 'Signature verified.'
            }

            Say 'Verifying checksum...'
            $actual = (Get-FileHash (Join-Path $tmp $archive) -Algorithm SHA256).Hash.ToLower()
            $line = Get-Content (Join-Path $tmp 'checksums.txt') |
                Where-Object { $_ -match ('\s' + [regex]::Escape($archive) + '$') } |
                Select-Object -First 1
            if (-not $line) { Fail "checksum entry not found for $archive" }
            $expected = ($line -split '\s+')[0].ToLower()
            if ($actual -ne $expected) {
                Fail 'checksum verification failed.' @(
                    "Expected: $expected",
                    "Actual:   $actual",
                    'The downloaded file may be corrupted. Please try again.')
            }
            Say 'Checksum verified.'

            Expand-Archive -Path (Join-Path $tmp $archive) -DestinationPath (Join-Path $tmp 'x') -Force

            $dir = if ($env:HELLOPAY_INSTALL_DIR) { $env:HELLOPAY_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\$bin" }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            # Resolve before installing, so a copy shadowing ours can be reported.
            $found = Get-Command $bin -CommandType Application -ErrorAction SilentlyContinue
            $existing = if ($found) { $found.Source } else { $null }

            $target = Join-Path $dir "$bin.exe"
            try {
                Copy-Item (Join-Path $tmp "x\$bin.exe") $target -Force
            } catch {
                Fail "could not write to $target" @("Close any running $bin process and try again.")
            }

            $pathState = 'onpath'
            if (-not (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $dir.TrimEnd('\'))) {
                if ($env:HELLOPAY_NO_MODIFY_PATH -eq '1') {
                    $pathState = 'manual'
                } else {
                    $pathState = Add-ToUserPath $dir
                }
            }

            Say ''
            Say "$bin $tag installed to $target"
            Say ''

            if ($existing -and $existing -ne $target) {
                Say "Note: another $bin is already on your PATH at $existing"
                Say "It will take precedence. Remove it, or put $dir earlier in PATH."
                Say ''
            }

            switch ($pathState) {
                'manual' {
                    Say "$dir is not on your PATH. Add it, then reopen your terminal."
                    Say ''
                    Say 'Get started:'
                }
                'failed' {
                    Say "Could not update your PATH. Add $dir to it manually."
                    Say ''
                    Say 'Get started:'
                }
                'added' {
                    Say "Added $dir to your user PATH."
                    Say 'Open a new terminal, then:'
                }
                'already' {
                    Say "$dir is already in your user PATH."
                    Say 'Open a new terminal, then:'
                }
                default { Say 'Get started:' }
            }
            Say "  $bin hello     - print a greeting"
            Say "  $bin version   - show version information"
            Say "  $bin help      - list all commands"
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $tlsBefore
    }
}

# Appends to the user PATH through the registry rather than
# [Environment]::SetEnvironmentVariable, which reads PATH already expanded and
# writes it back as REG_SZ - that turns %USERPROFILE% style entries into fixed
# paths and stops every %VAR% in PATH from expanding afterwards.
# Returns 'added', 'already' or 'failed'.
function Add-ToUserPath {
    param([string]$Dir)

    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    if (-not $key) { return 'failed' }
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
        if (($parts | ForEach-Object { $_.TrimEnd('\') }) -contains $Dir.TrimEnd('\')) { return 'already' }

        # Always ExpandString: identical to REG_SZ when there is nothing to expand,
        # and it keeps %VAR% entries working when there is.
        $key.SetValue('Path', (($parts + $Dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Dispose()
    }

    Send-EnvironmentChange
    return 'added'
}

# .NET's SetEnvironmentVariable broadcasts WM_SETTINGCHANGE for us; writing the
# registry directly does not, and without it Explorer keeps handing new terminals
# the old environment block until the next sign-in.
function Send-EnvironmentChange {
    if (-not ('HellopayEnv.Native' -as [type])) {
        Add-Type -Namespace 'HellopayEnv' -Name 'Native' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST   = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x2
    $result = [UIntPtr]::Zero
    [void][HellopayEnv.Native]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
        'Environment', $SMTO_ABORTIFHUNG, 5000, [ref]$result)
}

# Fail already printed the message. `exit` sets a real exit code under
# `powershell -File` but would close the caller's session under `irm | iex`.
try {
    Install-Hellopay
} catch {
    # Probed inside try: under `iex` there is no script path and StrictMode turns a
    # plain lookup into a second error on top of the one we just reported.
    $ranAsFile = $false
    try { $ranAsFile = [bool]$PSCommandPath } catch { $ranAsFile = $false }
    if ($ranAsFile) { exit 1 }
    return
}
