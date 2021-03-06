%% Copyright (c) 2017, Veronika Kebkal <veronika.kebkal@evologics.de>
%%                     Oleksiy Kebkal <lesha@evologics.de>
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. The name of the author may not be used to endorse or promote products
%%    derived from this software without specific prior written permission.
%%
%% Alternatively, this software may be distributed under the terms of the
%% GNU General Public License ("GPL") version 2 as published by the Free
%% Software Foundation.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-module(fsm_mux_burst).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include("fsm.hrl").
-include("nl.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3, handle_alarm/3, handle_final/3]).
-export([handle_init_roles/3, handle_ready_nl/3, handle_discovery/3]).

-define(TRANS, [
                {idle,
                 [{internal, idle},
                 {init, init_roles}
                 ]},

                {init_roles,
                 [
                 {ready, ready_nl}
                 ]},

                {ready_nl,
                 [{set_routing, ready_nl},
                  {update_routing, discovery}
                 ]},

                {discovery,
                 [{set_routing, ready_nl}
                ]},

                {alarm,
                 [{final, alarm}
                 ]},

                {final, []}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       ->
  [env:put(__, sync_routing_impl, false),
   env:put(__, update_routing, false),
   env:put(__, cast_routing_async, true),
   env:put(__, async_routing_nl, false),
   env:put(__, clear_routing, false),
   env:put(__, wait_send_sync, false)
  ](SM).
trans()        -> ?TRANS.
final()        -> [alarm].
init_event()   -> internal.
stop(_SM)      -> ok.

-define(TO_MM, fun(#mm{role_id = ID}, {_,Role_ID,_,_,_}, _) -> ID == Role_ID end).
%%--------------------------------Handler Event----------------------------------
handle_event(MM, SM, Term) ->
  %% ?TRACE(?ID, "state ~p ev ~p term ~p~n", [SM#sm.state, SM#sm.event, Term]),
  Sync_routing_impl = env:get(SM, sync_routing_impl),
  Wait_send_sync = env:get(SM, wait_send_sync),
  Clear_routing = env:get(SM, clear_routing),
  Current_protocol = share:get(SM, current_protocol),
  State = SM#sm.state,
  ?INFO(?ID, "State ~p Term ~p~n", [State, Term]),
  case Term of
    {timeout, reset_state} ->
      Burst_protocol = share:get(SM, burst_protocol),
      ProtocolMM = share:get(SM, Burst_protocol),
      fsm:cast(SM, ProtocolMM, [], {send, {nl, reset, state}}, ?TO_MM);
    {timeout, {get_protocol, Some_MM}} ->
      [fsm:set_timeout(__, {s, 1}, {get_protocol, Some_MM}),
       fsm:cast(__, Some_MM, [], {send, {nl, get, protocol}}, ?TO_MM)
      ](SM);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event = Event}, {});
    {connected} when MM#mm.role == nl ->
      [fsm:set_timeout(__#sm{state = init_roles}, {s, 1}, {get_protocol, MM}),
       fsm:cast(__, MM, [], {send, {nl, get, protocol}}, ?TO_MM)
      ](SM);
    {connected} ->
      SM;
    {disconnected, _} ->
      SM;
    {nl, update, routing} when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl_impl, {send, {nl, routing, error}});
    {nl, update, routing, Dst} when State == ready_nl ->
      Cast_handler =
      fun (LSM, nl_impl) ->
            fsm:cast(LSM, nl_impl, {send, {nl, routing, ok}});
          (LSM, nl) ->
            env:put(LSM, cast_routing_async, false)
      end,
      [Cast_handler(__, MM#mm.role),
       update_routing(__, Dst),
       fsm:set_event(__, update_routing),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, update, routing, _} when MM#mm.role == nl_impl ->
      fsm:cast(SM, nl_impl, {send, {nl, routing, busy}});
    {nl, update, routing, _} ->
      SM;
    {nl, send, error} when MM#mm.role == nl_impl ->
      ?INFO(?ID, "MM ~p~n", [MM#mm.role]),
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, send, Pkg} when Wait_send_sync, is_integer(Pkg) ->
      [fsm:cast(__, nl_impl, {send, Term}),
       env:put(__, wait_send_sync, false)
      ](SM);
    {nl, send, _} -> SM;
    {nl, send, tolerant, Src, Data} ->
      Payload = encode_mux(SM, mux, Data),
      send_data(SM, ?TO_MM, MM#mm.role, burst_protocol, {nl, send, tolerant, Src, Payload});
    {nl, send, Src, Data} ->
      Payload = encode_mux(SM, mux, Data),
      P =
      if Current_protocol == burst -> im_protocol;
        true -> current_protocol
      end,
      send_data(SM, ?TO_MM, MM#mm.role, P, {nl, send, Src, Payload});
    {nl, send, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, send, error}});
    {nl, delete, neighbour, _N} ->
      send_command(SM, ?TO_MM, discovery_protocol,Term);
    {nl, routing, Routing} when Clear_routing ->
      [env:put(__, clear_routing, false),
       share:put(__, routing_table, Routing)
      ](SM);
    %% SYNC nl,routing
    {nl, routing, Routing} when Sync_routing_impl ->
      [share:put(__, routing_table, Routing),
       fsm:cast(__, nl_impl, {send, Term}),
       env:put(__, sync_routing_impl, false),
       fsm:set_event(__, eps),
       fsm:run_event(MM, __, {})
      ](SM);
    %% ASYNC nl,routing
    {nl, routing, Routing} when MM#mm.role == nl ->
      Update_routing = env:get(SM, update_routing),
      Sync_routing_nl = env:get(SM, async_routing_nl),
      Cast_routing_async = env:get(SM, cast_routing_async),
      Cast_handler =
      fun (LSM) when Cast_routing_async == true ->
            fsm:cast(LSM, nl_impl, {send, Term});
          (LSM) ->
            env:put(LSM, cast_routing_async, true)
      end,
      ?INFO(?ID, "Update_routing ~p Sync_routing_nl ~p~n", [Update_routing, Sync_routing_nl]),
      Update_handler =
      fun (LSM) when Update_routing->
            [Cast_handler(__),
             env:put(__, update_routing, false),
             process_routing(__, Routing),
             fsm:set_event(__, set_routing)
            ](LSM);
          (LSM) when Sync_routing_nl->
            [process_routing(__, Routing),
             env:put(__, async_routing_nl, false),
             fsm:set_event(__, set_routing)
            ](LSM);
          (LSM) ->
            fsm:set_event(LSM, eps)
      end,
      [share:put(__, routing_table, Routing),
       Update_handler(__),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, routing, _} -> SM;
    {nl, reset, state} ->
      [send_command(__, ?TO_MM, current_protocol, Term),
       fsm:run_event(MM, __, {}),
       fsm:set_event(__, ready_nl),
       fsm:clear_timeouts(__)
      ](SM);
    {nl, get, help} ->
      NHelp = string:concat(?MUXBURSTHELP, ?HELP),
      fsm:cast(SM, nl_impl, {send, {nl, help, NHelp}});
    {nl, get, protocols} ->
      Tuple = {nl, protocols, share:get(SM, nothing, configured_protocols, [])},
      fsm:cast(SM, nl_impl, {send, Tuple});
    {nl, get, protocolinfo, _Some_protocol} ->
      ProtocolMM = share:get(SM, share:get(SM, discovery_protocol)),
      fsm:cast(SM, ProtocolMM, [], {send, Term}, ?TO_MM);
    {nl, get, routing} when MM#mm.role == nl_impl ->
      [env:put(__, sync_routing_impl, true),
       get_routing(__, ?TO_MM, Term)
      ](SM);
    {nl, get, routing} ->
      [env:put(__, async_routing_nl, true),
       get_routing(__, ?TO_MM, Term)
      ](SM);
    {nl, get, time, monotonic} ->
      send_command(SM, ?TO_MM, current_protocol, Term);
    {nl, get, protocol} ->
      send_command(SM, ?TO_MM, current_protocol, Term);
    {nl, get, buffer} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, flush, buffer} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, get, service} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, get, bitrate} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, get, status} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, get, statistics, tolerant} ->
      send_command(SM, ?TO_MM, burst_protocol, Term);
    {nl, get, statistics, data} ->
      P =
      if Current_protocol == burst -> im_protocol;
        true -> current_protocol
      end,
      send_command(SM, ?TO_MM, P, Term);
    {nl, get, statistics, _} ->
      send_command(SM, ?TO_MM, discovery_protocol, Term);
    {nl, get, _} ->
      send_command(SM, ?TO_MM, discovery_protocol, Term);
    {nl, set, protocol, Protocol} when State =/= discovery ->
      %% clear everything and set current protocol
      set_protocol(SM, MM#mm.role, Protocol);
    {nl, set, routing, _Routing} ->
      [env:put(__, sync_routing_impl, true),
       set_routing(__, ?TO_MM, discovery_protocol, Term)
      ](SM);
    {nl, set, debug, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, debug, error}});
    {nl, delivered, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, failed, _, _, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, path, failed, _} ->
      Burst_protocol = share:get(SM, burst_protocol),
      ProtocolMM = share:get(SM, Burst_protocol),
      Cast_routing_async = env:get(SM, cast_routing_async),
      Cast_handler =
        fun (LSM) when Cast_routing_async == true ->
              fsm:cast(LSM, nl_impl, {send, Term});
            (LSM) -> LSM
        end,
      [fsm:cast(__, ProtocolMM, [], {send, Term}, ?TO_MM),
       Cast_handler(__),
       env:put(__, update_routing, false),
       env:put(__, async_routing_nl, false),
       fsm:set_event(__, set_routing),
       fsm:run_event(MM, __, {})
      ](SM);
    {nl, path, _, _} ->
      SM;
    {nl, ack, Src, Data} ->
      Ack_protocol = share:get(SM, ack_protocol),
      ProtocolMM = share:get(SM, Ack_protocol),
      Payload = encode_mux(SM, nl, Data),
      [fsm:cast(__, ProtocolMM, [], {send, {nl, send, Src, Payload}}, ?TO_MM)
      ](SM);
    {nl, neighbours, _} ->
      fsm:cast(SM, nl_impl, {send, Term});
    {nl, time, monotonic, Time} ->
      fsm:cast(SM, nl_impl, {send, {nl, time, monotonic, Time}});
    {nl, version, Major, Minor, Description} ->
      fsm:cast(SM, nl_impl, {send, {nl, version, Major, Minor, "mux:" ++ Description}});
    {nl, protocol, NPA} when SM#sm.state == init_roles ->
      %% bind MM with protocol here
      %% NOTE: protocol must be unique per MM
      Current_protocol = share:get(SM, current_protocol),
      if Current_protocol == nothing ->
        share:put(SM, current_protocol, NPA);
        true -> nothing
      end,
      NLRoles = [Role || {nl,_,_,_,_} = Role <- SM#sm.roles],
      Configured_protocols = share:get(SM, configured_protocols),
      Event = case length(NLRoles) of
                NLCount when NLCount == (length(Configured_protocols) + 1);
                             NLCount == length(Configured_protocols) -> ready;
                _ -> eps
              end,
      NL =
      case lists:member(NPA, Configured_protocols) of
        true -> Configured_protocols;
        false -> [NPA|Configured_protocols]
      end,
      [share:put(__, NPA, MM),
       share:put(__, configured_protocols, NL),
       fsm:clear_timeout(__, {get_protocol, MM}),
       fsm:set_event(__, Event),
       fsm:run_event(MM, __, {})
      ] (SM);
    {nl, recv, tolerant, Src, Dst, Data} ->
      ?INFO(?ID, "Received tolerant tuple ~p~n", [Term]),
      process_recv(SM, Term, Src, Dst, Data);
    {nl, recv, Src, Dst, Data} ->
      ?INFO(?ID, "Received tuple ~p~n", [Term]),
      process_recv(SM, Term,  Src, Dst, Data);
    {nl, error, _} when MM#mm.role == nl_impl ->
      ?INFO(?ID, "MM ~p~n", [MM#mm.role]),
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    {send_error, _} ->
      fsm:cast(SM, nl_impl, {send, {nl, error}});
    _ when MM#mm.role == nl ->%, State =/= discovery ->
      fsm:cast(SM, nl_impl, {send, Term});
    UUg ->
      ?ERROR(?ID, "~s: unhandled event:~p from ~p~n", [?MODULE, UUg, MM#mm.role]),
      SM
  end.
%%--------------------------------Handler functions-------------------------------
handle_idle(_MM, #sm{event = internal} = SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  [share:put(__, configured_protocols, []),
   fsm:set_event(__, init)
  ](SM);
handle_idle(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_init_roles(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_ready_nl(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

handle_discovery(_MM, SM, Term) ->
  ?TRACE(?ID, "~120p~n", [Term]),
  SM#sm{event = eps}.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).

handle_final(_MM, SM, Term) ->
    ?TRACE(?ID, "Final ~120p~n", [Term]).

%%--------------------------------Helper functions-------------------------------
set_protocol(SM, Role, Protocol) ->
  ProtocolMM = share:get(SM, Protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        fsm:cast(LSM, nl_impl, {send, {nl, protocol, error}});
      (LSM, _) when Role == nl ->
        [share:put(__, current_protocol, Protocol),
         fsm:clear_timeouts(__)
        ](LSM);
      (LSM, _) ->
        [fsm:cast(__, nl_impl, {send, {nl, protocol, Protocol}}),
         share:put(__, current_protocol, Protocol),
         fsm:clear_timeouts(__)
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM).

update_routing(SM, Dst) ->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
        LSM;
      (LSM, _) ->
        Payload = encode_mux(SM, nl, <<"D">>),
        Tuple = {nl, send, Dst, Payload},
        Cleared = {nl, set, routing, clear_routing(SM, Dst)},
        % Delete routing
        [env:put(__, clear_routing, true),
         env:put(__, update_routing, true),
         fsm:cast(__, ProtocolMM, [], {send, Cleared}, ?TO_MM),
         fsm:cast(__, ProtocolMM, [], {send, Tuple}, ?TO_MM)
        ](LSM)
  end,
  Protocol_handler(SM, ProtocolMM).

clear_routing(SM, Dst) ->
  Routing_table = share:get(SM, nothing, routing_table, []),
  clear_routing_helper(SM, Routing_table, Dst).
clear_routing_helper(_, [], _) -> [{default, 63}];
clear_routing_helper(SM, Routing_table, Dst) ->
  NR =
  lists:filtermap(fun(X) ->
        case X of
          {Dst, _} -> false;
          Dst -> false;
          _ -> {true, X}
  end end, Routing_table),

  ?INFO(?ID, "clear_routing ~p  ~p~n", [Routing_table, NR]),

  if NR == [] -> [{default, 63}];
    true -> NR
  end.

process_routing(SM, NL) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),

  ?INFO(?ID, "process_routing ~p ~p ~p~n", [Burst_protocol, ProtocolMM, NL]),
  Protocol_handler =
  fun (LSM, P, true) when P =/= nothing ->
        Routing_table = [ {X, X} ||  X <- NL],
        set_routing(LSM, ?TO_MM, ProtocolMM, {nl, set, routing, Routing_table});
      (LSM, P, false) when P =/= nothing ->
        set_routing(LSM, ?TO_MM, ProtocolMM, {nl, set, routing, NL});
      (LSM, _, _) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Burst_protocol]),
        LSM
  end,
  [H|_] = NL,
  [share:put(__, neighbours, NL),
   Protocol_handler(__, ProtocolMM, is_number(H))
  ](SM).

%---------------------------- get commands ---------------------------------
get_routing(SM, MM, Command)->
  Discovery_protocol = share:get(SM, discovery_protocol),
  ProtocolMM = share:get(SM, Discovery_protocol),
  ?INFO(?ID, "get_routing ~p ~p ~n", [Discovery_protocol, ProtocolMM]),
  fsm:cast(SM, ProtocolMM, [], {send, Command}, MM).

set_routing(SM, MM, Protocol_Name, Command) when is_atom(Protocol_Name) ->
  Burst_protocol = share:get(SM, Protocol_Name),
  ProtocolMM = share:get(SM, Burst_protocol),
  set_routing(SM, MM, ProtocolMM, Command);
set_routing(SM, MM, ProtocolMM, Command) ->
  [fsm:cast(__, ProtocolMM, [], {send, Command}, MM)
  ](SM).

send_data(SM, MM, Role, Protocol_Name, Command) ->
  Sync_handler =
  fun (LSM, nl_impl) -> env:put(LSM, wait_send_sync, true);
      (LSM, _) -> LSM
  end,
  [Sync_handler(__, Role),
   send_command(__, MM, Protocol_Name, Command)
  ](SM).
send_command(SM, MM, Protocol_Name, Command) ->
  Discovery_protocol = share:get(SM, Protocol_Name),
  ProtocolMM = share:get(SM, Discovery_protocol),
  Protocol_handler =
  fun (LSM, nothing) ->
        ?ERROR(?ID, "Protocol ~p is not configured ~n", [Discovery_protocol]),
        LSM;
      (LSM, _) ->
        fsm:cast(LSM, ProtocolMM, [], {send, Command}, MM)
  end,
  Protocol_handler(SM, ProtocolMM).

encode_mux(_SM, Flag, Data) ->
  Flag_num = flag_num(Flag),
  B_Flag = <<Flag_num:1>>,
  <<B_Flag/bitstring, 0:7, Data/binary>>.

decode_mux(SM, Data) ->
  <<Flag_Num:1, _:7, Rest/bitstring>> = Data,
  ?INFO(?ID, "decode_mux ~p ~p~n", [Flag_Num, Rest]),
  Flag = num_flag(Flag_Num),
  [Flag, Rest].

process_recv(SM, Term, Src, Dst, Data) ->
  [Flag, Payload] = decode_mux(SM, Data),
  ?INFO(?ID, "Decode mux header ~p ~p~n", [Flag, Payload]),
  process_recv_helper(SM, Term, Flag, Src, Dst,Payload).

process_recv_helper(SM, _, nl, _, _, <<"D">>) -> SM;
process_recv_helper(SM, {nl,recv,tolerant,_,_,_}, mux, Src, Dst, Payload) ->
  fsm:cast(SM, nl_impl, {send, {nl, recv, tolerant, Src, Dst, Payload}});
process_recv_helper(SM, _, mux, Src, Dst, Payload) ->
  fsm:cast(SM, nl_impl, {send, {nl, recv, Src, Dst, Payload}});
process_recv_helper(SM, Term, nl, Src, Dst, Payload) ->
  Burst_protocol = share:get(SM, burst_protocol),
  ProtocolMM = share:get(SM, Burst_protocol),
  case burst_nl_hf:try_extract_ack(SM, Payload) of
    [] -> fsm:cast(SM, nl_impl, {send, Term});
    [_Count, _L] ->
      fsm:cast(SM, ProtocolMM, [], {send, {nl, ack, Src, Dst, Payload}}, ?TO_MM)
  end.

flag_num(nl) -> 1;
flag_num(mux) -> 0.
num_flag(1) -> nl;
num_flag(0) -> mux.
