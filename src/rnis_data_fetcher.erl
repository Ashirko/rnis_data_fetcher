-module(rnis_data_fetcher).

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

-record(state, {port, lsocket, rnis_pid}).

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

terminate(Reason, #state{rnis_pid = RnisPid, lsocket = LSocket}) ->
  lager:info("terminate rnis_data_fetcher with reason: ~p" , [Reason]),
  gen_tcp:close(LSocket),
  RnisPid ! stop,
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

connect_to_rnis(Lables)->
  RnisHosts = application:get_env(rnis_data_fetcher, rnis_hosts, []),
  lager:info("rnis_hosts: ~p", [RnisHosts]),
  Port = application:get_env(rnis_data_fetcher, rnis_connection_port, 9845),
  lager:info("port: ~p", [Port]),
  case create_rnis_service(RnisHosts, Port) of
    {ok,Pid}->
      lager:info("pid of created service: ~p", [Pid]),
      case connect_rnis_socket(Pid, Port) of
        ok->
          lager:info("connected to rnis socket"),
          Pid ! {cmd, {auth, subscribe, Lables}, self()},
          {ok,#state{port = Port, rnis_pid = Pid}};
        Error->
          lager:error("create_socket_error: ~p", [Error]),
          {error, create_socket_error}
      end;
    ConnError->
      lager:error("connection_error: ~p", [ConnError]),
      {error, connection_error}
  end.

create_rnis_service([], _)->
  error;
create_rnis_service([Node|T], Port)->
  lager:info("try to connect to ~p", [Node]),
  Connection = #plain_connection{parser = rnis_data_egts_parser},
  case rpc:call(Node,rnis_data_socket_server,start_link,[Connection]) of
    {ok,Pid}->
      {ok,{Pid,Node}};
    Error->
      lager:info("connectioin error to ~p : ~p", [Node, Error]),
      create_rnis_service(T, Port)
  end.

connect_rnis_socket({Pid,Node}, Port)->
  case rpc:call(Node, gen_tcp, connect, [node(), Port, [binary]]) of
    {ok,Socket}->
      rpc:call(Node, rnis_data_socket_server, set_socket, [Pid, Socket]);
    Error->
      Error
  end.