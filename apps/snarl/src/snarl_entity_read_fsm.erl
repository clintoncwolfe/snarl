%% @doc The coordinator for stat get operations.  The key here is to
%% generate the preflist just like in wrtie_fsm and then query each
%% replica and wait until a quorum is met.
-module(snarl_entity_read_fsm).
-behavior(gen_fsm).
-include("snarl.hrl").

-include("snarl_dtrace.hrl").

%% API
-export([start_link/7, start/2, start/3, start/4, start/5]).


-export([reconcile/1, different/1, needs_repair/2, repair/4, unique/1]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waiting/2, wait_for_n/2, finalize/2]).

-ignore_xref([
              code_change/4,
              different/1,
              execute/2,
              finalize/2,
              handle_event/3,
              handle_info/3,
              handle_sync_event/4,
              init/1,
              needs_repair/2,
              prepare/2,
              reconcile/1,
              repair/4,
              start/2,
              start/4,
              start_link/7,
              terminate/3,
              unique/1,
              wait_for_n/2,
              waiting/2
             ]).

-record(state, {raw = false ::boolean(),
                req_id,
                from,
                entity,
                start,
                op,
                r,
                n,
                preflist,
                num_r=0,
                size,
                timeout=?DEFAULT_TIMEOUT,
                val,
                vnode,
                bucket,
                system,
                replies=[]}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqID, {VNode, System}, Op, From, Entity, Val, Raw) ->
    gen_fsm:start_link(?MODULE, [ReqID, {VNode, System}, Op, From, Entity, Val, Raw], []);

start_link(ReqID, {VNode, System, Bucket}, Op, From, Entity, Val, Raw) ->
    gen_fsm:start_link(?MODULE, [ReqID, {VNode, System, Bucket}, Op, From, Entity, Val, Raw], []).

start(VNodeInfo, Op) ->
    start(VNodeInfo, Op, undefined).

start(VNodeInfo, Op, User) ->
    start(VNodeInfo, Op, User, undefined).

start(VNodeInfo, Op, User, Val) ->
    start(VNodeInfo, Op, User, Val, false).

start(VNodeInfo, Op, User, Val, Raw) ->
    ReqID = snarl_vnode:mk_reqid(),
    snarl_entity_read_fsm_sup:start_read_fsm(
      [ReqID, VNodeInfo, Op, self(), User, Val, Raw]
     ),
    receive
        {ReqID, ok} ->
            ok;
        {ReqID, ok, Result} ->
            {ok, Result}
    after ?DEFAULT_TIMEOUT ->
            {error, timeout}
    end.

%%%===================================================================
%%% States
%%%===================================================================

%% Intiailize state data.
init([ReqId, {VNode, System} | R]) ->
    init([ReqId, {VNode, System, list_to_binary(atom_to_list(System))} | R]);

init([ReqId, {VNode, System, Bucket}, Op, From, Entity, Val, Raw]) ->
    ?DT_READ_ENTRY(Entity, Op),
    {N, R, _W} = ?NRW(System),
    SD = #state{raw=Raw,
                bucket=Bucket,
                req_id=ReqId,
                from=From,
                op=Op,
                n=N,
                r=R,
                val=Val,
                start=now(),
                vnode=VNode,
                system=System,
                entity=Entity},
    {ok, prepare, SD, 0};

init([ReqId, {VNode, System, Bucket}, Op, From, Entity]) ->
    ?DT_READ_ENTRY(Entity, Op),
    SD = #state{req_id=ReqId,
                bucket=Bucket,
                from=From,
                op=Op,
                start=now(),
                vnode=VNode,
                system=System,
                entity=Entity},
    {ok, prepare, SD, 0};

init([ReqId, {VNode, System, Bucket}, Op, From]) ->
    ?DT_READ_ENTRY("undefined", Op),
    SD = #state{req_id=ReqId,
                bucket=Bucket,
                from=From,
                vnode=VNode,
                start=now(),
                system=System,
                op=Op},
    {ok, prepare, SD, 0}.

%% @doc Calculate the Preflist.
prepare(timeout, SD0=#state{entity=Entity,
                            bucket=Bucket,
                            n = N,
                            system=System}) ->
    DocIdx = riak_core_util:chash_key({Bucket, term_to_binary(Entity)}),
    Prelist = riak_core_apl:get_apl(DocIdx, N, System),
    SD = SD0#state{preflist=Prelist},
    {next_state, execute, SD, 0}.

%% @doc Execute the get reqs.
execute(timeout, SD0=#state{req_id=ReqId,
                            entity=Entity,
                            op=Op,
                            val=Val,
                            vnode=VNode,
                            preflist=Prelist}) ->
    case Entity of
        undefined ->
            VNode:Op(Prelist, ReqId);
        _ ->
            case Val of
                undefined ->
                    VNode:Op(Prelist, ReqId, Entity);
                _ ->
                    VNode:Op(Prelist, ReqId, Entity, Val)
            end
    end,
    {next_state, waiting, SD0}.

