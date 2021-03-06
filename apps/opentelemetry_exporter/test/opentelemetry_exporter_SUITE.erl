-module(opentelemetry_exporter_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

all() ->
    [{group, functional}, {group, http_protobuf}, {group, grpc}].

groups() ->
    [{functional, [], [span_round_trip, ets_instrumentation_info]},
     {grpc, [], [verify_export]},
     {http_protobuf, [], [verify_export]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(Group, Config) when Group =:= grpc ;
                                   Group =:= http_protobuf ->
    application:ensure_all_started(opentelemetry_exporter),
    [{protocol, Group}| Config];
init_per_group(_, _) ->
    ok.

end_per_group(Group, _Config) when Group =:= grpc ;
                                   Group =:= http_protobuf ->
    application:stop(opentelemetry_exporter),
    ok;
end_per_group(_, _) ->
    ok.

ets_instrumentation_info(_Config) ->
    Tid = ets:new(span_tab, [duplicate_bag, {keypos, #span.instrumentation_library}]),

    TraceId = opentelemetry:generate_trace_id(),
    SpanId = opentelemetry:generate_span_id(),

    ParentSpan =
        #span{name = <<"span-1">>,
              trace_id = TraceId,
              span_id = SpanId,
              kind = ?SPAN_KIND_CLIENT,
              start_time = opentelemetry:timestamp(),
              end_time = opentelemetry:timestamp(),
              events = [#event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-2">>,
                               attributes = [{<<"attr-3">>, <<"value-3">>}]}],
              attributes = [{<<"attr-2">>, <<"value-2">>}],
              instrumentation_library=#instrumentation_library{name = <<"tracer-2">>,
                                                               version = <<"0.0.1">>}},
    true = ets:insert(Tid, ParentSpan),

    ChildSpan = #span{name = <<"span-2">>,
                      trace_id = TraceId,
                      span_id = opentelemetry:generate_span_id(),
                      parent_span_id = SpanId,
                      kind = ?SPAN_KIND_SERVER,
                      start_time = opentelemetry:timestamp(),
                      end_time = opentelemetry:timestamp(),
                      events = [#event{system_time_nano=erlang:system_time(nanosecond),
                                       name = <<"event-1">>,
                                       attributes = [{<<"attr-1">>, <<"value-1">>}]},
                                #event{system_time_nano=erlang:system_time(nanosecond),
                                       name = <<"event-2">>,
                                       attributes = [{<<"attr-3">>, <<"value-3">>}]}],
                      attributes = [{<<"attr-2">>, <<"value-2">>}],
                      instrumentation_library=#instrumentation_library{name = <<"tracer-1">>,
                                                                       version = <<"0.0.1">>}},
    true = ets:insert(Tid, ChildSpan),

    ?assertMatch([#{instrumentation_library :=
                        #{name := <<"tracer-1">>,version := <<"0.0.1">>},
                    spans :=
                        [_]},
                  #{instrumentation_library :=
                        #{name := <<"tracer-2">>,version := <<"0.0.1">>},
                    spans :=
                        [_]}], lists:sort(opentelemetry_exporter:to_proto_by_instrumentation_library(Tid))),

    ok.

span_round_trip(_Config) ->
    TraceId = opentelemetry:generate_trace_id(),
    SpanId = opentelemetry:generate_span_id(),

    Span =
        #span{name = <<"span-1">>,
              trace_id = TraceId,
              span_id = SpanId,
              kind = ?SPAN_KIND_CLIENT,
              tracestate = [{<<"ts-attr-1">>, <<"ts-value-1">>}],
              start_time = opentelemetry:timestamp(),
              end_time = opentelemetry:timestamp(),
              events = [#event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-2">>,
                               attributes = [{<<"attr-3">>, <<"value-3">>}]}],
              attributes = [
                  {<<"attr-2">>, <<"value-2">>},
                  {<<"map-key-1">>, #{<<"map-key-1">> => 123}},
                  {<<"proplist-key-1">>, [{proplistkey1, 456}, {<<"proplist-key-2">>, 9.345}]},
                  {<<"tuple-key-1">>, {a, 123, [456, {1, 2}]}}
                ],
              status = #status{code=?OTEL_STATUS_OK,
                               message = <<"">>},
              instrumentation_library = #instrumentation_library{name = <<"tracer-1">>,
                                                                 version = <<"0.0.1">>}},

    PbSpan = opentelemetry_exporter:to_proto(Span),
    Proto = opentelemetry_exporter_trace_service_pb:encode_msg(PbSpan, span),

    PbSpan1 = maps:filter(fun(_, V) -> V =/= undefined end, PbSpan),
    DecodedProto = opentelemetry_exporter_trace_service_pb:decode_msg(Proto, span),
    ?assertEqual(maps:with([trace_id, span_id], DecodedProto),
                 maps:with([trace_id, span_id], PbSpan1)),

    ok.

