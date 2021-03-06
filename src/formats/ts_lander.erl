-module(ts_lander).
-export([start_link/1, start_link/2]).
-behaviour(gen_server).

-export([profile_name/1, exp_golomb_read_list/2, exp_golomb_read_list/3, exp_golomb_read_s/1]).

-include("../../include/ems.hrl").

% ems_sup:start_ts_lander("http://localhost:8080").


-record(ts_lander, {
  socket,
  url,
  buffer = <<>>,
  pids,
  consumer,
  byte_counter = 0
}).

-record(stream_out, {
  pid,
  handler
}).

-record(stream, {
  pid,
  program_num,
  handler,
  consumer,
  type,
  synced = false,
  ts_buffer = [],
  es_buffer = <<>>,
  counter = 0,
  start_pcr = 0,
  pcr = 0,
  start_dts = 0,
  dts = 0,
  video_config = undefined,
  send_audio_config = false,
  timestamp = 0,
  profile,
  profile_compat = 0,
  level,
  sps,
  pps
}).

-record(ts_header, {
  payload_start,
  pcr = undefined,
  opcr = undefined,
  timestamp
}).

-define(TYPE_VIDEO_MPEG1, 1).
-define(TYPE_VIDEO_MPEG2, 2).
-define(TYPE_VIDEO_MPEG4, 16).
-define(TYPE_VIDEO_H264,  27).
-define(TYPE_VIDEO_VC1,   234).
-define(TYPE_VIDEO_DIRAC, 209).
-define(TYPE_AUDIO_MPEG1, 3).
-define(TYPE_AUDIO_MPEG2, 4).
-define(TYPE_AUDIO_AAC,   15).
-define(TYPE_AUDIO_AAC2,  17).
-define(TYPE_AUDIO_AC3,   129).
-define(TYPE_AUDIO_DTS,   138).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([pat/4, pmt/4, pes/1]).

% {ok, Socket} = gen_tcp:connect("ya.ru", 80, [binary, {packet, http_bin}, {active, false}], 1000),
% gen_tcp:send(Socket, "GET / HTTP/1.0\r\n\r\n"),
% {ok, Reply} = gen_tcp:recv(Socket, 0, 1000),
% Reply.

% {ok, Pid1} = ems_sup:start_ts_lander("http://localhost:8080").

start_link(URL) -> start_link(URL, undefined).
  

start_link(URL, Consumer) ->
  gen_server:start_link(?MODULE, [URL, Consumer], []).


