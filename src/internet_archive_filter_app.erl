%%%-------------------------------------------------------------------
%%% @doc Internet Archive full-text search agent.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(internet_archive_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL, "https://archive.org/advancedsearch.php?q=").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"internet_archive">>, <<"archive">>,
                                      <<"history">>, <<"books">>, <<"documents">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case internet_archive_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(internet_archive_filter_query_listener),
    catch em_pop_sup:stop_node(internet_archive_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(internet_archive_filter, pop_port,   9444),
    QueryPort = application:get_env(internet_archive_filter, query_port, 9445),
    Seeds     = application:get_env(internet_archive_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(internet_archive_filter),
    catch cowboy:stop_listener(internet_archive_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(internet_archive_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => internet_archive_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(internet_archive_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[internet_archive_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    SearchUrl = lists:concat([?SEARCH_URL, uri_string:quote(Value), "&output=json"]),
    case httpc:request(get, {SearchUrl, []},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_response(Body, Timeout);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

parse_response(JsonData, TimeoutSecs) ->
    try json:decode(JsonData) of
        #{<<"response">> := #{<<"docs">> := Docs}} when is_list(Docs) ->
            StartTime = erlang:system_time(millisecond),
            process_docs(Docs, StartTime, TimeoutSecs * 1000, []);
        _ -> []
    catch
        _:_ -> []
    end.

process_docs([], _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
process_docs([Doc | Rest], Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = case process_doc(Doc) of
                {ok, E} -> [E | Acc];
                skip    -> Acc
            end,
            process_docs(Rest, Start, Timeout, NewAcc)
    end.

process_doc(Doc) ->
    case maps:get(<<"identifier">>, Doc, undefined) of
        Id when is_binary(Id) ->
            Title   = safe_bin(maps:get(<<"title">>,   Doc, <<"">>)),
            Creator = safe_bin(maps:get(<<"creator">>, Doc, <<"">>)),
            Resume  = case Creator of
                <<"">> -> Title;
                C      -> <<Title/binary, " - ", C/binary>>
            end,
            Url = <<"https://archive.org/details/", Id/binary>>,
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => Url,
                    <<"resume">> => Resume
                }
            }};
        _ -> skip
    end.

safe_bin(B) when is_binary(B) -> B;
safe_bin([B | _]) when is_binary(B) -> B;
safe_bin([H | _]) -> list_to_binary(io_lib:format("~p", [H]));
safe_bin(_) -> <<"">>.
