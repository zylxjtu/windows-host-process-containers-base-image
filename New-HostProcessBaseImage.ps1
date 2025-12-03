# Check if running as Administrator (required for reg load/unload)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator to create registry hive files using 'reg load'."
    Write-Host "Please right-click PowerShell and select 'Run as Administrator', then run this script again." -ForegroundColor Yellow
    exit 1
}

Remove-Item -Path "build" -Force -Recurse -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "build" | Out-Null
New-Item -ItemType Directory -Path "build\layer" | Out-Null

# Create the files that ProcessBaseLayer on Windows validates when unpacking images.
# On Windows Server 2025, these must be valid registry hives, not empty files.
New-Item -ItemType Directory -Path "build\layer\Files\Windows\System32\config" -Force | Out-Null

Write-Host "`nCreating minimal registry hive files..." -ForegroundColor Cyan

# Create valid empty registry hive files using reg load/unload
# This creates truly minimal empty hives without requiring saved registry keys
foreach ($f in @('DEFAULT', 'SAM', 'SECURITY', 'SOFTWARE', 'SYSTEM')) {
    $hivePath = "build\layer\Files\Windows\System32\config\$f"
    
    # Ensure the file doesn't exist
    if (Test-Path $hivePath) {
        Remove-Item -Path $hivePath -Force
    }
    
    # Create an empty hive by loading and immediately unloading
    # This creates a minimal valid registry hive file
    $tempKeyName = "HKLM\TempEmpty_$f"
    $null = & reg.exe load $tempKeyName $hivePath 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $null = & reg.exe unload $tempKeyName 2>&1
        
        if (Test-Path $hivePath) {
            $fileSize = (Get-Item $hivePath).Length
            Write-Host "  ✓ Created registry hive: $f ($fileSize bytes)" -ForegroundColor Green
        } else {
            Write-Error "Failed to create registry hive: $f"
            exit 1
        }
    } else {
        Write-Error "Failed to load registry hive: $f"
        exit 1
    }
}

# Add CC0 license to image.
Copy-Item -Path "cc0-license.txt" -Destination "build\layer\Files\License.txt"
Copy-item -Path "cc0-legalcode.txt" -Destination "build\layer\Files\cc0-legalcode.txt"

# Create layer.tar
Push-Location build\layer
if ($IsLinux) {
    tar -cf layer.tar Files
} else {
    tar.exe -cf layer.tar Files
}
Pop-Location

# Get hash of layer.tar
$layerHash = (Get-FileHash -Algorithm SHA256 "build\layer\layer.tar").Hash.ToLower()
Write-Output "layer.tar hash: $layerHash"

# Add json and VERSION files for layer
New-Item -ItemType Directory -Path "build\image\${layerhash}" | Out-Null
"1.0" | Out-File -FilePath "build\image\${layerHash}\VERSION" -Encoding ascii
Copy-Item -Path  "build\layer\layer.tar" -Destination "build\image\${layerHash}\layer.tar"

$now = [DateTime]::UtcNow.ToString("o")
@"
{
    "id": "${layerHash}",
    "created": "${now}",
    "container_config": {
        "Hostname": "",
        "Domainname": "",
        "User": "",
        "AttachStdin": false,
        "AttachStdout": false,
        "AttachStderr": false,
        "Tty": false,
        "OpenStdin": false,
        "StdinOnce": false,
        "Env": null,
        "Cmd": null,
        "Image": "",
        "Volumes": null,
        "WorkingDir": "",
        "Entrypoint": null,
        "OnBuild": null,
        "Labels": null
    },
    "config": {
        "Hostname": "",
        "Domainname": "",
        "User": "ContainerUser",
        "AttachStdin": false,
        "AttachStdout": false,
        "AttachStderr": false,
        "Tty": false,
        "OpenStdin": false,
        "StdinOnce": false,
        "Env": null,
        "Cmd": [
            "c:\\windows\\system32\\cmd.exe"
        ],
        "Image": "",
        "Volumes": null,
        "WorkingDir": "",
        "Entrypoint": null,
        "OnBuild": null,
        "Labels": null
    },
    "architecture": "amd64",
    "os": "windows"
}
"@ | Out-File -FilePath "build\image\${layerHash}\json" -Encoding ascii


# Create the image config and manifest files
@"
{
    "architecture": "amd64",
    "config": {
        "Hostname": "",
        "Domainname": "",
        "User": "",
        "AttachStdin": false,
        "AttachStdout": false,
        "AttachStderr": false,
        "Tty": false,
        "OpenStdin": false,
        "StdinOnce": false,
        "Env": null,
        "Cmd": [
            "c:\\windows\\system32\\cmd.exe"
        ],
        "Image": "",
        "Volumes": null,
        "WorkingDir": "",
        "Entrypoint": null,
        "OnBuild": null,
        "Labels": null
    },
    "created": "${now}",
    "history": [
        {
            "created": "${now}"
        }
    ],
    "os": "windows",
    "rootfs": {
        "type": "layers",
        "diff_ids": [
            "sha256:${layerHash}"
        ]
    }
}
"@ | Out-File -FilePath "build\image\config.json" -Encoding ascii
$configHash = (Get-FileHash -Algorithm SHA256 "build\image\config.json").Hash.ToLower()
Move-Item -Path "build\image\config.json" -Destination "build\image\${configHash}.json"

@"
[
    {
        "Config": "${configHash}.json",
        "Layers": [
            "${layerHash}/layer.tar"
        ]
    }
]
"@ | Out-File  -FilePath "build\image\manifest.json" -Encoding ascii

# Tar the image
if ($IsLinux) {
    tar  -cf "build/windows-host-process-containers-base-image.tar" -C "build/image" .
}
else {
    tar.exe  -cf "build\windows-host-process-containers-base-image.tar" -C "build\image" .
}

# Output a file with the image hash so we can import/push the image from CI
"${configHash}" | Out-File -FilePath "build\image-id.txt" -Encoding ascii  -NoNewline
