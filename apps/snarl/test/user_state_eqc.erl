-module(user_state_eqc).

-ifdef(TEST).
-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").
-compile(export_all).

-define(U, snarl_user_state).
%% This is larger then and time we ever get in the size, used for ensure setting data
%% in LWW registers.
-define(BIG_TIME, 1000000000).
id(T) ->
    {T, eqc}.

permission() ->
    ?SIZED(Size, permission(Size)).

permission(Size) ->
    ?LAZY(oneof([[oneof([<<"...">>, perm_entry()])] || Size == 0] ++
                    [[perm_entry() | permission(Size -1)] || Size > 0])).

perm_entry() ->
    oneof([<<"_">>, bin_str()]).

bin_str() ->
    ?LET(S, ?SUCHTHAT(L, list(choose($a, $z)), L =/= []), list_to_binary(S)).

existing_permission(U) ->
    oneof(permissions(model(U))).

existing_org(U) ->
    oneof(orgs(model(U))).

existing_role(U) ->
    oneof(roles(model(U))).

existing_yubikey(U) ->
    oneof(yubikeys(model(U))).

user() ->
    ?SIZED(Size, user(Size)).

user(Size) ->
    ?LAZY(oneof([{call, ?U, new, [id(Size)]} || Size == 0] ++
                    [?LETSHRINK(
                        [U], [user(Size - 1)],
                        oneof([
                               {call, ?U, load, [id(Size), U]},
                               {call, ?U, uuid, [id(Size), bin_str(), U]},
                               {call, ?U, add_key, [id(Size), bin_str(), bin_str(), U]},
                               {call, ?U, add_yubikey, [id(Size), bin_str(), U]},
                               {call, ?U, join, [id(Size), bin_str(), U]},
                               {call, ?U, join_org, [id(Size), bin_str(), U]},
                               {call, ?U, grant, [id(Size), permission(), U]},
                               {call, ?U, password, [id(Size), bin_str(), U]},
                               {call, ?U, name, [id(Size), bin_str(), U]},
                               {call, ?U, set_metadata, [id(Size), bin_str(), bin_str(), U]}
                              ] ++
                                  [{call, ?U, revoke_key, [id(Size), oneof(calc_keys(U)), U]}
                                   || calc_keys(U) =/= []] ++
                                  [{call, ?U, set_metadata, [id(Size), oneof(calc_metadata(U)), delete, U]}
                                   || calc_metadata(U) =/= []] ++
                                  [{call, ?U, remove_yubikey, [id(Size), oneof(calc_yubikeys(U)), U]}
                                   || calc_yubikeys(U) =/= []] ++
                                  [{call, ?U, leave, [id(Size), oneof(calc_roles(U)), U]}
                                   || calc_roles(U) =/= []] ++
                                  [{call, ?U, leave_org, [id(Size), oneof(calc_orgs(U)), U]}
                                   || calc_orgs(U) =/= []] ++
                                  [{call, ?U, revoke, [id(Size), oneof(calc_perms(U)), U]}
                                   || calc_perms(U) =/= []]))
                     || Size > 0])).

calc_yubikeys({call, _, add_yubikey, [_, K, U]}) ->
    [K | calc_yubikeys(U)];
calc_yubikeys({call, _, remove_yubikey, [_, K, U]}) ->
    lists:delete(K, lists:usort(calc_yubikeys(U)));
calc_yubikeys({call, _, _, P}) ->
    calc_yubikeys(lists:last(P));
calc_yubikeys(_) ->
    [].

calc_keys({call, _, add_key, [_, I, _K, U]}) ->
    [I | calc_keys(U)];
calc_keys({call, _, revoke_key, [_, K, U]}) ->
    lists:delete(K, lists:usort(calc_keys(U)));
calc_keys({call, _, _, P}) ->
    calc_keys(lists:last(P));
calc_keys(_) ->
    [].

calc_metadata({call, _, set_metadata, [_, delete, K, U]}) ->
    lists:delete(K, lists:usort(calc_metadata(U)));
calc_metadata({call, _, set_metadata, [_, I, _K, U]}) ->
    [I | calc_metadata(U)];
calc_metadata({call, _, _, P}) ->
    calc_metadata(lists:last(P));
calc_metadata(_) ->
    [].

calc_roles({call, _, join, [_, K, U]}) ->
    [K | calc_roles(U)];
