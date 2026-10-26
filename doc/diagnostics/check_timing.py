from pathlib import Path
import re,sys,json
s=Path(sys.argv[1]).read_text(encoding='utf-8',errors='replace')
sections=re.split(r'Timing constraint:\s*clock:\s*',s)[1:]
result={}
for block in sections:
    name=block.split()[0]
    m=re.search(r'(\d+) errors detected : (\d+) setup errors.*?, (\d+) hold errors',block)
    if not m:raise SystemExit('No timing summary:'+name)
    setup,hold=int(m[2]),int(m[3])
    period=re.search(r'Minimum period is ([\d.]+)ns',block)
    result[name]={'setup_errors':setup,'hold_errors':hold,'minimum_ns':float(period[1]) if period else None}
    if hold or setup>(3 if name=='audio_mclk' else 0):
        print(json.dumps(result));raise SystemExit('Constrained timing failed:'+name)
    if name=='audio_mclk' and setup:
        recovery=re.findall(r'Slack \(recovery check\):\s*(-[\d.]+)',block)
        data=re.findall(r'Slack \(setup check\):\s*(-[\d.]+)',block)
        if len(recovery)!=setup or data:raise SystemExit('New audio data/recovery errors')
assert set(result)=={'clk','sd_card_clk','ext_mem_clk','ext_mem_clk_sft','video_clk','hdmi_5x_clk','audio_mclk','emergency_rx_clk'},result.keys()
Path('timing_summary67.json').write_text(json.dumps(result,indent=2))
print('PASS8 clock groups; only up to3 inherited audio reset-recovery checks allowed. External SDRAM IO warnings remain outside this clock-only gate.')
