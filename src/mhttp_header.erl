%% Copyright (c) 2020 Nicolas Martyanoff <khaelin@gmail.com>.
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
%% REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
%% AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
%% INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
%% LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
%% OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
%% PERFORMANCE OF THIS SOFTWARE.

-module(mhttp_header).

-export([new/0,
         append/2,
         contains/2, find/2, find_all/2, find_all_concat/2, find_all_split/2,
         find_token_list/2,
         add/3, add_field/2, add_if_missing/3, remove/2,
         content_length/1,
         transfer_encoding/1, content_encoding/1,
         has_connection_close/1,
         body/1]).

-spec new() -> mhttp:header().
new() ->
  [].

-spec append(mhttp:header(), mhttp:header()) -> mhttp:header().
append(Header1, Header2) ->
  Header1 ++ Header2.

-spec contains(mhttp:header(), mhttp:header_name()) -> boolean().
contains(Header, Name) ->
  case find(Header, Name) of
    {ok, _} ->
      true;
    error ->
      false
  end.

-spec find(mhttp:header(), mhttp:header_name()) ->
        {ok, mhttp:header_value()} | error.
find(Header, Name) ->
  Pred = fun ({FieldName, _}) ->
             mhttp:header_name_equal(FieldName, Name)
         end,
  case lists:search(Pred, Header) of
    {value, {_, Value}} ->
      {ok, Value};
    false ->
      error
  end.

-spec find_all(mhttp:header(), mhttp:header_name()) -> [mhttp:header_value()].
find_all(Header, Name) ->
  lists:filtermap(fun ({FieldName, Value}) ->
                      case mhttp:header_name_equal(FieldName, Name) of
                        true ->
                          {true, Value};
                        false ->
                          false
                      end
                  end, Header).

-spec find_all_concat(mhttp:header(), mhttp:header_name()) ->
        mhttp:header_value().
find_all_concat(Header, Name) ->
  Values = find_all(Header, Name),
  Data = lists:join(<<", ">>, Values),
  iolist_to_binary(Data).

-spec find_all_split(mhttp:header(), mhttp:header_name()) ->
        [mhttp:header_value()].
find_all_split(Header, Name) ->
  case find_all_concat(Header, Name) of
    <<>> ->
      [];
    Value ->
      Values = binary:split(Value, <<",">>, [global]),
      lists:map(fun (V) -> string:trim(V, both, " \t") end, Values)
  end.

-spec find_token_list(mhttp:header(), mhttp:header_name()) -> [binary()].
find_token_list(Header, Name) ->
  Values = mhttp_header:find_all_split(Header, Name),
  lists:map(fun string:lowercase/1, Values).

-spec add(mhttp:header(), mhttp:header_name(), mhttp:header_value()) ->
        mhttp:header().
add(Header, Name, Value) ->
  [{Name, Value} | Header].

-spec add_field(mhttp:header(), mhttp:header_field()) -> mhttp:header().
add_field(Header, Field) ->
  [Field | Header].

-spec add_if_missing(mhttp:header(),
                     mhttp:header_name(), mhttp:header_value()) ->
        mhttp:header().
add_if_missing(Header, Name, Value) ->
  case contains(Header, Name) of
    true ->
      Header;
    false ->
      add(Header, Name, Value)
  end.

-spec remove(mhttp:header(), mhttp:header_name() | [mhttp:header_name()]) ->
        mhttp:header().
remove(Header, Names) when is_list(Names) ->
  lists:foldl(fun (Name, H) -> remove(H, Name) end,
              Header, Names);
remove(Header, Name) ->
  lists:filter(fun ({N, _}) ->
                   not mhttp:header_name_equal(N, Name)
               end, Header).

-spec content_length(mhttp:header()) -> {ok, pos_integer()} | {error, term()}.
content_length(Header) ->
  case mhttp_header:find_all(Header, <<"Content-Length">>) of
    [] ->
      {error, not_found};
    [Value] ->
      try
        {ok, binary_to_integer(Value)}
      catch
        error:badarg ->
          {error, invalid_content_length}
      end;
    _Values ->
      {error, multiple_content_length_fields}
  end.

-spec transfer_encoding(mhttp:header()) -> Codings :: [binary()].
transfer_encoding(Header) ->
  find_token_list(Header, <<"Transfer-Encoding">>).

-spec content_encoding(mhttp:header()) -> Codings :: [binary()].
content_encoding(Header) ->
  find_token_list(Header, <<"Content-Encoding">>).

-spec chunked_transfer_coding(mhttp:header()) ->
        intermediary | last | not_found.
chunked_transfer_coding(Header) ->
  Fun = fun F([]) -> not_found;
            F([<<"chunked">>]) -> last;
            F([<<"chunked">> | _]) -> intermediary;
            F([_ | T]) -> F(T)
        end,
  Fun(transfer_encoding(Header)).

-spec has_connection_close(mhttp:header()) -> boolean().
has_connection_close(Header) ->
  Values0 = mhttp_header:find_all_split(Header, <<"Connection">>),
  Values = lists:map(fun string:lowercase/1, Values0),
  lists:member(<<"close">>, Values).

-spec body(mhttp:header()) -> {ok, Body} | {error, term()} when
    Body :: {fixed, pos_integer()} | chunked | none.
body(Header) ->
  %% See RFC 7230 3.3.3.
  case chunked_transfer_coding(Header) of
    last ->
      {ok, chunked};
    intermediary ->
      %% "If a Transfer-Encoding header field is present in a request and the
      %% chunked transfer coding is not the final encoding, the message body
      %% length cannot be determined reliably; the server MUST respond with
      %% the 400 (Bad Request) status code and then close the connection."
      {error, invalid_intermediary_chunked_encoding};
    not_found ->
      case mhttp_header:content_length(Header) of
        {ok, Length} ->
          {ok, {fixed, Length}};
        {error, not_found} ->
          {ok, none};
        {error, Reason} ->
          {error, Reason}
      end
  end.
