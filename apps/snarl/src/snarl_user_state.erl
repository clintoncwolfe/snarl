%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 23 Aug 2012 by Heinz Nikolaus Gies <heinz@licenser.net>

-module(snarl_user_state).

-include("snarl.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([new/1,
         load/2,
         uuid/1, uuid/3,
         name/1, name/3,
         password/1, password/3,
         permissions/1, grant/3, revoke/3, revoke_prefix/3,
         groups/1, join/3, leave/3,
         join_org/3, leave_org/3, select_org/3, orgs/1, active_org/1,
         add_key/4, revoke_key/3, keys/1,
         metadata/1, set_metadata/4,
         add_yubikey/3, yubikeys/1, remove_yubikey/3,
         merge/2,
         to_json/1,
         is_a/1
        ]).

-export_type([user/0, any_user/0]).

-ignore_xref([
              new/0,
              load/1,
              uuid/1, uuid/3,
              name/1, name/3,
              password/1, password/3,
              permissions/1, grant/3, revoke/3, revoke_prefix/3,
              groups/1, join/3, leave/3,
              add_key/4, revoke_key/3, keys/1,
              metadata/1, set_metadata/4,
              join_org/3, leave_org/3, select_org/3, orgs/1, active_org/1,
              add_yubikey/3, yubikeys/1, remove_yubikey/3,
              merge/2,
              to_json/1
             ]).

-type user() :: #?USER{}.

-type any_user() :: user() |
                    #user_0_1_4{} |
                    #user_0_1_3{} |
                    #user_0_1_2{} |
                    #user_0_1_1{} |
                    #user_0_1_0{} |
                    statebox:statebox().

is_a(#?USER{}) ->
    true;
is_a(_) ->
    false.


-spec load({atom(), integer()}, any_user()) ->
                  user().

load(_, #?USER{} = User) ->
    User;

load({_, _},
     #user_0_1_3{
            uuid = UUID1,
            name = Name1,
            password = Passwd1,
            active_org = ActiveOrg1,
            permissions = Permissions1,
            groups = Groups1,
            ssh_keys = Keys1,
            orgs = Orgs1,
            metadata = Metadata1
           }) ->
    #user_0_1_4{
       uuid = UUID1,
       name = Name1,
       password = Passwd1,
       active_org = ActiveOrg1,
       permissions = Permissions1,
       groups = Groups1,
       ssh_keys = Keys1,
       orgs = Orgs1,
       yubikeys = riak_dt_orswot:new(),
       metadata = Metadata1
      };

load({T, ID},
     #user_0_1_2{
        uuid = UUID,
        name = Name,
        password = Passwd,
        permissions = Permissions,
        active_org = ActiveOrg,
        groups = Groups,
        ssh_keys = Keys,
        orgs = Orgs,
        metadata = Metadata}) ->
    {ok, UUID1} = ?NEW_LWW(vlwwregister:value(UUID), T),
    {ok, Name1} = ?NEW_LWW(vlwwregister:value(Name), T),
    {ok, Passwd1} = ?NEW_LWW(vlwwregister:value(Passwd), T),
    {ok, ActiveOrg1} = ?NEW_LWW(vlwwregister:value(ActiveOrg), T),
    {ok, Permissions1} = ?CONVERT_VORSET(Permissions),
    {ok, Groups1} = ?CONVERT_VORSET(Groups),
    {ok, Keys1} = ?CONVERT_VORSET(Keys),
    {ok, Orgs1} = ?CONVERT_VORSET(Orgs),
    Metadata1 = snarl_map:from_orddict(statebox:value(Metadata), ID, T),
    load({T, ID},
         #user_0_1_3{
            uuid = UUID1,
            name = Name1,
            password = Passwd1,
            active_org = ActiveOrg1,
            permissions = Permissions1,
            groups = Groups1,
            ssh_keys = Keys1,
            orgs = Orgs1,
            metadata = Metadata1
           });

