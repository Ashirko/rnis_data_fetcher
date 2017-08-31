-module(rnis_data_fetcher_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("../../rnis_data/include/rnis_data.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Port, Labels) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Port, Labels]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Port, Labels]) ->
    RestartStrategy = one_for_all,
    MaxRestarts = 5,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
    DataFetcher = {
        rnis_data_fetcher,
        {rnis_data_fetcher, start_link, [Labels]},
        permanent, 5000, supervisor, [rnis_data_socket_sup]},
    ParserSup = {
        rnis_data_parser_sup,
        {rnis_data_parser_sup, start_link, [rnis_data_egts_parser, tcp, [{port, Port}]]},
        permanent, 5000, supervisor, [rnis_data_socket_sup]},

    {ok, {SupFlags, [DataFetcher, ParserSup]}}.

