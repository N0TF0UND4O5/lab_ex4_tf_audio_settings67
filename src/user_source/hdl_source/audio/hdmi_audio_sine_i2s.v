// Public-domain melody: Twinkle, Twinkle, Little Star. Approximately 12s loop.
// Actual Fs = 48027.663934Hz, stereo 24-bit, 64 BCLK per channel.
// Short attack/release envelopes and gaps avoid clicks between notes.
module hdmi_audio_sine_i2s #(
 parameter integer PAUSE_ENABLE = 0,
 parameter integer BEAT_SAMPLES = 12007
)(input I_mclk, I_rst, I_pause,input[1:0]I_music, output reg O_i2s_BCLK, O_i2s_LRCK, O_i2s_DOUT);
// Freeze the melody only, never I2S clocks/sample transport.
wire music_paused=PAUSE_ENABLE?I_pause:1'b0;
reg [5:0] bit_count, note_index;
reg [15:0] sample_count;
reg [31:0] phase;
reg [63:0] shift_word;
reg [23:0] sample_word;
reg[1:0]music0,music1,music_active;
always @(posedge I_mclk or posedge I_rst)begin
 if(I_rst)begin music0<=0;music1<=0;end else begin music0<=I_music;music1<=music0;end
end
function[3:0]score;input[7:0]address;begin case(address)
8'd0:score=4'd0;
8'd1:score=4'd0;
8'd2:score=4'd4;
8'd3:score=4'd4;
8'd4:score=4'd5;
8'd5:score=4'd5;
8'd6:score=4'd12;
8'd7:score=4'd3;
8'd8:score=4'd3;
8'd9:score=4'd2;
8'd10:score=4'd2;
8'd11:score=4'd1;
8'd12:score=4'd1;
8'd13:score=4'd8;
8'd14:score=4'd4;
8'd15:score=4'd4;
8'd16:score=4'd3;
8'd17:score=4'd3;
8'd18:score=4'd2;
8'd19:score=4'd2;
8'd20:score=4'd9;
8'd21:score=4'd4;
8'd22:score=4'd4;
8'd23:score=4'd3;
8'd24:score=4'd3;
8'd25:score=4'd2;
8'd26:score=4'd2;
8'd27:score=4'd9;
8'd28:score=4'd0;
8'd29:score=4'd0;
8'd30:score=4'd4;
8'd31:score=4'd4;
8'd32:score=4'd5;
8'd33:score=4'd5;
8'd34:score=4'd12;
8'd35:score=4'd3;
8'd36:score=4'd3;
8'd37:score=4'd2;
8'd38:score=4'd2;
8'd39:score=4'd1;
8'd40:score=4'd1;
8'd41:score=4'd8;
8'd64:score=4'd2;
8'd65:score=4'd2;
8'd66:score=4'd3;
8'd67:score=4'd4;
8'd68:score=4'd4;
8'd69:score=4'd3;
8'd70:score=4'd2;
8'd71:score=4'd1;
8'd72:score=4'd0;
8'd73:score=4'd0;
8'd74:score=4'd1;
8'd75:score=4'd2;
8'd76:score=4'd2;
8'd77:score=4'd9;
8'd78:score=4'd9;
8'd79:score=4'd2;
8'd80:score=4'd2;
8'd81:score=4'd3;
8'd82:score=4'd4;
8'd83:score=4'd4;
8'd84:score=4'd3;
8'd85:score=4'd2;
8'd86:score=4'd1;
8'd87:score=4'd0;
8'd88:score=4'd0;
8'd89:score=4'd1;
8'd90:score=4'd2;
8'd91:score=4'd1;
8'd92:score=4'd8;
8'd93:score=4'd8;
8'd128:score=4'd0;
8'd129:score=4'd1;
8'd130:score=4'd2;
8'd131:score=4'd0;
8'd132:score=4'd0;
8'd133:score=4'd1;
8'd134:score=4'd2;
8'd135:score=4'd0;
8'd136:score=4'd2;
8'd137:score=4'd3;
8'd138:score=4'd12;
8'd139:score=4'd2;
8'd140:score=4'd3;
8'd141:score=4'd12;
8'd142:score=4'd4;
8'd143:score=4'd5;
8'd144:score=4'd4;
8'd145:score=4'd3;
8'd146:score=4'd2;
8'd147:score=4'd0;
8'd148:score=4'd4;
8'd149:score=4'd5;
8'd150:score=4'd4;
8'd151:score=4'd3;
8'd152:score=4'd2;
8'd153:score=4'd0;
8'd154:score=4'd8;
8'd155:score=4'd4;
8'd156:score=4'd8;
8'd157:score=4'd8;
8'd158:score=4'd4;
8'd159:score=4'd8;
default:score=0;endcase end endfunction
wire[3:0]note=score({music_active,note_index});
wire long_note=note[3];
function[31:0]note_increment;input[2:0]pitch;begin case(pitch)
3'd0:note_increment=32'd23396375;
3'd1:note_increment=32'd26261543;
3'd2:note_increment=32'd29477586;
3'd3:note_increment=32'd31230414;
3'd4:note_increment=32'd35054955;
3'd5:note_increment=32'd39347856;
3'd6:note_increment=32'd44166757;
3'd7:note_increment=32'd46792750;
endcase end endfunction
wire[5:0]last_note=music_active==0?41:music_active==1?29:31;
wire [15:0] note_samples = long_note ? (BEAT_SAMPLES*2) : BEAT_SAMPLES;
wire [15:0] remaining = note_samples-sample_count;
reg [7:0] gain;
always @* begin
 if(sample_count<256) gain=sample_count[7:0];
 else if(remaining<=512) gain=0;
 else if(remaining<768) gain=remaining-512;
 else gain=255;
