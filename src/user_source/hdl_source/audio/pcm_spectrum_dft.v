// 2048-sample Hann-windowed DFT, bins 1..128 of the actual HDMI PCM.
// 128 bins x 3 cycles + window preparation = 387 cycles/sample (<520 at 25MHz).
// Signed Q11 twiddles, 40-bit accumulators; no reset on RAM arrays.
// First sample of each window explicitly starts from zero, permitting RAM inference.
module pcm_spectrum_dft(
 input clk,rst,audio_valid,input [23:0]pcm_left,
 output wire [511:0]levels,output reg update_valid,output reg overrun
);
reg [2:0]state;
reg [10:0]sample_index,phase;
reg [6:0]bin_index;
reg signed [15:0]pcm_in,sample;
wire signed [11:0]window_coef,cos_coef,sin_coef;
reg signed [27:0]window_product,prod_r,prod_i;
reg signed [39:0]acc_r[0:127]; /* fehdl force_ram=1, ram_style="bram" */
reg signed [39:0]acc_i[0:127]; /* fehdl force_ram=1, ram_style="bram" */
reg signed [39:0]old_r,old_i;
reg signed[39:0]ram_r,ram_i;
always @(posedge clk)if(state==3)begin ram_r<=acc_r[bin_index];ram_i<=acc_i[bin_index];end
// One write port and one synchronous read port. The mapper shares its port
// between interpolation neighbours and peak scans, avoiding two 128:1 muxes.
reg [23:0]raw_magnitude[0:127]; /* fehdl force_ram=1, ram_style="bram" */
reg [23:0]magnitude_q;
reg bins_ready;

