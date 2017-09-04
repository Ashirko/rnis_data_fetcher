-module(  rnis_data_fetcher).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).


-include_lib("../../rnis_data/include/rnis_data.hrl").

-record(state, {port, socket}).

%% Callbacks
start_link(Lables) ->
  lager:info("start rnis_data_fetcher on node ~p", [node()]),
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Lables], []).

init([Labels]) ->
  {ok, State} = connect_to_rnis(Labels),
  {ok, State}.

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(Reason, #state{socket = LSocket}) ->
  lager:info("terminate rnis_data_fetcher with reason: ~p" , [Reason]),
  gen_tcp:close(LSocket),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

connect_to_rnis(Lables)->
  RnisHosts = application:get_env(rnis_data_fetcher, rnis_hosts, []),
  lager:info("rnis_hosts: ~p", [RnisHosts]),
  Port = application:get_env(rnis_data_fetcher, rnis_connection_port, 4017),
  lager:info("port: ~p", [Port]),
  case connect_egts_parser(RnisHosts, Port) of
    {ok,Socket}->
      lager:info("created socket: ~p", [Socket]),
      case subscribe_data(Socket, Lables) of
        ok->
          lager:info("connected to rnis socket"),
          {ok,#state{port = Port, socket = Socket}};
        Error->
          lager:error("create_socket_error: ~p", [Error]),
          {error, create_socket_error}
      end;
    ConnError->
      lager:error("connect_egts_parser error: ~p", [ConnError]),
      {error, connection_error}
  end.

connect_egts_parser([], _)->
  error;
connect_egts_parser([Node|T], Port)->
  lager:info("try to connect to ~p", [Node]),
  case gen_tcp:connect(Node, Port, [binary, {active,true}]) of
    {ok,Socket}->
      {ok,Socket};
    Error->
      lager:info("connectioin error to ~p : ~p", [Node, Error]),
      connect_egts_parser(T, Port)
  end.

subscribe_data(Socket, Lables) when is_binary(Lables)->
  Msg = <<"RNIS-subscribe-@", Lables/binary, "@">>,
  lager:info("subscribe msg: ~p", [Msg]),
  gen_tcp:send(Socket, Msg).
