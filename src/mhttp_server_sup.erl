%% Copyright (c) 2020-2021 Exograd SAS.
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

-module(mhttp_server_sup).

-behaviour(c_sup).

-export([start_link/0, start_server/2]).
-export([children/0]).

-spec start_link() -> c_sup:start_ret().
start_link() ->
  c_sup:start_link({local, ?MODULE}, ?MODULE, #{}).

-spec start_server(mhttp:server_id(), mhttp_server:options()) ->
        c_sup:start_child_ret().
start_server(Id, Options) ->
  c_sup:start_child(?MODULE, Id, server_child_spec(Id, Options)).

-spec children() -> c_sup:child_specs().
children() ->
  maps:fold(fun (Id, Options, Acc) ->
                [{Id, server_child_spec(Id, Options)} | Acc]
            end,
            [], application:get_env(mhttp, servers, #{})).

-spec server_child_spec(mhttp:server_id(), mhttp_server:options()) ->
        c_sup:child_spec().
server_child_spec(Id, Options) ->
  #{start => fun mhttp_server:start_link/2,
    start_args => [Id, Options]}.
