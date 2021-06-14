%% Copyright (c) 2020-2021 Nicolas Martyanoff <khaelin@gmail.com>.
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

-module(mhttp_pool).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([process_name/1, start_link/2, stop/1,
         send_request/2, send_request/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, ref/0, options/0]).

-type name() :: et_gen_server:name().
-type ref() :: et_gen_server:ref().

-type options() ::
        #{client_options => mhttp_client:options(),
          max_connections_per_key => pos_integer(),
          use_netrc => boolean()}.

-type state() ::
        #{id := mhttp:pool_id(),
          options := options(),
          clients_by_key := ets:tid(),
          clients_by_pid := ets:tid()}.

-spec process_name(mhttp:pool_id()) -> atom().
process_name(Id) ->
  Name = <<"mhttp_pool_", (atom_to_binary(Id))/binary>>,
  binary_to_atom(Name).

-spec start_link(mhttp:pool_id(), options()) -> Result when
    Result :: {ok, pid()} | ignore | {error, term()}.
start_link(Id, Options) ->
  Name = process_name(Id),
  gen_server:start_link({local, Name}, ?MODULE, [Id, Options], []).

-spec stop(mhttp:pool_id()) -> ok.
stop(Id) ->
  Name = process_name(Id),
  gen_server:stop(Name).

-spec send_request(ref(), mhttp:request()) ->
        {ok, mhttp:response() | {upgraded, mhttp:response(), pid()}} |
        {error, term()}.
send_request(Ref, Request) ->
  send_request(Ref, Request, #{}).

-spec send_request(ref(), mhttp:request(), mhttp:request_options()) ->
        {ok, mhttp:response() | {upgraded, mhttp:response(), pid()}} |
        {error, term()}.
send_request(Ref, Request, Options) ->
  gen_server:call(Ref, {send_request, Request, Options}, infinity).

-spec init(list()) -> et_gen_server:init_ret(state()).
init([Id, Options]) ->
  logger:update_process_metadata(#{domain => [mhttp, pool, Id]}),
  process_flag(trap_exit, true),
  ClientsByKey = ets:new(ets_table_name(<<"clients_by_key">>, Id), [bag]),
  ClientsByPid = ets:new(ets_table_name(<<"clients_by_pid">>, Id), [set]),
  State = #{id => Id,
            options => Options,
            clients_by_key => ClientsByKey,
            clients_by_pid => ClientsByPid},
  {ok, State}.

-spec ets_table_name(Table :: binary(), mhttp:pool_id()) -> atom().
ets_table_name(Table, Id) ->
  Bin = <<"mhttp_pool_", (atom_to_binary(Id))/binary, "__", Table/binary>>,
  binary_to_atom(Bin).

-spec handle_call(term(), {pid(), et_gen_server:request_id()}, state()) ->
        et_gen_server:handle_call_ret(state()).
handle_call({send_request, Request0, Options}, _From, State) ->
  try
    {Result, State2} = handle_send_request(Request0, Options, State),
    {reply, {ok, Result}, State2}
  catch
    throw:{error, Reason} ->
      {reply, {error, Reason}, State};
    exit:{Reason, _MFA} ->
      %% TODO
      {reply, {error, {client_error, Reason}}, State}
  end;
handle_call(Msg, From, State) ->
  ?LOG_WARNING("unhandled call ~p from ~p", [Msg, From]),
  {reply, unhandled, State}.

-spec handle_cast(term(), state()) -> et_gen_server:handle_cast_ret(state()).
handle_cast(Msg, State) ->
  ?LOG_WARNING("unhandled cast ~p", [Msg]),
  {noreply, State}.

-spec handle_info(term(), state()) -> et_gen_server:handle_info_ret(state()).
handle_info({'EXIT', Pid, normal}, State) ->
  delete_client(State, Pid),
  {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
  ?LOG_DEBUG("client ~p exited:~n~tp", [Pid, Reason]),
  delete_client(State, Pid),
  {noreply, State};
handle_info(Msg, State) ->
  ?LOG_WARNING("unhandled info ~p", [Msg]),
  {noreply, State}.

-spec handle_send_request(mhttp:request(), mhttp:request_options(), state()) ->
        {mhttp:response_result(), state()}.
handle_send_request(Request, Options, State) ->
  case mhttp_request:canonicalize_target(Request) of
    {ok, CanonicRequest} ->
      MaxNbRedirections = maps:get(max_nb_redirections, Options, 5),
      send_request_1(CanonicRequest, Options, MaxNbRedirections, State);
    {error, Reason} ->
      throw({error, Reason})
  end.

-spec send_request_1(mhttp:request(), mhttp:request_options(),
                      NbRedirectionsLeft :: non_neg_integer(), state()) ->
        {mhttp:response_result(), state()}.
send_request_1(_Request, _Options, 0, _State) ->
  throw({error, too_many_redirections});
send_request_1(CanonicRequest, Options, NbRedirectionsLeft, State) ->
  %% The actual request sent is derived from the canonic request. We only keep
  %% the path, query and fragment. We still need the canonic request to
  %% compute a potential redirection target since the URI reference resolution
  %% process requires the original scheme.
  NetrcEntry = netrc_entry(CanonicRequest, State),
  {Target, Key} = request_target_and_key(CanonicRequest, NetrcEntry),
  Credentials = netrc_credentials(NetrcEntry),
  Client = get_or_create_client(State, Key, Credentials),
  Request = CanonicRequest#{target => Target},
  case mhttp_client:send_request(Client, Request, Options) of
    {ok, Response} when is_map(Response) ->
      case redirection_uri(Response, Options) of
        undefined ->
          {Response, State};
        URI ->
          NextRequest = mhttp_request:redirect(CanonicRequest, Response, URI),
          send_request_1(NextRequest, Options, NbRedirectionsLeft-1, State)
      end;
    {ok, {upgraded, Response, Pid}} ->
      {{upgraded, Response, Pid}, State};
    {error, Reason} ->
      throw({error, Reason})
  end.

-spec redirection_uri(mhttp:response(), mhttp:request_options()) ->
        uri:uri() | undefined.
redirection_uri(Response, Options) ->
  case maps:get(follow_redirections, Options, true) of
    true ->
      case mhttp_response:is_redirection(Response) of
        {true, URI} ->
          URI;
        false ->
          undefined;
        {error, Reason} ->
          throw({error, Reason})
      end;
    false ->
      undefined
  end.

-spec get_or_create_client(state(), mhttp:client_key(),
                           mhttp:credentials()) ->
        mhttp_client:ref().
get_or_create_client(State = #{options := Options,
                               clients_by_key := ClientsByKey,
                               clients_by_pid := ClientsByPid},
                     Key,
                     Credentials) ->
  MaxConns = maps:get(max_connections_per_key, Options, 1),
  case ets:lookup(ClientsByKey, Key) of
    Entries when length(Entries) < MaxConns ->
      Pid = create_client(State, Key, Credentials),
      ets:insert(ClientsByKey, {Key, Pid}),
      ets:insert(ClientsByPid, {Pid, Key}),
      ?LOG_DEBUG("added new client ~p (~p)", [Key, Pid]),
      Pid;
    Entries ->
      {_, Pid} = lists:nth(rand:uniform(length(Entries)), Entries),
      Pid
  end.

-spec create_client(state(), mhttp:client_key(), mhttp:credentials()) ->
        mhttp_client:ref().
create_client(#{id := Id, options := Options}, {Host, Port, Transport},
              Credentials) ->
  %% Note that credentials supplied in client options override internal
  %% credentials (which are in the current state obtained from a netrc file).
  CACertificateBundlePath =
    persistent_term:get(mhttp_ca_certificate_bundle_path),
  ClientOptions0 = maps:merge(#{credentials => Credentials,
                                ca_certificate_bundle_path =>
                                  CACertificateBundlePath},
                              maps:get(client_options, Options, #{})),
  ClientOptions = ClientOptions0#{host => Host,
                                  port => Port,
                                  transport => Transport,
                                  pool => Id},
  case mhttp_client:start_link(ClientOptions) of
    {ok, Pid} ->
      Pid;
    {error, Reason} ->
      throw({error, Reason})
  end.

-spec delete_client(state(), pid()) -> ok.
delete_client(#{clients_by_key := ClientsByKey,
                clients_by_pid := ClientsByPid}, Pid) ->
  case ets:lookup(ClientsByPid, Pid) of
    [{Pid, Key}] ->
      ets:delete_object(ClientsByKey, {Key, Pid}),
      ets:delete(ClientsByPid, Pid),
      ok;
    [] ->
      ok
  end.