load(CT,
     #user_0_1_1{
        uuid = UUID,
        name = Name,
        password = Passwd,
        permissions = Permissions,
        groups = Groups,
        ssh_keys = Keys,
        metadata = Metadata
       }) ->
    Size = ?ENV(user_bucket_size, 50),
    load(CT,
         #user_0_1_2{
            uuid = UUID,
            name = Name,
            password = Passwd,
            permissions = Permissions,
            active_org = vlwwregister:new(<<"">>),
            groups = Groups,
            ssh_keys = Keys,
            orgs = vorsetg:new(Size),
            metadata = Metadata
           });

load(CT,
     #user_0_1_0{
        uuid = UUID,
        name = Name,
        password = Passwd,
        permissions = Permissions,
        groups = Groups,
        metadata = Metadata
       }) ->
    Size = ?ENV(user_bucket_size, 50),
    load(CT,
         #user_0_1_1{
            uuid = UUID,
            name = Name,
            password = Passwd,
            permissions = Permissions,
            groups = Groups,
            ssh_keys = vorsetg:new(Size),
            metadata = Metadata});

load(CT, UserSB) ->
    Size = ?ENV(user_bucket_size, 50),
    User = statebox:value(UserSB),
    {ok, Name} = jsxd:get([<<"name">>], User),
    {ok, UUID} = jsxd:get([<<"uuid">>], User),
    Password = jsxd:get([<<"password">>], <<>>, User),
    ID0 = {{0,0,0}, load},
    Groups0 = jsxd:get([<<"groups">>], [], User),
    Permissions0 = jsxd:get([<<"permissions">>], [], User),
    Metadata = jsxd:get([<<"metadata">>], [], User),
    Groups = lists:foldl(
               fun (G, Acc) ->
                       vorsetg:add(ID0, G, Acc)
               end, vorsetg:new(Size), Groups0),
    Permissions = lists:foldl(
                    fun (G, Acc) ->
                            vorsetg:add(ID0, G, Acc)
                    end, vorsetg:new(Size), Permissions0),
    load(CT,
         #user_0_1_0{
            uuid = vlwwregister:new(UUID),
            name = vlwwregister:new(Name),
            password = vlwwregister:new(Password),
            groups = Groups,
            permissions = Permissions,
            metadata = statebox:new(fun() -> Metadata end)}).

new({T, _ID}) ->
    {ok, UUID} = ?NEW_LWW(<<>>, T),
    {ok, Name} = ?NEW_LWW(<<>>, T),
    {ok, Passwd} = ?NEW_LWW(<<>>, T),
    {ok, ActiveOrg} = ?NEW_LWW(<<>>, T),
    #?USER{
        uuid = UUID,
        name = Name,
        password = Passwd,
        active_org = ActiveOrg,
        groups = riak_dt_orswot:new(),
        permissions = riak_dt_orswot:new(),
        yubikeys = riak_dt_orswot:new(),
        ssh_keys = riak_dt_orswot:new(),
        orgs = riak_dt_orswot:new(),
        metadata = snarl_map:new()
       }.

to_json(#?USER{
            uuid = UUID,
            name = Name,
            groups = Groups,
            ssh_keys = Keys,
            permissions = Permissions,
            active_org = Org,
            orgs = Orgs,
            yubikeys = YubiKeys,
            metadata = Metadata
           }) ->
    jsxd:from_list(
      [
       {<<"uuid">>, riak_dt_lwwreg:value(UUID)},
       {<<"name">>, riak_dt_lwwreg:value(Name)},
       {<<"groups">>, riak_dt_orswot:value(Groups)},
       {<<"permissions">>, riak_dt_orswot:value(Permissions)},
       {<<"yubikeys">>, riak_dt_orswot:value(YubiKeys)},
       {<<"keys">>, riak_dt_orswot:value(Keys)},
       {<<"org">>, riak_dt_lwwreg:value(Org)},
       {<<"orgs">>, riak_dt_orswot:value(Orgs)},
       {<<"metadata">>, snarl_map:value(Metadata)}
      ]).

