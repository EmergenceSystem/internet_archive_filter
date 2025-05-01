-module(internet_archive_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

%% Application callbacks
-export([start/2, stop/1]).

%% Cowboy handler callbacks
-export([init/2, terminate/3]).

-define(SEARCH_URL, "https://archive.org/advancedsearch.php?q=").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(archive_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% Cowboy handler behavior
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = binary_to_list(maps:get(value, Search, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),
            
            EncodedSearch = uri_string:quote(Value),
            SearchUrl = lists:concat([?SEARCH_URL, EncodedSearch, "&output=json"]),
            
            io:format("Search URL: ~s~n", [SearchUrl]),
            case httpc:request(get, {SearchUrl, []}, [{timeout, Timeout * 1000}], [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Body}} ->
                    io:format("Received response from Archive.org. Body length: ~p~n", [byte_size(Body)]),
                    extract_links_from_results(Body, Timeout);
                {error, Reason} ->
                    io:format("Error fetching search results: ~p~n", [Reason]),
                    []
            end;
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

extract_links_from_results(JsonData, TimeoutSecs) ->
    try jsone:decode(JsonData) of
        ParsedJson ->
            case get_path(ParsedJson, [<<"response">>, <<"docs">>]) of
                Docs when is_list(Docs) ->
                    io:format("Found ~p documents~n", [length(Docs)]),
                    StartTime = erlang:system_time(millisecond),
                    Timeout = TimeoutSecs * 1000,
                    process_docs(Docs, StartTime, Timeout, []);
                _ ->
                    io:format("No documents found in response~n"),
                    []
            end
    catch
        error:Reason ->
            io:format("Failed to parse JSON response: ~p~n", [Reason]),
            []
    end.

process_docs([], _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
process_docs([Doc | Rest], StartTime, Timeout, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= Timeout of
        true ->
            io:format("Timeout reached after processing ~p documents~n", [length(Acc)]),
            lists:reverse(Acc);
        false ->
            case process_doc(Doc) of
                {ok, Embryo} ->
                    process_docs(Rest, StartTime, Timeout, [Embryo | Acc]);
                skip ->
                    process_docs(Rest, StartTime, Timeout, Acc)
            end
    end.

process_doc(Doc) ->
    Title = case get_path(Doc, [<<"title">>]) of
        TitleBin when is_binary(TitleBin) -> TitleBin;
        _ -> <<"">>
    end,
    
    Creator = case get_path(Doc, [<<"creator">>]) of
        CreatorBin when is_binary(CreatorBin) -> CreatorBin;
        _ -> <<"">>
    end,
    
    case get_path(Doc, [<<"identifier">>]) of
        IdentifierBin when is_binary(IdentifierBin) ->
            Resume = case Creator of
                <<"">> -> Title;
                _ -> <<Title/binary, " - ", Creator/binary>>
            end,
            
            Url = <<"https://archive.org/details/", IdentifierBin/binary>>,
            
            Embryo = #{
                properties => #{
                    <<"url">> => Url,
                    <<"resume">> => Resume
                }
            },
            {ok, Embryo};
        _ ->
            io:format("Missing identifier in document, skipping~n"),
            skip
    end.

%% Helper function to safely get nested values from a JSON structure
get_path(Json, []) ->
    Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error -> undefined
    end;
get_path(_, _) ->
    undefined.
