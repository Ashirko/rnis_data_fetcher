-module(rnis_data_egts_fetcher).

-behaviour(gen_fsm).

%% API
-export([start_link/0]).

%% gen_fsm callbacks
-export([init/1,
  data/2,
  data/3,
  handle_info/2,
  handle_info/3,
  terminate/3,
  code_change/4,
  handle_event/3,
  handle_sync_event/4]).

-compile(export_all).

-include_lib("../../rnis_data/include/rnis_data.hrl").

-record(state, {socket, buffer = <<>>, packetId = 0, recordId = 0, timeout}).

-record(egts, {id, time, valid = false, latitude, longitude, speed, bearing, alarm_button = false}).

-define(CONNECT_TIMEOUT,  600000). %% 10 minutes
-define(ACTIVE_TIMEOUT,   600000). %% 10 minutes

-define(EGTS_PT_RESPONSE, 0).
-define(EGTS_PT_APPDATA, 1).

-define(EGTS_AUTH_SERVICE, 1).
-define(EGTS_TELEDATA_SERVICE, 2).

-define(TIMESTAMP_20100101_000000_UTC, 1262304000).

-define(RIGHT_NOW, 0). %% continue w/o timeout
-define(TIMEOUT, 600000). %% 10 minutes
-define(MAXBUFSZ, 102400). %% 100 kilobytes

