-module(ts_eldap).
%%% --------------------------------------------------------------------
%%% Created:  12 Oct 2000 by Tobbe <tnt@home.se>
%%% Function: Erlang client LDAP implementation according RFC 2251,2253
%%%           and 2255. The interface is based on RFC 1823, and
%%%           draft-ietf-asid-ldap-c-api-00.txt
%%% --------------------------------------------------------------------
-vc('$Id: eldap.erl,v 1.5 2006/11/24 09:38:11 etnt Exp $ ').
-export([open/1,open/2,simple_bind/3,controlling_process/2,
	 baseObject/0,singleLevel/0,wholeSubtree/0,close/1,
	 equalityMatch/2,greaterOrEqual/2,lessOrEqual/2,
	 approxMatch/2,search/2,substrings/2,present/1,
	 'and'/1,'or'/1,'not'/1,modify/3, mod_add/2, mod_delete/2,
	 mod_replace/2, add/3, delete/2, modify_dn/5,parse_dn/1,
	 parse_ldap_url/1]).

-import(lists,[concat/1]).

-include("ts_ELDAPv3.hrl").
-include("eldap.hrl").

-define(LDAP_VERSION, 3).
-define(LDAP_PORT, 389).
-define(LDAPS_PORT, 636).

-record(eldap, {version = ?LDAP_VERSION,
		host,                % Host running LDAP server
		port = ?LDAP_PORT,   % The LDAP server port
		fd,                  % Socket filedescriptor.
		binddn = "",         % Name of the entry to bind as
		passwd,              % Password for (above) entry
		id = 0,              % LDAP Request ID 
		log,                 % User provided log function
		timeout = infinity,  % Request timeout
		anon_auth = false,   % Allow anonymous authentication
		use_tls = false      % LDAP/LDAPS
	       }).

%%% For debug purposes
%%-define(PRINT(S, A), io:fwrite("~w(~w): " ++ S, [?MODULE,?LINE|A])).
-define(PRINT(S, A), true).

-define(elog(S, A), error_logger:info_msg("~w(~w): "++S,[?MODULE,?LINE|A])).

%%% ====================================================================
%%% Exported interface
%%% ====================================================================

%%% --------------------------------------------------------------------
%%% open(Hosts [,Opts] )
%%% --------------------
%%% Setup a connection to on of the Hosts in the argument
%%% list. Stop at the first successful connection attempt.
%%% Valid Opts are:      Where:
%%%
%%%    {port, Port}        - Port is the port number 
%%%    {log, F}            - F(LogLevel, FormatString, ListOfArgs)
%%%    {timeout, milliSec} - request timeout
%%%
%%% --------------------------------------------------------------------
open(Hosts) -> 
    open(Hosts, []).

open(Hosts, Opts) when list(Hosts), list(Opts) ->
    Self = self(),
    Pid = spawn_link(fun() -> init(Hosts, Opts, Self) end),
    recv(Pid).

%%% --------------------------------------------------------------------
%%% Shutdown connection (and process) asynchronous.
%%% --------------------------------------------------------------------

close(Handle) when pid(Handle) ->
    send(Handle, close).

%%% --------------------------------------------------------------------
%%% Set who we should link ourselves to
%%% --------------------------------------------------------------------

controlling_process(Handle, Pid) when pid(Handle),pid(Pid)  ->
    link(Pid),
    send(Handle, {cnt_proc, Pid}),
    recv(Handle).

%%% --------------------------------------------------------------------
%%% Authenticate ourselves to the Directory 
%%% using simple authentication.
%%%
%%%  Dn      -  The name of the entry to bind as
%%%  Passwd  -  The password to be used
%%%
%%%  Returns: ok | {error, Error}
%%% --------------------------------------------------------------------
simple_bind(Handle, Dn, Passwd) when pid(Handle)  ->
    send(Handle, {simple_bind, Dn, Passwd}),
    recv(Handle).

%%% --------------------------------------------------------------------
%%% Add an entry. The entry field MUST NOT exist for the AddRequest
%%% to succeed. The parent of the entry MUST exist.
%%% Example:
%%%
%%%  add(Handle, 
%%%         "cn=Bill Valentine, ou=people, o=Bluetail AB, dc=bluetail, dc=com",
%%%         [{"objectclass", ["person"]},
%%%          {"cn", ["Bill Valentine"]},
%%%          {"sn", ["Valentine"]},
%%%          {"telephoneNumber", ["545 555 00"]}]
%%%     )
%%% --------------------------------------------------------------------
add(Handle, Entry, Attributes) when pid(Handle),list(Entry),list(Attributes) ->
    send(Handle, {add, Entry, add_attrs(Attributes)}),
    recv(Handle).

%%% Do sanity check !
add_attrs(Attrs) ->
    F = fun({Type,Vals}) when list(Type),list(Vals) -> 
		%% Confused ? Me too... :-/
		{'AddRequest_attributes',Type, Vals} 
	end,
    case catch lists:map(F, Attrs) of
	{'EXIT', _} -> throw({error, attribute_values});
	Else        -> Else
    end.

%%% --------------------------------------------------------------------
%%% Delete an entry. The entry consists of the DN of 
%%% the entry to be deleted.
%%% Example:
%%%
%%%  delete(Handle, 
%%%         "cn=Bill Valentine, ou=people, o=Bluetail AB, dc=bluetail, dc=com"
%%%        )
%%% --------------------------------------------------------------------
delete(Handle, Entry) when pid(Handle), list(Entry) ->
    send(Handle, {delete, Entry}),
    recv(Handle).

