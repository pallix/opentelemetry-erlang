-module(opentelemetry_exporter_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/ot_span.hrl").

all() ->
    [{group, functional}, {group, with_grpc}].

groups() ->
    [{functional, [], [span_round_trip, ets_instrumentation_info]},
     {with_grpc, [], [verify_export]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(with_grpc, Config) ->
    application:ensure_all_started(opentelemetry_exporter),
    Config;
init_per_group(_, _) ->
    ok.

end_per_group(with_grpc, _Config) ->
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
              start_time = wts:timestamp(),
              end_time = wts:timestamp(),
              events = [#event{time=wts:timestamp(),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{time=wts:timestamp(),
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
                      start_time = wts:timestamp(),
                      end_time = wts:timestamp(),
                      events = [#event{time=wts:timestamp(),
                                       name = <<"event-1">>,
                                       attributes = [{<<"attr-1">>, <<"value-1">>}]},
                                #event{time=wts:timestamp(),
                                       name = <<"event-2">>,
                                       attributes = [{<<"attr-3">>, <<"value-3">>}]}],
                      attributes = [{<<"attr-2">>, <<"value-2">>}],
                      instrumentation_library=#instrumentation_library{name = <<"tracer-1">>,
                                                                       version = <<"0.0.1">>}},
    true = ets:insert(Tid, ChildSpan),

    ?assertMatch([#{instrumentation_library :=
                        #{name := <<"tracer-2">>,version := <<"0.0.1">>},
                    spans :=
                        [_]},
                  #{instrumentation_library :=
                        #{name := <<"tracer-1">>,version := <<"0.0.1">>},
                    spans :=
                        [_]}], opentelemetry_exporter:to_proto_by_instrumentation_library(Tid)),

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
              start_time = wts:timestamp(),
              end_time = wts:timestamp(),
              events = [#event{time=wts:timestamp(),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{time=wts:timestamp(),
                               name = <<"event-2">>,
                               attributes = [{<<"attr-3">>, <<"value-3">>}]}],
              attributes = [{<<"attr-2">>, <<"value-2">>}],
              status = #status{code='Ok',
                               message = <<"">>},
              instrumentation_library = #instrumentation_library{name = <<"tracer-1">>,
                                                                 version = <<"0.0.1">>}},

    PbSpan = opentelemetry_exporter:to_proto(Span),
    Proto = trace_service_pb:encode_msg(PbSpan, span),

    PbSpan1 = maps:filter(fun(_, V) -> V =/= undefined end, PbSpan),
    DecodedProto = trace_service_pb:decode_msg(Proto, span),
    ?assertEqual(maps:with([trace_id, span_id], DecodedProto),
                 maps:with([trace_id, span_id], PbSpan1)),

    ok.

%% insert a couple spans and export to locally running otel collector
verify_export(_Config) ->
    {ok, State} = opentelemetry_exporter:init(#{}),
    Tid = ets:new(span_tab, [duplicate_bag, {keypos, #span.instrumentation_library}]),

    ?assertMatch(ok, opentelemetry_exporter:export(Tid, ot_resource:create([]), State)),

    TraceId = opentelemetry:generate_trace_id(),
    SpanId = opentelemetry:generate_span_id(),

    ParentSpan =
        #span{name = <<"span-1">>,
              trace_id = TraceId,
              span_id = SpanId,
              kind = ?SPAN_KIND_CLIENT,
              start_time = wts:timestamp(),
              end_time = wts:timestamp(),
              events = [#event{time=wts:timestamp(),
                               name = <<"event-1">>,
                               attributes = [{<<"attr-1">>, <<"value-1">>}]},
                        #event{time=wts:timestamp(),
                               name = <<"event-2">>,
                               attributes = [{<<"attr-3">>, <<"value-3">>}]}],
              attributes = [{<<"attr-2">>, <<"value-2">>}]},
    true = ets:insert(Tid, ParentSpan),

    ChildSpan = #span{name = <<"span-2">>,
                      trace_id = TraceId,
                      span_id = opentelemetry:generate_span_id(),
                      parent_span_id = SpanId,
                      kind = ?SPAN_KIND_SERVER,
                      start_time = wts:timestamp(),
                      end_time = wts:timestamp(),
                      events = [#event{time=wts:timestamp(),
                                       name = <<"event-1">>,
                                       attributes = [{<<"attr-1">>, <<"value-1">>}]},
                                #event{time=wts:timestamp(),
                                       name = <<"event-2">>,
                                       attributes = [{<<"attr-3">>, <<"value-3">>}]}],
                      attributes = [{<<"attr-2">>, <<"value-2">>}]},
    true = ets:insert(Tid, ChildSpan),

    ?assertMatch([#{instrumentation_library := undefined,
                    spans := [_, _]}], opentelemetry_exporter:to_proto_by_instrumentation_library(Tid)),

    ?assertMatch(ok, opentelemetry_exporter:export(Tid, ot_resource:create([]), State)),

    ok.
