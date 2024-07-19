-module(carbon_cache_server).

-export([start/0]).
-export([server/2]).
-export([wait_for_accepting/0]).

start() ->
    case gen_tcp:listen(0, [{active, false}, {packet, line}]) of
        {ok, ListenSock} ->
            spawn(?MODULE, server, [ListenSock, self()]),
            {ok, Port} = inet:port(ListenSock),
            {Port, ListenSock};
        {error, Reason} ->
            {error, Reason}
    end.

server(LS, Parent) ->
    Parent ! {accepting, self()},
    server(LS).

server(LS) ->
    case gen_tcp:accept(LS) of
        {ok, S} ->
            loop(S, []),
            server(LS);
        Other ->
            ct:log("accept returned ~w - goodbye!~n", [Other])
    end.

loop(S, Pids) ->
    inet:setopts(S, [{active, once}]),
    receive
        {subscribe, Pid} ->
            loop(S, [Pid | Pids]);
        {tcp, S, Data} ->
            %% Printout disabled because it is very verbose
            %% ct:log("Carbon cache server received packet: ~p", [Data]),
            [Metric, ValueStr, TimeStamp] = string:tokens(Data, " \n"),
            Msg = {packet, Metric, list_to_integer(ValueStr), list_to_integer(TimeStamp)},
            [Pid ! Msg || Pid <- Pids],
            loop(S, Pids);
        {tcp_closed, S} ->
            ct:log("Socket ~w closed [~w]~n", [S, self()])
    end.

wait_for_accepting() ->
    receive
        {accepting, Pid} ->
            Pid
    end.