-define(NEXT_DATA(Data, State, Rest, Answer),
  {next, #parser_result{data = Data, state = State#state{buffer = Rest}, answer = Answer, next = check_data}}).
%%  {next, #parser_result{data = Data, state = State#state{buffer = Rest}, answer = Answer, next = check_data}, ?RIGHT_NOW}).

-define(NEXT(ReceiveTime, Reply, Data, State, TimeOut),
  {next_state, data,
    next(ReceiveTime, Reply, Data, State#state{timeout = TimeOut}),
    TimeOut}).

%% Callbacks
start_link() ->
  lager:info("start rnis_data_egts_fetcher on node ~p", [node()]),
  gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  {ok, Socket} = connect_to_egts(),
  subscribe_data(Socket),
  lager:info("rnis_data_fetcher started"),
  {ok, data, #state{socket = Socket}, ?CONNECT_TIMEOUT}.

data(timeout, State) ->
  {stop, timeout, State};
data(Msg, State) ->
  lager:error("Unknown async message: ~p", [Msg]),
  {stop, unknown_message, State}.
data(Msg, _From, State) ->
  lager:error("Unknown async message: ~p", [Msg]),
  {stop, unknown_message, State}.

process_message(NewAddBuf, #state{buffer = CurrBuf} = State) when size(CurrBuf) > ?MAXBUFSZ ->
  data(NewAddBuf, State#state{buffer = <<>>});
process_message(NewAddBuf, #state{buffer = CurrBuf, packetId = AnsPID, recordId = AnsRID} = State) ->
  case handle_header(<<CurrBuf/binary, NewAddBuf/binary>>) of
    {continue, Rest} ->
      {next,
        #parser_result{
          state = State#state{buffer = Rest},
          next = data
        }, ?TIMEOUT};
    {ok, ResultList, PackID, RecIDs, Rest} ->
      Answer = answer(PackID, RecIDs, AnsPID, AnsRID),
      ?NEXT_DATA(process_result(0, lists:sort(lists:flatten(ResultList))),
        State#state{packetId = (AnsPID + 1) band 16#ffff, recordId = (AnsRID + 1) band 16#ffff}, Rest, Answer);
    {error, Reason} ->
      lager:error("error parse data ~p", [Reason]),
      {error, {corrupted, Reason, CurrBuf},
        #parser_result{
          state = State#state{buffer = <<>>},
          next = data
        }, ?TIMEOUT}
  end.

process_result(I, R) ->
  process_result(I, R, []).
%
process_result(_OID, [], []) ->
  [];
process_result(OID, [], Acc) ->
  [{OID, lists:reverse(Acc)}];
process_result(OID, [#egts{id = OID} = I | R], Acc) ->
  process_result(OID, R, [make_value(I) | Acc]);
process_result(OID, [#egts{id = New} = I | R], []) when OID /= New ->
  process_result(New, R, [make_value(I)]);
process_result(OID, [#egts{id = New} = I | R], Acc) ->
  [{OID, lists:reverse(Acc)} | process_result(New, R, [make_value(I)])];
process_result(_, _, _) ->
  [].

make_value(#egts{time = Time, latitude = Lat,
  longitude = Lon, speed = Spd,
  bearing = Bear, alarm_button = ABtn,
  valid = Valid, id = OID}) ->
  Rd = [
    {<<"lat">>, Lat},
    {<<"lon">>, Lon},
    {<<"bearing">>, Bear},
    {<<"speed">>, Spd},
    {<<"a_btn">>, b2i(ABtn)}
  ],
  {Time, Rd}.

handle_info(_Info, State) ->
  {noreply, State}.

handle_info({tcp_closed, _Socket}, _StateName, State) ->
  lager:error("Socket closed"),
  {stop, normal, State};
handle_info({tcp_error, Socket, Reason}, _StateName, #state{socket = Socket} = State) ->
  lager:error("Socket error: ~p", [Reason]),
  {stop, normal, State};
handle_info({tcp, _Sock, MsgData}, data, State) ->
  lager:info("handle tcp message: ~p", [MsgData]),
  process_data(MsgData, State);
handle_info(MsgData, _StateName, State) ->
  lager:error("ehat ~p", [MsgData]),
  lager:error("Recieve unknown info: ~p", [MsgData]),
  {stop, unknown_message, State}.

terminate(Reason, _StateName, #state{socket = Socket}) ->
  lager:info("terminate rnis_data_egts_fetcher with reason: ~p" , [Reason]),
  gen_tcp:close(Socket),
  ok.

handle_event(Event, _StateName, State) ->
  lager:error("Recieve async message: ~p", [Event]),
  {stop, unknown_message, State}.

handle_sync_event(Event, _StateName, _From, State) ->
  lager:error("Recieve sync message: ~p", [Event]),
  {stop, unknown_message, State}.

code_change(_OldVsn, StateName, #state{timeout = TimeOut} = StateData, _Extra) ->
  {ok, StateName, StateData, TimeOut}.

process_data(MsgData, State) ->
  lager:info("process_data: ~p", [MsgData]),
  CurTime = zont_time_util:system_time(millisec),
  case catch process_message(MsgData, State) of
    {next, #parser_result{data = Data, answer = Answer}} ->
      ?NEXT(CurTime, Answer, Data, State, ?ACTIVE_TIMEOUT);
%%    {next, #parser_result{data = Data, answer = Answer}, Timeout} ->
%%      ?NEXT(CurTime, Answer, Data, State, Timeout);
    {error, Error, #parser_result{data = Data, answer = Answer}} ->
      lager:error("parser error:  ~p", [Error]),
      ?NEXT(CurTime, Answer, Data, State, ?ACTIVE_TIMEOUT);
%%    {error, Error, #parser_result{data = Data, answer = Answer}, Timeout} ->
%%      lager:error("parser error:  ~p", [Error]),
%%      ?NEXT(CurTime, Answer, Data, State, Timeout);
    {stop, Reason} ->
      lager:error("Data process error: ~p", [Reason]),
      {stop, Reason, State};
    Else ->
      lager:error("Data process unknown error: ~p", [Else]),
      {stop, normal, State}
  end.

next(ReceiveTime, Reply, DataToProcess,
    #state{socket = Sock} = State) ->
  ok = reply(Sock, Reply),
  ok = zont_process(ReceiveTime, DataToProcess),
  ok = set_active(Sock),
  State.

reply(_Sock, undefined) ->
  ok;
reply(_Sock, <<>>) ->
  ok;
reply(Sock, Data) ->
  lager:info("send data: ~p", [Data]),
  gen_tcp:send(Sock, Data).

zont_process(ReceiveTime, Data) when is_list(Data) ->
  case filter_data(ReceiveTime, Data) of
    empty ->
      ok;
    Data1 ->
      rnis_data_processor:process(Data1)
  end;
zont_process(_, _) ->
  ok.

filter_data(_ReceiveTime, []) ->
  empty;
filter_data(ReceiveTime, Data) when is_list(Data) ->
  lists:foldl(fun({ID, TimeList}, Acc) ->
    case TimeList of
      [] ->
        Acc;
      _ ->
        case ID of
          I when is_integer(I)->
            [{I, extend_data(ReceiveTime, TimeList, [])} | Acc];
          DevID->
            [{{tmp,DevID}, extend_data(ReceiveTime, TimeList, [])} | Acc]
        end
    end end, [], Data);
filter_data(_ReceiveTime, _) ->
  empty.

extend_data(_ReceiveTime, [], Acc) ->
  lists:ukeysort(1, Acc);
extend_data(ReceiveTime, [{Time, Data} | T], Acc) ->
  Data1 = lists:ukeysort(1, [{<<"rtime">>, ReceiveTime} | Data]),
  extend_data(ReceiveTime, T, [{Time, Data1} | Acc]).

set_active(Sock) ->
  inet:setopts(Sock, [{active, once}]).

connect_to_egts()->
  {ok,Node} = application:get_env(rnis_data_fetcher, rnis_connection_node),
  {ok,Port} = application:get_env(rnis_data_fetcher, rnis_connection_port),
  lager:info("try to connect to node ~p:~p", [Node, Port]),
  case gen_tcp:connect(Node, Port, [binary, {active, once}, {packet, 0}]) of
    {ok,Socket}->
      {ok,Socket};
    Error->
      lager:info("connectioin error to ~p : ~p", [Node, Error]),
      Error
  end.

auth_request()->
  PackID = 1,
  SubAuth = <<16#00, 10:32/little>>,
  SizeAuth = size(SubAuth),
  SubRecord = <<16#05, SizeAuth:16/little, SubAuth/binary>>,
  SubRecordSize = size(SubRecord),
  Body = <<SubRecordSize:16/little, 1:16/little, 0, ?EGTS_AUTH_SERVICE, ?EGTS_AUTH_SERVICE, SubRecord/binary>>,
  BodyLen = size(Body),
  BCS = crc16(Body),
  Header = <<16#01, 16#00, 16#03, 16#0b, 16#00, BodyLen:16/little, PackID:16/little, ?EGTS_PT_APPDATA>>,
  HCS = crc8(Header),
  <<Header/binary, HCS, Body/binary, BCS:16/little>>.

%%SecKey:8, Flags:8, 11, Encod:8,
%%DataLen:16/little, PackID:16/little, Type:8, HeadCS:8,
%%Body:DataLen/binary, BodyCS:16/little, Rest/binary>>)

%%SRBBody = <<0>>,
%%SRBBodySize = size(SRBBody),
%%SR = <<16#09, SRBBodySize:16/little, SRBBody/binary>>,
%%SRSize = size(SR),
%%%%                          flags 10011000: SSOD=1, RSOD=0, _, RPP=11=lowest, _, _, _
%%Body = <<SRSize:16/little, RecID:16/little, 16#58, ?EGTS_AUTH_SERVICE, ?EGTS_AUTH_SERVICE, SR/binary>>,
%%BodyLen = size(Body),
%%BCS = crc16(Body),
%%Header = <<16#01, 16#00, 16#03, 16#0b, 16#00, BodyLen:16/little, PackID:16/little, ?EGTS_PT_APPDATA>>,
%%HCS = crc8(Header),
%%Packet = <<Header/binary, HCS, Body/binary, BCS:16/little>>,
%%{ok, State#state{packetId = (PackID + 1) band 16#ffff, recordId = (RecID + 1) band 16#ffff}, Packet};

subscribe_data(Socket)->
  %%todo subscribe data
  Msg = auth_request(),
  lager:info("subscribe msg: ~p", [Msg]),
  gen_tcp:send(Socket, Msg).


%% Handle header
handle_header(<<16#01, SecKey:8, Flags:8, 11, Encod:8,
  DataLen:16/little, PackID:16/little, Type:8, HeadCS:8,
  Body:DataLen/binary, BodyCS:16/little, Rest/binary>>) ->
  CalcHeadCS = crc8(<<16#01, SecKey:8, Flags:8, 11, Encod:8, DataLen:16/little, PackID:16/little, Type:8>>),
  case HeadCS of
    CalcHeadCS ->
      case handle_body(Type, Body, BodyCS) of
        {ok, Result, RecIDs} ->
          {ok, Result, PackID, RecIDs, Rest};
        {error, Reason} ->
          {error, Reason}
      end;
    _ ->
      {error, "Header CS error"}
  end;
handle_header(<<16#01, _/binary>> = Data) ->
  {continue, Data};
handle_header(<<"RNIS-subscribe-@", LabelRest/binary>>) ->
  case binary:split(LabelRest, <<"@">>) of
    [Label, Rest] when is_binary(Label) andalso is_binary(Rest) ->
      Labels = binary:split(Label, <<",">>, [global]),
      spawn_link(?MODULE, queue_subscribe, [self(), Labels]),
      {continue, Rest};
    _ ->
      {error, <<"Subscribe header error">>}
  end;
handle_header(<<_:1/binary, Rest/binary>>) ->
  handle_header(Rest);
handle_header(<<>> = Data) ->
  {continue, Data};
handle_header(_) ->
  {error, "Header error"}.
%% Handle data
handle_body(Type, Body, CS) ->
  CalcCS = crc16(Body),
  case CS of
    CalcCS ->
      TmpList = handle_records(Type, Body),
      [RecIDs | ResultList] = lists:reverse(TmpList),
      %%lager:info("Result: ~p", [ResultList]),
      {ok, ResultList, RecIDs};
    _ ->
      {error, "Body CS error"}
  end.
%% Handle records
handle_records(?EGTS_PT_RESPONSE, _Body) ->
  %%lager:info("Response received: ~p", [Body]),
  %% Ignore responses so far
  [[], []];
handle_records(?EGTS_PT_APPDATA, Body) ->
  analyze_records(Body, []);
handle_records(Type, _Body) ->
  lager:error("Unknown packet type ~p", [Type]),
  [[], []].
%% Analyze records
analyze_records(<<_:32, _SSOD:1, _RSOD:1, _GRP:1, _RPP:2, TMFE:1, EVFE:1, OBFE:1, _/binary>> = Data, Acc) ->
  analyze_records(TMFE * 32, EVFE * 32, OBFE * 32, Data, Acc);
analyze_records(_, Acc) ->
  [Acc].
analyze_records(Tsz, Esz, Osz, Bin, Acc) ->
  <<Size:16/little, RecID:16/little, _Flags:8,
    OID:Osz/little, _EventID:Esz/little, _Tim:Tsz/little,
    SST:8, _RST:8, SubRecords:Size/binary, Rest/binary>> = Bin,
  [[E#egts{id = OID} || #egts{valid = true} = E <- analyze_subrecords(SST, SubRecords)] | analyze_records(Rest, [{SST, RecID} | Acc])].
%% Analyze subrecords
analyze_subrecords(?EGTS_AUTH_SERVICE, SubRecords) ->
  analyze_subrecords_auth(SubRecords);
analyze_subrecords(?EGTS_TELEDATA_SERVICE, SubRecords) ->
  analyze_subrecords_tele(SubRecords);
analyze_subrecords(Service, _SubRecords) ->
  lager:error("Unknown service ~p", [Service]),
  [].
%% Analyze subrecords auth
analyze_subrecords_auth(<<16#05, Size:16/little, Data:Size/binary, Rest/binary>>) ->
  [analyze_subrecord_auth_05(Data) | analyze_subrecords_auth(Rest)];
analyze_subrecords_auth(<<Type:8, Size:16/little, Data:Size/binary, Rest/binary>>) ->
  lager:info("Subrecord: Type: ~p, Data: ~p", [Type, Data]),
  analyze_subrecords_auth(Rest);
analyze_subrecords_auth(_) ->
  [].
analyze_subrecord_auth_05(<<16#00, DispID:32/little>>) ->
  PID = self(),
  lager:info("auth_05: ~p", [DispID]),
  PID ! {cmd, {auth, subscribe, DispID}, PID},
  ok;
analyze_subrecord_auth_05(_Data) ->
  %% Should authorize the client here
  %% Send response to the client
  PID = self(),
  PID ! {cmd, {auth, ok}, PID},
  ok.
%% Analyze subrecords teledata
analyze_subrecords_tele(<<16#10, Size:16/little, Data:Size/binary, Rest/binary>>) ->
  [analyze_subrecord_tele_10(Data) | analyze_subrecords_tele(Rest)];
analyze_subrecords_tele(<<_Type:8, Size:16/little, _Data:Size/binary, Rest/binary>>) ->
%%    lager:info("Type: ~p, Data: ~p",[Type, Data]),
  analyze_subrecords_tele(Rest);
analyze_subrecords_tele(_) ->
  [].
analyze_subrecord_tele_10(<<Tim:32/little, Lat:32/little, Lon:32/little,
  _ALTE:1, LOHS:1, LAHS:1, _MV:1, _BB:1, _CS:1, _FIX:1, VLD:1,
  SpdLo:8, BearHi:1, _ALTS:1, SpdHi:6, BearLo:8, _Odometer:24/little,
  _DigitalInputs:8, Source:8, _Unknown/binary>>) ->
  Time = (Tim + ?TIMESTAMP_20100101_000000_UTC) * 1000,
  Latitude = (Lat * 90 / 16#ffffffff) * (1 - 2 * LAHS),
  Longitude = (Lon * 180 / 16#ffffffff) * (1 - 2 * LOHS),
  Valid = tf(VLD),
  Speed = (SpdHi * 256 + SpdLo) div 10,
  Bearing = BearHi * 256 + BearLo,
  ABtn = if Source == 13 -> true; true -> false end,
  #egts{time = Time, valid = Valid,
    latitude = Latitude, longitude = Longitude,
    speed = Speed, bearing = Bearing, alarm_button = ABtn}.

%% Answer generation
answer(_PackID, [], _AnsPID, _AnsRID) ->
  <<>>;
answer(PackID, RecIDs, AnsPID, AnsRID) ->
  Service = case RecIDs of
              [{?EGTS_AUTH_SERVICE, _} | _] ->
                ?EGTS_AUTH_SERVICE;
              [{?EGTS_TELEDATA_SERVICE, _} | _] ->
                ?EGTS_TELEDATA_SERVICE;
              [{Srv, _} | _] ->
                lager:info("Unsupoorted service ~p", [Srv]),
                Srv;
              _ ->
                lager:error("Error in RecIDs: ~p", [RecIDs]),
                ?EGTS_AUTH_SERVICE
            end,
  SubRecs = list_to_binary(lists:flatten(
    [[0,          %% SubRec Type
      3,          %% SubRec Len Low
      0,          %% SubRec Len High
      E rem 256,  %% Record num to confirm Low
      E div 256,  %% Record num to confirm High
      0           %% Confirm OK
    ] || {_, E} <- lists:reverse(RecIDs)])),
  SubRecLen = size(SubRecs),
  RecLen = SubRecLen + 10,
  Header =
    <<16#01,            %% start symbol
      16#00,            %% security key
      16#03,            %% xxxxxx11 - lowest priority
      16#0b,            %% header length = 11
      16#00,            %% encription
      RecLen:16/little,
      AnsPID:16/little,
      ?EGTS_PT_RESPONSE>>,
  HCS = crc8(Header),
  Body =
    <<PackID:16/little,   %% Packet id we response to
      16#00,                %% data accepted and saved
      SubRecLen:16/little,  %% record size
      AnsRID:16/little,     %% record id
      16#18,                %% xxx11xxx - lowest priority
      Service,
      Service,
      SubRecs/binary>>,
  BCS = crc16(Body),
  <<Header/binary, HCS, Body/binary, BCS:16/little>>.

% Utility
tf(I) when is_integer(I) andalso I > 0 ->
  true;
tf(_) ->
  false.
%
b2i(true) ->
  1;
b2i(_) ->
  0.

%

-define(CRC8, {
  16#00, 16#31, 16#62, 16#53, 16#C4, 16#F5, 16#A6, 16#97,
  16#B9, 16#88, 16#DB, 16#EA, 16#7D, 16#4C, 16#1F, 16#2E,
  16#43, 16#72, 16#21, 16#10, 16#87, 16#B6, 16#E5, 16#D4,
  16#FA, 16#CB, 16#98, 16#A9, 16#3E, 16#0F, 16#5C, 16#6D,
  16#86, 16#B7, 16#E4, 16#D5, 16#42, 16#73, 16#20, 16#11,
  16#3F, 16#0E, 16#5D, 16#6C, 16#FB, 16#CA, 16#99, 16#A8,
  16#C5, 16#F4, 16#A7, 16#96, 16#01, 16#30, 16#63, 16#52,
  16#7C, 16#4D, 16#1E, 16#2F, 16#B8, 16#89, 16#DA, 16#EB,
  16#3D, 16#0C, 16#5F, 16#6E, 16#F9, 16#C8, 16#9B, 16#AA,
  16#84, 16#B5, 16#E6, 16#D7, 16#40, 16#71, 16#22, 16#13,
  16#7E, 16#4F, 16#1C, 16#2D, 16#BA, 16#8B, 16#D8, 16#E9,
  16#C7, 16#F6, 16#A5, 16#94, 16#03, 16#32, 16#61, 16#50,
  16#BB, 16#8A, 16#D9, 16#E8, 16#7F, 16#4E, 16#1D, 16#2C,
  16#02, 16#33, 16#60, 16#51, 16#C6, 16#F7, 16#A4, 16#95,
  16#F8, 16#C9, 16#9A, 16#AB, 16#3C, 16#0D, 16#5E, 16#6F,
  16#41, 16#70, 16#23, 16#12, 16#85, 16#B4, 16#E7, 16#D6,
  16#7A, 16#4B, 16#18, 16#29, 16#BE, 16#8F, 16#DC, 16#ED,
  16#C3, 16#F2, 16#A1, 16#90, 16#07, 16#36, 16#65, 16#54,
  16#39, 16#08, 16#5B, 16#6A, 16#FD, 16#CC, 16#9F, 16#AE,
  16#80, 16#B1, 16#E2, 16#D3, 16#44, 16#75, 16#26, 16#17,
  16#FC, 16#CD, 16#9E, 16#AF, 16#38, 16#09, 16#5A, 16#6B,
  16#45, 16#74, 16#27, 16#16, 16#81, 16#B0, 16#E3, 16#D2,
  16#BF, 16#8E, 16#DD, 16#EC, 16#7B, 16#4A, 16#19, 16#28,
  16#06, 16#37, 16#64, 16#55, 16#C2, 16#F3, 16#A0, 16#91,
  16#47, 16#76, 16#25, 16#14, 16#83, 16#B2, 16#E1, 16#D0,
  16#FE, 16#CF, 16#9C, 16#AD, 16#3A, 16#0B, 16#58, 16#69,
  16#04, 16#35, 16#66, 16#57, 16#C0, 16#F1, 16#A2, 16#93,
  16#BD, 16#8C, 16#DF, 16#EE, 16#79, 16#48, 16#1B, 16#2A,
  16#C1, 16#F0, 16#A3, 16#92, 16#05, 16#34, 16#67, 16#56,
  16#78, 16#49, 16#1A, 16#2B, 16#BC, 16#8D, 16#DE, 16#EF,
  16#82, 16#B3, 16#E0, 16#D1, 16#46, 16#77, 16#24, 16#15,
  16#3B, 16#0A, 16#59, 16#68, 16#FF, 16#CE, 16#9D, 16#AC
}).

crc8(Data) ->
  crc8(Data, 16#ff).
crc8(<<Byte:8, Data/binary>>, CheckSum) ->
  crc8(Data, table_crc8(CheckSum bxor Byte));
crc8(_, CheckSum) ->
  CheckSum.
table_crc8(Num) when is_integer(Num) andalso Num > 0 andalso Num < 257 ->
  element(Num + 1, ?CRC8);
table_crc8(_) ->
  0.

-define(CRC16, {
  16#0000, 16#1021, 16#2042, 16#3063, 16#4084, 16#50A5, 16#60C6, 16#70E7,
  16#8108, 16#9129, 16#A14A, 16#B16B, 16#C18C, 16#D1AD, 16#E1CE, 16#F1EF,
  16#1231, 16#0210, 16#3273, 16#2252, 16#52B5, 16#4294, 16#72F7, 16#62D6,
  16#9339, 16#8318, 16#B37B, 16#A35A, 16#D3BD, 16#C39C, 16#F3FF, 16#E3DE,
  16#2462, 16#3443, 16#0420, 16#1401, 16#64E6, 16#74C7, 16#44A4, 16#5485,
  16#A56A, 16#B54B, 16#8528, 16#9509, 16#E5EE, 16#F5CF, 16#C5AC, 16#D58D,
  16#3653, 16#2672, 16#1611, 16#0630, 16#76D7, 16#66F6, 16#5695, 16#46B4,
  16#B75B, 16#A77A, 16#9719, 16#8738, 16#F7DF, 16#E7FE, 16#D79D, 16#C7BC,
  16#48C4, 16#58E5, 16#6886, 16#78A7, 16#0840, 16#1861, 16#2802, 16#3823,
  16#C9CC, 16#D9ED, 16#E98E, 16#F9AF, 16#8948, 16#9969, 16#A90A, 16#B92B,
  16#5AF5, 16#4AD4, 16#7AB7, 16#6A96, 16#1A71, 16#0A50, 16#3A33, 16#2A12,
  16#DBFD, 16#CBDC, 16#FBBF, 16#EB9E, 16#9B79, 16#8B58, 16#BB3B, 16#AB1A,
  16#6CA6, 16#7C87, 16#4CE4, 16#5CC5, 16#2C22, 16#3C03, 16#0C60, 16#1C41,
  16#EDAE, 16#FD8F, 16#CDEC, 16#DDCD, 16#AD2A, 16#BD0B, 16#8D68, 16#9D49,
  16#7E97, 16#6EB6, 16#5ED5, 16#4EF4, 16#3E13, 16#2E32, 16#1E51, 16#0E70,
  16#FF9F, 16#EFBE, 16#DFDD, 16#CFFC, 16#BF1B, 16#AF3A, 16#9F59, 16#8F78,
  16#9188, 16#81A9, 16#B1CA, 16#A1EB, 16#D10C, 16#C12D, 16#F14E, 16#E16F,
  16#1080, 16#00A1, 16#30C2, 16#20E3, 16#5004, 16#4025, 16#7046, 16#6067,
  16#83B9, 16#9398, 16#A3FB, 16#B3DA, 16#C33D, 16#D31C, 16#E37F, 16#F35E,
  16#02B1, 16#1290, 16#22F3, 16#32D2, 16#4235, 16#5214, 16#6277, 16#7256,
  16#B5EA, 16#A5CB, 16#95A8, 16#8589, 16#F56E, 16#E54F, 16#D52C, 16#C50D,
  16#34E2, 16#24C3, 16#14A0, 16#0481, 16#7466, 16#6447, 16#5424, 16#4405,
  16#A7DB, 16#B7FA, 16#8799, 16#97B8, 16#E75F, 16#F77E, 16#C71D, 16#D73C,
  16#26D3, 16#36F2, 16#0691, 16#16B0, 16#6657, 16#7676, 16#4615, 16#5634,
  16#D94C, 16#C96D, 16#F90E, 16#E92F, 16#99C8, 16#89E9, 16#B98A, 16#A9AB,
  16#5844, 16#4865, 16#7806, 16#6827, 16#18C0, 16#08E1, 16#3882, 16#28A3,
  16#CB7D, 16#DB5C, 16#EB3F, 16#FB1E, 16#8BF9, 16#9BD8, 16#ABBB, 16#BB9A,
  16#4A75, 16#5A54, 16#6A37, 16#7A16, 16#0AF1, 16#1AD0, 16#2AB3, 16#3A92,
  16#FD2E, 16#ED0F, 16#DD6C, 16#CD4D, 16#BDAA, 16#AD8B, 16#9DE8, 16#8DC9,
  16#7C26, 16#6C07, 16#5C64, 16#4C45, 16#3CA2, 16#2C83, 16#1CE0, 16#0CC1,
  16#EF1F, 16#FF3E, 16#CF5D, 16#DF7C, 16#AF9B, 16#BFBA, 16#8FD9, 16#9FF8,
  16#6E17, 16#7E36, 16#4E55, 16#5E74, 16#2E93, 16#3EB2, 16#0ED1, 16#1EF0
}).

crc16(Data) ->
  crc16(Data, 16#FFFF).
crc16(<<S:8, R/binary>>, CRC) ->
  C = (CRC bsl 8) bxor crc16Table((CRC bsr 8) bxor S),
  <<C1:16/unsigned-integer>> = <<C:16/unsigned-integer>>,
  crc16(R, C1);
crc16(_, CRC) ->
  CRC.

crc16Table(I) when is_integer(I) andalso I >= 0 andalso I < 256 ->
  element(I + 1, ?CRC16);
crc16Table(_I) ->
  0.