%%% --------------------------------------------------------------------
%%% Modify an entry. Given an entry a number of modification
%%% operations can be performed as one atomic operation.
%%% Example:
%%%
%%%  modify(Handle, 
%%%         "cn=Torbjorn Tornkvist, ou=people, o=Bluetail AB, dc=bluetail, dc=com",
%%%         [replace("telephoneNumber", ["555 555 00"]),
%%%          add("description", ["LDAP hacker"])] 
%%%        )
%%% --------------------------------------------------------------------
modify(Handle, Object, Mods) when pid(Handle), list(Object), list(Mods) ->
    send(Handle, {modify, Object, Mods}),
    recv(Handle).

%%%
%%% Modification operations. 
%%% Example:
%%%            replace("telephoneNumber", ["555 555 00"])
%%%
mod_add(Type, Values) when list(Type), list(Values)     -> m(add, Type, Values).
mod_delete(Type, Values) when list(Type), list(Values)  -> m(delete, Type, Values).
mod_replace(Type, Values) when list(Type), list(Values) -> m(replace, Type, Values).

m(Operation, Type, Values) ->
    #'ModifyRequest_modification_SEQOF'{
       operation = Operation,
       modification = #'AttributeTypeAndValues'{
	 type = Type,
	 vals = Values}}.

%%% --------------------------------------------------------------------
%%% Modify an entry. Given an entry a number of modification
%%% operations can be performed as one atomic operation.
%%% Example:
%%%
%%%  modify_dn(Handle, 
%%%    "cn=Bill Valentine, ou=people, o=Bluetail AB, dc=bluetail, dc=com",
%%%    "cn=Ben Emerson",
%%%    true,
%%%    ""
%%%        )
%%% --------------------------------------------------------------------
modify_dn(Handle, Entry, NewRDN, DelOldRDN, NewSup) 
  when pid(Handle),list(Entry),list(NewRDN),atom(DelOldRDN),list(NewSup) ->
    send(Handle, {modify_dn, Entry, NewRDN, 
		  bool_p(DelOldRDN), optional(NewSup)}),
    recv(Handle).

%%% Sanity checks !

bool_p(Bool) when Bool==true;Bool==false -> Bool.

optional([])    -> asn1_NOVALUE;
optional(Value) -> Value.