init([URL, Consumer]) ->
  {_, _, Host, Port, Path, Query} = http_uri:parse(URL),
  {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, http_bin}, {active, false}], 1000),
  gen_tcp:send(Socket, "GET "++Path++"?"++Query++" HTTP/1.0\r\n\r\n"),
  ok = inet:setopts(Socket, [{active, once}]),
  
  timer:send_after(3000, {byte_count}),
  
  {ok, #ts_lander{socket = Socket, url = URL, consumer = Consumer, pids = [#stream{pid = 0, handler = pat}]}}.
  
  % io:format("HTTP Request ~p~n", [RequestId]),
  % {ok, #ts_lander{request_id = RequestId, url = URL, pids = [#stream{pid = 0, handler = pat}]}}.
    


%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_call(Request, _From, State) ->
  ?D({"Undefined call", Request, _From}),
  {stop, {unknown_call, Request}, State}.


%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(_Msg, State) ->
  ?D({"Undefined cast", _Msg}),
  {noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_info({http, Socket, {http_response, _Version, 200, _Reply}}, TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, TSLander};

handle_info({http, Socket, {http_header, _, _Header, _, _Value}}, TSLander) ->
  inet:setopts(Socket, [{active, once}]),
  {noreply, TSLander};


handle_info({http, Socket, http_eoh}, TSLander) ->
  inet:setopts(Socket, [{active, true}, {packet, raw}]),
  {noreply, TSLander};


handle_info({tcp, _Socket, Bin}, #ts_lander{buffer = <<>>, byte_counter = Counter} = TSLander) ->
  {noreply, synchronizer(Bin, TSLander#ts_lander{byte_counter = Counter + size(Bin)})};

handle_info({tcp, _Socket, Bin}, #ts_lander{buffer = Buf, byte_counter = Counter} = TSLander) ->
  {noreply, synchronizer(<<Buf/binary, Bin/binary>>, TSLander#ts_lander{byte_counter = Counter + size(Bin)})};

handle_info({tcp_closed, Socket}, #ts_lander{socket = Socket} = TSLander) ->
  {stop, normal, TSLander#ts_lander{socket = undefined}};
  
handle_info({byte_count}, #ts_lander{byte_counter = Counter} = TSLander) ->
  ?D({"Bytes read", Counter}),
  % timer:send_after(3000, {byte_count}),
  {noreply, TSLander};

handle_info({stop}, #ts_lander{socket = Socket} = TSLander) ->
  gen_tcp:close(Socket),
  {stop, normal, TSLander#ts_lander{socket = undefined}};

handle_info(_Info, State) ->
  ?D({"Undefined info", _Info}),
  {noreply, State}.


synchronizer(<<16#47, _:187/binary, 16#47, _/binary>> = Bin, TSLander) ->
  {Packet, Rest} = split_binary(Bin, 188),
  Lander = demux(TSLander, Packet),
  synchronizer(Rest, Lander);

synchronizer(<<_, Bin/binary>>, TSLander) when size(Bin) >= 374 ->
  synchronizer(Bin, TSLander);

synchronizer(Bin, TSLander) ->
  TSLander#ts_lander{buffer = Bin}.


demux(#ts_lander{pids = Pids} = TSLander, <<16#47, _:1, PayloadStart:1, _:1, Pid:13, _:4, Counter:4, _/binary>> = Packet) ->
  Header = packet_timestamp(adaptation_field(Packet, #ts_header{payload_start = PayloadStart})),
  case lists:keyfind(Pid, #stream.pid, Pids) of
    #stream{handler = Handler, counter = _OldCounter} = Stream ->
      % Counter = (OldCounter + 1) rem 15,
      ?MODULE:Handler(ts_payload(Packet), TSLander, Stream#stream{counter = Counter}, Header);
    #stream_out{handler = Handler} ->
      Handler ! {ts_packet, Header, ts_payload(Packet)},
      TSLander;
    false ->
      TSLander
  end.
  
      

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 0:1, 1:1, _Counter:4, Payload/binary>>)  -> Payload;

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 1:1, 1:1, _Counter:4, 
              AdaptationLength, _AdaptationField:AdaptationLength/binary, Payload/binary>>) -> Payload;

ts_payload(<<16#47, _TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 
              _Adaptation:1, 0:1, _Counter:4, _Payload/binary>>)  ->
  ?D({"Empty payload on pid", _Pid}),
  <<>>.

adaptation_field(<<16#47, _:18, 0:1, _:5, _/binary>>, Header) -> Header;
adaptation_field(<<16#47, _:18, 1:1, _:5, AdaptationLength, AdaptationField:AdaptationLength/binary, _/binary>>, Header) when AdaptationLength > 0 -> 
  parse_adaptation_field(AdaptationField, Header);
  
adaptation_field(_, Header) -> Header.


parse_adaptation_field(<<_Discontinuity:1, _RandomAccess:1, _Priority:1, PCR:1, OPCR:1, _Splice:1, _Private:1, _Ext:1, Data/binary>>, Header) ->
  parse_adaptation_field(Data, PCR, OPCR, Header).

parse_adaptation_field(<<Pcr1:33, Pcr2:9, Rest/bitstring>>, 1, OPCR, Header) ->
  parse_adaptation_field(Rest, 0, OPCR, Header#ts_header{pcr = round((Pcr1 * 300 + Pcr2) / 27000)});

parse_adaptation_field(<<OPcr1:33, OPcr2:9, _Rest/bitstring>>, 0, 1, Header) ->
  Header#ts_header{opcr = round((OPcr1 * 300 + OPcr2) / 27000)};
  
parse_adaptation_field(_, 0, 0, Field) -> Field.


packet_timestamp(#ts_header{pcr = PCR} = Header) when is_integer(PCR) andalso PCR > 0 -> Header#ts_header{timestamp = PCR};
packet_timestamp(#ts_header{opcr = OPCR} = Header) when is_integer(OPCR) andalso OPCR > 0 -> Header#ts_header{timestamp = OPCR};
packet_timestamp(Header) -> Header.


%%%%%%%%%%%%%%%   Program access table  %%%%%%%%%%%%%%

pat(<<_PtField, 0, 2#10:2, 2#11:2, Length:12, _Misc:5/binary, PAT/binary>>, #ts_lander{pids = Pids} = TSLander, _, _) -> % PAT
  ProgramCount = round((Length - 5)/4) - 1,
  % io:format("PAT: ~p programs (~p)~n", [ProgramCount, size(PAT)]),
  Descriptors = extract_pat(PAT, ProgramCount, []),
  TSLander#ts_lander{pids = lists:keymerge(#stream.pid, Pids, Descriptors)}.


extract_pat(<<_CRC32/binary>>, 0, Descriptors) ->
  lists:keysort(#stream.pid, Descriptors);
extract_pat(<<ProgramNum:16, _:3, Pid:13, PAT/binary>>, ProgramCount, Descriptors) ->
  % io:format("Program ~p on pid ~p~n", [ProgramNum, Pid]),
  extract_pat(PAT, ProgramCount - 1, [#stream{handler = pmt, pid = Pid, counter = 0, program_num = ProgramNum} | Descriptors]).




pmt(<<_Pointer, 2, _SectionInd:1, 0:1, 2#11:2, SectionLength:12, 
    ProgramNum:16, _:2, _Version:5, _CurrentNext:1, _SectionNumber,
    _LastSectionNumber, _:3, _PCRPID:13, _:4, ProgramInfoLength:12, 
    _ProgramInfo:ProgramInfoLength/binary, PMT/binary>>, #ts_lander{pids = Pids, consumer = Consumer} = TSLander, _, _) ->
  _SectionCount = round(SectionLength - 13),
  % io:format("Program ~p v~p. PCR: ~p~n", [ProgramNum, _Version, PCRPID]),
  Descriptors = extract_pmt(PMT, []),
  io:format("Streams: ~p~n", [Descriptors]),
  Descriptors1 = lists:map(fun(#stream{pid = Pid} = Stream) ->
    case lists:keyfind(Pid, #stream.pid, Pids) of
      false ->
        Handler = spawn_link(?MODULE, pes, [Stream#stream{program_num = ProgramNum, consumer = Consumer}]),
        ?D({"Starting", Handler}),
        #stream_out{pid = Pid, handler = Handler};
      Other ->
        Other
    end
  end, Descriptors),
  % AllPids = [self() | lists:map(fun(A) -> element(#stream_out.handler, A) end, Descriptors1)],
  % eprof:start(),
  % eprof:start_profiling(AllPids),
  % TSLander#ts_lander{pids = lists:keymerge(#stream.pid, Pids, Descriptors1)}.
  TSLander#ts_lander{pids = Descriptors1}.

extract_pmt(<<StreamType, 2#111:3, Pid:13, _:4, ESLength:12, _ES:ESLength/binary, Rest/binary>>, Descriptors) ->
  ?D({"Pid -> Type", Pid, StreamType}),
  extract_pmt(Rest, [#stream{handler = pes, counter = 0, pid = Pid, type = stream_type(StreamType)}|Descriptors]);
  
extract_pmt(_CRC32, Descriptors) ->
  % io:format("Unknown PMT: ~p~n", [PMT]),
  lists:keysort(#stream.pid, Descriptors).


stream_type(?TYPE_VIDEO_H264) -> video;
stream_type(?TYPE_AUDIO_AAC) -> audio;
stream_type(?TYPE_AUDIO_AAC2) -> audio;
stream_type(Type) -> ?D({"Unknown TS PID type", Type}), unhandled.

pes(#stream{synced = false, pid = Pid} = Stream) ->
  receive
    {ts_packet, #ts_header{payload_start = 0}, _} ->
      ?D({"Not synced pes", Pid}),
      ?MODULE:pes(Stream);
    {ts_packet, #ts_header{payload_start = 1}, Packet} ->
      ?D({"Synced PES", Pid}),
      Stream1 = Stream#stream{synced = true, ts_buffer = [Packet]},
      ?MODULE:pes(Stream1);
    Other ->
      ?D({"Undefined message to pid", Pid, Other})
  end;
  
pes(#stream{synced = true, pid = Pid, ts_buffer = Buf} = Stream) ->
  receive
    {ts_packet, #ts_header{payload_start = 0}, Packet} ->
      Stream1 = Stream#stream{synced = true, ts_buffer = [Packet | Buf]},
      ?MODULE:pes(Stream1);
    {ts_packet, #ts_header{payload_start = 1} = Header, Packet} ->
      PES = list_to_binary(lists:reverse(Buf)),
      % ?D({"Decode PES", Pid, size(Stream#stream.es_buffer), length(Stream#stream.ts_buffer)}),
      % ?D({"Decode PES", Pid, length(element(2, process_info(self(), binary)))}),
      % ?D({"Decode PES", Pid, length(Stream#stream.parameters)}),
      Stream1 = pes_packet(PES, Stream, Header),
      Stream2 = Stream1#stream{ts_buffer = [Packet]},
      ?MODULE:pes(Stream2);
    Other ->
      ?D({"Undefined message to pid", Pid, Other})
  end.
    
      
pes_packet(_, #stream{type = unhandled} = Stream, _) -> Stream#stream{ts_buffer = []};

pes_packet(<<1:24, _:5/binary, Length, _PESHeader:Length/binary, Data/binary>> = Packet, #stream{type = audio, es_buffer = Buffer} = Stream, Header) ->
  Stream1 = stream_timestamp(Packet, Stream, Header),
  % ?D({"Audio", Stream1#stream.timestamp}),
  Stream1;
  % decode_aac(Stream1#stream{es_buffer = <<Buffer/binary, Data/binary>>});
  
pes_packet(<<1:24, _:5/binary, PESHeaderLength, _PESHeader:PESHeaderLength/binary, Rest/binary>> = Packet, #stream{es_buffer = Buffer, type = video} = Stream, Header) ->
  % ?D({"Timestamp1", Stream#stream.timestamp, Stream#stream.start_time}),
  Stream1 = stream_timestamp(Packet, Stream, Header),
  % ?D({"Video", Stream1#stream.timestamp}),
  decode_avc(Stream1#stream{es_buffer = <<Buffer/binary, Rest/binary>>}).


stream_timestamp(<<_:7/binary, 2#00:2, _:6, PESHeaderLength, _PESHeader:PESHeaderLength/binary, _/binary>>, Stream, #ts_header{timestamp = TimeStamp}) when is_integer(TimeStamp) andalso TimeStamp > 0 ->
  % ?D({"No DTS, taking", TimeStamp}),
  normalize_timestamp(Stream#stream{pcr = round(TimeStamp)});

stream_timestamp(<<_:7/binary, 2#11:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>, Stream, _Header) ->
  <<3:4/integer, _:36/integer, 1:4/integer, Dts3:3/integer, 1:1/integer, Dts2:15/integer, 1:1/integer, Dts1:15/integer, 1:1/integer>> = PESHeader,
  % ?D({"Have DTS & PTS", round((Dts1 + (Dts2 bsl 15) + (Dts3 bsl 30))/90)}),
  normalize_timestamp(Stream#stream{dts = round((Dts1 + (Dts2 bsl 15) + (Dts3 bsl 30))/90)});
  

stream_timestamp(<<_:7/binary, 2#10:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>, Stream, _Header) ->
  <<2:4/integer, Pts3:3/integer, 1:1/integer, Pts2:15/integer, 1:1/integer, Pts1:15/integer, 1:1/integer>> = PESHeader,
  % ?D("Have DTS"),
  normalize_timestamp(Stream#stream{dts = round((Pts1 + (Pts2 bsl 15) + (Pts3 bsl 30))/90)});

% FIXME!!!
% Here is a HUGE hack. VLC give me stream, where are no DTS or PTS, only OPCR, once a second,
% thus I increment timestamp counter on each NAL, assuming, that there is 25 FPS.
% This is very, very wrong, but I really don't know how to calculate it in other way.
stream_timestamp(_, #stream{timestamp = TimeStamp} = Stream, _) ->
  Stream#stream{timestamp = TimeStamp + 40}.

% normalize_timestamp(Stream) -> Stream;
normalize_timestamp(#stream{start_dts = 0, dts = DTS} = Stream) when is_integer(DTS) andalso DTS > 0 -> 
  Stream#stream{start_dts = DTS, timestamp = 0, dts = 0};
normalize_timestamp(#stream{start_dts = Start, dts = DTS} = Stream) when is_integer(DTS) andalso DTS > 0 -> 
  Stream#stream{timestamp = DTS - Start, dts = 0};
normalize_timestamp(#stream{start_pcr = 0, pcr = PCR} = Stream) when is_integer(PCR) andalso PCR > 0 -> 
  Stream#stream{start_pcr = PCR, timestamp = 0, pcr = 0};
normalize_timestamp(#stream{start_pcr = Start, pcr = PCR} = Stream) -> 
  Stream#stream{timestamp = PCR - Start, pcr = 0}.
% normalize_timestamp(Stream) -> Stream.

% <<18,16,6>>
decode_aac(#stream{send_audio_config = false, consumer = Consumer} = Stream) ->
  % Config = <<16#A:4, 3:2, 1:1, 1:1, 0>>,
  Config = <<18,16,6>>,
  AudioConfig = #video_frame{       
   	type          = ?FLV_TAG_TYPE_AUDIO,
   	decoder_config = true,
		timestamp_abs = 0,
		body          = Config,
	  sound_format	= ?FLV_AUDIO_FORMAT_AAC,
	  sound_type	  = ?FLV_AUDIO_TYPE_STEREO,
	  sound_size	  = ?FLV_AUDIO_SIZE_16BIT,
	  sound_rate	  = ?FLV_AUDIO_RATE_44,
	  raw_body      = false
	},
	Consumer ! {audio_config, AudioConfig},
	?D({"Send audio config", AudioConfig}),
	decode_aac(Stream#stream{send_audio_config = true});
  

decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, 1:1, _Profile:2, _Sampling:4,
                                 _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
                                 _FrameLength:13, _ADTS:11, _Count:2, _CRC:16, Rest/binary>>} = Stream) ->
  send_aac(Stream#stream{es_buffer = Rest});

decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, _ProtectionAbsent:1, _Profile:2, _Sampling:4,
                                 _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
                                 _FrameLength:13, _ADTS:11, _Count:2, Rest/binary>>} = Stream) ->
  % ?D({"AAC", Syncword, ID, Layer, ProtectionAbsent, Profile, Sampling, Private, Channel, Original, Home,
  % Copyright, CopyrightStart, FrameLength, ADTS, Count}),
  send_aac(Stream#stream{es_buffer = Rest}).

send_aac(#stream{es_buffer = Data, consumer = Consumer, timestamp = Timestamp} = Stream) ->
  % ?D({"Audio", Stream#stream.timestamp}),
  AudioFrame = #video_frame{       
    type          = ?FLV_TAG_TYPE_AUDIO,
    timestamp_abs = Timestamp,
    streamid      = 1,
    body          = Data,
    sound_format  = ?FLV_AUDIO_FORMAT_AAC,
    sound_type    = ?FLV_AUDIO_TYPE_STEREO,
    sound_size    = ?FLV_AUDIO_SIZE_16BIT,
    sound_rate    = ?FLV_AUDIO_RATE_44,
    raw_body      = false
  },
  Consumer ! {audio, AudioFrame},
  Stream#stream{es_buffer = <<>>}.
  

decode_avc(#stream{es_buffer = <<16#000001:24, _/binary>>} = Stream) ->
  find_nal_end(Stream, 3);
  
decode_avc(#stream{es_buffer = Data} = Stream) ->
  % io:format("PES ~p ~p ~p ~p, ~p, ~p~n", [StreamId, _DataAlignmentIndicator, _PesPacketLength, PESHeaderLength, PESHeader, Rest]),
  % io:format("PES ~p ~p ~p ~p, ~p, ~p~n", [StreamId, _DataAlignmentIndicator, _PesPacketLength, PESHeaderLength, PESHeader, Rest]),
  Offset1 = nal_unit_start_code_finder(Data, 0) + 3,
  find_nal_end(Stream, Offset1).
  
find_nal_end(Stream, false) ->  
  Stream;
  
find_nal_end(#stream{es_buffer = Data} = Stream, Offset1) ->
  Offset2 = nal_unit_start_code_finder(Data, Offset1+3),
  extract_nal(Stream, Offset1, Offset2).

extract_nal(Stream, _, false) ->
  Stream;
  
extract_nal(#stream{es_buffer = Data} = Stream, Offset1, Offset2) ->
  Length = Offset2-Offset1,
  <<_:Offset1/binary, NAL:Length/binary, Rest1/binary>> = Data,
  Stream1 = decode_nal(NAL, Stream),
  decode_avc(Stream1#stream{es_buffer = Rest1}).

send_video_config(#stream{consumer = Consumer} = Stream) ->
  case decoder_config(Stream) of
    ok -> Stream;
    DecoderConfig -> 
      VideoFrame = #video_frame{       
       	type          = ?FLV_TAG_TYPE_VIDEO,
       	decoder_config = true,
    		timestamp_abs = 0,
    		body          = DecoderConfig,
    		frame_type    = ?FLV_VIDEO_FRAME_TYPE_KEYFRAME,
    		codec_id      = ?FLV_VIDEO_CODEC_AVC,
    	  raw_body      = false,
    	  streamid      = 1
    	},
      % ?D({"Send decoder config to", Consumer}),
  	  Consumer ! {video_config, VideoFrame},
      Stream#stream{video_config = DecoderConfig}
  end.
  
decoder_config(#stream{sps = undefined}) -> ok;
decoder_config(#stream{pps = undefined}) -> ok;
decoder_config(#stream{pps = PPS, sps = SPS, profile = Profile, profile_compat = ProfileCompat, level = Level}) ->
  LengthSize = 4-1,
  Version = 1,
  SPSBin = iolist_to_binary(SPS),
  PPSBin = iolist_to_binary(PPS),
  <<Version, Profile, ProfileCompat, Level, 2#111111:6, LengthSize:2, 
    2#111:3, (length(SPS)):5, (size(SPSBin)):16, SPSBin/binary,
    (length(PPS)), (size(PPSBin)):16, PPSBin/binary>>.


nal_unit_start_code_finder(Bin, Offset) ->
  case Bin of
    <<_:Offset/binary, Rest/binary>> -> find_nal_start_code(Rest, Offset);
    _ -> false
  end.

find_nal_start_code(<<16#000001:24, _/binary>>, Offset) -> Offset;
find_nal_start_code(<<_:1/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 1;
find_nal_start_code(<<_:2/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 2;
find_nal_start_code(<<_:3/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 3;
find_nal_start_code(<<_:4/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 4;
find_nal_start_code(<<_:5/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 5;
find_nal_start_code(<<_:6/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 6;
find_nal_start_code(<<_:7/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 7;
find_nal_start_code(<<_:8/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 8;
find_nal_start_code(<<_:9/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 9;
find_nal_start_code(<<_:10/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 10;
find_nal_start_code(<<_:11/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 11;
find_nal_start_code(<<_:12/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 12;
find_nal_start_code(<<_:13/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 13;
find_nal_start_code(<<_:14/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 14;
find_nal_start_code(<<_:15/binary, 16#000001:24, _/binary>>, Offset) -> Offset + 15;
find_nal_start_code(<<_:16/binary, Rest/binary>>, Offset) -> find_nal_start_code(Rest, Offset+16);
% find_nal_start_code(<<_, Rest/binary>>, Offset) -> find_nal_start_code(Rest, Offset+1);
find_nal_start_code(_, _) -> false.

decode_nal(<<0:1, _NalRefIdc:2, 1:5, Rest/binary>>, #stream{consumer = undefined} = Stream) ->
  % io:format("Coded slice of a non-IDR picture :: "),
  slice_header(Rest, Stream);

decode_nal(<<0:1, _NalRefIdc:2, 1:5, _/binary>> = Data, #stream{timestamp = TimeStamp, consumer = Consumer} = Stream) ->
  VideoFrame = #video_frame{
   	type          = ?FLV_TAG_TYPE_VIDEO,
		timestamp_abs = TimeStamp,
		body          = nal_with_size(Data),
		frame_type    = ?FLV_VIDEO_FRAME_TYPEINTER_FRAME,
		codec_id      = ?FLV_VIDEO_CODEC_AVC,
	  raw_body      = false,
	  streamid      = 1
  },
  % ?D({"Send slice to", TimeStamp, Consumer}),
  Consumer ! {video, VideoFrame},
  Stream;


decode_nal(<<0:1, _NalRefIdc:2, 2:5, Rest/binary>>, Stream) ->
  % io:format("Coded slice data partition A     :: "),
  slice_header(Rest, Stream);

decode_nal(<<0:1, _NalRefIdc:2, 3:5, Rest/binary>>, Stream) ->
  % io:format("Coded slice data partition B     :: "),
  slice_header(Rest, Stream);

decode_nal(<<0:1, _NalRefIdc:2, 4:5, Rest/binary>>, Stream) ->
  % io:format("Coded slice data partition C     :: "),
  slice_header(Rest, Stream);

decode_nal(<<0:1, _NalRefIdc:2, 5:5, Rest/binary>>, #stream{consumer = undefined} = Stream) ->
  % io:format("~nCoded slice of an IDR picture~n"),
  slice_header(Rest, Stream);
  
decode_nal(<<0:1, _NalRefIdc:2, 5:5, _/binary>> = Data, #stream{timestamp = TimeStamp, consumer = Consumer} = Stream) ->
  VideoFrame = #video_frame{
   	type          = ?FLV_TAG_TYPE_VIDEO,
		timestamp_abs = TimeStamp,
		body          = nal_with_size(Data),
		frame_type    = ?FLV_VIDEO_FRAME_TYPE_KEYFRAME,
		codec_id      = ?FLV_VIDEO_CODEC_AVC,
	  raw_body      = false,
	  streamid      = 1
  },
  % ?D({"Send keyframe to", Consumer}),
  Consumer ! {video, VideoFrame},
  Stream;

decode_nal(<<0:1, _NalRefIdc:2, 8:5, _/binary>> = PPS, Stream) ->
  % io:format("Picture parameter set: ~p~n", [PPS]),
  send_video_config(Stream#stream{pps = [remove_trailing_zero(PPS)]});

decode_nal(<<0:1, _NalRefIdc:2, 9:5, PrimaryPicTypeId:3, _:5, _/binary>>, Stream) ->
  PrimaryPicType = case PrimaryPicTypeId of
      0 -> "I";
      1 -> "I, P";
      2 -> "I, P, B";
      3 -> "SI";
      4 -> "SI, SP";
      5 -> "I, SI";
      6 -> "I, SI, P, SP";
      7 -> "I, SI, P, SP, B"
  end,
  io:format("Access unit delimiter, PPT = ~p~n", [PrimaryPicType]),
  Stream;


decode_nal(<<0:1, _NalRefIdc:2, 7:5, Profile, _:8, Level, _/binary>> = SPS, Stream) ->
  % {_SeqParameterSetId, _Data2} = exp_golomb_read(Data1),
  % {Log2MaxFrameNumMinus4, Data3} = exp_golomb_read(Data2),
  % {PicOrderCntType, Data4} = exp_golomb_read(Data3),
  % case PicOrderCntType of
  %   0 ->
  %     {Log2MaxPicOrder, Data5} = exp_golomb_read(Data4);
  %   1 ->
  %     <<DeltaPicAlwaysZero:1, Data4_1/bitstring>> = Data4,
      
  % _ProfileName = profile_name(Profile),
  % io:format("~nSequence parameter set ~p ~p~n", [ProfileName, Level/10]),
  % io:format("log2_max_frame_num_minus4: ~p~n", [Log2MaxFrameNumMinus4]),
  send_video_config(Stream#stream{profile = Profile, level = Level, sps = [remove_trailing_zero(SPS)]});
  


decode_nal(<<0:1, _NalRefIdc:2, _NalUnitType:5, _/binary>>, Stream) ->
  % io:format("Unknown NAL unit type ~p~n", [NalUnitType]),
  Stream.
  
  
nal_with_size(NAL) -> <<(size(NAL)):32, NAL/binary>>.

remove_trailing_zero(Bin) ->
  Size = size(Bin) - 1,
  case Bin of
    <<Smaller:Size/binary, 0>> -> remove_trailing_zero(Smaller);
    _ -> Bin
  end.

profile_name(66) -> "Baseline";
profile_name(77) -> "Main";
profile_name(88) -> "Extended";
profile_name(100) -> "High";
profile_name(110) -> "High 10";
profile_name(122) -> "High 4:2:2";
profile_name(144) -> "High 4:4:4";
profile_name(Profile) -> "Unknown "++integer_to_list(Profile).


slice_header(Bin, Stream) ->
    {_FirstMbInSlice, Rest} = exp_golomb_read(Bin),
    {SliceTypeId, Rest2 } = exp_golomb_read(Rest),
    {_PicParameterSetId, Rest3 } = exp_golomb_read(Rest2),
    <<_FrameNum:5, _FieldPicFlag:1, _BottomFieldFlag:1, _/bitstring>> = Rest3,
    _SliceType = slice_type(SliceTypeId),
    % io:format("~s~p:~p:~p:~p ~n", [_SliceType, _FrameNum, _PicParameterSetId, _FieldPicFlag, _BottomFieldFlag]),
    Stream.

slice_type(0) -> 'P';
slice_type(1) -> 'B';
slice_type(2) -> 'I';
slice_type(3) -> 'p';
slice_type(4) -> 'i';
slice_type(5) -> 'P';
slice_type(6) -> 'B';
slice_type(7) -> 'I';
slice_type(8) -> 'p';
slice_type(9) -> 'i'.


exp_golomb_read_list(Bin, List) ->
  exp_golomb_read_list(Bin, List, []).
  
exp_golomb_read_list(Bin, [], Results) -> {Results, Bin};
exp_golomb_read_list(Bin, [Key | Keys], Results) ->
  {Value, Rest} = exp_golomb_read(Bin),
  exp_golomb_read_list(Rest, Keys, [{Key, Value} | Results]).

exp_golomb_read_s(Bin) ->
  {Value, _Rest} = exp_golomb_read(Bin),
  case Value band 1 of
    1 -> (Value + 1)/2;
    _ -> - (Value/2)
  end.

exp_golomb_read(Bin) ->
  exp_golomb_read(Bin, 0).
  
exp_golomb_read(<<0:1, Rest/bitstring>>, LeadingZeros) ->
  exp_golomb_read(Rest, LeadingZeros + 1);

exp_golomb_read(<<1:1, Data/bitstring>>, LeadingZeros) ->
  <<ReadBits:LeadingZeros, Rest/bitstring>> = Data,
  CodeNum = (1 bsl LeadingZeros) -1 + ReadBits,
  {CodeNum, Rest}.


%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _TSLander) ->
  ?D({"TS Lander terminating", _Reason}),
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