merge(#?USER{
          uuid = UUID1,
          name = Name1,
          password = Password1,
          groups = Groups1,
          permissions = Permissions1,
          ssh_keys = Keys1,
          active_org = Org1,
          orgs = Orgs1,
          yubikeys = YubiKeys1,
          metadata = Metadata1
         },
      #?USER{
          uuid = UUID2,
          name = Name2,
          password = Password2,
          groups = Groups2,
          permissions = Permissions2,
          ssh_keys = Keys2,
          active_org = Org2,
          orgs = Orgs2,
          yubikeys = YubiKeys2,
          metadata = Metadata2
         }) ->
    #?USER{
        uuid = riak_dt_lwwreg:merge(UUID1, UUID2),
        name = riak_dt_lwwreg:merge(Name1, Name2),
        password = riak_dt_lwwreg:merge(Password1, Password2),
        active_org = riak_dt_lwwreg:merge(Org1, Org2),
        groups = riak_dt_orswot:merge(Groups1, Groups2),
        ssh_keys = riak_dt_orswot:merge(Keys1, Keys2),
        yubikeys = riak_dt_orswot:merge(YubiKeys1, YubiKeys2),
        permissions = riak_dt_orswot:merge(Permissions1, Permissions2),
        orgs = riak_dt_orswot:merge(Orgs1, Orgs2),
        metadata = snarl_map:merge(Metadata1, Metadata2)
       }.

