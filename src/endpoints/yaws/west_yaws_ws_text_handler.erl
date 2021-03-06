%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Andres Bolaños, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author Carlos Andres Bolaños R.A. <candres@niagara.io>
%%% @copyright (C) 2013, <Carlos Andres Bolaños>, All Rights Reserved.
%%% @doc Text Wire Protocol. This module is the `yaws' extended
%%%      callback module. Here the WS messages are received and
%%%      handled.
%%% @see <a href="https://github.com/klacke/yaws">Yaws Sources</a>
%%% @end
%%% Created : 03. Oct 2013 9:57 AM
%%%-------------------------------------------------------------------
-module(west_yaws_ws_text_handler).

%% Export for websocket callbacks
-export([init/1,
         terminate/2,
         handle_open/2,
         handle_message/2,
         handle_info/2]).

%% Callback
-export([ev_callback/2]).

-include("west.hrl").

-record(state, {server = ?WEST{}, nb_texts = 0, nb_bins = 0}).

%%%===================================================================
%%% WS callback
%%%===================================================================

%% @doc Initialize the internal state of the callback module.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
init([Arg, InitialState]) ->
  ?LOG_INFO("Initalize ~p: ~p~n", [self(), InitialState]),
  Dist = application:get_env(west, dist, gproc),
  Scope = ?GPROC_SCOPE(Dist),
  DistProps = application:get_env(west, dist_props, [{opts, [{n, 1}, {q, 1}]}]),
  case string:tokens(yaws_api:arg_pathinfo(Arg), "/") of
    [_, Key] ->
      Name = west_util:build_name([Key, self(), west_util:get_timestamp_ms()]),
      register(Name, self()),
      CbSpec = {?MODULE, ev_callback, [{Name, node()}, undefined]},
      {ok, #state{server = ?WEST{name = Name,
                                        key = Key,
                                        dist = Dist,
                                        dist_props = DistProps,
                                        scope = Scope,
                                        cb = CbSpec,
                                        encoding = text}}};
    _ ->
      {error, <<"Error, missing key in path.">>}
  end.

%% @doc This function is called when the connection is upgraded from
%%      HTTP to WebSocket.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_open(WSState, State) ->
  yaws_websockets:send(WSState, {text, <<"Welcome !">>}),
  {ok, State}.

%% @doc This function is called when a message <<"bye">> is received.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_message({text, <<"bye">>}, #state{nb_texts = N, nb_bins = M} = State) ->
  ?LOG_INFO("bye - Msg processed: ~p text, ~p binary~n", [N, M]),
  NbTexts = list_to_binary(integer_to_list(N)),
  NbBins = list_to_binary(integer_to_list(M)),
  Messages = [{text, <<"Goodbye !">>},
              {text, <<NbTexts/binary, " text messages received">>},
              {text, <<NbBins/binary, " binary messages received">>}],
  {close, {1000, <<"bye">>}, Messages, State};

%% @doc This function is called when a message <<"ping">> is received.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_message({text, <<"ping">>}, #state{nb_texts = N} = State) ->
  ?LOG_INFO("Received text msg (N=~p): 4 bytes~n", [N]),
  {reply, {text, <<"west pong">>}, State#state{nb_texts = N + 1}};

%% @doc This function is called when a TEXT message is received.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_message({text, Msg}, #state{nb_texts = N} = State) ->
  ?LOG_INFO("Received text msg (N=~p): ~p bytes~n", [N, byte_size(Msg)]),
  case dec_msg(Msg) of
    none ->
      {reply, {text, Msg}, State#state{nb_texts = N + 1}};
    Cmd ->
      case handle_event(string:to_lower(Cmd), State#state.server) of
        {ok, Reason} ->
          {reply, {text, Reason}, State#state{nb_texts = N + 1}};
        {error, Err0} ->
          {reply, {text, Err0}, State#state{nb_texts = N + 1}};
        _ ->
          ErrMsg = <<"west:action_not_allowed">>,
          {reply, {text, ErrMsg}, State#state{nb_texts = N + 1}}
      end
  end;

%% @doc This function is called when a binary message is received.
%%      NOT HANDLED by this handler.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_message({binary, Msg}, #state{nb_bins = M} = State) ->
  ?LOG_INFO("Received binary msg (M=~p): ~p bytes~n", [M, byte_size(Msg)]),
  {reply, {binary, <<"bad_encoding">>}, State#state{nb_bins = M + 1}};

%% @doc When the client closes the connection, the callback module is
%%      notified with the message {close, Status, Reason}
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_message({close, Status, Reason}, _) ->
  ?LOG_INFO("Close connection: ~p - ~p~n", [Status, Reason]),
  {close, Status}.

%% @doc
%% If defined, this function is called when a timeout occurs or when
%% the handling process receives any unknown message.
%% <br/>
%% Info is either the atom timeout, if a timeout has occurred, or
%% the received message.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
handle_info(timeout, State) ->
  ?LOG_INFO("process timed out~n", []),
  {reply, {text, <<"Anybody Else ?">>}, State};
handle_info(_Info, State) ->
  {noreply, State}.

%% @doc This function is called when the handling process is about to
%%      terminate. it should be the opposite of Module:init/1 and do
%%      any necessary cleaning up.
%% @see <a href="http://hyber.org/websockets.yaws">Yaws</a>
terminate(Reason, State) ->
  ?LOG_INFO("terminate ~p: ~p (state:~p)~n", [self(), Reason, State]),
  ok.

%%%===================================================================
%%% Event handlers
%%%===================================================================

%% @private
%% @doc Handle the register event.
handle_event(["reg", Ch], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch},
  Res = west_protocol_handler:handle_event(register, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
%% @doc Handle the unregister event.
handle_event(["unreg", Ch], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch},
  Res = west_protocol_handler:handle_event(unregister, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
%% @doc Handle the send event.
handle_event(["send", Ch, Msg], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch, data = Msg},
  Res = west_protocol_handler:handle_event(send, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
%% @doc Handle the publish event.
handle_event(["pub", Ch, Msg], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch, data = Msg},
  Res = west_protocol_handler:handle_event(publish, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
%% @doc Handle the subscribe event.
handle_event(["sub", Ch], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch},
  Res = west_protocol_handler:handle_event(subscribe, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
%% @doc Handle the unsubscribe event.
handle_event(["unsub", Ch], WS) ->
  MsgSpec = ?MSG{id = undefined, channel = Ch},
  Res = west_protocol_handler:handle_event(unsubscribe, MsgSpec, WS),
  {ok, bin_msg(Ch, Res)};

%% @private
handle_event(Any, _State) ->
  {none, Any}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
%% @doc Parse the text-based event.
dec_msg(Msg) ->
  L = [string:strip(X, both, $ ) || X <- string:tokens(binary_to_list(Msg), "\"")],
  case L of
    [C, M] -> string:tokens(C, " ") ++ [M];
    [C] -> string:tokens(C, " ");
    _ -> none
  end.

%% @private
bin_msg(Ch, {_, ?MSG{event = Event}}) ->
  <<(<<"west ">>)/binary,
    (iolist_to_binary(Ch ++ ":"))/binary,
    (iolist_to_binary(Event))/binary>>.

%%%===================================================================
%%% Callback
%%%===================================================================

%% @private
%% @doc Event callback. This function is executed when message arrives.
ev_callback({ETag, Event, Msg}, [WSRef, _Id]) ->
  Body = case Msg of
           Msg when is_binary(Msg) ->
             binary_to_list(Msg);
           _ ->
             Msg
         end,
  Reply = <<(iolist_to_binary(ETag))/binary,
  (<<" ">>)/binary,
  (atom_to_binary(Event, utf8))/binary,
  (iolist_to_binary(":new_message "))/binary,
  (iolist_to_binary(Body))/binary>>,
  yaws_api:websocket_send(WSRef, {text, Reply}).
