-module(snarl_zmq_handler).

-export([init/1, message/2]).

init([]) ->
    {ok, stateless}.

%%%===================================================================
%%% User Functions
%%%===================================================================

message({user, list}, State) ->
    {reply, snarl_user:list(), State};

message({user, get, User}, State) ->
    {reply,
     snarl_user:get(ensure_binary(User)),
     State};

message({user, add, User}, State) ->
    {reply,
     snarl_user:add(ensure_binary(User)),
     State};

message({user, auth, User, Pass}, State) ->
    {reply,
     snarl_user:auth(ensure_binary(User), ensure_binary(Pass)),
     State};

message({user, allowed, User, Permission}, State) ->
    {reply, 
     snarl_user:allowed(ensure_binary(User), Permission),
     State};

message({user, delete, User}, State) ->
    {reply, 
     snarl_user:delete(ensure_binary(User)), 
     State};

message({user, passwd, User, Pass}, State) ->
    {reply, 
     snarl_user:passwd(ensure_binary(User), ensure_binary(Pass)),
     State};

message({user, join, User, Group}, State) ->
    {reply, snarl_user:join(ensure_binary(User), Group), State};

message({user, leave, User, Group}, State) ->
    {reply, snarl_user:leave(ensure_binary(User), Group), State};

message({user, grant, User, Permission}, State) ->
    {reply, snarl_user:grant(ensure_binary(User), Permission), State};

message({user, revoke, User, Permission}, State) ->
    {reply, snarl_user:grant(ensure_binary(User), Permission), State};

%%%===================================================================
%%% Group Functions
%%%===================================================================

message({group, list}, State) ->
    {reply, snarl_group:list(), State};

message({group, get, Group}, State) ->
    {reply, snarl_group:get(ensure_binary(Group)), State};

message({group, add, Group}, State) ->
    {reply, snarl_group:add(ensure_binary(Group)), State};

message({group, delete, Group}, State) ->
    {reply, snarl_group:delete(ensure_binary(Group)), State};

message({group, grant, Group, Permission}, State) ->
    {reply, snarl_group:grant(ensure_binary(Group), Permission), State};

message({group, revoke, Group, Permission}, State) ->
    {reply, snarl_group:grant(ensure_binary(Group), Permission), State};

message(Message, State) ->
    io:format("Unsuppored 0MQ message: ~p", [Message]),
    {noreply, State}.

ensure_binary(A) when is_atom(A) ->
    list_to_binary(atom_to_list(A));
ensure_binary(L) when is_list(L) ->
    list_to_binary(L);
ensure_binary(B) when is_binary(B)->
    B;
ensure_binary(I) when is_integer(I) ->
    list_to_binary(integer_to_list(I));
ensure_binary(F) when is_float(F) ->
    list_to_binary(float_to_list(F));
ensure_binary(T) ->
    term_to_binary(T).