wire signed [39:0]sum_r=old_r+{{12{prod_r[27]}},prod_r};
wire signed [39:0]sum_i=old_i-{{12{prod_i[27]}},prod_i};
wire [39:0]abs_r=sum_r[39]?-sum_r:sum_r;
wire [39:0]abs_i=sum_i[39]?-sum_i:sum_i;
wire [40:0]magnitude={1'b0,abs_r}+{1'b0,abs_i};
function signed [11:0]quarter_sin;
 input [9:0]address;
 begin case(address)
 10'd0: quarter_sin=12'sd0;
 10'd1: quarter_sin=12'sd6;
 10'd2: quarter_sin=12'sd13;
 10'd3: quarter_sin=12'sd19;
 10'd4: quarter_sin=12'sd25;
 10'd5: quarter_sin=12'sd31;
 10'd6: quarter_sin=12'sd38;
 10'd7: quarter_sin=12'sd44;
 10'd8: quarter_sin=12'sd50;
 10'd9: quarter_sin=12'sd57;
 10'd10: quarter_sin=12'sd63;
 10'd11: quarter_sin=12'sd69;
 10'd12: quarter_sin=12'sd75;
 10'd13: quarter_sin=12'sd82;
 10'd14: quarter_sin=12'sd88;
 10'd15: quarter_sin=12'sd94;
 10'd16: quarter_sin=12'sd100;
 10'd17: quarter_sin=12'sd107;
 10'd18: quarter_sin=12'sd113;
 10'd19: quarter_sin=12'sd119;
 10'd20: quarter_sin=12'sd126;
 10'd21: quarter_sin=12'sd132;
 10'd22: quarter_sin=12'sd138;
 10'd23: quarter_sin=12'sd144;
 10'd24: quarter_sin=12'sd151;
 10'd25: quarter_sin=12'sd157;
 10'd26: quarter_sin=12'sd163;
 10'd27: quarter_sin=12'sd169;
 10'd28: quarter_sin=12'sd176;
 10'd29: quarter_sin=12'sd182;
 10'd30: quarter_sin=12'sd188;
 10'd31: quarter_sin=12'sd194;
 10'd32: quarter_sin=12'sd201;
 10'd33: quarter_sin=12'sd207;
 10'd34: quarter_sin=12'sd213;
 10'd35: quarter_sin=12'sd219;
 10'd36: quarter_sin=12'sd226;
 10'd37: quarter_sin=12'sd232;
 10'd38: quarter_sin=12'sd238;
 10'd39: quarter_sin=12'sd244;
 10'd40: quarter_sin=12'sd251;
 10'd41: quarter_sin=12'sd257;
 10'd42: quarter_sin=12'sd263;
 10'd43: quarter_sin=12'sd269;
 10'd44: quarter_sin=12'sd275;
 10'd45: quarter_sin=12'sd282;
 10'd46: quarter_sin=12'sd288;
 10'd47: quarter_sin=12'sd294;
 10'd48: quarter_sin=12'sd300;
 10'd49: quarter_sin=12'sd307;
 10'd50: quarter_sin=12'sd313;
 10'd51: quarter_sin=12'sd319;
 10'd52: quarter_sin=12'sd325;
 10'd53: quarter_sin=12'sd331;
 10'd54: quarter_sin=12'sd338;
 10'd55: quarter_sin=12'sd344;
 10'd56: quarter_sin=12'sd350;
 10'd57: quarter_sin=12'sd356;
 10'd58: quarter_sin=12'sd362;
 10'd59: quarter_sin=12'sd369;
 10'd60: quarter_sin=12'sd375;
 10'd61: quarter_sin=12'sd381;
 10'd62: quarter_sin=12'sd387;
 10'd63: quarter_sin=12'sd393;
 10'd64: quarter_sin=12'sd399;
 10'd65: quarter_sin=12'sd406;
 10'd66: quarter_sin=12'sd412;
 10'd67: quarter_sin=12'sd418;
 10'd68: quarter_sin=12'sd424;
 10'd69: quarter_sin=12'sd430;
 10'd70: quarter_sin=12'sd436;
 10'd71: quarter_sin=12'sd442;
 10'd72: quarter_sin=12'sd449;
 10'd73: quarter_sin=12'sd455;
 10'd74: quarter_sin=12'sd461;
 10'd75: quarter_sin=12'sd467;
 10'd76: quarter_sin=12'sd473;
 10'd77: quarter_sin=12'sd479;
 10'd78: quarter_sin=12'sd485;
 10'd79: quarter_sin=12'sd491;
 10'd80: quarter_sin=12'sd497;
 10'd81: quarter_sin=12'sd503;
 10'd82: quarter_sin=12'sd510;
 10'd83: quarter_sin=12'sd516;
 10'd84: quarter_sin=12'sd522;
 10'd85: quarter_sin=12'sd528;
 10'd86: quarter_sin=12'sd534;
 10'd87: quarter_sin=12'sd540;
 10'd88: quarter_sin=12'sd546;
 10'd89: quarter_sin=12'sd552;
 10'd90: quarter_sin=12'sd558;
 10'd91: quarter_sin=12'sd564;
 10'd92: quarter_sin=12'sd570;
 10'd93: quarter_sin=12'sd576;
 10'd94: quarter_sin=12'sd582;
 10'd95: quarter_sin=12'sd588;
 10'd96: quarter_sin=12'sd594;
 10'd97: quarter_sin=12'sd600;
 10'd98: quarter_sin=12'sd606;
 10'd99: quarter_sin=12'sd612;
 10'd100: quarter_sin=12'sd618;
 10'd101: quarter_sin=12'sd624;
 10'd102: quarter_sin=12'sd630;
 10'd103: quarter_sin=12'sd636;
 10'd104: quarter_sin=12'sd642;
 10'd105: quarter_sin=12'sd648;
 10'd106: quarter_sin=12'sd654;
 10'd107: quarter_sin=12'sd660;
 10'd108: quarter_sin=12'sd666;
 10'd109: quarter_sin=12'sd672;
 10'd110: quarter_sin=12'sd678;
 10'd111: quarter_sin=12'sd684;
 10'd112: quarter_sin=12'sd690;
 10'd113: quarter_sin=12'sd696;
 10'd114: quarter_sin=12'sd701;
 10'd115: quarter_sin=12'sd707;
 10'd116: quarter_sin=12'sd713;
 10'd117: quarter_sin=12'sd719;
 10'd118: quarter_sin=12'sd725;
 10'd119: quarter_sin=12'sd731;
 10'd120: quarter_sin=12'sd737;
 10'd121: quarter_sin=12'sd743;
 10'd122: quarter_sin=12'sd748;
 10'd123: quarter_sin=12'sd754;
 10'd124: quarter_sin=12'sd760;
 10'd125: quarter_sin=12'sd766;
 10'd126: quarter_sin=12'sd772;
 10'd127: quarter_sin=12'sd778;
 10'd128: quarter_sin=12'sd783;
 10'd129: quarter_sin=12'sd789;
 10'd130: quarter_sin=12'sd795;
 10'd131: quarter_sin=12'sd801;
 10'd132: quarter_sin=12'sd807;
 10'd133: quarter_sin=12'sd812;
 10'd134: quarter_sin=12'sd818;
 10'd135: quarter_sin=12'sd824;
 10'd136: quarter_sin=12'sd830;
 10'd137: quarter_sin=12'sd835;
 10'd138: quarter_sin=12'sd841;
 10'd139: quarter_sin=12'sd847;
 10'd140: quarter_sin=12'sd852;
 10'd141: quarter_sin=12'sd858;
 10'd142: quarter_sin=12'sd864;
 10'd143: quarter_sin=12'sd870;
 10'd144: quarter_sin=12'sd875;
 10'd145: quarter_sin=12'sd881;
 10'd146: quarter_sin=12'sd887;
 10'd147: quarter_sin=12'sd892;
 10'd148: quarter_sin=12'sd898;
 10'd149: quarter_sin=12'sd903;
 10'd150: quarter_sin=12'sd909;
 10'd151: quarter_sin=12'sd915;
 10'd152: quarter_sin=12'sd920;
 10'd153: quarter_sin=12'sd926;
 10'd154: quarter_sin=12'sd932;
 10'd155: quarter_sin=12'sd937;
 10'd156: quarter_sin=12'sd943;
 10'd157: quarter_sin=12'sd948;
 10'd158: quarter_sin=12'sd954;
 10'd159: quarter_sin=12'sd959;
 10'd160: quarter_sin=12'sd965;
 10'd161: quarter_sin=12'sd970;
 10'd162: quarter_sin=12'sd976;
 10'd163: quarter_sin=12'sd982;
 10'd164: quarter_sin=12'sd987;
 10'd165: quarter_sin=12'sd993;
 10'd166: quarter_sin=12'sd998;
 10'd167: quarter_sin=12'sd1003;
 10'd168: quarter_sin=12'sd1009;
 10'd169: quarter_sin=12'sd1014;
 10'd170: quarter_sin=12'sd1020;
 10'd171: quarter_sin=12'sd1025;
 10'd172: quarter_sin=12'sd1031;
 10'd173: quarter_sin=12'sd1036;
 10'd174: quarter_sin=12'sd1042;
 10'd175: quarter_sin=12'sd1047;
 10'd176: quarter_sin=12'sd1052;
 10'd177: quarter_sin=12'sd1058;
 10'd178: quarter_sin=12'sd1063;
 10'd179: quarter_sin=12'sd1068;
 10'd180: quarter_sin=12'sd1074;
 10'd181: quarter_sin=12'sd1079;
 10'd182: quarter_sin=12'sd1085;
 10'd183: quarter_sin=12'sd1090;
 10'd184: quarter_sin=12'sd1095;
 10'd185: quarter_sin=12'sd1100;
 10'd186: quarter_sin=12'sd1106;
 10'd187: quarter_sin=12'sd1111;
 10'd188: quarter_sin=12'sd1116;
 10'd189: quarter_sin=12'sd1122;
 10'd190: quarter_sin=12'sd1127;
 10'd191: quarter_sin=12'sd1132;
 10'd192: quarter_sin=12'sd1137;
 10'd193: quarter_sin=12'sd1142;
 10'd194: quarter_sin=12'sd1148;
 10'd195: quarter_sin=12'sd1153;
 10'd196: quarter_sin=12'sd1158;
 10'd197: quarter_sin=12'sd1163;
 10'd198: quarter_sin=12'sd1168;
 10'd199: quarter_sin=12'sd1174;
 10'd200: quarter_sin=12'sd1179;
 10'd201: quarter_sin=12'sd1184;
 10'd202: quarter_sin=12'sd1189;
 10'd203: quarter_sin=12'sd1194;
 10'd204: quarter_sin=12'sd1199;
 10'd205: quarter_sin=12'sd1204;
 10'd206: quarter_sin=12'sd1209;
 10'd207: quarter_sin=12'sd1214;
 10'd208: quarter_sin=12'sd1219;
 10'd209: quarter_sin=12'sd1224;
 10'd210: quarter_sin=12'sd1229;
 10'd211: quarter_sin=12'sd1234;
 10'd212: quarter_sin=12'sd1239;
 10'd213: quarter_sin=12'sd1244;
 10'd214: quarter_sin=12'sd1249;
 10'd215: quarter_sin=12'sd1254;
 10'd216: quarter_sin=12'sd1259;
 10'd217: quarter_sin=12'sd1264;
 10'd218: quarter_sin=12'sd1269;
 10'd219: quarter_sin=12'sd1274;
 10'd220: quarter_sin=12'sd1279;
 10'd221: quarter_sin=12'sd1284;
 10'd222: quarter_sin=12'sd1289;
 10'd223: quarter_sin=12'sd1294;
 10'd224: quarter_sin=12'sd1299;
 10'd225: quarter_sin=12'sd1303;
 10'd226: quarter_sin=12'sd1308;
 10'd227: quarter_sin=12'sd1313;
 10'd228: quarter_sin=12'sd1318;
 10'd229: quarter_sin=12'sd1323;
 10'd230: quarter_sin=12'sd1328;
 10'd231: quarter_sin=12'sd1332;
 10'd232: quarter_sin=12'sd1337;
 10'd233: quarter_sin=12'sd1342;
 10'd234: quarter_sin=12'sd1347;
 10'd235: quarter_sin=12'sd1351;
 10'd236: quarter_sin=12'sd1356;
 10'd237: quarter_sin=12'sd1361;
 10'd238: quarter_sin=12'sd1365;
 10'd239: quarter_sin=12'sd1370;
 10'd240: quarter_sin=12'sd1375;
 10'd241: quarter_sin=12'sd1379;
 10'd242: quarter_sin=12'sd1384;
 10'd243: quarter_sin=12'sd1389;
 10'd244: quarter_sin=12'sd1393;
 10'd245: quarter_sin=12'sd1398;
 10'd246: quarter_sin=12'sd1402;
 10'd247: quarter_sin=12'sd1407;
 10'd248: quarter_sin=12'sd1411;
 10'd249: quarter_sin=12'sd1416;
 10'd250: quarter_sin=12'sd1421;
 10'd251: quarter_sin=12'sd1425;
 10'd252: quarter_sin=12'sd1430;
 10'd253: quarter_sin=12'sd1434;
 10'd254: quarter_sin=12'sd1439;
 10'd255: quarter_sin=12'sd1443;
 10'd256: quarter_sin=12'sd1447;
 10'd257: quarter_sin=12'sd1452;
 10'd258: quarter_sin=12'sd1456;
 10'd259: quarter_sin=12'sd1461;
 10'd260: quarter_sin=12'sd1465;
 10'd261: quarter_sin=12'sd1469;
 10'd262: quarter_sin=12'sd1474;
 10'd263: quarter_sin=12'sd1478;
 10'd264: quarter_sin=12'sd1483;
 10'd265: quarter_sin=12'sd1487;
 10'd266: quarter_sin=12'sd1491;
 10'd267: quarter_sin=12'sd1495;
 10'd268: quarter_sin=12'sd1500;
 10'd269: quarter_sin=12'sd1504;
 10'd270: quarter_sin=12'sd1508;
 10'd271: quarter_sin=12'sd1513;
 10'd272: quarter_sin=12'sd1517;
 10'd273: quarter_sin=12'sd1521;
 10'd274: quarter_sin=12'sd1525;
 10'd275: quarter_sin=12'sd1529;
 10'd276: quarter_sin=12'sd1533;
 10'd277: quarter_sin=12'sd1538;
 10'd278: quarter_sin=12'sd1542;
 10'd279: quarter_sin=12'sd1546;
 10'd280: quarter_sin=12'sd1550;
 10'd281: quarter_sin=12'sd1554;
 10'd282: quarter_sin=12'sd1558;
 10'd283: quarter_sin=12'sd1562;
 10'd284: quarter_sin=12'sd1566;
 10'd285: quarter_sin=12'sd1570;
 10'd286: quarter_sin=12'sd1574;
 10'd287: quarter_sin=12'sd1578;
 10'd288: quarter_sin=12'sd1582;
 10'd289: quarter_sin=12'sd1586;
 10'd290: quarter_sin=12'sd1590;
 10'd291: quarter_sin=12'sd1594;
 10'd292: quarter_sin=12'sd1598;
 10'd293: quarter_sin=12'sd1602;
 10'd294: quarter_sin=12'sd1606;
 10'd295: quarter_sin=12'sd1610;
 10'd296: quarter_sin=12'sd1614;
 10'd297: quarter_sin=12'sd1618;
 10'd298: quarter_sin=12'sd1621;
 10'd299: quarter_sin=12'sd1625;
 10'd300: quarter_sin=12'sd1629;
 10'd301: quarter_sin=12'sd1633;
 10'd302: quarter_sin=12'sd1637;
 10'd303: quarter_sin=12'sd1640;
 10'd304: quarter_sin=12'sd1644;
 10'd305: quarter_sin=12'sd1648;
 10'd306: quarter_sin=12'sd1652;
 10'd307: quarter_sin=12'sd1655;
 10'd308: quarter_sin=12'sd1659;
 10'd309: quarter_sin=12'sd1663;
 10'd310: quarter_sin=12'sd1666;
 10'd311: quarter_sin=12'sd1670;
 10'd312: quarter_sin=12'sd1674;
 10'd313: quarter_sin=12'sd1677;
 10'd314: quarter_sin=12'sd1681;
 10'd315: quarter_sin=12'sd1684;
 10'd316: quarter_sin=12'sd1688;
 10'd317: quarter_sin=12'sd1691;
 10'd318: quarter_sin=12'sd1695;
 10'd319: quarter_sin=12'sd1699;
 10'd320: quarter_sin=12'sd1702;
 10'd321: quarter_sin=12'sd1705;
 10'd322: quarter_sin=12'sd1709;
 10'd323: quarter_sin=12'sd1712;
 10'd324: quarter_sin=12'sd1716;
 10'd325: quarter_sin=12'sd1719;
 10'd326: quarter_sin=12'sd1723;
 10'd327: quarter_sin=12'sd1726;
 10'd328: quarter_sin=12'sd1729;
 10'd329: quarter_sin=12'sd1733;
 10'd330: quarter_sin=12'sd1736;
 10'd331: quarter_sin=12'sd1739;
 10'd332: quarter_sin=12'sd1743;
 10'd333: quarter_sin=12'sd1746;
 10'd334: quarter_sin=12'sd1749;
 10'd335: quarter_sin=12'sd1753;
 10'd336: quarter_sin=12'sd1756;
 10'd337: quarter_sin=12'sd1759;
 10'd338: quarter_sin=12'sd1762;
 10'd339: quarter_sin=12'sd1765;
 10'd340: quarter_sin=12'sd1769;
 10'd341: quarter_sin=12'sd1772;
 10'd342: quarter_sin=12'sd1775;
 10'd343: quarter_sin=12'sd1778;
 10'd344: quarter_sin=12'sd1781;
 10'd345: quarter_sin=12'sd1784;
 10'd346: quarter_sin=12'sd1787;
 10'd347: quarter_sin=12'sd1790;
 10'd348: quarter_sin=12'sd1793;
 10'd349: quarter_sin=12'sd1796;
 10'd350: quarter_sin=12'sd1799;
 10'd351: quarter_sin=12'sd1802;
 10'd352: quarter_sin=12'sd1805;
 10'd353: quarter_sin=12'sd1808;
 10'd354: quarter_sin=12'sd1811;
 10'd355: quarter_sin=12'sd1814;
 10'd356: quarter_sin=12'sd1817;
 10'd357: quarter_sin=12'sd1820;
 10'd358: quarter_sin=12'sd1823;
 10'd359: quarter_sin=12'sd1826;
 10'd360: quarter_sin=12'sd1828;
 10'd361: quarter_sin=12'sd1831;
 10'd362: quarter_sin=12'sd1834;
 10'd363: quarter_sin=12'sd1837;
 10'd364: quarter_sin=12'sd1840;
 10'd365: quarter_sin=12'sd1842;
 10'd366: quarter_sin=12'sd1845;
 10'd367: quarter_sin=12'sd1848;
 10'd368: quarter_sin=12'sd1850;
 10'd369: quarter_sin=12'sd1853;
 10'd370: quarter_sin=12'sd1856;
 10'd371: quarter_sin=12'sd1858;
 10'd372: quarter_sin=12'sd1861;
 10'd373: quarter_sin=12'sd1864;
 10'd374: quarter_sin=12'sd1866;
 10'd375: quarter_sin=12'sd1869;
 10'd376: quarter_sin=12'sd1871;
 10'd377: quarter_sin=12'sd1874;
 10'd378: quarter_sin=12'sd1876;
 10'd379: quarter_sin=12'sd1879;
 10'd380: quarter_sin=12'sd1881;
 10'd381: quarter_sin=12'sd1884;
 10'd382: quarter_sin=12'sd1886;
 10'd383: quarter_sin=12'sd1889;
 10'd384: quarter_sin=12'sd1891;
 10'd385: quarter_sin=12'sd1894;
 10'd386: quarter_sin=12'sd1896;
 10'd387: quarter_sin=12'sd1898;
 10'd388: quarter_sin=12'sd1901;
 10'd389: quarter_sin=12'sd1903;
 10'd390: quarter_sin=12'sd1905;
 10'd391: quarter_sin=12'sd1908;
 10'd392: quarter_sin=12'sd1910;
 10'd393: quarter_sin=12'sd1912;
 10'd394: quarter_sin=12'sd1914;
 10'd395: quarter_sin=12'sd1917;
 10'd396: quarter_sin=12'sd1919;
 10'd397: quarter_sin=12'sd1921;
 10'd398: quarter_sin=12'sd1923;
 10'd399: quarter_sin=12'sd1925;
 10'd400: quarter_sin=12'sd1927;
 10'd401: quarter_sin=12'sd1929;
 10'd402: quarter_sin=12'sd1932;
 10'd403: quarter_sin=12'sd1934;
 10'd404: quarter_sin=12'sd1936;
 10'd405: quarter_sin=12'sd1938;
 10'd406: quarter_sin=12'sd1940;
 10'd407: quarter_sin=12'sd1942;
 10'd408: quarter_sin=12'sd1944;
 10'd409: quarter_sin=12'sd1946;
 10'd410: quarter_sin=12'sd1948;
 10'd411: quarter_sin=12'sd1950;
 10'd412: quarter_sin=12'sd1951;
 10'd413: quarter_sin=12'sd1953;
 10'd414: quarter_sin=12'sd1955;
 10'd415: quarter_sin=12'sd1957;
 10'd416: quarter_sin=12'sd1959;
 10'd417: quarter_sin=12'sd1961;
 10'd418: quarter_sin=12'sd1962;
 10'd419: quarter_sin=12'sd1964;
 10'd420: quarter_sin=12'sd1966;
 10'd421: quarter_sin=12'sd1968;
 10'd422: quarter_sin=12'sd1969;
 10'd423: quarter_sin=12'sd1971;
 10'd424: quarter_sin=12'sd1973;
 10'd425: quarter_sin=12'sd1975;
 10'd426: quarter_sin=12'sd1976;
 10'd427: quarter_sin=12'sd1978;
 10'd428: quarter_sin=12'sd1979;
 10'd429: quarter_sin=12'sd1981;
 10'd430: quarter_sin=12'sd1983;
 10'd431: quarter_sin=12'sd1984;
 10'd432: quarter_sin=12'sd1986;
 10'd433: quarter_sin=12'sd1987;
 10'd434: quarter_sin=12'sd1989;
 10'd435: quarter_sin=12'sd1990;
 10'd436: quarter_sin=12'sd1992;
 10'd437: quarter_sin=12'sd1993;
 10'd438: quarter_sin=12'sd1994;
 10'd439: quarter_sin=12'sd1996;
 10'd440: quarter_sin=12'sd1997;
 10'd441: quarter_sin=12'sd1999;
 10'd442: quarter_sin=12'sd2000;
 10'd443: quarter_sin=12'sd2001;
 10'd444: quarter_sin=12'sd2003;
 10'd445: quarter_sin=12'sd2004;
 10'd446: quarter_sin=12'sd2005;
 10'd447: quarter_sin=12'sd2006;
 10'd448: quarter_sin=12'sd2008;
 10'd449: quarter_sin=12'sd2009;
 10'd450: quarter_sin=12'sd2010;
 10'd451: quarter_sin=12'sd2011;
 10'd452: quarter_sin=12'sd2012;
 10'd453: quarter_sin=12'sd2014;
 10'd454: quarter_sin=12'sd2015;
 10'd455: quarter_sin=12'sd2016;
 10'd456: quarter_sin=12'sd2017;
 10'd457: quarter_sin=12'sd2018;
 10'd458: quarter_sin=12'sd2019;
 10'd459: quarter_sin=12'sd2020;
 10'd460: quarter_sin=12'sd2021;
 10'd461: quarter_sin=12'sd2022;
 10'd462: quarter_sin=12'sd2023;
 10'd463: quarter_sin=12'sd2024;
 10'd464: quarter_sin=12'sd2025;
 10'd465: quarter_sin=12'sd2026;
 10'd466: quarter_sin=12'sd2027;
 10'd467: quarter_sin=12'sd2028;
 10'd468: quarter_sin=12'sd2028;
 10'd469: quarter_sin=12'sd2029;
 10'd470: quarter_sin=12'sd2030;
 10'd471: quarter_sin=12'sd2031;
 10'd472: quarter_sin=12'sd2032;
 10'd473: quarter_sin=12'sd2032;
 10'd474: quarter_sin=12'sd2033;
 10'd475: quarter_sin=12'sd2034;
 10'd476: quarter_sin=12'sd2035;
 10'd477: quarter_sin=12'sd2035;
 10'd478: quarter_sin=12'sd2036;
 10'd479: quarter_sin=12'sd2037;
 10'd480: quarter_sin=12'sd2037;
 10'd481: quarter_sin=12'sd2038;
 10'd482: quarter_sin=12'sd2038;
 10'd483: quarter_sin=12'sd2039;
 10'd484: quarter_sin=12'sd2039;
 10'd485: quarter_sin=12'sd2040;
 10'd486: quarter_sin=12'sd2040;
 10'd487: quarter_sin=12'sd2041;
 10'd488: quarter_sin=12'sd2041;
 10'd489: quarter_sin=12'sd2042;
 10'd490: quarter_sin=12'sd2042;
 10'd491: quarter_sin=12'sd2043;
 10'd492: quarter_sin=12'sd2043;
 10'd493: quarter_sin=12'sd2044;
 10'd494: quarter_sin=12'sd2044;
 10'd495: quarter_sin=12'sd2044;
 10'd496: quarter_sin=12'sd2045;
 10'd497: quarter_sin=12'sd2045;
 10'd498: quarter_sin=12'sd2045;
 10'd499: quarter_sin=12'sd2045;
 10'd500: quarter_sin=12'sd2046;
 10'd501: quarter_sin=12'sd2046;
 10'd502: quarter_sin=12'sd2046;
 10'd503: quarter_sin=12'sd2046;
 10'd504: quarter_sin=12'sd2046;
 10'd505: quarter_sin=12'sd2047;
 10'd506: quarter_sin=12'sd2047;
 10'd507: quarter_sin=12'sd2047;
 10'd508: quarter_sin=12'sd2047;
 10'd509: quarter_sin=12'sd2047;
 10'd510: quarter_sin=12'sd2047;
 10'd511: quarter_sin=12'sd2047;
 10'd512: quarter_sin=12'sd2047;
 default:quarter_sin=0;
 endcase end
