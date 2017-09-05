-module(rnis_data_fetcher_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("../../rnis_data/include/rnis_data.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    RestartStrategy = one_for_all,
    MaxRestarts = 5,
    MaxSecondsBetweenRestarts = 10,
    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
    DataFetcher = {
        rnis_data_egts_fetcher,
        {rnis_data_egts_fetcher, start_link, []},
        permanent, 5000, worker, [rnis_data_egts_fetcher]},
    {ok, {SupFlags, [DataFetcher]}}.

