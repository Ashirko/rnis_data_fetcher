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
        {rnis_data_fetcher, start_link, [Labels, self()]},
        permanent, 5000, supervisor, [rnis_data_fetcher]},
    ParserSup = {
%%        rnis_data_parser_sup,
%%%%        {rnis_data_parser_sup, start_link, [nn, tcp, []]},
%%        {rnis_data_parser_sup, start_link, [nn, tcp, [{port, Port}]]},
%%        permanent, 5000, supervisor, [rnis_data_socket_sup]},
        rnis_data_socket_sup,
%%        {rnis_data_parser_sup, start_link, [nn, tcp, []]},
        {rnis_data_socket_sup, start_link, [rpc_socket_sup]},
        permanent, 5000, supervisor, [rnis_data_socket_sup]},

    {ok, {SupFlags, [ParserSup, DataFetcher]}}.
%%    {ok, {SupFlags, [DataFetcher]}}.