end
// Precomputed additive timbre:6harmonics,1024phase positions. One synchronous
// ROM replaces6parallel sine lookups/adders. Phase changes only once per256
// mclk ticks; ROM is settled long before the next stereo sample capture.
wire signed[15:0]timbre;
`ifdef __ICARUS__
reg[15:0]timbre_rom[0:1023];reg[15:0]timbre_q;
initial $readmemh("settings61_timbre.hex",timbre_rom);
always @(posedge I_mclk)timbre_q<=timbre_rom[phase[31:22]];
assign timbre=timbre_q;
`else
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("SP"),
 .REGMODE_A("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE("D:/EG4S20/Contest/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/project2/lab_ex4_tf_audio_settings67/src/user_source/hdl_source/audio/settings61_timbre.mif"),.FILL_ALL("NONE")) u_timbre_rom(
 .dia(16'd0),.dib(16'd0),.addra(phase[31:22]),.addrb(10'd0),.cea(1'b1),.ceb(1'b0),
 .ocea(1'b0),.oceb(1'b0),.clka(I_mclk),.clkb(1'b0),.wea(1'b0),.web(1'b0),
 .bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(timbre),.dob());
`endif
wire signed [24:0] scaled_sample = timbre * $signed({1'b0,gain});
wire [23:0] next_sample = scaled_sample[23:0];
always @(posedge I_mclk or posedge I_rst) begin
 if(I_rst) begin
  O_i2s_BCLK<=0;O_i2s_LRCK<=0;O_i2s_DOUT<=0;
  music_active<=0;bit_count<=0;note_index<=0;sample_count<=0;phase<=0;shift_word<=0;sample_word<=0;
 end else begin
  O_i2s_BCLK<=~O_i2s_BCLK;
  if(O_i2s_BCLK) begin
   O_i2s_DOUT<=shift_word[63];shift_word<={shift_word[62:0],1'b0};
   if(bit_count==63) begin
    bit_count<=0;
    if(!O_i2s_LRCK) begin
     O_i2s_LRCK<=1;shift_word<={sample_word,40'd0};
    end else begin
     O_i2s_LRCK<=0;sample_word<=next_sample;shift_word<={next_sample,40'd0};
     if(music1!=music_active&&music1<3)begin music_active<=music1;note_index<=0;sample_count<=0;phase<=0;end
     else if(!music_paused)begin
     if(sample_count==note_samples-1) begin
      sample_count<=0;phase<=0;note_index<=note_index==last_note ? 0 : note_index+1'b1;
     end else begin
      sample_count<=sample_count+1'b1;phase<=phase+note_increment(note[2:0]);
     end
     end
    end
   end else bit_count<=bit_count+1'b1;
  end
 end
end
endmodule
