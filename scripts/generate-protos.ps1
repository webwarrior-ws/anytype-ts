#Requires -Version 5.1
<#
.SYNOPSIS
    Generates TypeScript protobuf bindings from .proto files using ts-proto.

.DESCRIPTION
    PowerShell translation of ./scripts/generate-protos.sh for Windows,
    assuming the --from-dist flag (CI mode): .proto files are taken from
    dist/lib/protos/ (downloaded by update-ci.sh / update.ps1).

    Usage:
        powershell -File scripts\generate-protos.ps1 --from-dist
        powershell -File scripts\generate-protos.ps1 -FromDist

.PARAMETER FromDist
    Use dist/lib/protos/ as the proto source (default, kept for parity with the
    shell script's --from-dist flag).
#>

param(
    [switch]$FromDist = $true,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'

# The shell script is invoked as `generate-protos.sh --from-dist`; accept the
# literal flag in the remaining arguments as well (Windows PowerShell passes
# unrecognized --flags through to $RemainingArgs).
if ($RemainingArgs -contains '--from-dist') {
    $FromDist = $true
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$MiddlewareDir = Join-Path $RootDir 'middleware'
$TsProtoJs     = Join-Path $RootDir 'node_modules/ts-proto/protoc-gen-ts_proto'

if (-not $FromDist) {
    Write-Host "Error: only --from-dist mode is supported on Windows (run: powershell -File scripts\generate-protos.ps1 --from-dist)"
    exit 1
}

if (-not (Test-Path -Path $TsProtoJs -PathType Leaf)) {
    Write-Host "Error: ts-proto not found at $TsProtoJs. Run 'bun install' first."
    exit 1
}

if (-not (Get-Command protoc -ErrorAction SilentlyContinue)) {
    Write-Host "Error: protoc not found. Install protobuf compiler."
    exit 1
}

# protoc must be able to resolve the well-known types (google/protobuf/*.proto),
# imported by models.proto etc. They ship in the include/ directory of the official
# protoc release zip and are resolved automatically relative to the binary.
# A protoc installed without that include/ dir produces a confusing wall of
# "File not found" / "is not defined" errors — fail fast with a clear hint instead.
$ProbeDir = Join-Path ([IO.Path]::GetTempPath()) ("protoc-probe-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $ProbeDir | Out-Null
$ProbeOut = Join-Path $ProbeDir 'probe.bin'
[IO.File]::WriteAllText((Join-Path $ProbeDir 'probe.proto'), "syntax = `"proto3`";`nimport `"google/protobuf/struct.proto`";`nmessage Probe {}`n")
$ProbeOk = $false
try {
    $PrevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # In Windows PowerShell 5.1, redirecting native stderr can surface ErrorRecords;
    # don't let them trip $ErrorActionPreference = 'Stop'.
    & protoc "--proto_path=$ProbeDir" "--descriptor_set_out=$ProbeOut" (Join-Path $ProbeDir 'probe.proto') 2>$null | Out-Null
    $ProbeOk = ($LASTEXITCODE -eq 0)
} catch {
    $ProbeOk = $false
} finally {
    $ErrorActionPreference = $PrevEap
}
Remove-Item -Path $ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
if (-not $ProbeOk) {
    Write-Host "Error: protoc cannot find the well-known types (google/protobuf/struct.proto)."
    Write-Host "This protoc is missing its 'include' directory (google/protobuf/*.proto files)."
    Write-Host "Install the official protoc release zip (like .github/workflows/build.yml does):"
    Write-Host "  https://github.com/protocolbuffers/protobuf/releases (protoc-*-win64.zip, includes an 'include' dir next to 'bin')"
    Write-Host "and make sure that 'bin\protoc.exe' is the one on PATH."
    exit 1
}

# Create a .cmd wrapper that protoc can execute as a plugin on Windows
# (protoc executes plugin files without a shebang, so the wrapper must be a
# batch file that invokes node with the ts-proto plugin entry point).
$WinNode   = (Get-Command node).Source
$WinScript = $TsProtoJs
$Wrapper   = Join-Path ([IO.Path]::GetTempPath()) ("protoc-plugin-" + [IO.Path]::GetRandomFileName() + ".cmd")
$WrapperContent = '@"' + $WinNode + '" "' + $WinScript + '"' + "`r`n"
[IO.File]::WriteAllText($Wrapper, $WrapperContent)

try {
    # Create a temp directory with the proto file structure that matches import paths
    $ProtoRoot = Join-Path ([IO.Path]::GetTempPath()) ("protoc-protos-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $ProtoRoot | Out-Null

    try {
        # CI mode: use .proto files downloaded by update-ci.sh into dist/lib/protos/
        $ProtoSrc = Join-Path $RootDir 'dist/lib/protos'
        if (-not (Test-Path -Path $ProtoSrc -PathType Container)) {
            Write-Host "Error: dist/lib/protos not found. Run update-ci.sh first."
            exit 1
        }

        # pb/protos/ — commands, events, changes, snapshot
        $PbProtos = Join-Path $ProtoRoot 'pb/protos'
        New-Item -ItemType Directory -Force -Path $PbProtos | Out-Null
        foreach ($f in @('commands.proto', 'events.proto', 'changes.proto', 'snapshot.proto')) {
            Copy-Item -Path (Join-Path $ProtoSrc $f) -Destination $PbProtos
        }

        # pkg/lib/pb/model/protos/ — models, localstore
        $ModelProtos = Join-Path $ProtoRoot 'pkg/lib/pb/model/protos'
        New-Item -ItemType Directory -Force -Path $ModelProtos | Out-Null
        foreach ($f in @('models.proto', 'localstore.proto')) {
            Copy-Item -Path (Join-Path $ProtoSrc $f) -Destination $ModelProtos
        }
        if (Test-Path -Path (Join-Path $ProtoSrc 'export_report.proto') -PathType Leaf) {
            Copy-Item -Path (Join-Path $ProtoSrc 'export_report.proto') -Destination $ModelProtos
        }

        Write-Host "Generating TypeScript protobuf bindings..."

        # Clean previous generated files
        foreach ($d in @('pb', 'pkg', 'google')) {
            Remove-Item -Path (Join-Path $MiddlewareDir $d) -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Ensure middleware directory exists
        New-Item -ItemType Directory -Force -Path $MiddlewareDir | Out-Null

        # Run protoc with ts-proto.
        # outputJsonMethods=false — fromJSON/toJSON are never called by the app; skipping them
        # cuts roughly a third of the generated method surface (parse time + memory at startup).
        # initializeFieldsAsUndefined=false — do not pre-fill optional/oneof fields with `undefined`
        # in createBase*: decoded messages only carry fields present on the wire, which shrinks
        # per-message allocations (Event_Message has ~90 oneof members) and makes Object.keys()
        # scans over decoded events cheap.
        $protocArgs = @(
            "--plugin=protoc-gen-ts_proto=$Wrapper"
            "--ts_proto_out=$MiddlewareDir"
            '--ts_proto_opt=outputJsonMethods=false,initializeFieldsAsUndefined=false'
            "--proto_path=$ProtoRoot"
            (Join-Path $ProtoRoot 'pb/protos/commands.proto')
            (Join-Path $ProtoRoot 'pb/protos/events.proto')
            (Join-Path $ProtoRoot 'pb/protos/changes.proto')
            (Join-Path $ProtoRoot 'pb/protos/snapshot.proto')
        )
        $protocArgs += (Get-ChildItem -Path (Join-Path $ProtoRoot 'pkg/lib/pb/model/protos/*.proto') | ForEach-Object { $_.FullName })

        & protoc @protocArgs
        if ($LASTEXITCODE -ne 0) {
            throw "protoc failed with exit code $LASTEXITCODE"
        }

        # Replace the generated Struct/Value codec with the hand-optimized override
        # (decodes google.protobuf.Struct/Value straight into plain JS objects without
        # transient wrapper allocations — the hottest decode path for object details).
        Write-Host "Applying struct.ts override..."
        $OverrideDst = Join-Path $MiddlewareDir 'google/protobuf'
        New-Item -ItemType Directory -Force -Path $OverrideDst | Out-Null
        Copy-Item -Path (Join-Path $RootDir 'scripts/proto-overrides/struct.ts') `
                  -Destination (Join-Path $OverrideDst 'struct.ts') -Force

        Write-Host "Generated TypeScript files:"
        Get-ChildItem -Path @(
            (Join-Path $MiddlewareDir 'pb'),
            (Join-Path $MiddlewareDir 'pkg'),
            (Join-Path $MiddlewareDir 'google')
        ) -Recurse -Filter '*.ts' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName } |
            Sort-Object |
            ForEach-Object { Write-Host $_ }

        Write-Host "Generating service registry..."
        & node (Join-Path $RootDir 'scripts/generate-service-registry.js') --from-dist
        if ($LASTEXITCODE -ne 0) {
            throw "generate-service-registry.js failed with exit code $LASTEXITCODE"
        }

        Write-Host "Done!"
    }
    finally {
        Remove-Item -Path $ProtoRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -Path $Wrapper -Force -ErrorAction SilentlyContinue
}
