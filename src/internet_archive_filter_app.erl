%%%-------------------------------------------------------------------
%%% @doc Internet Archive full-text search filter.
%%%
%%% Queries the Archive.org advanced search API and returns
%%% matching documents as embryo maps.
%%% @end
%%%-------------------------------------------------------------------
-module(internet_archive_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

-define(SEARCH_URL, "https://archive.org/advancedsearch.php?q=").

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(archive_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(archive_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

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
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
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

%%--------------------------------------------------------------------
%% Response parsing
%%--------------------------------------------------------------------

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

%% Archive.org may return title/creator as a list — take the first element.
safe_bin(B) when is_binary(B) -> B;
safe_bin([B | _]) when is_binary(B) -> B;
safe_bin([H | _]) -> list_to_binary(io_lib:format("~p", [H]));
safe_bin(_) -> <<"">>.