-spec request_target_and_key(mhttp:request(), netrc:entry() | undefined) ->
        {mhttp:target(), mhttp:client_key()}.
request_target_and_key(Request, NetrcEntry) ->
  Target = mhttp_request:target_uri(Request),
  Host = mhttp_uri:host(Target),
  Port = request_port(Target, NetrcEntry),
  Transport = mhttp_uri:transport(Target),
  Key = {Host, Port, Transport},
  Target2 = maps:without([scheme, userinfo, host, port], Target),
  Target3 = Target2#{path => mhttp_uri:path(Target2)},
  {Target3, Key}.

-spec netrc_entry(mhttp:request(), state()) -> netrc:entry() | undefined.
netrc_entry(Request, #{options := Options}) ->
  case maps:get(use_netrc, Options, false) of
    true ->
      Target = mhttp_request:target_uri(Request),
      Host = mhttp_uri:host(Target),
      case mhttp_netrc:lookup(Host) of
        {ok, Entry} ->
          Entry;
        error ->
          undefined
      end;
    false ->
      undefined
  end.

-spec netrc_credentials(netrc:entry() | undefined) -> mhttp:credentials().
netrc_credentials(undefined) ->
  none;
netrc_credentials(#{login := Login, password := Password}) ->
  {basic, Login, Password};
netrc_credentials(_) ->
  none.

-spec request_port(uri:uri(), netrc:entry() | undefined) -> uri:port_number().
request_port(Target, undefined) ->
  mhttp_uri:port(Target);
request_port(#{port := Port}, _) ->
  %% Do not override an explicit port in the target URI even if there is a
  %% matching netrc entry.
  Port;
request_port(_, #{port := Port}) when is_integer(Port) ->
  Port;
request_port(Target, #{port := Port}) when is_binary(Port) ->
  case string:to_lower(binary_to_list(Port)) of
    "http" ->
      80;
    "https" ->
      443;
    _ ->
      ?LOG_WARNING("unknown port '~ts' for machine ~ts in netrc file",
                   [Port, mhttp_uri:host(Target)]),
      mhttp_uri:port(Target)
  end;
request_port(Target, _) ->
  mhttp_uri:port(Target).
