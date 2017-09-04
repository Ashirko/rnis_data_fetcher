-module(rnis_data_fetcher_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Port = application:get_env(rnis_data_fetcher, rnis_connection_port, 4017),
    Labels = application:get_env(rnis_data_fetcher, data_lables, <<"all">>),
    rnis_data_fetcher_sup:start_link(Port,Labels).

stop(_State) ->
    ok.
