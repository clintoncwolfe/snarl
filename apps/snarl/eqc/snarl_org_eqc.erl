-module(snarl_org_eqc).


%% sync:stop(), c('apps/snarl/test/snarl_org_eqc', [{d, 'TEST'}, {d, 'EQC'}]), sync:start().

-ifdef(TEST).
-ifdef(EQC).

-define(O, snarl_org).
-define(M, ?MODULE).
-define(REALM, <<"realm">>).


-define(FWD(C),
        C({_, UUID}) ->
               ?O:C(?REALM, UUID)).

-define(FWD2(C),
        C({_, UUID}, A1) ->
               ?O:C(?REALM, UUID, A1)).

-define(FWD3(C),
        C({_, UUID}, A1, A2) ->
               ?O:C(?REALM, UUID, A1, A2)).

-import(snarl_test_helper,
        [id/0, permission/0, maybe_oneof/1, cleanup_mock_servers/0,
         mock_vnode/2, start_mock_servers/0, metadata_value/0, metadata_kvs/0,
         handoff/0, handon/1, delete/0]).

-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eqc/include/eqc.hrl").
-include_lib("fqc/include/fqci.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").
-include_lib("snarl/include/snarl.hrl").

-compile(export_all).

-record(state, {added = [], next_uuid=fifo_utils:uuid(), metadata=[], resources = []}).

