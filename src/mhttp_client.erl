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

-module(mhttp_client).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([start_link/1, send_request/2, send_request/3]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, ref/0, connect_options/0, options/0]).

-type name() :: et_gen_server:name().
-type ref() :: et_gen_server:ref().

-type connect_options() :: [gen_tcp:connect_option() | ssl:tls_client_option()].

%% XXX If the client is part of a pool, we need to keep track of the pool id
%% for request logging. Using options to store the pool id is a hack, we need
%% a better way.
-type options() :: #{host => uri:host(),
                     port => uri:port_number(),
                     transport => mhttp:transport(),
                     connection_timeout => timeout(),
                     read_timeout => timeout(),
                     connect_options => connect_options(),
                     header => mhttp:header(),
                     compression => boolean(),
                     log_requests => boolean(),
                     pool => mhttp:pool_id()}.

-type state() :: #{options := options(),
                   transport := mhttp:transport(),
                   socket := inet:socket() | ssl:sslsocket(),
                   parser := mhttp_parser:parser()}.

-spec start_link(options()) -> Result when
    Result :: {ok, pid()} | ignore | {error, term()}.
start_link(Options) ->
  gen_server:start_link(?MODULE, [Options], []).

-spec send_request(ref(), mhttp:request()) ->
        {mhttp:response()} | {error, term()}.
