%% @doc The coordinator for stat get operations.  The key here is to
%% generate the preflist just like in wrtie_fsm and then query each
%% replica and wait until a quorum is met.
-module(snarl_user_read_fsm).
-behavior(gen_fsm).
-include("snarl.hrl").

%% API
-export([start_link/3, get/1]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waiting/2]).

-record(state, {req_id,
                from,
		user,
                preflist,
                num_r=0,
                replies=[]}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqID, From, User) ->
    gen_fsm:start_link(?MODULE, [ReqID, From, User], []).

get(User) ->
    ReqID = mk_reqid(),
    snarl_user_read_fsm_sup:start_read_fsm([ReqID, self(), User]),
    {ok, ReqID}.

%%%===================================================================
%%% States
%%%===================================================================

%% Intiailize state data.
init([ReqId, From, User]) ->
    SD = #state{req_id=ReqId,
                from=From,
                user=User},
    {ok, prepare, SD, 0}.

%% @doc Calculate the Preflist.
prepare(timeout, SD0=#state{user=User}) ->
    ?PRINT({prepare, User}),
    DocIdx = riak_core_util:chash_key({<<"user">>, list_to_binary(User)}),
    Prelist = riak_core_apl:get_apl(DocIdx, ?N, snarl_user),
    SD = SD0#state{preflist=Prelist},
    {next_state, execute, SD, 0}.

%% @doc Execute the get reqs.
execute(timeout, SD0=#state{req_id=ReqId,
                            user=User,
                            preflist=Prelist}) ->
    ?PRINT({execute, User}),
    snarl_user_vnode:read(Prelist, ReqId, User),
    {next_state, waiting, SD0}.

%% @doc Wait for R replies and then respond to From (original client
%% that called `rts:get/2').
%% TODO: read repair...or another blog post?
waiting({ok, ReqID, Val}, SD0=#state{from=From, num_r=NumR0, replies=Replies0}) ->
    ?PRINT({waiting, ReqID, Val}),
    NumR = NumR0 + 1,
    Replies = [Val|Replies0],
    SD = SD0#state{num_r=NumR,replies=Replies},
    if
        NumR =:= ?R ->
            Reply =
                case lists:any(different(Val), Replies) of
                    true ->
                        Replies;
                    false ->
                        Val
                end,
            From ! {ReqID, ok, Reply},
            {stop, normal, SD};
        true -> {next_state, waiting, SD}
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

different(A) -> fun(B) -> A =/= B end.

mk_reqid() -> erlang:phash2(erlang:now()).
