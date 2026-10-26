from pathlib import Path
import re
from PIL import Image,ImageDraw,ImageFont
root=Path(__file__).resolve().parents[2]
rtl=root/'src/user_source/hdl_source/osd'
source=rtl/'player52_subtitle_font.mif'
rows=[0]*1024
for addr,value in re.findall(r'(\d+)\s*:\s*([0-9a-fA-F]+)\s*;',source.read_text(encoding='utf-8-sig')):
 rows[int(addr)]=int(value,16)
font=ImageFont.truetype('C:/Windows/Fonts/simsun.ttc',16)
for index,ch in enumerate('你好请排队安路赛道题一',46):
 image=Image.new('1',(16,16));ImageDraw.Draw(image).text((0,0),ch,font=font,fill=1)
 for y in range(16):rows[index*16+y]=sum(int(bool(image.getpixel((x,y))))<<(15-x) for x in range(16))
(rtl/'settings67_subtitle_font.mif').write_text('WIDTH=16;\nDEPTH=1024;\nADDRESS_RADIX=UNS;\nDATA_RADIX=HEX;\nCONTENT BEGIN\n'+''.join(f'{i} : {v:04x};\n' for i,v in enumerate(rows))+'END;\n',encoding='ascii')
Path(__file__).with_name('settings67_subtitle_font.hex').write_text(''.join(f'{v:04x}\n' for v in rows),encoding='ascii')
print('PASS new subtitle font: 11 unique glyphs, same 1024x16 ROM capacity')
