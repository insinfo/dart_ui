param(
    [Parameter(Mandatory = $true)][string]$PdfPath,
    [int]$Iterations = 20,
    [string]$OutputDirectory = "build\pdf_profile",
    [switch]$Aot,
    [switch]$Trace,
    [switch]$FullValidation,
    [switch]$RenderFirst
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$pdf = (Resolve-Path -LiteralPath $PdfPath).Path
$output = Join-Path $repo $OutputDirectory
New-Item -ItemType Directory -Force -Path $output | Out-Null
$report = Join-Path $output "pdf-benchmark.json"
$benchmark = Join-Path $repo "benchmark\pdf_benchmark.dart"
$arguments = @($pdf, "--iterations=$Iterations", "--json=$report")
if ($FullValidation) { $arguments += "--full-validation" }
if ($RenderFirst) { $arguments += "--render-first" }

Push-Location $repo
try {
    if ($Aot) {
        $executable = Join-Path $output "pdf-benchmark.exe"
        & dart compile exe $benchmark -o $executable
        if ($LASTEXITCODE -ne 0) { throw "AOT compilation failed" }
        & $executable @arguments
    }
    elseif ($Trace) {
        $timeline = Join-Path $output "pdf-timeline.json"
        & dart run --timeline-streams=Dart,GC,Compiler `
            "--timeline-recorder=file:$timeline" `
            $benchmark @arguments
    }
    else {
        & dart run $benchmark @arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "PDF benchmark failed" }
}
finally {
    Pop-Location
}

Write-Host "Benchmark: $report"
if ($Trace) { Write-Host "Timeline: $timeline" }
