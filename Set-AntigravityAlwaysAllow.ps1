[CmdletBinding()]
param(
    [int]$Port = 9000,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Backup-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $backupPath = "$Path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if ($DryRun) {
        Write-Log "[dry-run] backup $Path -> $backupPath"
        return
    }

    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Log "Backed up: $backupPath"
}

function Convert-ToMergeObject {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = Convert-ToMergeObject $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            $result[$prop.Name] = Convert-ToMergeObject $prop.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { Convert-ToMergeObject $_ })
        return ,$items
    }

    return $Value
}

function Parse-JsonLikeFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        return Convert-ToMergeObject ($raw | ConvertFrom-Json)
    } catch {
        $withoutBlockComments = [regex]::Replace($raw, "/\*[\s\S]*?\*/", "")
        $withoutLineComments = [regex]::Replace($withoutBlockComments, "(?m)^\s*//.*$", "")
        $withoutTrailingCommas = [regex]::Replace($withoutLineComments, ",(\s*[}\]])", '$1')
        return Convert-ToMergeObject ($withoutTrailingCommas | ConvertFrom-Json)
    }
}

function Merge-Hashtable {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    foreach ($key in $Overlay.Keys) {
        $overlayValue = $Overlay[$key]
        if (
            $Base.ContainsKey($key) -and
            ($Base[$key] -is [hashtable]) -and
            ($overlayValue -is [hashtable])
        ) {
            Merge-Hashtable -Base $Base[$key] -Overlay $overlayValue | Out-Null
            continue
        }

        $Base[$key] = $overlayValue
    }

    return $Base
}

function Write-JsonSettings {
    param(
        [string]$Path,
        [hashtable]$Overlay
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($DryRun) {
        Write-Log "[dry-run] merge settings into $Path"
        return
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        "{}" | Set-Content -LiteralPath $Path -Encoding utf8
    }

    Backup-File -Path $Path
    $base = Parse-JsonLikeFile -Path $Path
    $merged = Merge-Hashtable -Base $base -Overlay $Overlay
    $merged | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
    Write-Log "Updated: $Path"
}

function Write-CdpShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ExecutablePath,
        [int]$Port
    )

    if ($DryRun) {
        Write-Log "[dry-run] write launcher $ShortcutPath -> $ExecutablePath --remote-debugging-port=$Port"
        return
    }

    $dir = [System.IO.Path]::GetDirectoryName($ShortcutPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $ExecutablePath
    $shortcut.Arguments = "--remote-debugging-port=$Port"
    $shortcut.WorkingDirectory = Split-Path -Parent $ExecutablePath
    $shortcut.Description = "Start Antigravity with CDP $Port for Auto Accept"
    $shortcut.Save()
    Write-Log "Updated launcher: $ShortcutPath"
}