%%% --------------------------------------------------------------------
%%% Synchronous search of the Directory returning a 
%%% requested set of attributes.
%%%
%%%  Example:
%%%
%%%	Filter = ts_eldap:substrings("sn", [{any,"o"}]),
%%%	ts_eldap:search(S, [{base, "dc=bluetail, dc=com"},
%%%	                 {filter, Filter},
%%%			 {attributes,["cn"]}])),
%%%
%%% Returned result:  {ok, #eldap_search_result{}}
%%%
%%% Example:
%%%
%%%  {ok,{eldap_search_result,
%%%        [{eldap_entry,
%%%           "cn=Magnus Froberg, dc=bluetail, dc=com",
%%%           [{"cn",["Magnus Froberg"]}]},
%%%         {eldap_entry,
%%%           "cn=Torbjorn Tornkvist, dc=bluetail, dc=com",
%%%           [{"cn",["Torbjorn Tornkvist"]}]}],
%%%        []}}
%%%
%%% --------------------------------------------------------------------
search(Handle, A) when pid(Handle), record(A, eldap_search) ->
    call_search(Handle, A);
search(Handle, L) when pid(Handle), list(L) ->
    case catch parse_search_args(L) of
	{error, Emsg}                  -> {error, Emsg};
	A when record(A, eldap_search) -> call_search(Handle, A)
    end.

call_search(Handle, A) ->
    send(Handle, {search, A}),
    recv(Handle).

parse_search_args(Args) ->
    parse_search_args(Args, #eldap_search{scope = wholeSubtree}).
    
parse_search_args([{base, Base}|T],A) ->
    parse_search_args(T,A#eldap_search{base = Base});
parse_search_args([{filter, Filter}|T],A) ->
    parse_search_args(T,A#eldap_search{filter = Filter});
parse_search_args([{scope, Scope}|T],A) ->
    parse_search_args(T,A#eldap_search{scope = Scope});
parse_search_args([{attributes, Attrs}|T],A) ->
    parse_search_args(T,A#eldap_search{attributes = Attrs});
parse_search_args([{types_only, TypesOnly}|T],A) ->
    parse_search_args(T,A#eldap_search{types_only = TypesOnly});
parse_search_args([{timeout, Timeout}|T],A) when integer(Timeout) ->
    parse_search_args(T,A#eldap_search{timeout = Timeout});
parse_search_args([H|_],_) ->
    throw({error,{unknown_arg, H}});
parse_search_args([],A) ->
    A.

%%%
%%% The Scope parameter
%%%
baseObject()   -> baseObject.
singleLevel()  -> singleLevel.
wholeSubtree() -> wholeSubtree.

%%%
%%% Boolean filter operations
%%%
'and'(ListOfFilters) when list(ListOfFilters) -> {'and',ListOfFilters}.
'or'(ListOfFilters)  when list(ListOfFilters) -> {'or', ListOfFilters}.
'not'(Filter)        when tuple(Filter)       -> {'not',Filter}.

%%%
%%% The following Filter parameters consist of an attribute
%%% and an attribute value. Example: F("uid","tobbe")
%%%
equalityMatch(Desc, Value)   -> {equalityMatch, av_assert(Desc, Value)}.
greaterOrEqual(Desc, Value)  -> {greaterOrEqual, av_assert(Desc, Value)}.
lessOrEqual(Desc, Value)     -> {lessOrEqual, av_assert(Desc, Value)}.
approxMatch(Desc, Value)     -> {approxMatch, av_assert(Desc, Value)}.

av_assert(Desc, Value) ->
    #'AttributeValueAssertion'{attributeDesc  = Desc,
			       assertionValue = Value}.

%%%
%%% Filter to check for the presence of an attribute
%%%
present(Attribute) when list(Attribute) -> 
    {present, Attribute}.


%%%
%%% A substring filter seem to be based on a pattern:
%%%
%%%   InitValue*AnyValue*FinalValue
%%%
%%% where all three parts seem to be optional (at least when
%%% talking with an OpenLDAP server). Thus, the arguments
%%% to substrings/2 looks like this:
%%%
%%% Type   ::= string( <attribute> )
%%% SubStr ::= listof( {initial,Value} | {any,Value}, {final,Value})
%%%
%%% Example: substrings("sn",[{initial,"To"},{any,"kv"},{final,"st"}])
%%% will match entries containing:  'sn: Tornkvist'
%%%
substrings(Type, SubStr) when list(Type), list(SubStr) -> 
    Ss = {'SubstringFilter_substrings',v_substr(SubStr)},
    {substrings,#'SubstringFilter'{type = Type,
				   substrings = Ss}}.
    
%%% --------------------------------------------------------------------
%%% Worker process. We keep track of a controlling process to
%%% be able to terminate together with it.
%%% --------------------------------------------------------------------

init(Hosts, Opts, Cpid) ->
    Data = parse_args(Opts, Cpid, #eldap{}),
    case try_connect(Hosts, Data) of
	{ok,Data2} ->
	    send(Cpid, {ok,self()}),
 	    put(req_timeout, Data#eldap.timeout), % kludge...
	    loop(Cpid, Data2);
	Else ->
 	    send(Cpid, Else),
	    unlink(Cpid),
	    exit(Else)
    end.

parse_args([{port, Port}|T], Cpid, Data) when integer(Port) ->
    parse_args(T, Cpid, Data#eldap{port = Port});
parse_args([{timeout, Timeout}|T], Cpid, Data) when integer(Timeout),Timeout>0 ->
    parse_args(T, Cpid, Data#eldap{timeout = Timeout});
parse_args([{anon_auth, true}|T], Cpid, Data) ->
    parse_args(T, Cpid, Data#eldap{anon_auth = false});
parse_args([{anon_auth, _}|T], Cpid, Data) ->
    parse_args(T, Cpid, Data);
parse_args([{ssl, true}|T], Cpid, Data) ->
    parse_args(T, Cpid, Data#eldap{use_tls = true});
parse_args([{ssl, _}|T], Cpid, Data) ->
    parse_args(T, Cpid, Data);
parse_args([{log, F}|T], Cpid, Data) when function(F) ->
    parse_args(T, Cpid, Data#eldap{log = F});
parse_args([{log, _}|T], Cpid, Data) ->
    parse_args(T, Cpid, Data);
parse_args([H|_], Cpid, _) ->
    send(Cpid, {error,{wrong_option,H}}),
    exit(wrong_option);
parse_args([], _, Data) ->
    Data.
		  
%%% Try to connect to the hosts in the listed order,
%%% and stop with the first one to which a successful
%%% connection is made.

try_connect([Host|Hosts], Data) ->
    TcpOpts = [{packet, asn1}, {active,false}],
    case do_connect(Host, Data, TcpOpts) of
	{ok,Fd} -> {ok,Data#eldap{host = Host, fd   = Fd}};
	_       -> try_connect(Hosts, Data)
    end;
try_connect([],_) ->
    {error,"connect failed"}.

do_connect(Host, Data, Opts) when Data#eldap.use_tls == false ->
    gen_tcp:connect(Host, Data#eldap.port, Opts, Data#eldap.timeout);
do_connect(Host, Data, Opts) when Data#eldap.use_tls == true ->
    Vsn = erlang:system_info(version),
    if Vsn >= "5.3" ->
	    %% In R9C, but not in R9B
	    {_,_,X} = erlang:now(),
	    ssl:seed("bkrlnateqqo" ++ integer_to_list(X));
       true -> true
    end,
    ssl:connect(Host, Data#eldap.port, [{verify,0}|Opts]).


loop(Cpid, Data) ->
    receive

	{From, {search, A}} ->
	    {Res,NewData} = do_search(Data, A),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {modify, Obj, Mod}} ->
	    {Res,NewData} = do_modify(Data, Obj, Mod),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {modify_dn, Obj, NewRDN, DelOldRDN, NewSup}} ->
	    {Res,NewData} = do_modify_dn(Data, Obj, NewRDN, DelOldRDN, NewSup),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {add, Entry, Attrs}} ->
	    {Res,NewData} = do_add(Data, Entry, Attrs),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {delete, Entry}} ->
	    {Res,NewData} = do_delete(Data, Entry),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {simple_bind, Dn, Passwd}} ->
	    {Res,NewData} = do_simple_bind(Data, Dn, Passwd),
	    send(From,Res),
	    loop(Cpid, NewData);

	{From, {cnt_proc, NewCpid}} ->
	    unlink(Cpid),
	    send(From,ok),
	    ?PRINT("New Cpid is: ~p~n",[NewCpid]),
	    loop(NewCpid, Data);

	{From, close} ->
	    unlink(Cpid),
	    exit(closed);

	{Cpid, 'EXIT', Reason} ->
	    ?PRINT("Got EXIT from Cpid, reason=~p~n",[Reason]),
	    exit(Reason);

	_XX ->
	    ?PRINT("loop got: ~p~n",[_XX]),
	    loop(Cpid, Data)

    end.

%%% --------------------------------------------------------------------
%%% bindRequest
%%% --------------------------------------------------------------------

%%% Authenticate ourselves to the directory using
%%% simple authentication.

do_simple_bind(Data, anon, anon) ->   %% For testing
    do_the_simple_bind(Data, "", "");
do_simple_bind(Data, Dn, _Passwd) when Dn=="",Data#eldap.anon_auth==false ->
    {{error,anonymous_auth},Data};
do_simple_bind(Data, _Dn, Passwd) when Passwd=="",Data#eldap.anon_auth==false ->
    {{error,anonymous_auth},Data};
do_simple_bind(Data, Dn, Passwd) ->
    do_the_simple_bind(Data, Dn, Passwd).

do_the_simple_bind(Data, Dn, Passwd) ->
    case catch exec_simple_bind(Data#eldap{binddn = Dn, 
					   passwd = Passwd,
					   id     = bump_id(Data)}) of
	{ok,NewData} -> {ok,NewData};
	{error,Emsg} -> {{error,Emsg},Data};
	Else         -> {{error,Else},Data}
    end.

exec_simple_bind(Data) ->
    Req = #'BindRequest'{version        = Data#eldap.version,
			 name           = Data#eldap.binddn,  
			 authentication = {simple, Data#eldap.passwd}},
    log2(Data, "bind request = ~p~n", [Req]),
    Reply = request(Data#eldap.fd, Data, Data#eldap.id, {bindRequest, Req}),
    log2(Data, "bind reply = ~p~n", [Reply]),    
    exec_simple_bind_reply(Data, Reply).

exec_simple_bind_reply(Data, {ok,Msg}) when 
  Msg#'LDAPMessage'.messageID == Data#eldap.id ->
    case Msg#'LDAPMessage'.protocolOp of
	{bindResponse, Result} ->
	    case Result#'BindResponse'.resultCode of
		success -> {ok,Data};
		Error   -> {error, Error}
	    end;
	Other -> {error, Other}
    end;
exec_simple_bind_reply(_, Error) ->
    {error, Error}.


%%% --------------------------------------------------------------------
%%% searchRequest
%%% --------------------------------------------------------------------

do_search(Data, A) ->
    case catch do_search_0(Data, A) of
	{error,Emsg}         -> {ldap_closed_p(Data, Emsg),Data};
	{'EXIT',Error}       -> {ldap_closed_p(Data, Error),Data};
	{ok,Res,Ref,NewData} -> {{ok,polish(Res, Ref)},NewData};
	Else                 -> {ldap_closed_p(Data, Else),Data}
    end.

%%%
%%% Polish the returned search result
%%%

polish(Res, Ref) ->
    R = polish_result(Res),
    %%% No special treatment of referrals at the moment.
    #eldap_search_result{entries = R,
			 referrals = Ref}.

polish_result([H|T]) when record(H, 'SearchResultEntry') ->
    ObjectName = H#'SearchResultEntry'.objectName,
    F = fun({_,A,V}) -> {A,V} end,
    Attrs = lists:map(F, H#'SearchResultEntry'.attributes),
    [#eldap_entry{object_name = ObjectName,
		  attributes  = Attrs}|
     polish_result(T)];
polish_result([]) ->
    [].

do_search_0(Data, A) ->
    Req = #'SearchRequest'{baseObject = A#eldap_search.base,
			   scope = v_scope(A#eldap_search.scope),
			   derefAliases = neverDerefAliases,
			   sizeLimit = 0, % no size limit
			   timeLimit = v_timeout(A#eldap_search.timeout),
			   typesOnly = v_bool(A#eldap_search.types_only),
			   filter = v_filter(A#eldap_search.filter),
			   attributes = v_attributes(A#eldap_search.attributes)
			  },
    Id = bump_id(Data),
    collect_search_responses(Data#eldap{id=Id}, Req, Id).
    
%%% The returned answers cames in one packet per entry
%%% mixed with possible referals

collect_search_responses(Data, Req, ID) ->
    S = Data#eldap.fd,
    log2(Data, "search request = ~p~n", [Req]),
    send_request(S, Data, ID, {searchRequest, Req}),
    Resp = recv_response(S, Data),
    log2(Data, "search reply = ~p~n", [Resp]),    
    collect_search_responses(Data, S, ID, Resp, [], []).

collect_search_responses(Data, S, ID, {ok,Msg}, Acc, Ref) 
  when record(Msg,'LDAPMessage') ->
    case Msg#'LDAPMessage'.protocolOp of
	{'searchResDone',R} when R#'LDAPResult'.resultCode == success ->
	    log2(Data, "search reply = searchResDone ~n", []),    
	    {ok,Acc,Ref,Data};
	{'searchResEntry',R} when record(R,'SearchResultEntry') ->
	    Resp = recv_response(S, Data),
	    log2(Data, "search reply = ~p~n", [Resp]),    
	    collect_search_responses(Data, S, ID, Resp, [R|Acc], Ref);
	{'searchResRef',R} ->
	    %% At the moment we don't do anyting sensible here since
	    %% I haven't been able to trigger the server to generate
	    %% a response like this.
	    Resp = recv_response(S, Data),
	    log2(Data, "search reply = ~p~n", [Resp]),    
	    collect_search_responses(Data, S, ID, Resp, Acc, [R|Ref]);
	Else ->
	    throw({error,Else})
    end;
collect_search_responses(_, _, _, Else, _, _) ->
    throw({error,Else}).

%%% --------------------------------------------------------------------
%%% addRequest
%%% --------------------------------------------------------------------

do_add(Data, Entry, Attrs) ->
    case catch do_add_0(Data, Entry, Attrs) of
	{error,Emsg}   -> {ldap_closed_p(Data, Emsg),Data};
	{'EXIT',Error} -> {ldap_closed_p(Data, Error),Data};
	{ok,NewData}   -> {ok,NewData};
	Else           -> {ldap_closed_p(Data, Else),Data}
    end.

do_add_0(Data, Entry, Attrs) ->
    Req = #'AddRequest'{entry = Entry,
			attributes = Attrs},
    S = Data#eldap.fd,
    Id = bump_id(Data),
    log2(Data, "add request = ~p~n", [Req]),
    Resp = request(S, Data, Id, {addRequest, Req}),
    log2(Data, "add reply = ~p~n", [Resp]),    
    check_reply(Data#eldap{id = Id}, Resp, addResponse).


%%% --------------------------------------------------------------------
%%% deleteRequest
%%% --------------------------------------------------------------------

do_delete(Data, Entry) ->
    case catch do_delete_0(Data, Entry) of
	{error,Emsg}   -> {ldap_closed_p(Data, Emsg),Data};
	{'EXIT',Error} -> {ldap_closed_p(Data, Error),Data};
	{ok,NewData}   -> {ok,NewData};
	Else           -> {ldap_closed_p(Data, Else),Data}
    end.

do_delete_0(Data, Entry) ->
    S = Data#eldap.fd,
    Id = bump_id(Data),
    log2(Data, "del request = ~p~n", [Entry]),
    Resp = request(S, Data, Id, {delRequest, Entry}),
    log2(Data, "del reply = ~p~n", [Resp]),    
    check_reply(Data#eldap{id = Id}, Resp, delResponse).


%%% --------------------------------------------------------------------
%%% modifyRequest
%%% --------------------------------------------------------------------

do_modify(Data, Obj, Mod) ->
    case catch do_modify_0(Data, Obj, Mod) of
	{error,Emsg}   -> {ldap_closed_p(Data, Emsg),Data};
	{'EXIT',Error} -> {ldap_closed_p(Data, Error),Data};
	{ok,NewData}   -> {ok,NewData};
	Else           -> {ldap_closed_p(Data, Else),Data}
    end.

do_modify_0(Data, Obj, Mod) ->
    v_modifications(Mod),
    Req = #'ModifyRequest'{object = Obj,
			   modification = Mod},
    S = Data#eldap.fd,
    Id = bump_id(Data),
    log2(Data, "modify request = ~p~n", [Req]),
    Resp = request(S, Data, Id, {modifyRequest, Req}),
    log2(Data, "modify reply = ~p~n", [Resp]),    
    check_reply(Data#eldap{id = Id}, Resp, modifyResponse).

%%% --------------------------------------------------------------------
%%% modifyDNRequest
%%% --------------------------------------------------------------------

do_modify_dn(Data, Entry, NewRDN, DelOldRDN, NewSup) ->
    case catch do_modify_dn_0(Data, Entry, NewRDN, DelOldRDN, NewSup) of
	{error,Emsg}   -> {ldap_closed_p(Data, Emsg),Data};
	{'EXIT',Error} -> {ldap_closed_p(Data, Error),Data};
	{ok,NewData}   -> {ok,NewData};
	Else           -> {ldap_closed_p(Data, Else),Data}
    end.

do_modify_dn_0(Data, Entry, NewRDN, DelOldRDN, NewSup) ->
    Req = #'ModifyDNRequest'{entry = Entry,
			     newrdn = NewRDN,
			     deleteoldrdn = DelOldRDN,
			     newSuperior = NewSup},
    S = Data#eldap.fd,
    Id = bump_id(Data),
    log2(Data, "modify DN request = ~p~n", [Req]),
    Resp = request(S, Data, Id, {modDNRequest, Req}),
    log2(Data, "modify DN reply = ~p~n", [Resp]),    
    check_reply(Data#eldap{id = Id}, Resp, modDNResponse).

%%% --------------------------------------------------------------------
%%% Send an LDAP request and receive the answer
%%% --------------------------------------------------------------------

request(S, Data, ID, Request) ->
    send_request(S, Data, ID, Request),
    recv_response(S, Data).

send_request(S, Data, ID, Request) ->
    Message = #'LDAPMessage'{messageID  = ID,
			     protocolOp = Request},
    {ok,Bytes} = asn1rt:encode('ts_ELDAPv3', 'LDAPMessage', Message),
    case do_send(S, Data, Bytes) of
	{error,Reason} -> throw({gen_tcp_error,Reason});
	Else           -> Else
    end.

do_send(S, Data, Bytes) when Data#eldap.use_tls == false ->
    gen_tcp:send(S, Bytes);
do_send(S, Data, Bytes) when Data#eldap.use_tls == true ->
    ssl:send(S, Bytes).

do_recv(S, Data, Len, Timeout) when Data#eldap.use_tls == false ->
    gen_tcp:recv(S, Len, Timeout);
do_recv(S, Data, Len, Timeout) when Data#eldap.use_tls == true ->
    ssl:recv(S, Len, Timeout).

recv_response(S, Data) ->
    Timeout = get(req_timeout), % kludge...
    case do_recv(S, Data, 0, Timeout) of
	{ok, Packet} ->
	    check_tag(Packet),
	    case asn1rt:decode('ts_ELDAPv3', 'LDAPMessage', Packet) of
		{ok,Resp} -> {ok,Resp};
		Error     -> throw(Error)
	    end;
	{error,Reason} ->
	    throw({gen_tcp_error, Reason});
	Error ->
	    throw(Error)
    end.

%%% Sanity check of received packet
check_tag(Data) ->
    case asn1rt_ber_bin:decode_tag(b2l(Data)) of
	{_Tag, Data1, _Rb} ->
	    case asn1rt_ber_bin:decode_length(b2l(Data1)) of
		{{_Len, _Data2}, _Rb2} -> ok;
		_ -> throw({error,decoded_tag_length})
	    end;
	_ -> throw({error,decoded_tag})
    end.

%%% Check for expected kind of reply
check_reply(Data, {ok,Msg}, Op) when 
  Msg#'LDAPMessage'.messageID == Data#eldap.id ->
    case Msg#'LDAPMessage'.protocolOp of
	{Op, Result} ->
	    case Result#'LDAPResult'.resultCode of
		success -> {ok,Data};
		Error   -> {error, Error}
	    end;
	Other -> {error, Other}
    end;
check_reply(_, Error, _) ->
    {error, Error}.


%%% --------------------------------------------------------------------
%%% Verify the input data
%%% --------------------------------------------------------------------

v_filter({'and',L})           -> {'and',L};
v_filter({'or', L})           -> {'or',L};
v_filter({'not',L})           -> {'not',L};
v_filter({equalityMatch,AV})  -> {equalityMatch,AV};
v_filter({greaterOrEqual,AV}) -> {greaterOrEqual,AV};
v_filter({lessOrEqual,AV})    -> {lessOrEqual,AV};
v_filter({approxMatch,AV})    -> {approxMatch,AV};
v_filter({present,A})         -> {present,A};
v_filter({substrings,S}) when record(S,'SubstringFilter') -> {substrings,S};
v_filter(_Filter) -> throw({error,concat(["unknown filter: ",_Filter])}).

v_modifications(Mods) ->
    F = fun({_,Op,_}) ->
		case lists:member(Op,[add,delete,replace]) of
		    true -> true;
		    _    -> throw({error,{mod_operation,Op}})
		end
	end,
    lists:foreach(F, Mods).

v_substr([{Key,Str}|T]) when list(Str),Key==initial;Key==any;Key==final ->
    [{Key,Str}|v_substr(T)];
v_substr([H|_]) ->
    throw({error,{substring_arg,H}});
v_substr([]) -> 
    [].
v_scope(baseObject)   -> baseObject;
v_scope(singleLevel)  -> singleLevel;
v_scope(wholeSubtree) -> wholeSubtree;
v_scope(_Scope)       -> throw({error,concat(["unknown scope: ",_Scope])}).

v_bool(true)  -> true;
v_bool(false) -> false;
v_bool(_Bool) -> throw({error,concat(["not Boolean: ",_Bool])}).

v_timeout(I) when integer(I), I>=0 -> I;
v_timeout(_I) -> throw({error,concat(["timeout not positive integer: ",_I])}).

v_attributes(Attrs) ->
    F = fun(A) when list(A) -> A;
	   (A) -> throw({error,concat(["attribute not String: ",A])})
	end,
    lists:map(F,Attrs).


%%% --------------------------------------------------------------------
%%% Log routines. Call a user provided log routine F.
%%% --------------------------------------------------------------------

log1(Data, Str, Args) -> log(Data, Str, Args, 1).
log2(Data, Str, Args) -> log(Data, Str, Args, 2).

log(Data, Str, Args, Level) when function(Data#eldap.log) ->
    catch (Data#eldap.log)(Level, Str, Args);
log(_, _, _, _) -> 
    ok.


%%% --------------------------------------------------------------------
%%% Misc. routines
%%% --------------------------------------------------------------------

send(To,Msg) -> To ! {self(),Msg}.
recv(From)   -> receive {From,Msg} -> Msg end.

ldap_closed_p(Data, Emsg) when Data#eldap.use_tls == true ->
    %% Check if the SSL socket seems to be alive or not
    case catch ssl:sockname(Data#eldap.fd) of
	{error, _} ->
	    ssl:close(Data#eldap.fd),
	    {error, ldap_closed};
	{ok, _} ->
	    {error, Emsg};
	_ ->
	    %% sockname crashes if the socket pid is not alive
	    {error, ldap_closed}
    end;
ldap_closed_p(Data, Emsg) ->
    %% non-SSL socket
    case inet:port(Data#eldap.fd) of
	{error,_} -> {error, ldap_closed};
	_         -> {error,Emsg}
    end.
    
bump_id(Data) -> Data#eldap.id + 1.

    
%%% --------------------------------------------------------------------
%%% parse_dn/1  -  Implementation of RFC 2253:
%%%
%%%   "UTF-8 String Representation of Distinguished Names"
%%%
%%% Test cases:
%%%
%%%  The simplest case:
%%%  
%%%  1> ts_eldap:parse_dn("CN=Steve Kille,O=Isode Limited,C=GB").
%%%  {ok,[[{attribute_type_and_value,"CN","Steve Kille"}],
%%%       [{attribute_type_and_value,"O","Isode Limited"}],
%%%       [{attribute_type_and_value,"C","GB"}]]}
%%%
%%%  The first RDN is multi-valued:
%%%  
%%%  2> ts_eldap:parse_dn("OU=Sales+CN=J. Smith,O=Widget Inc.,C=US").
%%%  {ok,[[{attribute_type_and_value,"OU","Sales"},
%%%        {attribute_type_and_value,"CN","J. Smith"}],
%%%       [{attribute_type_and_value,"O","Widget Inc."}],
%%%       [{attribute_type_and_value,"C","US"}]]}
%%%
%%%  Quoting a comma:
%%%
%%%  3> ts_eldap:parse_dn("CN=L. Eagle,O=Sue\\, Grabbit and Runn,C=GB").
%%%  {ok,[[{attribute_type_and_value,"CN","L. Eagle"}],
%%%       [{attribute_type_and_value,"O","Sue\\, Grabbit and Runn"}],
%%%       [{attribute_type_and_value,"C","GB"}]]}
%%%
%%%  A value contains a carriage return:
%%%
%%%  4> ts_eldap:parse_dn("CN=Before                                    
%%%  4> After,O=Test,C=GB").
%%%  {ok,[[{attribute_type_and_value,"CN","Before\nAfter"}],
%%%       [{attribute_type_and_value,"O","Test"}],
%%%       [{attribute_type_and_value,"C","GB"}]]}
%%%
%%%  5> ts_eldap:parse_dn("CN=Before\\0DAfter,O=Test,C=GB").
%%%  {ok,[[{attribute_type_and_value,"CN","Before\\0DAfter"}],
%%%       [{attribute_type_and_value,"O","Test"}],
%%%       [{attribute_type_and_value,"C","GB"}]]}
%%%  
%%%  An RDN in OID form:
%%%  
%%%  6> ts_eldap:parse_dn("1.3.6.1.4.1.1466.0=#04024869,O=Test,C=GB").
%%%  {ok,[[{attribute_type_and_value,"1.3.6.1.4.1.1466.0","#04024869"}],
%%%       [{attribute_type_and_value,"O","Test"}],
%%%       [{attribute_type_and_value,"C","GB"}]]}
%%%  
%%%
%%% --------------------------------------------------------------------

parse_dn("") -> % empty DN string
    {ok,[]};  
parse_dn([H|_] = Str) when H=/=$, -> % 1:st name-component !
    case catch parse_name(Str,[]) of
	{'EXIT',Reason} -> {parse_error,internal_error,Reason};
	Else            -> Else
    end.

parse_name("",Acc)  -> 
    {ok,lists:reverse(Acc)};
parse_name([$,|T],Acc) -> % N:th name-component !
    parse_name(T,Acc);
parse_name(Str,Acc) ->
    {Rest,NameComponent} = parse_name_component(Str),
    parse_name(Rest,[NameComponent|Acc]).
    
parse_name_component(Str) ->
    parse_name_component(Str,[]).

parse_name_component(Str,Acc) ->
    case parse_attribute_type_and_value(Str) of
	{[$+|Rest], ATV} ->
	    parse_name_component(Rest,[ATV|Acc]);
	{Rest,ATV} ->
	    {Rest,lists:reverse([ATV|Acc])}
    end.

parse_attribute_type_and_value(Str) ->
    case parse_attribute_type(Str) of
	{Rest,[]} -> 
	    error(expecting_attribute_type,Str);
	{Rest,Type} ->
	    Rest2 = parse_equal_sign(Rest),
	    {Rest3,Value} = parse_attribute_value(Rest2),
	    {Rest3,{attribute_type_and_value,Type,Value}}
    end.

-define(IS_ALPHA(X) , X>=$a,X=<$z;X>=$A,X=<$Z ).
-define(IS_DIGIT(X) , X>=$0,X=<$9 ).
-define(IS_SPECIAL(X) , X==$,;X==$=;X==$+;X==$<;X==$>;X==$#;X==$; ).
-define(IS_QUOTECHAR(X) , X=/=$\\,X=/=$" ).
-define(IS_STRINGCHAR(X) , 
	X=/=$,,X=/=$=,X=/=$+,X=/=$<,X=/=$>,X=/=$#,X=/=$;,?IS_QUOTECHAR(X) ).
-define(IS_HEXCHAR(X) , ?IS_DIGIT(X);X>=$a,X=<$f;X>=$A,X=<$F ).

parse_attribute_type([H|T]) when ?IS_ALPHA(H) ->
    %% NB: It must be an error in the RFC in the definition
    %% of 'attributeType', should be: (ALPHA *keychar)
    {Rest,KeyChars} = parse_keychars(T),  
    {Rest,[H|KeyChars]};
parse_attribute_type([H|_] = Str) when ?IS_DIGIT(H) ->
    parse_oid(Str);
parse_attribute_type(Str) ->
    error(invalid_attribute_type,Str).



%%% Is a hexstring !
parse_attribute_value([$#,X,Y|T]) when ?IS_HEXCHAR(X),?IS_HEXCHAR(Y) ->
    {Rest,HexString} = parse_hexstring(T),
    {Rest,[$#,X,Y|HexString]}; 
%%% Is a "quotation-sequence" !
parse_attribute_value([$"|T]) -> 
    {Rest,Quotation} = parse_quotation(T),
    {Rest,[$"|Quotation]};
%%% Is a stringchar , pair or Empty !
parse_attribute_value(Str) -> 
    parse_string(Str).

parse_hexstring(Str) ->
    parse_hexstring(Str,[]).

parse_hexstring([X,Y|T],Acc) when ?IS_HEXCHAR(X),?IS_HEXCHAR(Y) ->
    parse_hexstring(T,[Y,X|Acc]);
parse_hexstring(T,Acc) ->
    {T,lists:reverse(Acc)}.

parse_quotation([$"|T]) -> % an empty: ""  is ok !
    {T,[$"]};
parse_quotation(Str) -> 
    parse_quotation(Str,[]).

%%% Parse to end of quotation
parse_quotation([$"|T],Acc) -> 
    {T,lists:reverse([$"|Acc])};
parse_quotation([X|T],Acc) when ?IS_QUOTECHAR(X) -> 
    parse_quotation(T,[X|Acc]);
parse_quotation([$\\,X|T],Acc) when ?IS_SPECIAL(X) -> 
    parse_quotation(T,[X,$\\|Acc]);
parse_quotation([$\\,$\\|T],Acc) -> 
    parse_quotation(T,[$\\,$\\|Acc]);
parse_quotation([$\\,$"|T],Acc) -> 
    parse_quotation(T,[$",$\\|Acc]);
parse_quotation([$\\,X,Y|T],Acc) when ?IS_HEXCHAR(X),?IS_HEXCHAR(Y) -> 
    parse_quotation(T,[Y,X,$\\|Acc]);
parse_quotation(T,_) -> 
    error(expecting_double_quote_mark,T).

parse_string(Str) -> 
    parse_string(Str,[]).

parse_string("",Acc) -> 
    {"",lists:reverse(Acc)};
parse_string([H|T],Acc) when ?IS_STRINGCHAR(H) -> 
    parse_string(T,[H|Acc]);
parse_string([$\\,X|T],Acc) when ?IS_SPECIAL(X) -> % is a pair !
    parse_string(T,[X,$\\|Acc]);
parse_string([$\\,$\\|T],Acc)                   -> % is a pair !
    parse_string(T,[$\\,$\\|Acc]);
parse_string([$\\,$" |T],Acc)                   -> % is a pair !
    parse_string(T,[$" ,$\\|Acc]);
parse_string([$\\,X,Y|T],Acc) when ?IS_HEXCHAR(X),?IS_HEXCHAR(Y) -> % is a pair!
    parse_string(T,[Y,X,$\\|Acc]);
parse_string(T,Acc) ->
    {T,lists:reverse(Acc)}.

parse_equal_sign([$=|T]) -> T;
parse_equal_sign(T)      -> error(expecting_equal_sign,T).

parse_keychars(Str) -> parse_keychars(Str,[]).

parse_keychars([H|T],Acc) when ?IS_ALPHA(H) -> parse_keychars(T,[H|Acc]);
parse_keychars([H|T],Acc) when ?IS_DIGIT(H) -> parse_keychars(T,[H|Acc]);
parse_keychars([$-|T],Acc)                  -> parse_keychars(T,[$-|Acc]);
parse_keychars(T,Acc)                       -> {T,lists:reverse(Acc)}.

parse_oid(Str) -> parse_oid(Str,[]).

parse_oid([H,$.|T], Acc) when ?IS_DIGIT(H) ->
    parse_oid(T,[$.,H|Acc]);
parse_oid([H|T], Acc) when ?IS_DIGIT(H) ->
    parse_oid(T,[H|Acc]);
parse_oid(T, Acc) ->
    {T,lists:reverse(Acc)}.

error(Emsg,Rest) -> 
    throw({parse_error,Emsg,Rest}).


%%% --------------------------------------------------------------------
%%% Parse LDAP url according to RFC 2255
%%%
%%% Test case:
%%%
%%%  2> ts_eldap:parse_ldap_url("ldap://10.42.126.33:389/cn=Administrative%20CA,o=Post%20Danmark,c=DK?certificateRevokationList;binary").
%%%  {ok,{{10,42,126,33},389},
%%%      [[{attribute_type_and_value,"cn","Administrative%20CA"}],
%%%       [{attribute_type_and_value,"o","Post%20Danmark"}],
%%%       [{attribute_type_and_value,"c","DK"}]],
%%%      {attributes,["certificateRevokationList;binary"]}}
%%%
%%% --------------------------------------------------------------------

parse_ldap_url("ldap://" ++ Rest1 = Str) ->
    {Rest2,HostPort} = parse_hostport(Rest1),
    %% Split the string into DN and Attributes+etc
    {Sdn,Rest3} = split_string(rm_leading_slash(Rest2),$?),
    case parse_dn(Sdn) of
	{parse_error,internal_error,_Reason} ->
	    {parse_error,internal_error,{Str,[]}};
	{parse_error,Emsg,Tail} ->
	    Head = get_head(Str,Tail),
	    {parse_error,Emsg,{Head,Tail}};
	{ok,DN} ->
            %% We stop parsing here for now and leave
            %% 'scope', 'filter' and 'extensions' to
            %% be implemented later if needed.				      
	    {_Rest4,Attributes} = parse_attributes(Rest3),
	    {ok,HostPort,DN,Attributes}
    end.

rm_leading_slash([$/|Tail]) -> Tail;
rm_leading_slash(Tail)      -> Tail.

parse_attributes([$?|Tail]) ->
    case split_string(Tail,$?) of
        {[],Attributes} ->
	    {[],{attributes,string:tokens(Attributes,",")}};
        {Attributes,Rest} ->
            {Rest,{attributes,string:tokens(Attributes,",")}}
    end.

parse_hostport(Str) ->
    {HostPort,Rest} = split_string(Str,$/),
    case split_string(HostPort,$:) of
	{Shost,[]} -> 
	    {Rest,{parse_host(Rest,Shost),?LDAP_PORT}};
	{Shost,[$:|Sport]} ->
	    {Rest,{parse_host(Rest,Shost),
		   parse_port(Rest,Sport)}}
    end.

parse_port(Rest,Sport) ->
    case list_to_integer(Sport) of
	Port when integer(Port) -> Port;
	_ -> error(parsing_port,Rest)
    end.

parse_host(Rest,Shost) ->
    case catch validate_host(Shost) of
	{parse_error,Emsg,_} -> error(Emsg,Rest);
	Host -> Host
    end.

validate_host(Shost) ->
    case inet_parse:address(Shost) of
	{ok,Host} -> Host;
	_ ->
	    case inet_parse:domain(Shost) of
		true -> Shost;
		_    -> error(parsing_host,Shost)
	    end
    end.

    
split_string(Str,Key) ->
    Pred = fun(X) when X==Key -> false; (_) -> true end,
    lists:splitwith(Pred, Str).

get_head(Str,Tail) ->
    get_head(Str,Tail,[]).

%%% Should always succeed !
get_head([H|Tail],Tail,Rhead) -> lists:reverse([H|Rhead]);
get_head([H|Rest],Tail,Rhead) -> get_head(Rest,Tail,[H|Rhead]).

b2l(B) when binary(B) -> B;
b2l(L) when list(L)   -> list_to_binary(L).

