%% @doc @todo Add description to rnis_data_egts_fetcher_logger.

-module(rnis_data_egts_fetcher_logger).
-behaviour(gen_server).

%API
-export([start_link/0,stop/0,add_buf/1]).

%gen_server callback
-export([init/1,terminate/2,handle_cast/2,handle_info/2,handle_call/3,code_change/3]).

%internal function
-export([to_file_local/2,to_file_global/2]).


-record(state, {timer_ref,buf}).
-define(FILENAME,"log/rnis_data_egts_fetcher_log.txt").


%% ====================================================================
%% API functions
%% ====================================================================

start_link()->
	gen_server:start_link({local,?MODULE}, ?MODULE, [],[]).
stop()->
	gen_server:call(?MODULE, stop).
add_buf(Data)->
	gen_server:cast(?MODULE,{add_buf,Data}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([])->
	TimePeriod = application:get_env(rnis_data_fetcher, time_period_log),
	%TimePeriod = 60000,
	{ok,Ref} = timer:send_interval(TimePeriod, write_log),
	{ok,#state{timer_ref=Ref,buf=0}}.

handle_cast({add_buf,Data},#state{buf=Buf}=State)->
	{noreply,State#state{buf=Buf+Data}};
handle_cast(_Request,State)->
	{stop, unknown_message, State}.

handle_info(write_log,#state{buf=Buf}=State)->	
	<<Year:4/binary,Month:2/binary,Day:2/binary,H:2/binary,M:2/binary,S:2/binary>> = zont_time_util:get_formated_time(),
	Time = <<Year/binary,"-",Month/binary,"-",Day/binary," ",H/binary,":",M/binary,":",S/binary>>,		
	to_file_global(Buf,Time),
	{noreply,State#state{buf=0}};
handle_info(_Info,State)->
	{stop, unknown_message, State}.

handle_call(_Request,_From,State)->
	{stop, unknown_message, State}.

terminate(_Reason,#state{timer_ref=Ref})-> 
	timer:cancel(Ref),
	ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

to_file_local(Buf,Time)->
	{ok,[[HomeDir]]} = init:get_argument(home),	
	BufBinary=integer_to_binary(Buf),
	Path=HomeDir ++"/"++ ?FILENAME,
	Data= <<Time/binary," : ", BufBinary/binary," bytes\n" >>,
	file:write_file(Path,Data,[append]).

to_file_global(Buf,Time)->
	Nodes=riak_core_node_watcher:nodes(zont_core),
	rpc:multicall(Nodes,?MODULE,to_file_local, [Buf,Time]).
