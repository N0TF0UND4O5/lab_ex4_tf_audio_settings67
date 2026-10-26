from pathlib import Path
import re,json,hashlib
root=Path(__file__).resolve().parents[2]
td=root/'src/td_project'
log=(td/'settings67_release_build.log').read_text(encoding='utf-8',errors='replace')
assert 'REPAIR_BUILD_DONE' in log and 'REPAIR_BUILD_FAILED' not in log,'Final build incomplete'
assert 'REPAIR_BUILD_STEP_OK: exec python ../../doc/diagnostics/check_timing.py rpt_settings67.txt' in log
bit=td/'settings67.bit';assert bit.stat().st_size>700000
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
baseline=root.parent/'lab_ex4_tf_audio_settings61/src/td_project/settings61.bit'
assert sha(baseline)=='d8c1b271ccb5e55bd1b0eaf85cf810c0fd9cf5ee4c967ef8af0824283c47ba96'
resources=re.findall(r'(\d+) mslices, (\d+) lslices, (\d+) pads, (\d+) brams, (\d+) dsps',log)[-1]
actual=dict(zip(['MSLICE','LSLICE','PAD','BRAM','DSP'],map(int,resources)))
base={'MSLICE':4677,'LSLICE':4677,'PAD':123,'BRAM':59,'DSP':21}
assert actual['MSLICE']<base['MSLICE'] and actual['LSLICE']<base['LSLICE']
tests={}
for name in ['renderer67','tft61_equivalence67','router67','bmp67_0_0','bmp67_0_1','bmp67_1_0','bmp67_1_1']:
 p=root/f'doc/diagnostics/{name}.log';t=p.read_text(encoding='utf-8-sig');assert 'PASS' in t and 'FATAL' not in t,name
 tests[name]={'passed':True,'log':p.relative_to(root).as_posix(),'sha256':sha(p)}
sources={}
for p in (root/'src').rglob('*'):
 if p.is_file() and p.suffix.lower() in {'.v','.vh','.mif','.hex','.sdc','.adc','.al','.tcl'}:
  sources[p.relative_to(root).as_posix()]=sha(p)
manifest={'version':'settings67','date':'2026-10-25','baseline':'settings61','baseline_bit_sha256':sha(baseline),
 'bitstream':{'path':bit.relative_to(root).as_posix(),'bytes':bit.stat().st_size,'sha256':sha(bit)},
 'downloaded':False,'flash_written':False,'hardware_verified':False,
 'features':{'sw1_pin':'C8','sw1_up':'HDMI menu ON / TFT OFF','sw1_down':'HDMI menu OFF / TFT ON','menu_bounds_xywh':[16,392,608,72],'menu_font_px':12,'subtitle_bounds_xywh':[16,356,608,30],'subtitle_text':'你好请排队   安路赛道赛题一','subtitle_font_px':16,'subtitle_control_independent_of_menu':True,'shared_menu_renderer_and_font':True,'bmp_header_cache_bram':True},
 'resources':actual,'baseline_resources':base,'resource_delta':{k:actual[k]-base[k] for k in base},
 'clock_timing_gate_passed':True,'clock_timing':json.loads((td/'timing_summary67.json').read_text()),
 'timing_limitations':['Up to 3 inherited audio reset recovery violations retained','Packaged SDRAM external IO warnings remain outside the clock-only timing gate','No clocks slowed and no new timing false paths'],
 'tests':tests,'source_sha256':sources,
 'hardware_limitations':['settings61 TFT corruption/white-screen root cause is not claimed fixed','TFT66 user reported deadlock; it was not used as the baseline','User will download and test; no automatic JTAG action performed'],
 'non_release_attempts':['Initial upper-right-layout build failed strict timing and produced no bitstream','Before-fontfix build passed clock gate; its intermediate bitstream is not the final delivery']}
(root/'doc/release_manifest67.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
p=root/'README_SETTINGS67.md';s=p.read_text(encoding='utf-8').replace('最终位流/校验/资源/时序待构建完成后写入manifest。未下载，待用户自行上板验证。',f"最终位流：src/td_project/settings67.bit，{bit.stat().st_size}字节，SHA256 `{sha(bit)}`。\n资源：{actual}，相对settings61：{manifest['resource_delta']}。\n业务时钟setup/hold为0，保留原3条音频复位recovery及SDRAM外部IO告警。未下载，待用户自行上板验证。")
p.write_text(s,encoding='utf-8')
print(json.dumps({'bit':manifest['bitstream'],'resources':actual,'delta':manifest['resource_delta'],'tests':len(tests)},ensure_ascii=False))