calc_roles({call, _, leave, [_, K, U]}) ->
    lists:delete(K, lists:usort(calc_roles(U)));
calc_roles({call, _, _, P}) ->
    calc_roles(lists:last(P));
calc_roles(_) ->
    [].

calc_orgs({call, _, join_org, [_, K, U]}) ->
    [K | calc_orgs(U)];
calc_orgs({call, _, leave_org, [_, K, U]}) ->
    lists:delete(K, lists:usort(calc_orgs(U)));
calc_orgs({call, _, _, P}) ->
    calc_orgs(lists:last(P));
calc_orgs(_) ->
    [].

calc_perms({call, _, grant, [_, P, U]}) ->
    [P | calc_perms(U)];
calc_perms({call, _, revoke, [_, P, U]}) ->
    lists:delete(P, lists:usort(calc_perms(U)));
calc_perms({call, _, _, P}) ->
    calc_perms(lists:last(P));
calc_perms(_) ->
    [].

r(K, V, U) ->
    lists:keystore(K, 1, U, {K, V}).

model(U) ->
    lists:sort([{<<"password">>, ?U:password(U)} | ?U:to_json(U)]).

model_uuid(N, U) ->
    r(<<"uuid">>, N, U).

model_name(N, U) ->
    r(<<"name">>, N, U).

model_password(N, U) ->
    r(<<"password">>, N, U).

model_revoke(P, U) ->
    r(<<"permissions">>, lists:delete(P, permissions(U)), U).

model_grant(P, U) ->
    r(<<"permissions">>, lists:usort([P | permissions(U)]), U).

model_set_metadata(K, V, U) ->
    r(<<"metadata">>, lists:usort(r(K, V, metadata(U))), U).

model_delete_metadata(K, U) ->
    r(<<"metadata">>, lists:keydelete(K, 1, metadata(U)), U).

model_leave_org(P, U) ->
    r(<<"orgs">>, lists:delete(P, orgs(U)), U).

model_join_org(P, U) ->
    r(<<"orgs">>, lists:usort([P | orgs(U)]), U).

model_leave_role(P, U) ->
    r(<<"roles">>, lists:delete(P, roles(U)), U).

model_add_role(P, U) ->
    r(<<"roles">>, lists:usort([P | roles(U)]), U).

model_add_key(I, K, U) ->
    r(<<"keys">>, lists:usort([{I, K} | keys(U)]), U).

model_revoke_key(I, U) ->
    r(<<"keys">>, lists:keydelete(I, 1, keys(U)), U).

model_add_yubikey(K, U) ->
    r(<<"yubikeys">>, lists:usort([K | yubikeys(U)]), U).

model_remove_yubikey(P, U) ->
    r(<<"yubikeys">>, lists:delete(P, yubikeys(U)), U).

permissions(U) ->
    {<<"permissions">>, Ps} = lists:keyfind(<<"permissions">>, 1, U),
    Ps.

roles(U) ->
    {<<"roles">>, Ps} = lists:keyfind(<<"roles">>, 1, U),
    Ps.

orgs(U) ->
    {<<"orgs">>, Ps} = lists:keyfind(<<"orgs">>, 1, U),
    Ps.

yubikeys(U) ->
    {<<"yubikeys">>, Ps} = lists:keyfind(<<"yubikeys">>, 1, U),
    Ps.

keys(U) ->
    {<<"keys">>, Ps} = lists:keyfind(<<"keys">>, 1, U),
    Ps.

metadata(U) ->
    {<<"metadata">>, M} = lists:keyfind(<<"metadata">>, 1, U),
    M.

has_permissions(U) ->
    ?U:permissions(U) =/= [].

has_orgs(U) ->
    ?U:orgs(U) =/= [].

has_roles(U) ->
    ?U:roles(U) =/= [].

has_yubikeys(U) ->
    ?U:yubikeys(U) =/= [].

has_keys(U) ->
    ?U:keys(U) =/= [].

has_metadata(U) ->
    ?U:metadata(U) =/= [].

prop_name() ->
    ?FORALL({N,U},
            {bin_str(),user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~n", [U, User]),
                          model(?U:name(id(?BIG_TIME),N,User)) ==
                              model_name(N, model(User)))
            end).

prop_uuid() ->
    ?FORALL({N,U},
            {bin_str(),user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~n", [U, User]),
                          model(?U:uuid(id(?BIG_TIME),N,User)) ==
                              model_uuid(N, model(User)))
            end).