maybe_a_uuid(#state{added = Added}) ->
    ?SUCHTHAT(
       U,
       ?LET(E, ?SUCHTHAT(N,
                         non_blank_string(),
                         lists:keyfind(N, 1, Added) == false),
            oneof([{E, non_blank_string()} | Added])),
       U /= duplicate).

maybe_a_resource(#state{resources = Rs}, UUID) ->
    ?LET(Existing,
         case lists:keyfind(UUID, 1, Rs) of
             {UUID, Res} ->
                 oneof([R || {R, _} <- Res]);
             _ ->
                 non_blank_string()
         end,
         oneof([Existing, non_blank_string()])).

initial_state() ->
    random:seed(erlang:timestamp()),
    #state{}.

prop_compare_org_to_model() ->
    ?SETUP(fun setup/0,
    ?FORALL(Cmds,commands(?MODULE),
            begin
                {H,S,Res} = run_commands(?MODULE,Cmds),
                cleanup(),
                ?WHENFAIL(
                   io:format(user, "History: ~p\nState: ~p\nRes: ~p\n", [H,S,Res]),
                   Res == ok)
            end)).

cleanup() ->
    delete().

resource_actions() ->
    oneof([create, destroy, change]).

name() ->
    oneof([a, b, c, d, e, f, g]).


command(S) ->
    oneof([
           {call, ?M, add, [S#state.next_uuid, non_blank_string()]},
           {call, ?M, delete, [maybe_a_uuid(S)]},
           {call, ?M, wipe, [maybe_a_uuid(S)]},
           {call, ?M, get, [maybe_a_uuid(S)]},
           {call, ?M, lookup, [maybe_a_uuid(S)]},
           %{call, ?M, lookup_, [maybe_a_uuid(S)]},
           {call, ?M, raw, [maybe_a_uuid(S)]},

           %% List
           {call, ?O, list, [?REALM]},
           {call, ?O, list, [?REALM, [], bool()]},
           %{call, ?O, list_, [?REALM]},

           %% This is accounting now
           %% ?LET(UUID, maybe_a_uuid(S),
           %%      {call, ?M, resource_action,
           %%       [UUID, maybe_a_resource(S, UUID), choose(0, 10000),
           %%        resource_actions(),list({name(), non_blank_string()})]}),

           %% Metadata
           {call, ?M, set_metadata, [maybe_a_uuid(S), metadata_kvs()]},

           %% Meta command
           {call, ?M, handoff_handon, []}
          ]).

handoff_handon() ->
    Data = handoff(),
    delete(),
    handon(Data).

%% Normal auth takes a name.
auth({N, _}, P) ->
    ?O:auth(?REALM, N, P, <<>>).

add(UUID, Org) ->
    meck:new(fifo_utils, [passthrough]),
    meck:expect(fifo_utils, uuid, fun(org) -> UUID end),
    R = case ?O:add(?REALM, Org) of
            duplicate ->
                duplicate;
            {ok, UUID} ->
                {Org, UUID}
        end,
    meck:unload(fifo_utils),
    R.


resource_action({_, UUID}, Res, Timee, Action, Opts) ->
    ?O:resource_action(?REALM, UUID, Res, Timee, Action, Opts).

handoff_delete_handin() ->
    ok.

?FWD(get).
?FWD(raw).

lookup({N, _}) ->
    ?O:lookup(?REALM, N).

lookup_({N, _}) ->
    ?O:lookup_(?REALM, N).

?FWD(delete).
?FWD(wipe).

?FWD2(set_metadata).

next_state(S, duplicate, {call, _, add, [_, _Org]}) ->
    S#state{next_uuid=fifo_utils:uuid()};

next_state(S = #state{added = Added}, V, {call, _, add, [_, _Org]}) ->
    S#state{added = [V | Added], next_uuid=fifo_utils:uuid()};

next_state(S, _V, {call, _, delete, [UUIDAndName]}) ->
    S#state{added = lists:delete(UUIDAndName,  S#state.added)};

next_state(S, _V, {call, _, wipe, [UUIDAndName]}) ->
    S#state{added = lists:delete(UUIDAndName,  S#state.added)};

next_state(S, _, {call, _, set_metadata, [UU, KVs]}) ->
    lists:foldl(fun({K, V}, SAcc) ->
                        do_metadata(SAcc, UU, K, V)
               end, S, KVs);

next_state(S, _V, _C) ->
    S.

do_metadata(S = #state{metadata=Ms}, UUID, K, V) ->
    case has_uuid(S, UUID) of
        false ->
            S;
        true ->
            case lists:keyfind(UUID, 1, Ms) of
                {UUID, M} ->
                    Ms1 = proplists:delete(UUID, Ms),
                    Ms2 = case V of
                              delete ->
                                  [{UUID, orddict:erase(K, M)} | Ms1];
                              _ ->
                                  [{UUID, orddict:store(K, V, M)} | Ms1]
                          end,
                    S#state{metadata = Ms2};
                _  ->
                    case V of
                        delete ->
                            S;
                        _ ->
                            S#state{metadata = [{UUID, [{K, V}]} | Ms]}
                    end
            end
    end.
dynamic_precondition(S, {call,snarl_org_eqc, lookup, [{Name, UUID}]}) ->
    case lists:keyfind(Name, 1, S#state.added) of
        false ->
            true;
        {Name, UUID} ->
            true;
        {Name, _} ->
            false
    end;

dynamic_precondition(_S, {call, _, _, Args}) ->
    not lists:member(duplicate, Args);

dynamic_precondition(_, _) ->
    true.

precondition(_S, _) ->
    true.

%% Metadata
postcondition(S, {call, _, set_metadata, [{_, UUID}, _]}, not_found) ->
    not has_uuid(S, UUID);

postcondition(S, {call, _, set_metadata, [{_, UUID}, _]}, ok) ->
    has_uuid(S, UUID);

postcondition(S, {call, _, resource_action, [{_, UUID} | _]}, not_found) ->
    not has_uuid(S, UUID);

postcondition(S, {call, _, resource_action, [{_, UUID} | _]}, ok) ->
    has_uuid(S, UUID);

%% List

postcondition(#state{added = A}, {call, _, list, [?REALM]}, {ok, R}) ->
    lists:usort([U || {_, U} <- A]) == lists:usort(R);

postcondition(#state{added = A}, {call, _, list, [?REALM, _, true]}, {ok, R}) ->
    lists:usort([U || {_, U} <- A]) == lists:usort([ft_org:uuid(O) || {_, O} <- R]);

postcondition(#state{added = A}, {call, _, list, [?REALM, _, false]}, {ok, R}) ->
    lists:usort([U || {_, U} <- A]) == lists:usort([UUID || {_, UUID} <- R]);

postcondition(#state{added = A}, {call, _, list_, [?REALM]}, {ok, R}) ->
    lists:usort([U || {_, U} <- A]) ==
        lists:usort([UUID || {UUID, _} <- R]);

%% General
postcondition(S, {call, _, get, [{_, UUID}]}, not_found) ->
    not has_uuid(S, UUID);

postcondition(S, {call, _, get, [{_, UUID}]}, {ok, _U}) ->
    has_uuid(S, UUID);

postcondition(S, {call, _, lookup, [{_, UUID}]}, not_found) ->
    not has_uuid(S, UUID);

postcondition(S, {call, _, lookup, [{_, UUID}]}, {ok, Result}) ->
    UUID == ft_org:uuid(Result) andalso has_uuid(S, UUID);

postcondition(S, {call, _, raw, [{_, UUID}]}, not_found) ->
    not has_uuid(S, UUID);

postcondition(S, {call, _, raw, [{_, UUID}]}, {ok, _}) ->
    has_uuid(S, UUID);

postcondition(S, {call, _, add, [_UUID, Org]}, duplicate) ->
    has_org(S, Org);

postcondition(#state{added=_Us}, {call, _, add, [_Org, _]}, {error, _}) ->
    false;

postcondition(#state{added=_Us}, {call, _, add, [_Org, _]}, _) ->
    true;

postcondition(#state{added=_Us}, {call, _, delete, [{_, _UUID}]}, ok) ->
    true;

postcondition(#state{added=_Us}, {call, _, wipe, [{_, _UUID}]}, {ok, _}) ->
    true;

postcondition(_S, {call, _, handoff_handon, []}, _) ->
    true;

postcondition(_S, C, R) ->
    io:format(user, "postcondition(_, ~p, ~p).~n", [C, R]),
    false.

metadata_match(S, UUID, U) ->
    Ks = ft_org:metadata(U),
    Ks == known_metadata(S, UUID).

known_metadata(#state{metadata=Ms}, UUID) ->
    case lists:keyfind(UUID, 1, Ms) of
        {UUID, M} ->
            M;
        _ ->
            []
    end.
has_uuid(#state{added = A}, UUID) ->
    case lists:keyfind(UUID, 2, A) of
        {_, UUID} ->
            true;
        _ ->
            false
    end.

has_org(#state{added = A}, Org) ->
    case lists:keyfind(Org, 1, A) of
        {Org, _} ->
            true;
        _ ->
            false
    end.

%% We kind of have to start a lot of services for this tests :(
setup() ->
    start_mock_servers(),
    mock_vnode(snarl_org_vnode, [0]),

    meck:new(snarl_role, [passthrough]),
    meck:expect(snarl_role, revoke_prefix, fun(?REALM, _, _) -> ok end),
    meck:expect(snarl_role, list, fun(?REALM) -> {ok, []} end),
    meck:expect(snarl_role, get, fun(?REALM, _) -> {ok, dummy} end),

    meck:new(fifo_opt, [passthrough]),
    meck:expect(fifo_opt, get, fun(_,_,_,_,_,D) -> D end),
    meck:expect(fifo_opt, set, fun(_,_,_) ->ok end),

    fun() ->
            cleanup_mock_servers(),
            meck:unload(fifo_opt),
            meck:unload(snarl_role),
            ok
    end.

-endif.
-endif.
