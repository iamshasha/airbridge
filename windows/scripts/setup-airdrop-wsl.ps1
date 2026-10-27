<#
.SYNOPSIS
  One-time setup so Apple devices can AirDrop to this PC through AirBridge.

.DESCRIPTION
  AirDrop needs Apple Wireless Direct Link (AWDL). Windows can't speak it, so AirBridge runs the open-source
  OWL (AWDL) and OpenDrop (AirDrop protocol) from TU Darmstadt's SEEMOO lab inside WSL2, using a USB Wi-Fi
  adapter that supports monitor mode and frame injection, passed through with usbipd-win.

  Known-good adapter chipsets: MediaTek MT7612U / MT7921AU (mt76), Atheros AR9271 (ath9k_htc, 2.4 GHz only).
  AWDL uses 5 GHz channels 44/149, so a 5 GHz adapter (MediaTek) works best.

  Limits: Apple devices see this PC only when their AirDrop is set to "Everyone". Sending to Apple devices
  works with any AirDrop setting that allows you.

  Steps (each is skipped when already done):
    1. WSL2 + Ubuntu
    2. usbipd-win
    3. A WSL kernel with USB Wi-Fi drivers (the stock WSL kernel has none) — built from Microsoft's source
    4. OWL and OpenDrop inside Ubuntu
    5. Attach the adapter to WSL

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup-airdrop-wsl.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu",
    [string]$BusId
)
$ErrorActionPreference = "Stop"

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Wsl([string]$script) {
    wsl.exe -d $Distro -u root -e bash -lc $script
    if ($LASTEXITCODE -ne 0) { throw "WSL step failed: $script" }
}

Step "1/5 WSL2 and $Distro"
$distros = (wsl.exe -l -q 2>$null) -replace "`0", ""
if (-not ($distros -match "^$Distro")) {
    wsl.exe --install -d $Distro
    Write-Host "Restart Windows if asked, finish the $Distro first-run setup, then run this script again."
    exit 0
}

Step "2/5 usbipd-win (USB passthrough)"
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    winget install --exact --id dorssel.usbipd-win --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

Step "3/5 WSL kernel with USB Wi-Fi drivers"
$kernelDir = Join-Path $env:USERPROFILE ".airbridge"
$kernel = Join-Path $kernelDir "bzImage-wifi"
if (-not (Test-Path $kernel)) {
    New-Item -ItemType Directory -Force $kernelDir | Out-Null
    $winOut = (wsl.exe -d $Distro -e wslpath -a $kernel) -replace "`0", ""
    Wsl @"
set -e
apt-get update -qq
apt-get install -y -qq build-essential flex bison libssl-dev libelf-dev bc dwarves python3 git
cd /usr/src
[ -d WSL2-Linux-Kernel ] || git clone --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
cp Microsoft/config-wsl .config
for opt in CFG80211 MAC80211 WLAN WLAN_VENDOR_MEDIATEK MT76x2U MT7921U WLAN_VENDOR_ATH ATH9K_HTC WLAN_VENDOR_RALINK RT2X00 RT2800USB USB_NET_DRIVERS; do
  scripts/config --enable `$opt
done
scripts/config --module MT76x2U --module MT7921U --module ATH9K_HTC --module RT2800USB
make olddefconfig
make -j`$(nproc)
make modules_install
cp arch/x86/boot/bzImage '$winOut'
"@
    $wslconfig = Join-Path $env:USERPROFILE ".wslconfig"
    $line = "kernel=" + ($kernel -replace "\\", "\\\\")
    if (Test-Path $wslconfig) {
        $content = Get-Content $wslconfig -Raw
        if ($content -notmatch "(?m)^kernel=") {
            if ($content -notmatch "(?m)^\[wsl2\]") { $content += "`n[wsl2]`n" }
            $content = $content -replace "(?m)^\[wsl2\]", "[wsl2]`n$line"
            Set-Content $wslconfig $content
        } else { Write-Warning ".wslconfig already sets a custom kernel; point it at $kernel if needed." }
    } else {
        Set-Content $wslconfig "[wsl2]`n$line`n"
    }
    wsl.exe --shutdown
}

Step "4/5 OWL and OpenDrop inside $Distro"
Wsl @"
set -e
command -v owl >/dev/null || {
  apt-get install -y -qq cmake libpcap-dev libev-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev iw
  cd /usr/src
  [ -d owl ] || git clone --recursive https://github.com/seemoo-lab/owl.git
  cd owl && mkdir -p build && cd build && cmake .. && make -j`$(nproc) && make install
}
command -v opendrop >/dev/null || {
  apt-get install -y -qq pipx libarchive-dev
  PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install opendrop
}
"@

Step "5/5 Attach the USB Wi-Fi adapter to WSL"
usbipd list
if (-not $BusId) { $BusId = Read-Host "Enter the BUSID of your USB Wi-Fi adapter (for example 2-3)" }
usbipd bind --busid $BusId
usbipd attach --wsl --busid $BusId
Start-Sleep 3
Wsl "iw dev; iw list | grep -A10 'Supported interface modes'"

Write-Host "`nDone. In AirBridge › Settings › AirDrop, choose the adapter's interface (usually wlan1) and turn AirDrop on." -ForegroundColor Green
Write-Host "Re-run 'usbipd attach --wsl --busid $BusId' after unplugging the adapter or restarting Windows."
