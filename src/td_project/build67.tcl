# Combined TF picture + HDMI audio build; original repair42 is preserved.
proc checked {args} {
    if {[catch {uplevel 1 $args} result]} {
        puts "REPAIR_BUILD_FAILED: $args : $result"
        exit 1
    }
    puts "REPAIR_BUILD_STEP_OK: $args"
}
checked import_device eagle_s20.db -package EG4S20BG256
checked open_project -single_run ./lab_ex4_tf_audio_settings67.al
checked set_param flow seed 3
# Avoid physical optimization moving the packaged SDRAM primitive.
checked set_param place opt_timing off
checked set_param route fix_hold on
checked set_param route effort high
checked set_param route opt_timing high
checked elaborate -top top_hdmi_bmp
checked read_adc ../user_source/constraints_source/pin.adc
checked optimize_rtl
checked read_sdc ../user_source/constraints_source/timing.sdc
checked optimize_gate
checked export_db settings67_gate.db
checked legalize_phy_inst
checked read_sdc ../user_source/constraints_source/timing.sdc
checked place
checked export_db settings67_placed.db
checked route
checked export_db settings67_routed.db
# This installed TD version has no update_timing command. report_timing after
# route performs the timing report; do not silently swallow command failures.
checked report_timing -file rpt_settings67.txt
checked exec python ../../doc/diagnostics/check_timing.py rpt_settings67.txt
checked bitgen -bit settings67.bit
checked close_project
puts "REPAIR_BUILD_DONE"
exit






