-module(fsm_inv_usbl).
-compile({parse_transform, pipeline}).
-behaviour(fsm).

-include_lib("evins/include/fsm.hrl").

-export([start_link/1, trans/0, final/0, init_event/0]).
-export([init/1,handle_event/3,stop/1]).
-export([handle_idle/3,handle_waiting_answer/3,handle_alarm/3]).

-define(TRANS, [{idle,
                 [{init, idle},
                  {send_at_command, waiting_answer},
                  {sync_answer, alarm},
                  {answer_timeout, alarm}]},

                {waiting_answer,
                 [{send_at_command, waiting_answer},
                  {sync_answer, waiting_answer},
                  {empty_queue, idle},
                  {answer_timeout, alarm}]},

                {alarm,[]}
               ]).

start_link(SM) -> fsm:start_link(SM).
init(SM)       -> SM.
trans()        -> ?TRANS.
final()        -> [].
init_event()   -> init.
stop(_SM)      -> ok.

handle_event(MM, SM, Term) ->
  LAddr = share:get(SM, local_address),
  case Term of
    {timeout, {am_timeout, {Pid, RAddr, TTS}}} ->
      AT = {at, {pid, Pid}, "*SENDIMS", RAddr, TTS, <<"N">>},
      fsm:run_event(MM, SM#sm{event=send_at_command}, AT);
    {timeout, Event} ->
      fsm:run_event(MM, SM#sm{event=Event}, {});

    % RECVIM (only for debugging)
    {async,  {pid, Pid}, {recvim, _, _RAddr, LAddr, ack, _, _, _, _, _Payload}} ->
      %io:format("RDistance = ~p~n", [extractIM(Payload)]),
      share:put(SM, im_pid, Pid);

    % RECVIMS
    {async, {pid, Pid}, {recvims, _, RAddr, LAddr, TS, Dur, _, _, _, _Payload}} ->
      %io:format("RDistance = ~p~n", [extractIM(Payload)]),
      AD = share:get(SM, answer_delay),
      fsm:set_timeout(SM, {ms, 0.5 * AD - Dur / 1000}, {am_timeout, {Pid, RAddr, TS + AD * 1000}});

    % create AM to send by PBM or IMS
    {async, {usblangles, _, _, RAddr, Bearing, Elevation, _, _, Roll, Pitch, Yaw, _, _, Acc}} ->
      AM = case Acc of
             _ when Acc >= 0 -> createAM(lists:map(fun rad2deg/1, [Bearing, Elevation, Roll, Pitch, Yaw]));
             _ -> <<"N">>
           end,
      %io:format("LAngles: ~p~n", [extractAM(AM)]),
      case find_spec_timeouts(SM, am_timeout) of
        [] ->
          Pid = share:get(SM, im_pid),
          AT = {at, {pid, Pid}, "*SENDPBM", RAddr, AM},
          fsm:run_event(MM, SM#sm{event=send_at_command}, AT);
        List ->
          lists:foldl(fun({am_timeout, {Pid, MRAddr, TTS}} = Spec, MSM) ->
                          AT = {at, {pid, Pid}, "*SENDIMS", RAddr, TTS, AM},
                          case MRAddr of
                            RAddr ->
                              [fsm:clear_timeout(__, Spec),
                               fsm:run_event(MM, __#sm{event=send_at_command}, AT)
                              ](MSM);
                            _ -> MSM
                          end
                      end, SM, List)
      end;

    {sync, _Req, _Answer} ->
      [fsm:clear_timeout(__, answer_timeout),
       fsm:run_event(MM, __#sm{event=sync_answer}, {})
      ](SM);

    _ -> SM
  end.


handle_idle(_MM, SM, _Term) ->
  case SM#sm.event of
    init ->
      [share:put(__, im_pid, 0),
       share:put(__, at_queue, queue:new()),
       fsm:set_event(__, eps)
      ](SM);
    _ -> fsm:set_event(SM, eps)
  end.

handle_waiting_answer(_MM, SM, Term) ->
  AQ = share:get(SM, at_queue),
  case SM#sm.event of
    send_at_command ->
      SM1 = case fsm:check_timeout(SM, answer_timeout) of
              true ->
                share:put(SM, at_queue, queue:in(Term, AQ));
              _ ->
                fsm:send_at_command(SM, Term)
            end,
      fsm:set_event(SM1, eps);

    sync_answer ->
      case queue:out(AQ) of
        {{value, AT}, AQn} ->
          [fsm:send_at_command(__, AT),
           share:put(__, at_queue, AQn),
           fsm:set_event(__, eps)
          ](SM);

        {empty, _} ->
          fsm:set_event(SM, empty_queue)
      end;

    _ -> fsm:set_event(SM, eps)
  end.

-spec handle_alarm(any(), any(), any()) -> no_return().
handle_alarm(_MM, SM, _Term) ->
  exit({alarm, SM#sm.module}).


find_spec_timeouts(SM, Spec) ->
  R = lists:filter(fun({V, _}) ->
                       case V of
                         {Spec, _} -> true;
                         _ -> false
                       end
                   end, SM#sm.timeouts),
  lists:map(fun({V, _}) -> V end, R).


floor(X) when X < 0 ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T - 1
    end;
floor(X) ->
    trunc(X).

smod(X, M)  -> X - floor(X / M + 0.5) * M.
%wrap_pi(A) -> smod(A, -2*math:pi()).
wrap_2pi(A) -> smod(A - math:pi(), 2*math:pi()) + math:pi().

rad2deg(Angle) -> wrap_2pi(Angle) * 180 / math:pi().

createAM(Angles) ->
  [Bearing, Elevation, Roll, Pitch, Yaw] = lists:map(fun(A) -> trunc(A * 10) end, Angles),
  BinMsg = <<"L", Bearing:12/little-unsigned-integer,
             Elevation:12/little-unsigned-integer,
             Roll:12/little-unsigned-integer,
             Pitch:12/little-unsigned-integer,
             Yaw:12/little-unsigned-integer>>,
  Padding = (8 - (bit_size(BinMsg) rem 8)) rem 8,
  <<BinMsg/bitstring, 0:Padding>>.

%extractAM(<<"N">>) ->
%    nothing;
%extractAM(Payload) ->
%  <<"L", Bearing:12/little-unsigned-integer,
%    Elevation:12/little-unsigned-integer,
%    Roll:12/little-unsigned-integer,
%    Pitch:12/little-unsigned-integer,
%    Yaw:12/little-unsigned-integer, _/bitstring>> = Payload,
%  lists:map(fun(A) -> A / 10 end, [Bearing, Elevation, Roll, Pitch, Yaw]).

%extractIM(Payload) ->
%  case Payload of
%    <<"D", Distance:16/little-unsigned-integer,
%           _Heading:12/little-unsigned-integer, _/bitstring>> ->
%      Distance / 10;
%    _ -> nothing
%  end.
