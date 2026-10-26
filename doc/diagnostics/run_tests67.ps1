$ErrorActionPreference = 'Stop'
$iverilog = 'C:/iverilog/bin/iverilog.exe'
$vvp = 'C:/iverilog/bin/vvp.exe'
Push-Location $PSScriptRoot
try {
  $ui = '../../src/user_source/hdl_source/ui'
  $osd = '../../src/user_source/hdl_source/osd'
  function Run-Case($name, $sources, $parameters = @()) {
    & $iverilog -g2012 -s $name -o "$name.vvp" @parameters @sources
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $name" }
    & $vvp "$name.vvp" | Tee-Object "$name.log"
    if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $name" }
  }
  Run-Case 'tb_renderer67' @('tb_renderer67.v', 'tft_settings_renderer_reference.v', "$ui/tft_settings_renderer.v")
  Run-Case 'tb_tft61_equivalence67' @('tb_tft61_equivalence67.v', 'tft_settings_display_reference.v', 'tft_settings_renderer_reference.v', "$ui/tft_settings_renderer.v", "$ui/tft_settings_display.v", "$ui/tft_8080_bus.v")
  Run-Case 'tb_router67' @('tb_router67.v', "$ui/settings_display_router.v", "$ui/tft_settings_renderer.v", "$ui/tft_settings_display.v", "$ui/tft_8080_bus.v", "$osd/hdmi_subtitle_osd.v")
  foreach ($direct in 0, 1) {
    foreach ($stall in 0, 1) {
      Run-Case 'tb_bmp67' @('tb_bmp67.v', 'bmp_read_reference.v', '../../src/user_source/hdl_source/SD/bmp_read.v') @("-Ptb_bmp67.DIRECT=$direct", "-Ptb_bmp67.STALL=$stall")
      Copy-Item 'tb_bmp67.log' "bmp67_${direct}_${stall}.log" -Force
    }
  }
  Write-Output 'PASS all settings67 regressions'
} finally { Pop-Location }