prop_password() ->
    ?FORALL({N,U},
            {bin_str(),user()},
            begin
                User = eval(U),
                U1 = ?U:password(id(?BIG_TIME),N,User),
                M1 = model_password(N, model(User)),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n"
                                    "User': ~p~nModel': ~p~n", [U, User, model(User), U1, M1]),
                          model(U1) == M1)
            end).

prop_grant() ->
    ?FORALL({P,U},
            {permission(),user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:grant(id(?BIG_TIME), P, User)) ==
                              model_grant(P, model(User)))
            end).

prop_add_role() ->
    ?FORALL({R,U},
            {bin_str(),user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:join(id(?BIG_TIME), R, User)) ==
                              model_add_role(R, model(User)))
            end).

prop_add_org() ->
    ?FORALL({O,U},
            {bin_str(),user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:join_org(id(?BIG_TIME), O, User)) ==
                              model_join_org(O, model(User)))
            end).


prop_add_yubikey() ->
    ?FORALL({K, U},
            {bin_str(), user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:add_yubikey(id(?BIG_TIME), K, User)) ==
                              model_add_yubikey(K, model(User)))
            end).

prop_add_key() ->
    ?FORALL({I, K, U},
            {bin_str(), bin_str(), user()},
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:add_key(id(?BIG_TIME), I, K, User)) ==
                              model_add_key(I, K, model(User)))
            end).

prop_revoke() ->
    ?FORALL({U, P}, ?LET(U, ?SUCHTHAT(T, user(), calc_perms(T) =/= []), {U, oneof(calc_perms(U))}),
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:revoke(id(?BIG_TIME), P, User)) ==
                              model_revoke(P, model(User)))
            end).

prop_set_metadata() ->
    ?FORALL({K, V, U}, {bin_str(), bin_str(), user()},
            begin
                User = eval(U),
                U1 = ?U:set_metadata(id(?BIG_TIME), K, V, User),
                M1 = model_set_metadata(K, V, model(User)),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n"
                                    "User': ~p~nModel': ~p~n", [U, User, model(User), U1, M1]),
                          model(U1) == M1)
            end).

prop_leave_org() ->
    ?FORALL({U, O}, ?LET(U, ?SUCHTHAT(T, user(), calc_orgs(T) =/= []), {U, oneof(calc_orgs(U))}),
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:leave_org(id(?BIG_TIME), O, User)) ==
                                             model_leave_org(O, model(User)))
            end).

prop_leave_role() ->
    ?FORALL({U, P}, ?LET(U, ?SUCHTHAT(T, user(), calc_roles(T) =/= []), {U, oneof(calc_roles(U))}),
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:leave(id(?BIG_TIME), P, User)) ==
                              model_leave_role(P, model(User)))
            end).

prop_remove_yubikey() ->
    ?FORALL({U, K}, ?LET(U, ?SUCHTHAT(T, user(), calc_yubikeys(T) =/= []), {U, oneof(calc_yubikeys(U))}),
            begin
                User = eval(U),
                U1 = ?U:remove_yubikey(id(?BIG_TIME), K, User),
                M1 = model_remove_yubikey(K, model(User)),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(U1) == M1)
            end).

prop_remove_key() ->
    ?FORALL({U, K}, ?LET(U, ?SUCHTHAT(T, user(), calc_keys(T) =/= []), {U, oneof(calc_keys(U))}),
            begin
                User = eval(U),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n", [U, User, model(User)]),
                          model(?U:revoke_key(id(?BIG_TIME), K, User)) ==
                              model_revoke_key(K, model(User)))
            end).

prop_remove_metadata() ->
    ?FORALL({U, K}, ?LET(U, ?SUCHTHAT(T, user(), calc_metadata(T) =/= []), {U, oneof(calc_metadata(U))}),
            begin
                User = eval(U),
                U1 = ?U:set_metadata(id(?BIG_TIME), K, delete, User),
                M1 = model_delete_metadata(K, model(User)),
                ?WHENFAIL(io:format(user, "History: ~p~nUser: ~p~nModel: ~p~n"
                                    "User': ~p~nModel': ~p~n", [U, User, model(User), U1, M1]),
                          model(U1) == M1)
            end).

-ifndef(EQC_NUM_TESTS).
-define(EQC_NUM_TESTS, 100).
-endif.
-include("eqc_helper.hrl").
-endif.
-endif.
