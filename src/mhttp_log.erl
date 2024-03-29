%% Copyright (c) 2020-2022 Exograd SAS.
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
%% SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
%% IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(mhttp_log).

-export([log_incoming_request/5, log_outgoing_request/5]).

-spec log_incoming_request(mhttp:request(), mhttp:response(),
                           mhttp:handler_context(), Server, Domain) -> ok when
    Server :: mhttp:server_id() | undefined,
    Domain :: [atom()].
log_incoming_request(Request, Response, Context, Server, Domain) ->
  StartTime = maps:get(start_time, Context),
  RequestTime = erlang:monotonic_time(microsecond) - StartTime,
  Address = maps:get(real_client_address, Context),
  RequestId = maps:get(request_id, Context),
  Data = #{address => inet:ntoa(Address),
           request_id => RequestId},
  Data2 = case Server of
            undefined -> Data;
            _ -> Data#{server => Server}
          end,
  Event = [mhttp, request, in],
  log_request(Request, Response, RequestTime, Domain, Event, Data2).

-spec log_outgoing_request(mhttp:request(), mhttp:response(), integer(),
                           Pool, Domain) -> ok when
    Pool :: mhttp:pool_id() | undefined,
    Domain :: [atom()].
log_outgoing_request(Request, Response, RequestTime, Pool, Domain) ->
  Data = case Pool of
           undefined -> #{};
           _ -> #{pool => Pool}
         end,
  Event = [mhttp, request, out],
  log_request(Request, Response, RequestTime, Domain, Event, Data).

-spec log_request(mhttp:request(), mhttp:response(), integer(), Domain, Event,
                  ExtraData) -> ok when
    Domain :: [atom()],
    Event :: [atom()],
    ExtraData :: #{atom() := term()}.
log_request(Request, Response, RequestTime, Domain, Event, ExtraData) ->
  MethodString = mhttp_proto:encode_method(mhttp_request:method(Request)),
  Target = mhttp_request:target_string(Request),
  Status = mhttp_response:status(Response),
  Internal = mhttp_response:internal(Response),
  BodySize = case maps:find(original_body_size, Internal) of
               {ok, Size} ->
                 Size;
               error ->
                 iolist_size(mhttp_response:body(Response))
             end,
  Data = #{domain => Domain,
           event => Event,
           status => Status,
           request_time => RequestTime},
  logger:info("~s ~s ~b ~ts ~ts",
              [MethodString, Target, Status,
               format_data_size(BodySize),
               format_request_time(RequestTime)],
              maps:merge(Data, ExtraData)),
  ok.

-spec format_request_time(Microseconds :: non_neg_integer()) -> binary().
format_request_time(Microseconds) when Microseconds < 1_000 ->
  <<(integer_to_binary(Microseconds))/binary, "µs"/utf8>>;
format_request_time(Microseconds) when Microseconds > 1_000_000 ->
  <<(float_to_binary(Microseconds / 1.0e6, [{decimals, 1}]))/binary, "s">>;
format_request_time(Microseconds) ->
  <<(float_to_binary(Microseconds / 1.0e3, [{decimals, 1}]))/binary, "ms">>.

-spec format_data_size(Bytes :: non_neg_integer()) -> binary().
format_data_size(Bytes) when Bytes < 1_000 ->
  <<(integer_to_binary(Bytes))/binary, "B"/utf8>>;
format_data_size(Bytes) when Bytes < 1_000_000 ->
  <<(float_to_binary(Bytes / 1.0e3, [{decimals, 1}]))/binary, "kB">>;
format_data_size(Bytes) when Bytes < 1_000_000_000 ->
  <<(float_to_binary(Bytes / 1.0e6, [{decimals, 1}]))/binary, "MB">>;
format_data_size(Bytes) ->
  <<(float_to_binary(Bytes / 1.0e9, [{decimals, 1}]))/binary, "GB">>.
