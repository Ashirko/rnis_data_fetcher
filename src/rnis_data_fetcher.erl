-module(  rnis_data_fetcher).

-behaviour(gen_server).

%% API
-export([start_link/2]).

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
start_link(SupPid, Lables) ->
  lager:info("start rnis_data_fetcher on node ~p", [node()]),
  gen_server:start_link({local, ?MODULE}, ?MODULE, [SupPid, Lables], []).

init([SupPid, Labels]) ->
  {ok, State} = connect_to_rnis(Labels),
  lager:info("connected_to_rnis: ~p" , [State]),
  redirect_to_parser(SupPid, State),
  lager:info("rnis_data_fetcher started"),
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
          lager:info("subscribed to data"),
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

redirect_to_parser(SupPid, #state{socket = Socket})->
  lager:info("start redirect_to_parser: ~p", [SupPid]),
%%  SupChildren = supervisor:which_children(SupPid),
%%  lager:info("SupChildren: ~p", [SupChildren]),
%%  {_, SocketSupPid, _, _}
%%    = lists:keyfind(rnis_data_socket_sup, 1, SupChildren),

  {ok, Pid} = rnis_data_socket_sup:start_socket(
    rpc_socket_sup,
    #plain_connection{parser = rnis_data_egts_parser}
  ),
  lager:info("Pid of parser: ~p", [Pid]),
  ok = gen_tcp:controlling_process(Socket, Pid),
  ok = rnis_data_socket_server:set_socket(Pid, Socket).