%% @doc Wait for R replies and then respond to From (original client
%% that called `snarl:get/2').
%% TODO: read repair...or another blog post?

waiting({ok, ReqID, IdxNode, Obj},
        SD0=#state{from=From, num_r=NumR0, replies=Replies0,
                   r=R, n = N, timeout=Timeout}) ->
    NumR = NumR0 + 1,
    Replies = [{IdxNode, Obj}|Replies0],
    SD = SD0#state{num_r=NumR,replies=Replies},
    if
        NumR =:= R ->
            case merge(Replies) of
                not_found ->
                    ?DT_READ_NOT_FOUND_RETURN(SD0#state.entity, SD0#state.op),
                    From ! {ReqID, ok, not_found};
                Merged ->
                    ?DT_READ_FOUND_RETURN(SD0#state.entity, SD0#state.op),
                    Reply = case SD#state.raw of
                                false ->
                                    snarl_obj:val(Merged);
                                true ->
                                    Merged
                            end,
                    From ! {ReqID, ok, Reply}
            end,
            if
                NumR =:= N ->
                    {next_state, finalize, SD, 0};
                true ->
                    {next_state, wait_for_n, SD, Timeout}
            end;
        true ->
            {next_state, waiting, SD}
    end.

wait_for_n({ok, _ReqID, IdxNode, Obj},
           SD0=#state{n = N, num_r=NumR, replies=Replies0})
  when NumR =:= N - 1 ->
    Replies = [{IdxNode, Obj}|Replies0],
    {next_state, finalize, SD0#state{num_r=N, replies=Replies}, 0};

wait_for_n({ok, _ReqID, IdxNode, Obj},
           SD0=#state{num_r=NumR0, replies=Replies0, timeout=Timeout}) ->
    NumR = NumR0 + 1,
    Replies = [{IdxNode, Obj}|Replies0],
    {next_state, wait_for_n, SD0#state{num_r=NumR, replies=Replies}, Timeout};

%% TODO partial repair?
wait_for_n(timeout, SD) ->
    {stop, timeout, SD}.

finalize(timeout, SD=#state{
                        vnode=VNode,
                        replies=Replies,
                        entity=Entity}) ->
    MObj = merge(Replies),
    case needs_repair(MObj, Replies) of
        true ->
            lager:warning("[read] performing read repair on '~p'.", [Entity]),
            repair(VNode, Entity, MObj, Replies),
            {stop, normal, SD};
        false ->
            {stop, normal, SD}
    end.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% @pure
%%
%% @doc Given a list of `Replies' return the merged value.
-spec merge([vnode_reply()]) -> snarl_obj() | not_found.
merge(Replies) ->
    Objs = [Obj || {_,Obj} <- Replies],
    snarl_obj:merge(snarl_entity_read_fsm, Objs).

%% @pure
%%
%% @doc Reconcile conflicts among conflicting values.
-spec reconcile([A :: snarl_user_state:user() | snarl_user_state:role() ]) ->
                       snarl_user_state:user() | snarl_user_state:role().
%%-spec reconcile([A :: snarl_user_state:user() | snarl_user_state:role() ]) -> snarl_user_state:user();
%%               ([A :: snarl_user_state:role()]) -> snarl_user_state:role().

reconcile([V | Vs]) ->
    case {snarl_user_state:is_a(V),
          snarl_role_state:is_a(V),
          snarl_org_state:is_a(V)} of
        {true, _, _} ->
            reconcile_user(Vs, V);
        {_, true, _} ->
            reconcile_role(Vs, V);
        {_, _, true} ->
            reconcile_org(Vs, V);
        _ ->
            V
    end.

reconcile_role([G | R], Acc) ->
    reconcile_role(R, snarl_role_state:merge(Acc, G));
reconcile_role(_, Acc) ->
    Acc.

reconcile_user([U | R], Acc) ->
    reconcile_user(R, snarl_user_state:merge(Acc, U));
reconcile_user(_, Acc) ->
    Acc.

reconcile_org([U | R], Acc) ->
    reconcile_org(R, snarl_org_state:merge(Acc, U));
reconcile_org(_, Acc) ->
    Acc.

%% @pure
%%
%% @doc Given the merged object `MObj' and a list of `Replies'
%% determine if repair is needed.
-spec needs_repair(any(), [vnode_reply()]) -> boolean().
needs_repair(MObj, Replies) ->
    Objs = [Obj || {_,Obj} <- Replies],
    lists:any(different(MObj), Objs).

%% @pure
different(A) -> fun(B) -> not snarl_obj:equal(A,B) end.

%% @impure
%%
%% @doc Repair any vnodes that do not have the correct object.
-spec repair(atom(), string(), snarl_obj(), [vnode_reply()]) -> io.
repair(_, _, _, []) -> io;

repair(VNode, StatName, MObj, [{IdxNode,Obj}|T]) ->
    case snarl_obj:equal(MObj, Obj) of
        true ->
            repair(VNode, StatName, MObj, T);
        false ->
            case Obj of
                not_found ->
                    VNode:repair(IdxNode, StatName, not_found, MObj);
                _ ->
                    VNode:repair(IdxNode, StatName, Obj#snarl_obj.vclock, MObj)
            end,
            repair(VNode, StatName, MObj, T)
    end.

%% pure
%%
%% @doc Given a list return the set of unique values.
-spec unique([A::any()]) -> [A::any()].
unique(L) ->
    sets:to_list(sets:from_list(L)).

%%stat_name(snarl_user_vnode) ->
%%    "user";
%%stat_name(snarl_role_vnode) ->
%%    "role";
%%stat_name(snarl_org_vnode) ->
%%    "org";
%%stat_name(snarl_token_vnode) ->
%%    "token".
