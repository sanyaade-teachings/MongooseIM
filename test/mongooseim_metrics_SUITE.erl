-module(mongooseim_metrics_SUITE).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [
     {group, exometer}
    ].

groups() ->
    [
     {exometer, [], [metrics_are_reported]}
    ].

init_per_suite(C) ->
    application:load(exometer_core),
    application:set_env(exometer_core, mongooseim_report_interval, 1000),
    {Port, Socket} = carbon_cache_server:start(),
    PortServer = carbon_cache_server:wait_for_accepting(),
    gen_tcp:controlling_process(Socket, PortServer),
    {ok, _Apps} = application:ensure_all_started(exometer_core),
    [{carbon_port, Port}, {carbon_server, PortServer}, {carbon_socket, Socket} | C].

end_per_suite(C) ->
    CarbonServer = ?config(carbon_server, C),
    erlang:exit(CarbonServer, kill),
    CarbonSocket = ?config(carbon_socket, C),
    gen_tcp:close(CarbonSocket),
    application:stop(exometer_core),
    C.

init_per_group(Group, C) ->
    mongoose_config:set_opts(opts(Group, C)),
    C1 = async_helper:start(C, mongoose_instrument, start_link, []),
    mongoose_system_probes:start(), % required to have some metrics to report
    C1.

end_per_group(_Group, C) ->
    mongoose_system_probes:stop(),
    async_helper:stop_all(C),
    mongoose_config:erase_opts().

init_per_testcase(_TC, C) ->
    ?config(carbon_server, C) ! {subscribe, self()},
    C.

metrics_are_reported(_C) ->
    F = fun() -> get_carbon_metric("mongooseim.global.system_up_time.seconds.value") end,

    %% Both uptime and timestamp should be positive
    Check1 = fun({Value, TS}) when is_integer(Value), is_integer(TS) ->
                     Value > 0 andalso TS > 0;
                (_) -> false
             end,
    {ok, {Value1, TS1}} = mongoose_helper:wait_until(F, Check1, #{name => system_up_time_1}),

    %% Both uptime and timestamp should be growing
    Check2 = fun({Value, TS}) when is_integer(Value), is_integer(TS) ->
                     Value > Value1 andalso TS > TS1;
                (_) -> false
             end,
    mongoose_helper:wait_until(F, Check2, #{name => system_up_time_2}).

get_carbon_metric(Metric) ->
    receive
        {packet, Metric, Value, TS} ->
            ct:log("Received metric ~p with value ~p and timestamp ~p", [Metric, Value, TS]),
            {Value, TS}
    after 0 ->
            no_metric
    end.

opts(Group, Config) ->
    AllGlobal = Group =:= all_metrics_are_global,
    Port = ?config(carbon_port, Config),
    InstrConfig = #{probe_interval => 1,
                    exometer => #{all_metrics_are_global => AllGlobal,
                                  report => get_reporters_cfg(Port)}},
    #{hosts => [<<"localhost">>],
      host_types => [],
      internal_databases => #{},
      instrumentation => config_parser_helper:config([instrumentation], InstrConfig)}.

get_reporters_cfg(Port) ->
    Name = list_to_atom("graphite:127.0.0.1:" ++ integer_to_list(Port)),
    #{Name => #{prefix => "mongooseim",
                connect_timeout => 10000,
                host => "127.0.0.1",
                port => Port,
                interval => 1000}}.