endfunction
function signed [11:0]sine;
 input [10:0]angle;
 reg [9:0]address;reg signed [11:0]v;
 begin
 address=angle[9]?(10'd512-{1'b0,angle[8:0]}):{1'b0,angle[8:0]};
 v=quarter_sin(address);sine=angle[10]?-v:v;
 end
endfunction
function signed [11:0]cosine;
 input [10:0]angle;
 begin cosine=sine(angle+11'd512);end
endfunction
// Sine/cosine share the same quarter-wave values. Two clocked ROM ports
// replace three large combinational lookup networks; cosine's port serves the
// Hann window on state0 and the DFT on state3. No extra sample/bin cycle.
wire[10:0]rom_angle=state==0?sample_index:phase;
wire[9:0]sin_address=rom_angle[9]?(10'd512-{1'b0,rom_angle[8:0]}):{1'b0,rom_angle[8:0]};
wire[9:0]cos_address=rom_angle[9]?{1'b0,rom_angle[8:0]}:(10'd512-{1'b0,rom_angle[8:0]});
wire sin_read=state==3,cos_read=(state==0&&audio_valid)||state==3;
reg sin_negative,cos_negative;
always @(posedge clk or posedge rst)begin
 if(rst)begin sin_negative<=0;cos_negative<=0;end
 else begin
  if(sin_read)sin_negative<=rom_angle[10];
  if(cos_read)cos_negative<=rom_angle[10]^rom_angle[9];
 end
end
wire[15:0]sin_rom_bits,cos_rom_bits;
`ifdef __ICARUS__
 `ifndef PLAYER53_TEST_PRIMITIVE
  `define PLAYER53_BEHAVIOR_TWIDDLE
 `endif
`endif
`ifdef PLAYER53_BEHAVIOR_TWIDDLE
reg[15:0]sin_sim,cos_sim;
always @(posedge clk)begin
 if(sin_read)sin_sim<={4'd0,quarter_sin(sin_address)};
 if(cos_read)cos_sim<={4'd0,quarter_sin(cos_address)};
end
assign sin_rom_bits=sin_sim;assign cos_rom_bits=cos_sim;
`undef PLAYER53_BEHAVIOR_TWIDDLE
`else
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("SP"),
 .REGMODE_A("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/audio/player53_quarter_sin.mif"),.FILL_ALL("NONE")) u_sin_rom(
 .dia(16'd0),.dib(16'd0),.addra(sin_address),.addrb(10'd0),
 .cea(sin_read),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(sin_rom_bits),.dob());
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("SP"),
 .REGMODE_A("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/audio/player53_quarter_sin.mif"),.FILL_ALL("NONE")) u_cos_rom(
 .dia(16'd0),.dib(16'd0),.addra(cos_address),.addrb(10'd0),
 .cea(cos_read),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(cos_rom_bits),.dob());
`endif
assign sin_coef=sin_negative?-$signed(sin_rom_bits[11:0]):$signed(sin_rom_bits[11:0]);
assign cos_coef=cos_negative?-$signed(cos_rom_bits[11:0]):$signed(cos_rom_bits[11:0]);
wire signed[12:0]window_difference=13'sd2047-$signed(cos_coef);
assign window_coef=window_difference>>>1;

always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=0;sample_index<=0;phase<=0;bin_index<=0;
  pcm_in<=0;sample<=0;window_product<=0;
  prod_r<=0;prod_i<=0;old_r<=0;old_i<=0;
  bins_ready<=0;overrun<=0;
 end else begin
  bins_ready<=0;
  if(audio_valid && state!=0)overrun<=1;
  case(state)
   0:if(audio_valid)begin
    pcm_in<=$signed(pcm_left[23:8]);
    state<=1;
   end
   1:begin window_product<=pcm_in*window_coef;state<=2;end
   2:begin sample<=window_product>>>11;bin_index<=0;phase<=sample_index;state<=3;end
   3:begin
    state<=4; // ROM and accumulator reads launch together
   end
   4:begin old_r<=sample_index==0?40'sd0:ram_r;old_i<=sample_index==0?40'sd0:ram_i;prod_r<=sample*cos_coef;prod_i<=sample*sin_coef;state<=5;end
   5:begin
    acc_r[bin_index]<=sum_r;acc_i[bin_index]<=sum_i;
    if(bin_index==7'd127)begin
     if(sample_index==11'd2047)begin
      bins_ready<=1;sample_index<=0;
     end else sample_index<=sample_index+1'b1;
     state<=0;
    end else begin bin_index<=bin_index+1'b1;phase<=phase+sample_index;state<=3;end
   end
   default:state<=0;
  endcase
 end
end

// Logarithmic 23.45Hz..3kHz frequency axis. Interpolate adjacent true DFT bins.
// Independent publication engine runs after the last bin; next PCM window can
// already start while it reads the stable magnitudes (unchanged for ~42ms).
function [10:0]frequency_position;
 input [5:0]band;
 begin case(band)
 6'd0:frequency_position=11'd0;
 6'd1:frequency_position=11'd1;
 6'd2:frequency_position=11'd3;
 6'd3:frequency_position=11'd4;
 6'd4:frequency_position=11'd6;
 6'd5:frequency_position=11'd8;
 6'd6:frequency_position=11'd9;
 6'd7:frequency_position=11'd11;
 6'd8:frequency_position=11'd14;
 6'd9:frequency_position=11'd16;
 6'd10:frequency_position=11'd19;
 6'd11:frequency_position=11'd21;
 6'd12:frequency_position=11'd24;
 6'd13:frequency_position=11'd28;
 6'd14:frequency_position=11'd31;
 6'd15:frequency_position=11'd35;
 6'd16:frequency_position=11'd39;
 6'd17:frequency_position=11'd43;
 6'd18:frequency_position=11'd48;
 6'd19:frequency_position=11'd53;
 6'd20:frequency_position=11'd59;
 6'd21:frequency_position=11'd65;
 6'd22:frequency_position=11'd71;
 6'd23:frequency_position=11'd78;
 6'd24:frequency_position=11'd86;
 6'd25:frequency_position=11'd94;
 6'd26:frequency_position=11'd103;
 6'd27:frequency_position=11'd112;
 6'd28:frequency_position=11'd122;
 6'd29:frequency_position=11'd133;
 6'd30:frequency_position=11'd145;
 6'd31:frequency_position=11'd158;
 6'd32:frequency_position=11'd172;
 6'd33:frequency_position=11'd187;
 6'd34:frequency_position=11'd203;
 6'd35:frequency_position=11'd221;
 6'd36:frequency_position=11'd240;
 6'd37:frequency_position=11'd260;
 6'd38:frequency_position=11'd283;
 6'd39:frequency_position=11'd307;
 6'd40:frequency_position=11'd332;
 6'd41:frequency_position=11'd360;
 6'd42:frequency_position=11'd390;
 6'd43:frequency_position=11'd423;
 6'd44:frequency_position=11'd458;
 6'd45:frequency_position=11'd496;
 6'd46:frequency_position=11'd537;
 6'd47:frequency_position=11'd581;
 6'd48:frequency_position=11'd629;
 6'd49:frequency_position=11'd681;
 6'd50:frequency_position=11'd737;
 6'd51:frequency_position=11'd797;
 6'd52:frequency_position=11'd862;
 6'd53:frequency_position=11'd932;
 6'd54:frequency_position=11'd1008;
 6'd55:frequency_position=11'd1090;
 6'd56:frequency_position=11'd1179;
 6'd57:frequency_position=11'd1274;
 6'd58:frequency_position=11'd1377;
 6'd59:frequency_position=11'd1489;
 6'd60:frequency_position=11'd1609;
 6'd61:frequency_position=11'd1740;
 6'd62:frequency_position=11'd1880;
 6'd63:frequency_position=11'd2032;
 default:frequency_position=0;
 endcase end
endfunction
// Equivalent log compression: only exponents8..16 are unsaturated.
// Fixed bit slices replace integer priority search and a variable barrel shift.
function [7:0]compress_amplitude;
 input[23:0]value;
 begin
  if(|value[23:17])compress_amplitude=8'd80;
  else if(value[16])compress_amplitude=8'd72+{5'd0,value[15:13]};
  else if(value[15])compress_amplitude=8'd64+{5'd0,value[14:12]};
  else if(value[14])compress_amplitude=8'd56+{5'd0,value[13:11]};
  else if(value[13])compress_amplitude=8'd48+{5'd0,value[12:10]};
  else if(value[12])compress_amplitude=8'd40+{5'd0,value[11:9]};
  else if(value[11])compress_amplitude=8'd32+{5'd0,value[10:8]};
  else if(value[10])compress_amplitude=8'd24+{5'd0,value[9:7]};
  else if(value[9])compress_amplitude=8'd16+{5'd0,value[8:6]};
  else if(value[8])compress_amplitude=8'd8+{5'd0,value[7:5]};
  else compress_amplitude=0;
 end
endfunction
// Preserve narrow harmonic peaks when logarithmic bands become wider than bins.
function [14:0]band_bounds;
 input [5:0]band;
 begin case(band)
 6'd0:band_bounds=15'd16384;
 6'd1:band_bounds=15'd128;
 6'd2:band_bounds=15'd128;
 6'd3:band_bounds=15'd128;
 6'd4:band_bounds=15'd128;
 6'd5:band_bounds=15'd128;
 6'd6:band_bounds=15'd128;
 6'd7:band_bounds=15'd128;
 6'd8:band_bounds=15'd128;
 6'd9:band_bounds=15'd16513;
 6'd10:band_bounds=15'd257;
 6'd11:band_bounds=15'd257;
 6'd12:band_bounds=15'd257;
 6'd13:band_bounds=15'd257;
 6'd14:band_bounds=15'd16642;
 6'd15:band_bounds=15'd386;
 6'd16:band_bounds=15'd386;
 6'd17:band_bounds=15'd386;
 6'd18:band_bounds=15'd16771;
 6'd19:band_bounds=15'd515;
 6'd20:band_bounds=15'd515;
 6'd21:band_bounds=15'd16900;
 6'd22:band_bounds=15'd644;
 6'd23:band_bounds=15'd17029;
 6'd24:band_bounds=15'd773;
 6'd25:band_bounds=15'd17158;
 6'd26:band_bounds=15'd902;
 6'd27:band_bounds=15'd17287;
 6'd28:band_bounds=15'd1031;
 6'd29:band_bounds=15'd17416;
 6'd30:band_bounds=15'd17545;
 6'd31:band_bounds=15'd17674;
 6'd32:band_bounds=15'd17803;
 6'd33:band_bounds=15'd17932;
 6'd34:band_bounds=15'd18061;
 6'd35:band_bounds=15'd18190;
 6'd36:band_bounds=15'd18319;
 6'd37:band_bounds=15'd18448;
 6'd38:band_bounds=15'd18578;
 6'd39:band_bounds=15'd18835;
 6'd40:band_bounds=15'd18965;
 6'd41:band_bounds=15'd19223;
 6'd42:band_bounds=15'd19481;
 6'd43:band_bounds=15'd19739;
 6'd44:band_bounds=15'd19997;
 6'd45:band_bounds=15'd20256;
 6'd46:band_bounds=15'd20642;
 6'd47:band_bounds=15'd20901;
 6'd48:band_bounds=15'd21288;
 6'd49:band_bounds=15'd21676;
 6'd50:band_bounds=15'd22191;
 6'd51:band_bounds=15'd22579;
 6'd52:band_bounds=15'd23096;
 6'd53:band_bounds=15'd23740;
 6'd54:band_bounds=15'd24257;
 6'd55:band_bounds=15'd24902;
 6'd56:band_bounds=15'd25548;
 6'd57:band_bounds=15'd26322;
 6'd58:band_bounds=15'd27097;
 6'd59:band_bounds=15'd28000;
 6'd60:band_bounds=15'd28904;
 6'd61:band_bounds=15'd29937;
 6'd62:band_bounds=15'd31098;
 6'd63:band_bounds=15'd32255;
 default:band_bounds=0;
 endcase end
endfunction
reg [3:0]map_state;
reg [5:0]map_band;
reg [23:0]amp_a,amp_b;
reg [3:0]fraction;
reg [28:0]weighted;
reg [7:0]target_height;
reg [6:0]range_index,range_end;
reg [23:0]band_magnitude;
wire [14:0]bounds=band_bounds(map_band);
// Heights are inductively bounded0..80. Store seven bits, keep the public
//64x8bit interface byte-compatible with the original analyzer.
reg[6:0]work_levels[0:63];reg[6:0]level_regs[0:63];
genvar level_band;
generate for(level_band=0;level_band<64;level_band=level_band+1)begin:pack_levels
 assign levels[level_band*8+:8]={1'b0,level_regs[level_band]};
end endgenerate
integer level_i;
wire [10:0]position=frequency_position(map_band);
wire [6:0]index_a=position[10:4];
wire [6:0]index_b=(index_a==127)?7'd127:index_a+1'b1;
wire [6:0]magnitude_address=(map_state==5)?range_index:(map_state==8)?index_b:index_a;
always @(posedge clk)begin
 if(!rst&&state==5&&sample_index==11'd2047)raw_magnitude[bin_index]<=magnitude[39:16];
 if(map_state==1||map_state==8||map_state==5)magnitude_q<=raw_magnitude[magnitude_address];
end
wire [7:0]previous_height=levels[{map_band,3'b000}+:8];
wire [7:0]new_height=(target_height>=previous_height)?target_height:
 ((previous_height>8'd8&&previous_height-8'd8>target_height)?previous_height-8'd8:target_height);
always @(posedge clk or posedge rst)begin
 if(rst)begin
  map_state<=0;map_band<=0;amp_a<=0;amp_b<=0;fraction<=0;weighted<=0;target_height<=0;
  range_index<=0;range_end<=0;band_magnitude<=0;
  for(level_i=0;level_i<64;level_i=level_i+1)begin work_levels[level_i]<=0;level_regs[level_i]<=0;end
  update_valid<=0;
 end else begin
  update_valid<=0;
  case(map_state)
   0:if(bins_ready)begin map_band<=0;map_state<=1;end
   1:map_state<=8; // launch neighbour A read
   8:begin amp_a<=magnitude_q;fraction<=position[3:0];map_state<=9;end // launch B read
   9:begin amp_b<=magnitude_q;map_state<=2;end
   2:begin weighted<=amp_a*(5'd16-{1'b0,fraction})+amp_b*fraction;map_state<=3;end
   3:begin
    if(bounds[14])begin band_magnitude<=weighted[27:4];range_index<=bounds[13:7];range_end<=bounds[6:0];map_state<=5;end
    else begin target_height<=compress_amplitude(weighted[27:4]);map_state<=4;end
   end
   5:map_state<=6;
   6:begin
    if(magnitude_q>band_magnitude)band_magnitude<=magnitude_q;
    if(range_index==range_end)map_state<=7;
    else begin range_index<=range_index+1'b1;map_state<=5;end
   end
   7:begin target_height<=compress_amplitude(band_magnitude);map_state<=4;end
   4:begin
    work_levels[map_band]<=new_height[6:0];
    if(map_band==63)begin for(level_i=0;level_i<63;level_i=level_i+1)level_regs[level_i]<=work_levels[level_i];level_regs[63]<=new_height[6:0];update_valid<=1;map_state<=0;end
    else begin map_band<=map_band+1'b1;map_state<=1;end
   end
   default:map_state<=0;
  endcase
 end
end
endmodule