join_org({_T, ID}, Org, User) ->
    {ok, O1} = riak_dt_orswot:update({add, Org}, ID, User#?USER.orgs),
    User#?USER{orgs = O1}.

leave_org({_T, ID}, Org, User) ->
    {ok, O1} = riak_dt_orswot:update({remove, Org}, ID, User#?USER.orgs),
    User#?USER{orgs = O1}.

select_org({T, _ID}, Org, User) ->
    {ok, O1} = riak_dt_lwwreg:update({assign, Org, T}, none, User#?USER.active_org),
    User#?USER{active_org = O1}.

orgs(User) ->
    riak_dt_orswot:value(User#?USER.orgs).

active_org(User) ->
    riak_dt_lwwreg:value(User#?USER.active_org).

add_key({_T, ID}, KeyID, Key, User) ->
    {ok, S1} = riak_dt_orswot:update({add, {KeyID, Key}}, ID, User#?USER.ssh_keys),
    User#?USER{ssh_keys = S1}.

revoke_key({_T, ID}, KeyID, User) ->
    case lists:keyfind(KeyID, 1, keys(User)) of
        false ->
            User;
        Tpl ->
            {ok, S1} = riak_dt_orswot:update({remove, Tpl}, ID,
                                             User#?USER.ssh_keys),
            User#?USER{ssh_keys = S1}
    end.

keys(User) ->
    riak_dt_orswot:value(User#?USER.ssh_keys).

add_yubikey({_T, ID}, KeyID, User) ->
    {ok, S1} = riak_dt_orswot:update({add, KeyID}, ID, User#?USER.yubikeys),
    User#?USER{yubikeys = S1}.

remove_yubikey({_T, ID}, KeyID, User) ->
    {ok, S1} = riak_dt_orswot:update({remove, KeyID}, ID, User#?USER.yubikeys),
    User#?USER{yubikeys = S1}.

yubikeys(User) ->
    riak_dt_orswot:value(User#?USER.yubikeys).

name(User) ->
    riak_dt_lwwreg:value(User#?USER.name).

name({T, _ID}, Name, User) ->
    {ok, Name1} = riak_dt_lwwreg:update({assign, Name, T}, none, User#?USER.name),
    User#?USER{name = Name1}.

uuid(User) ->
    riak_dt_lwwreg:value(User#?USER.uuid).

uuid({T, _ID}, UUID, User) ->
    {ok, UUID1} = riak_dt_lwwreg:update({assign, UUID, T}, none, User#?USER.uuid),
    User#?USER{uuid = UUID1}.

password(User) ->
    riak_dt_lwwreg:value(User#?USER.password).

password({T, _ID}, Hash, User) ->
    {ok, PWD1} = riak_dt_lwwreg:update({assign, Hash, T}, none, User#?USER.password),
    User#?USER{password = PWD1}.

permissions(User) ->
    riak_dt_orswot:value(User#?USER.permissions).

grant({_T, ID}, P, User) ->
    {ok, P1} = riak_dt_orswot:update({add, P}, ID, User#?USER.permissions),
    User#?USER{permissions = P1}.


revoke({_T, ID}, P, User) ->
    {ok, P1} = riak_dt_orswot:update({remove, P}, ID, User#?USER.permissions),
    User#?USER{permissions = P1}.

revoke_prefix({_T, ID}, Prefix, User) ->
    P0 = User#?USER.permissions,
    Ps = permissions(User),
    P1 = lists:foldl(fun (P, PAcc) ->
                             case lists:prefix(Prefix, P) of
                                 true ->
                                     {ok, R} = riak_dt_orswot:update(
                                                 {remove, P}, ID, PAcc),
                                     R;
                                 _ ->
                                     PAcc
                             end
                     end, P0, Ps),
    User#?USER{
            permissions = P1
           }.

groups(User) ->
    riak_dt_orswot:value(User#?USER.groups).


join({_T, ID}, Group, User) ->
    {ok, G} = riak_dt_orswot:update({add, Group}, ID, User#?USER.groups),
    User#?USER{groups = G}.

leave({_T, ID}, Group, User) ->
    {ok, G} = riak_dt_orswot:update({remove, Group}, ID, User#?USER.groups),
    User#?USER{groups = G}.

metadata(User) ->
    User#?USER.metadata.

set_metadata({T, ID}, P, Value, User) when is_binary(P) ->
    set_metadata({T, ID}, snarl_map:split_path(P), Value, User);

set_metadata({_T, ID}, Attribute, delete, User) ->
    {ok, M1} = snarl_map:remove(Attribute, ID, User#?USER.metadata),
    User#?USER{metadata = M1};

set_metadata({T, ID}, Attribute, Value, User) ->
    {ok, M1} = snarl_map:set(Attribute, Value, ID, T, User#?USER.metadata),
    User#?USER{metadata = M1}.

-ifdef(TEST).

mkid() ->
    {ecrdt:timestamp_us(), test}.

to_json_test() ->
    User = new(mkid()),
    UserJ = [{<<"groups">>, []},
             {<<"keys">>, []},
             {<<"metadata">>, []},
             {<<"name">>, <<>>},
             {<<"org">>, <<>>},
             {<<"orgs">>, []},
             {<<"permissions">>, []},
             {<<"uuid">>, <<>> },
             {<<"yubikeys">>, []}],
    ?assertEqual(UserJ, to_json(User)).

name_test() ->
    Name0 = <<"Test0">>,
    User0 = new(mkid()),
    User1 = name(mkid(), Name0, User0),
    Name1 = <<"Test1">>,
    User2 = name(mkid(), Name1, User1),
    ?assertEqual(Name0, name(User1)),
    ?assertEqual(Name1, name(User2)).

yubikey_test() ->
    Key = <<"Test0">>,
    User0 = new(mkid()),
    User1 = add_yubikey(mkid(), Key, User0),
    ?assertEqual([<<"Test0">>], yubikeys(User1)).

password_test() ->
    Name = "Test",
    Password = "Test",
    User0 = new(mkid()),
    User1 = name(mkid(), Name, User0),
    User2 = password(mkid(), Password, User1),
    ?assertEqual(Password, password(User2)).

permissions_test() ->
    P0 = [<<"P0">>],
    P1 = [<<"P1">>],
    User0 = new(mkid()),
    User1 = grant(mkid(), P0, User0),
    User2 = grant(mkid(), P1, User1),
    User3 = grant(mkid(), P0, User2),
    User4 = revoke(mkid(), P0, User3),
    User5 = revoke(mkid(), P1, User3),
    ?assertEqual([P0], permissions(User1)),
    ?assertEqual([P0, P1], permissions(User2)),
    ?assertEqual([P0, P1], permissions(User3)),
    ?assertEqual([P1], permissions(User4)),
    ?assertEqual([P0], permissions(User5)).

groups_test() ->
    G0 = "G0",
    G1 = "G1",
    User0 = new(mkid()),
    User1 = join(mkid(), G0, User0),
    User2 = join(mkid(), G1, User1),
    User3 = join(mkid(), G0, User2),
    User4 = leave(mkid(), G0, User3),
    User5 = leave(mkid(), G1, User3),
    ?assertEqual([G0], groups(User1)),
    ?assertEqual([G0, G1], groups(User2)),
    ?assertEqual([G0, G1], groups(User3)),
    ?assertEqual([G1], groups(User4)),
    ?assertEqual([G0], groups(User5)).

-endif.