function Invoke-PythonStatePatch {
    param(
        [int]$Port,
        [string]$LauncherPath
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        Write-Log "Python not found. Skipping Antigravity SQLite state patch."
        return
    }

    if ($DryRun) {
        Write-Log "[dry-run] patch Antigravity state.vscdb files"
        return
    }

    $env:AG_ALWAYS_ALLOW_PORT = [string]$Port
    $env:AG_ALWAYS_ALLOW_LAUNCHER = $LauncherPath

    $script = @'
import base64
import json
import os
import sqlite3
from pathlib import Path

port = int(os.environ["AG_ALWAYS_ALLOW_PORT"])
launcher = os.environ["AG_ALWAYS_ALLOW_LAUNCHER"]
appdata = Path(os.environ["APPDATA"])

dbs = [
    appdata / "Antigravity" / "User" / "globalStorage" / "state.vscdb",
    appdata / "Antigravity IDE" / "User" / "globalStorage" / "state.vscdb",
]

def enc_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def field_bytes(field_no, payload):
    return bytes([(field_no << 3) | 2]) + enc_varint(len(payload)) + payload

def make_entry(k, v):
    inner = field_bytes(1, v.encode("utf-8"))
    entry = field_bytes(1, k.encode("utf-8")) + field_bytes(2, inner)
    return field_bytes(1, entry)

def parse_entries(raw):
    entries = []
    i = 0
    while i < len(raw):
        if raw[i] != 0x0a:
            break
        i += 1
        shift = 0
        length = 0
        while True:
            c = raw[i]
            i += 1
            length |= (c & 0x7f) << shift
            if not c & 0x80:
                break
            shift += 7
        entries.append(raw[i:i + length])
        i += length
    return entries

def parse_entry(entry):
    i = 0
    key = None
    val = None
    while i < len(entry):
        tag = entry[i]
        i += 1
        shift = 0
        length = 0
        while True:
            c = entry[i]
            i += 1
            length |= (c & 0x7f) << shift
            if not c & 0x80:
                break
            shift += 7
        payload = entry[i:i + length]
        i += length
        if tag == 0x0a:
            key = payload.decode("utf-8", errors="replace")
        elif tag == 0x12 and payload and payload[0] == 0x0a:
            j = 1
            shift = 0
            ln = 0
            while True:
                c = payload[j]
                j += 1
                ln |= (c & 0x7f) << shift
                if not c & 0x80:
                    break
                shift += 7
            val = payload[j:j + ln].decode("utf-8", errors="replace")
    return key, val

for db in dbs:
    if not db.exists():
        print(f"Skipped missing state DB: {db}")
        continue

    backup = db.with_name(db.name + ".backup-" + __import__("datetime").datetime.now().strftime("%Y%m%d-%H%M%S"))
    backup.write_bytes(db.read_bytes())

    con = sqlite3.connect(str(db), timeout=10)
    cur = con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")

    key = "pesosz.antigravity-auto-accept"
    cur.execute("SELECT value FROM ItemTable WHERE key = ?", (key,))
    row = cur.fetchone()
    state = {}
    if row and row[0]:
        value = row[0].decode("utf-8", errors="replace") if isinstance(row[0], bytes) else row[0]
        try:
            state = json.loads(value)
        except Exception:
            state = {}
    state.update({
        "auto-accept-free-enabled": True,
        "auto-accept-free-background": True,
        "auto-accept-free-saved-launcher-path-v1": launcher,
        "auto-accept-free-saved-launcher-port-v1": port,
    })
    cur.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", (key, json.dumps(state, separators=(",", ":"))))

    cur.execute("SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.agentPreferences'")
    row = cur.fetchone()
    raw = b""
    if row and row[0]:
        value = row[0].decode("utf-8", errors="replace") if isinstance(row[0], bytes) else row[0]
        try:
            raw = base64.b64decode(value)
        except Exception:
            raw = b""

    existing = {}
    order = []
    for entry in parse_entries(raw):
        k, v = parse_entry(entry)
        if k:
            existing[k] = v or ""
            order.append(k)

    updates = {
        "terminalAutoExecutionPolicySentinelKey": "EAM=",
        "artifactReviewPolicySentinelKey": "EAI=",
        "permission_grants_global": "ChZleGVjdXRlX3VybChsb2NhbGhvc3Qp",
    }
    for k, v in updates.items():
        if k not in order:
            if k.startswith("terminal"):
                order.insert(0, k)
            elif k.startswith("artifact"):
                order.insert(min(1, len(order)), k)
            else:
                order.append(k)
        existing[k] = v

    rebuilt = b"".join(make_entry(k, existing[k]) for k in order if k in existing)
    encoded = base64.b64encode(rebuilt).decode("ascii")
    cur.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.agentPreferences', ?)", (encoded,))

    con.commit()
    con.close()
    print(f"Updated state DB: {db}")
'@

    $script | & $python.Source -
}

$executablePath = Join-Path $env:LOCALAPPDATA "Programs\Antigravity\Antigravity.exe"
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Antigravity executable not found: $executablePath"
}

$overlay = @{
    "autoAcceptFree.cdpPort" = $Port
    "autoAcceptFree.pauseOnCdpMismatch" = $false
    "autoAcceptFree.antigravityExecutablePath" = $executablePath
    "autoAcceptFree.pollInterval" = 250
    "autoAcceptFree.bannedCommands" = @()
    "security.workspace.trust.enabled" = $false
    "security.workspace.trust.startupPrompt" = "never"
    "security.workspace.trust.banner" = "never"
    "security.workspace.trust.emptyWindow" = $false
    "workbench.trustedDomains.promptInTrustedWorkspace" = $false
}

$userDirs = @(
    (Join-Path $env:APPDATA "Antigravity\User"),
    (Join-Path $env:APPDATA "Antigravity IDE\User")
)

foreach ($userDir in $userDirs) {
    Write-JsonSettings -Path (Join-Path $userDir "settings.json") -Overlay $overlay
}

$launcherPath = Join-Path $env:USERPROFILE "OneDrive\Desktop\Start Antigravity (CDP $Port).lnk"
Write-CdpShortcut -ShortcutPath $launcherPath -ExecutablePath $executablePath -Port $Port
Invoke-PythonStatePatch -Port $Port -LauncherPath $launcherPath

if (-not $DryRun) {
    $listener = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($listener) {
        Write-Log "CDP port $Port is currently listening."
    } else {
        Write-Log "CDP port $Port is not listening. Fully restart Antigravity through: $launcherPath"
    }
}

Write-Log "Done."