%% insert a couple spans and export to locally running otel collector
verify_export(Config) ->
    os:putenv("OTEL_RESOURCE_ATTRIBUTES", "service.name=my-test-service,service.version=98da75ea6d38724743bf42b45565049238d86b3f"),
    Protocol = ?config(protocol, Config),
    Port = case Protocol of
               grpc ->
                   55680;
               http_protobuf ->
                   55681
           end,
    {ok, State} = opentelemetry_exporter:init(#{protocol => Protocol,
                                                endpoints => [{http, "localhost", Port, []}]}),
    Tid = ets:new(span_tab, [duplicate_bag, {keypos, #span.instrumentation_library}]),

    ?assertMatch(ok, opentelemetry_exporter:export(Tid, otel_resource:create([]), State)),

    TraceId = opentelemetry:generate_trace_id(),
    SpanId = opentelemetry:generate_span_id(),

    ParentSpan =
        #span{name = <<"span-1">>,
              trace_id = TraceId,
              span_id = SpanId,
              kind = ?SPAN_KIND_CLIENT,
              start_time = opentelemetry:timestamp(),
              end_time = opentelemetry:timestamp(),
              events = [#event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{system_time_nano=erlang:system_time(nanosecond),
                               name = <<"event-2">>,
                               attributes = [{<<"attr-3">>, <<"value-3">>}]}],
              status = #status{code=?OTEL_STATUS_UNSET,
                               message = <<"hello I'm unset">>},
              attributes = [{<<"attr-2">>, <<"value-2">>}]},
    true = ets:insert(Tid, ParentSpan),

    ChildSpan = #span{name = <<"span-2">>,
                      trace_id = TraceId,
                      span_id = opentelemetry:generate_span_id(),
                      parent_span_id = SpanId,
                      kind = ?SPAN_KIND_SERVER,
                      start_time = opentelemetry:timestamp(),
                      end_time = opentelemetry:timestamp(),
                      events = [#event{system_time_nano=erlang:system_time(nanosecond),
                                       name = <<"event-1">>,
                                       attributes = [{<<"attr-1">>, <<"value-1">>}]},
                                #event{system_time_nano=erlang:system_time(nanosecond),
                                       name = <<"event-2">>,
                                       attributes = [{<<"attr-3">>, <<"value-3">>}]}],
                      status = #status{code=?OTEL_STATUS_ERROR,
                                       message = <<"hello I'm an error">>},
                      attributes = [
                                    {atom_attr, atom_value},
                                    {<<"attr-2">>, <<"value-2">>},
                                    {<<"map-key-1">>, #{<<"map-key-1">> => 123}},
                                    {<<"proplist-key-1">>, [{proplistkey1, 456}, {<<"proplist-key-2">>, 9.345}]},
                                    {<<"list-key-1">>, [listkey1, 123, <<"list-value-3">>]},
                                    {<<"tuple-key-1">>, {a, 123, [456, {1, 2}]}}
                                   ]},
    true = ets:insert(Tid, ChildSpan),

    ?assertMatch([#{instrumentation_library := undefined,
                    spans := [_, _]}], opentelemetry_exporter:to_proto_by_instrumentation_library(Tid)),
    Resource = otel_resource_env_var:get_resource([]),
    ?assertMatch({otel_resource, [{<<"service.name">>,<<"my-test-service">>},
                                  {<<"service.version">>,<<"98da75ea6d38724743bf42b45565049238d86b3f">>}]},
                 Resource),
    ?assertMatch(ok, opentelemetry_exporter:export(Tid, Resource, State)),

    ok.