send_request(Ref, Request) ->
  send_request(Ref, Request, #{}).

-spec send_request(ref(), mhttp:request(), mhttp:request_options()) ->
        {ok, mhttp:response()} | {error, term()}.
send_request(Ref, Request, Options) ->
  gen_server:call(Ref, {send_request, Request, Options}, infinity).

-spec init(list()) -> et_gen_server:init_ret(state()).
init([Options]) ->
  logger:update_process_metadata(#{domain => log_domain()}),
  case connect(Options) of
    {ok, State} ->
      {ok, State};
    {error, Reason} ->
      {stop, Reason}
  end.

-spec terminate(et_gen_server:terminate_reason(), state()) -> ok.
terminate(_Reason, #{transport := tcp, socket := Socket}) ->
  ?LOG_DEBUG("closing connection"),
  gen_tcp:close(Socket),
  ok;
terminate(_Reason, #{transport := tls, socket := Socket}) ->
  ?LOG_DEBUG("closing connection"),
  ssl:close(Socket),
  ok.

-spec handle_call(term(), {pid(), et_gen_server:request_id()}, state()) ->
        et_gen_server:handle_call_ret(state()).

handle_call({send_request, Request, Options}, _From, State) ->
  try
    {State2, Response} = do_send_request(State, Request, Options),
    case connection_needs_closing(Response) of
      true ->
        {stop, normal, {ok, Response}, State2};
      false ->
        {reply, {ok, Response}, State2}
    end
  catch
    throw:{error, Reason} ->
      {stop, normal, {error, Reason}, State}
  end;

handle_call(Msg, From, State) ->
  ?LOG_WARNING("unhandled call ~p from ~p", [Msg, From]),
  {reply, unhandled, State}.

-spec handle_cast(term(), state()) -> et_gen_server:handle_cast_ret(state()).

handle_cast(Msg, State) ->
  ?LOG_WARNING("unhandled cast ~p", [Msg]),
  {noreply, State}.

-spec handle_info(term(), state()) -> et_gen_server:handle_info_ret(state()).

handle_info({Event, _}, _State) when Event =:= tcp_closed;
                                     Event =:= ssl_closed ->
  ?LOG_DEBUG("connection closed"),
  exit(normal);

handle_info({tcp, _Socket, Data}, _State) ->
  error({unexpected_data, Data});

handle_info({ssl, _Socket, Data}, _State) ->
  error({unexpected_data, Data});

handle_info(Msg, State) ->
  ?LOG_WARNING("unhandled info ~p", [Msg]),
  {noreply, State}.

-spec options_transport(options()) -> mhttp:transport().
options_transport(Options) ->
  maps:get(transport, Options, tcp).

-spec options_host(options()) -> binary().
options_host(Options) ->
  maps:get(host, Options, <<"localhost">>).

-spec options_port(options()) -> inet:port_number().
options_port(Options) ->
  maps:get(port, Options, 80).

-spec connect(options()) -> {ok, state()} | {error, term()}.
connect(Options) ->
  Transport = options_transport(Options),
  Host = options_host(Options),
  Port = options_port(Options),
  Timeout = maps:get(connection_timeout, Options, 5000),
  RequiredConnectOptions = [{mode, binary}],
  ConnectOptions = RequiredConnectOptions ++
    maps:get(connect_options, Options, []),
  ?LOG_DEBUG("connecting to ~s:~b", [Host, Port]),
  HostString = unicode:characters_to_list(Host),
  Connect = case Transport of
              tcp -> fun gen_tcp:connect/4;
              tls -> fun ssl:connect/4
            end,
  case Connect(HostString, Port, ConnectOptions, Timeout) of
    {ok, Socket} ->
      State = #{options => Options,
                transport => Transport,
                socket => Socket,
                parser => mhttp_parser:new(response)},
      {ok, State};
    {error, Reason} ->
      ?LOG_ERROR("connection failed: ~p", [Reason]),
      {error, Reason}
  end.

-spec do_send_request(state(), mhttp:request(), mhttp:request_options()) ->
        {state(), mhttp:response()}.
do_send_request(State, Request0, _RequestOptions) ->
  StartTime = erlang:system_time(microsecond),
  Request = finalize_request(State, Request0),
  send(State, mhttp_proto:encode_request(Request)),
  set_socket_active(State, false),
  {State2, Response} = read_response(State),
  log_request(Request, Response, StartTime, State),
  set_socket_active(State2, true),
  {State2, Response}.

-spec finalize_request(state(), mhttp:request()) -> mhttp:request().
finalize_request(#{options := Options}, Request) ->
  Funs = [compression_finalization_fun(Options),
          header_finalization_fun(Options),
          host_finalization_fun(Options),
          fun mhttp_request:maybe_add_content_length/1],
  lists:foldl(fun (Fun, R) -> Fun(R) end, Request, Funs).

-spec header_finalization_fun(options()) ->
        fun((mhttp:request()) -> mhttp:request()).
header_finalization_fun(Options) ->
  fun (Request) ->
      Header = maps:get(header, Options, []),
      mhttp_request:prepend_header(Request, Header)
  end.

-spec host_finalization_fun(options()) ->
        fun((mhttp:request()) -> mhttp:request()).
host_finalization_fun(Options) ->
  Transport = options_transport(Options),
  Host = options_host(Options),
  Port = options_port(Options),
  fun (Request) ->
      mhttp_request:ensure_host(Request, Host, Port, Transport)
  end.

-spec compression_finalization_fun(options()) ->
        fun((mhttp:request()) -> mhttp:request()).
compression_finalization_fun(Options) ->
  fun (Request) ->
      Header = mhttp_request:header(Request),
      Header2 = case maps:get(compression, Options, false) of
                 true ->
                   mhttp_header:add(Header, <<"Accept-Encoding">>, <<"gzip">>);
                  false ->
                    Header
                end,
      Request#{header => Header2}
  end.

-spec log_request(mhttp:request(), mhttp:response(), StartTime :: integer(),
                  state()) -> ok.
log_request(Request, Response, StartTime, #{options := Options}) ->
  case maps:get(log_requests, Options, true) of
    true ->
      Pool = maps:get(pool, Options, undefined),
      mhttp_log:log_outgoing_request(Request, Response, StartTime, Pool,
                                     log_domain()),
      ok;
    false ->
      ok
  end.

-spec read_response(state()) -> {state(), mhttp:response()}.
read_response(State = #{parser := Parser}) ->
  Data = recv(State, 0),
  case mhttp_parser:parse(Parser, Data) of
    {ok, Response, Parser2} ->
      {State#{parser => Parser2}, Response};
    {more, Parser2} ->
      read_response(State#{parser => Parser2});
    {error, Reason} ->
      throw({error, {invalid_data, Reason}})
  end.

-spec set_socket_active(state(), boolean() | pos_integer()) -> ok.
set_socket_active(#{transport := Transport, socket := Socket}, Active) ->
  Setopts = case Transport of
              tcp -> fun inet:setopts/2;
              tls -> fun ssl:setopts/2
            end,
  case Setopts(Socket, [{active, Active}]) of
    ok ->
      ok;
    {error, closed} ->
      throw({error, connection_closed});
    {error, Reason} ->
      throw({error, {setopts, Reason}})
  end.

-spec send(state(), iodata()) -> ok.
send(#{transport := Transport, socket := Socket}, Data) ->
  Send = case Transport of
          tcp -> fun gen_tcp:send/2;
          tls -> fun ssl:send/2
        end,
  case Send(Socket, Data) of
    ok ->
      ok;
    {error, closed} ->
      throw({error, connection_closed});
    {error, timeout} ->
      throw({error, write_timeout});
    {error, Reason} ->
      throw({error, {send, Reason}})
  end.

-spec recv(state(), non_neg_integer()) -> binary().
recv(#{options := Options, transport := Transport, socket := Socket}, N) ->
  Recv = case Transport of
          tcp -> fun gen_tcp:recv/3;
          tls -> fun ssl:recv/3
        end,
  Timeout = maps:get(read_timeout, Options, 30_000),
  case Recv(Socket, N, Timeout) of
    {ok, Data} ->
      Data;
    {error, closed} ->
      throw({error, connection_closed});
    {error, timeout} ->
      throw({error, read_timeout});
    {error, Reason} ->
      throw({error, {recv, Reason}})
  end.

-spec connection_needs_closing(mhttp:response()) -> boolean().
connection_needs_closing(Response) ->
  mhttp_header:has_connection_close(mhttp_response:header(Response)).

-spec log_domain() -> [atom()].
log_domain() ->
  [mhttp, client].
