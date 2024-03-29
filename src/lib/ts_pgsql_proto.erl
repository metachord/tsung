%%% File    : ts_pgsql_proto.erl
%%% Author  : Christian Sunesson <chrisu@kth.se>
%%% Description : PostgreSQL protocol driver
%%% Created :  9 May 2005

%%% This is the protocol handling part of the PostgreSQL driver, it turns packages into
%%% erlang term messages and back.

-module(ts_pgsql_proto).

%% TODO:
%% When factorizing make clear distinction between message and packet.
%% Packet == binary on-wire representation
%% Message = parsed Packet as erlang terms.

%%% Version 3.0 of the protocol. 
%%% Supported in postgres from version 7.4
-define(PROTOCOL_MAJOR, 3).
-define(PROTOCOL_MINOR, 0).

%%% PostgreSQL protocol message codes
-define(PG_BACKEND_KEY_DATA, $K).
-define(PG_PARAMETER_STATUS, $S).
-define(PG_ERROR_MESSAGE, $E).
-define(PG_NOTICE_RESPONSE, $N).
-define(PG_EMPTY_RESPONSE, $I).
-define(PG_ROW_DESCRIPTION, $T).
-define(PG_DATA_ROW, $D).
-define(PG_READY_FOR_QUERY, $Z).
-define(PG_AUTHENTICATE, $R).
-define(PG_BIND, $B).
-define(PG_PARSE, $P).
-define(PG_COMMAND_COMPLETE, $C).
-define(PG_PARSE_COMPLETE, $1).
-define(PG_BIND_COMPLETE, $2).
-define(PG_CLOSE_COMPLETE, $3).
-define(PG_PORTAL_SUSPENDED, $s).
-define(PG_NO_DATA, $n).
-define(PG_COPY_RESPONSE, $G).

-export([init/2, idle/2]).
-export([run/1]).

%% For protocol unwrapping, pgsql_tcp for example.
-export([decode_packet/2]).
-export([encode_message/2]).
-export([encode/2]).

-import(ts_pgsql_util, [option/2]).
-import(ts_pgsql_util, [socket/1]).
-import(ts_pgsql_util, [send/2, send_int/2, send_msg/3]).
-import(ts_pgsql_util, [recv_msg/2, recv_msg/1, recv_byte/2, recv_byte/1]).
-import(ts_pgsql_util, [string/1, make_pair/2, split_pair/1]).
-import(ts_pgsql_util, [count_string/1, to_string/1]).
-import(ts_pgsql_util, [coldescs/2, datacoldescs/3]).

deliver(Message) ->
    DriverPid = get(driver),
    DriverPid ! Message.

run(Options) ->
    Db = spawn_link(ts_pgsql_proto, init,
		    [self(), Options]),
    {ok, Db}.

%% TODO: We should use states instead of process dictionary
init(DriverPid, Options) ->
    put(options, Options), % connection setup options
    put(driver, DriverPid), % driver's process id

    %%io:format("Init~n", []),
    %% Default values: We connect to localhost on the standard TCP/IP
    %% port.
    Host = option(host, "localhost"),
    Port = option(port, 5432),

    case socket({tcp, Host, Port}) of 
	{ok, Sock} ->
	    connect(Sock);
	Error ->
	    Reason = {init, Error},
	    DriverPid ! {pgsql_error, Reason},
	    exit(Reason)
    end.

connect(Sock) ->
    %%io:format("Connect~n", []),
    %% Connection settings for database-login.
    %% TODO: Check if the default values are relevant:
    UserName = option(user, "cos"),
    DatabaseName = option(database, "template1"),
    
    %% Make protocol startup packet.
    Version = <<?PROTOCOL_MAJOR:16/integer, ?PROTOCOL_MINOR:16/integer>>,
    User = make_pair(user, UserName),
    Database = make_pair(database, DatabaseName),
    StartupPacket = <<Version/binary, 
		     User/binary,
		     Database/binary,
		     0>>,

    %% Backend will continue with authentication after the startup packet
    PacketSize = 4 + size(StartupPacket),
    ok = gen_tcp:send(Sock, <<PacketSize:32/integer, StartupPacket/binary>>),
    authenticate(Sock).


authenticate(Sock) ->
    %% Await authentication request from backend.
    {ok, Code, Packet} = recv_msg(Sock, 5000),
    {ok, Value} = decode_packet(Code, Packet),
    case Value of
	%% Error response
	{error_message, Message} ->
	    exit({authentication, Message});
	{authenticate, {AuthMethod, Salt}} ->
	    case AuthMethod of 
		0 -> % Auth ok
		    setup(Sock, []);
		1 -> % Kerberos 4
		    exit({nyi, auth_kerberos4});
		2 -> % Kerberos 5
		    exit({nyi, auth_kerberos5});
		3 -> % Plaintext password
		    Password = option(password, ""),
		    EncodedPass = encode_message(pass_plain, Password),
		    ok = send(Sock, EncodedPass),
		    authenticate(Sock);
		4 -> % Hashed password
		    exit({nyi, auth_crypt});
		5 -> % MD5 password
		    Password = option(password, ""),
		    User = option(user, ""),
		    EncodedPass = encode_message(pass_md5,
						 {User, Password, Salt}),
		    ok = send(Sock, EncodedPass),
		    authenticate(Sock);
		_ ->
		    exit({authentication, {unknown, AuthMethod}})
	    end;
	%% Unknown message received
	Any ->
	    exit({protocol_error, Any})
    end.

setup(Sock, Params) ->
    %% Receive startup messages until ReadyForQuery
    {ok, Code, Package} = recv_msg(Sock, 5000),
    {ok, Pair} = decode_packet(Code, Package),
    case Pair of
	%% BackendKeyData, necessary for issuing cancel requests
	{backend_key_data, {Pid, Secret}} ->
	    Params1 = [{secret, {Pid, Secret}}|Params],
	    setup(Sock, Params1);
	%% ParameterStatus, a key-value pair.
	{parameter_status, {Key, Value}} ->
	    Params1 = [{{parameter, Key}, Value}|Params],
	    setup(Sock, Params1);
	%% Error message, with a sequence of <<Code:8/integer, String, 0>>
	%% of error descriptions. Code==0 terminates the Reason.
	{error_message, Message} ->
	    gen_tcp:close(Sock),
	    exit({error_response, Message});
	%% Notice Response, with a sequence of <<Code:8/integer, String,0>>
	%% identified fields. Code==0 terminates the Notice.
	{notice_response, Notice} ->
	    deliver({pgsql_notice, Notice}),
	    setup(Sock, Params);
	%% Ready for Query, backend is ready for a new query cycle
	{ready_for_query, Status} ->
	    deliver({pgsql_params, Params}),
	    deliver(pgsql_connected),
	    put(params, Params),
	    connected(Sock);
	Any ->
	    deliver({unknown_setup, Any}),
	    connected(Sock)
    
    end.

%% Connected state. Can now start to push messages 
%% between frontend and backend. But first some setup.
connected(Sock) ->
    DriverPid = get(driver),
    
    %% Protocol unwrapping process. Factored out to make future
    %% SSL and unix domain support easier. Store process under
    %% 'socket' in the process dictionary.
    begin
	Unwrapper = spawn_link(pgsql_tcp, loop0, [Sock, self()]),
	ok = gen_tcp:controlling_process(Sock, Unwrapper),
	put(socket, Unwrapper)
    end,

    %% Lookup oid to type names and store them in a dictionary under 
    %% 'oidmap' in the process dictionary.
    begin
	Packet = encode_message(squery, "SELECT oid, typname FROM pg_type"),
	ok = send(Sock, Packet),
	{ok, [{"SELECT", _ColDesc, Rows}]} = process_squery([]),
	Rows1 = lists:map(fun ([CodeS, NameS]) -> 
				  Code = list_to_integer(CodeS),
				  Name = list_to_atom(NameS),
				  {Code, Name}
			  end,
			  Rows),
	OidMap = dict:from_list(Rows1),
	put(oidmap, OidMap)
    end,
    
    %% Ready to start marshalling between frontend and backend.
    idle(Sock, DriverPid).

%% In the idle state we should only be receiving requests from the 
%% frontend. Async backend messages should be forwarded to responsible
%% process.
idle(Sock, Pid) ->
    receive
	%% Unexpected idle messages. No request should continue to the
	%% idle state before a ready-for-query has been received.
	{message, Message} ->
	    io:format("Unexpected message when idle: ~p~n", [Message]),
	    idle(Sock, Pid);

	%% Socket closed or socket error messages.
	{socket, Sock, Condition} ->
	    exit({socket, Condition});
	
	%% Close connection
	{terminate, Ref, Pid} ->
	    Packet = encode_message(terminate, []),
	    ok = send(Sock, Packet),
	    gen_tcp:close(Sock),
	    Pid ! {pgsql, Ref, terminated},
	    unlink(Pid),
	    exit(terminating);
	%% Simple query
	{squery, Ref, Pid, Query} ->
	    Packet = encode_message(squery, Query),
	    ok = send(Sock, Packet),
	    {ok, Result} = process_squery([]),
	    case lists:keymember(error, 1, Result) of
		true ->
		    RBPacket = encode_message(squery, "ROLLBACK"),
		    ok = send(Sock, RBPacket),
		    {ok, RBResult} = process_squery([]);
		_ ->
		    ok
	    end,
	    Pid ! {pgsql, Ref, Result},
	    idle(Sock, Pid);
	%% Extended query
	%% simplistic version using the unnammed prepared statement and portal.
	{equery, Ref, Pid, {Query, Params}} ->
	    ParseP =    encode_message(parse, {"", Query, []}),
	    BindP =     encode_message(bind,  {"", "", Params, [binary]}),
	    DescribeP = encode_message(describe, {portal, ""}), 
	    ExecuteP =  encode_message(execute,  {"", 0}),
	    SyncP =     encode_message(sync, []),
	    ok = send(Sock, [ParseP, BindP, DescribeP, ExecuteP, SyncP]),

	    {ok, Command, Desc, Status, Logs} = process_equery([]),

	    OidMap = get(oidmap),
	    NameTypes = lists:map(fun({Name, _Format, _ColNo, Oid, _, _, _}) ->
					  {Name, dict:fetch(Oid, OidMap)}
				  end,
				  Desc),
	    Pid ! {pgsql, Ref, {Command, Status, NameTypes, Logs}},
	    idle(Sock, Pid);
	%% Prepare a statement, so it can be used for queries later on.
	{prepare, Ref, Pid, {Name, Query}} ->
	    send_message(Sock, parse, {Name, Query, []}),
	    send_message(Sock, describe, {prepared_statement, Name}),
	    send_message(Sock, sync, []),
	    {ok, State, ParamDesc, ResultDesc} = process_prepare({[], []}),
	    OidMap = get(oidmap),
 	    ParamTypes = 
		lists:map(fun (Oid) -> dict:fetch(Oid, OidMap) end, ParamDesc),
	    ResultNameTypes = lists:map(fun ({ColName, _Format, _ColNo, Oid, _, _, _}) ->
						{ColName, dict:fetch(Oid, OidMap)}
					end,
					ResultDesc),
	    Pid ! {pgsql, Ref, {prepared, State, ParamTypes, ResultNameTypes}},
	    idle(Sock, Pid);
	%% Close a prepared statement.
	{unprepare, Ref, Pid, Name} ->
	    send_message(Sock, close, {prepared_statement, Name}),
	    send_message(Sock, sync, []),
	    {ok, _Status} = process_unprepare(),
	    Pid ! {pgsql, Ref, unprepared},
	    idle(Sock, Pid);
	%% Execute a prepared statement
	{execute, Ref, Pid, {Name, Params}} ->
	    %%io:format("execute: ~p ~p ~n", [Name, Params]),
	    begin % Issue first requests for the prepared statement.
		BindP     = encode_message(bind, {"", Name, Params, [binary]}),
		DescribeP = encode_message(describe, {portal, ""}),
		ExecuteP  = encode_message(execute, {"", 0}),
		FlushP    = encode_message(flush, []),
		ok = send(Sock, [BindP, DescribeP, ExecuteP, FlushP])
	    end,
	    receive
		{pgsql, {bind_complete, _}} -> % Bind reply first.
		    %% Collect response to describe message, 
		    %% which gives a hint of the rest of the messages.
		    {ok, Command, Result} = process_execute(Sock, Ref, Pid),
		    
		    begin % Close portal and end extended query.
			CloseP = encode_message(close, {portal, ""}),
			SyncP  = encode_message(sync, []),
			ok = send(Sock, [CloseP, SyncP])
		    end,
		    receive 
			%% Collect response to close message.
			{pgsql, {close_complete, _}} ->
			    receive 
				%% Collect response to sync message.
				{pgsql, {ready_for_query, Status}} ->
				    %%io:format("execute: ~p ~p ~p~n", 
				    %%	      [Status, Command, Result]),
				    Pid ! {pgsql, Ref, {Command, Result}},
				    idle(Sock, Pid);
				{pgsql, Unknown} ->
				    exit(Unknown)
			    end;
			{pgsql, Unknown} ->
			    exit(Unknown)
		    end;
		{pgsql, Unknown} ->
		    exit(Unknown)
	    end;
	
	%% More requests to come.
	%% .
	%% .
	%% .

	Any ->
	    exit({unknown_request, Any})

    end.


%% In the process_squery state we collect responses until the backend is
%% done processing.
process_squery(Log) ->
    receive
	{pgsql, {row_description, Cols}} ->
	    {ok, Command, Rows} = process_squery_cols([]),
	    process_squery([{Command, Cols, Rows}|Log]);
	{pgsql, {command_complete, Command}} ->
	    process_squery([Command|Log]);
	{pgsql, {ready_for_query, Status}} ->
	    {ok, lists:reverse(Log)};
	{pgsql, {error_message, Error}} ->
	    process_squery([{error, Error}|Log]);
	{pgsql, Any} ->
	    process_squery(Log)
    end.
process_squery_cols(Log) ->
    receive
	{pgsql, {data_row, Row}} ->
	    process_squery_cols([lists:map(fun binary_to_list/1, Row)|Log]);
	{pgsql, {command_complete, Command}} ->
	    {ok, Command, lists:reverse(Log)}
    end.

process_equery(Log) ->
    receive 
	%% Consume parse and bind complete messages when waiting for the first
	%% first row_description message. What happens if the equery doesnt
	%% return a result set?
	{pgsql, {parse_complete, _}} ->
	    process_equery(Log);
	{pgsql, {bind_complete, _}} ->
	    process_equery(Log);
	{pgsql, {row_description, Descs}} ->
	    {ok, Descs1} = ts_pgsql_util:decode_descs(Descs),
	    process_equery_datarow(Descs1, Log, {undefined, Descs, undefined});
	{pgsql, Any} ->
	    process_equery([Any|Log])
    end.

process_equery_datarow(Types, Log, Info={Command, Desc, Status}) ->
    receive
	%% 
	{pgsql, {command_complete, Command1}} ->
	    process_equery_datarow(Types, Log, {Command1, Desc, Status});
	{pgsql, {ready_for_query, Status1}} ->
	    {ok, Command, Desc, Status1, lists:reverse(Log)};
	{pgsql, {data_row, Row}} ->
	    {ok, DecodedRow} = ts_pgsql_util:decode_row(Types, Row),
	    process_equery_datarow(Types, [DecodedRow|Log], Info);
	{pgsql, Any} ->
	    process_equery_datarow(Types, [Any|Log], Info)
    end.

process_prepare(Info={ParamDesc, ResultDesc}) ->
    receive 
	{pgsql, {no_data, _}} ->
	    process_prepare({ParamDesc, []});
	{pgsql, {parse_complete, _}} ->
	    process_prepare(Info);
	{pgsql, {parameter_description, Oids}} ->
	    process_prepare({Oids, ResultDesc});
	{pgsql, {row_description, Desc}} ->
	    process_prepare({ParamDesc, Desc});
	{pgsql, {ready_for_query, Status}} ->
	    {ok, Status, ParamDesc, ResultDesc};
	{pgsql, Any} ->
	    io:format("process_prepare: ~p~n", [Any]),
	    process_prepare(Info)
    end.
	
process_unprepare() ->
    receive 
	{pgsql, {ready_for_query, Status}} ->
	    {ok, Status};
	{pgsql, {close_complate, []}} ->
	    process_unprepare();
	{pgsql, Any} ->
	    io:format("process_unprepare: ~p~n", [Any]),
	    process_unprepare()
    end.

process_execute(Sock, Ref, Pid) ->
    %% Either the response begins with a no_data or a row_description
    %% Needs to return {ok, Status, Result}
    %% where Result = {Command, ...}
    receive
	{pgsql, {no_data, _}} ->
	    {ok, Command, Result} = process_execute_nodata();
	{pgsql, {row_description, Descs}} ->
	    {ok, Types} = ts_pgsql_util:decode_descs(Descs),
	    {ok, Command, Result} = 
		process_execute_resultset(Sock, Ref, Pid, Types, []);
		    
	{pgsql, Unknown} ->
	    exit(Unknown)
    end.

process_execute_nodata() ->
    receive 
	{pgsql, {command_complete, Command}} ->
	    case Command of 
		"INSERT "++Rest ->
		    {ok, [{integer, _, _Table}, 
			  {integer, _, NRows}], _} = erl_scan:string(Rest),
		    {ok, 'INSERT', NRows};
		"SELECT" ->
		    {ok, 'SELECT', should_not_happen};
		"DELETE "++Rest ->
		    {ok, [{integer, _, NRows}], _} =
			erl_scan:string(Rest),
		    {ok, 'DELETE', NRows};
		Any ->
		    {ok, nyi, Any}
	    end;

	{pgsql, Unknown} ->
	    exit(Unknown)
    end.
process_execute_resultset(Sock, Ref, Pid, Types, Log) ->
    receive
	{pgsql, {command_complete, Command}} ->
	    {ok, list_to_atom(Command), lists:reverse(Log)};
	{pgsql, {data_row, Row}} ->
	    {ok, DecodedRow} = ts_pgsql_util:decode_row(Types, Row),
	    process_execute_resultset(Sock, Ref, Pid, Types, [DecodedRow|Log]);
	{pgsql, {portal_suspended, _}} ->
	    throw(portal_suspended);
	{pgsql, Any} ->
	    %%process_execute_resultset(Types, [Any|Log])
	    exit(Any)
    end.

%% With a message type Code and the payload Packet apropriate 
%% decoding procedure can proceed.
decode_packet(Code, Packet) ->
    Ret = fun(CodeName, Values) -> {ok, {CodeName, Values}} end,
    case Code of 
	?PG_ERROR_MESSAGE ->
	    Message = ts_pgsql_util:errordesc(Packet),
	    Ret(error_message, Message);
	?PG_EMPTY_RESPONSE ->
	    Ret(empty_response, []);
	?PG_ROW_DESCRIPTION ->
	    <<Columns:16/integer, ColDescs/binary>> = Packet,
	    Descs = coldescs(ColDescs, []),
	    Ret(row_description, Descs);
	?PG_READY_FOR_QUERY ->
	    <<State:8/integer>> = Packet,
	    case State of 
		$I ->
		    Ret(ready_for_query, idle);
		$T ->
		    Ret(ready_for_query, transaction);
		$E ->
		    Ret(ready_for_query, failed_transaction)
	    end;
	?PG_COMMAND_COMPLETE ->
	    {Task, _} = to_string(Packet),
	    Ret(command_complete, Task);
	?PG_DATA_ROW ->
	    <<NumberCol:16/integer, RowData/binary>> = Packet,
	    ColData = datacoldescs(NumberCol, RowData, []),
	    Ret(data_row, ColData);
	?PG_BACKEND_KEY_DATA -> 
	    <<Pid:32/integer, Secret:32/integer>> = Packet,
	    Ret(backend_key_data, {Pid, Secret});
	?PG_PARAMETER_STATUS ->
	    {Key, Value} = split_pair(Packet),
	    Ret(parameter_status, {Key, Value});
	?PG_NOTICE_RESPONSE ->
	    Ret(notice_response, []);
	?PG_AUTHENTICATE ->
	    <<AuthMethod:32/integer, Salt/binary>> = Packet,
	    Ret(authenticate, {AuthMethod, Salt});
	?PG_PARSE_COMPLETE ->
	    Ret(parse_complete, []);
	?PG_BIND_COMPLETE ->
	    Ret(bind_complete, []);
	?PG_PORTAL_SUSPENDED ->
	    Ret(portal_suspended, []);
	?PG_CLOSE_COMPLETE ->
	    Ret(close_complete, []);
	?PG_COPY_RESPONSE ->
            <<FormatCode:8/integer, ColN:16/integer, ColFormat/binary>> = Packet,
            Format = case FormatCode of
                         0 -> text;
                         1 -> binary
                     end,
            Cols=ts_pgsql_util:int16(ColFormat,[]),
            Ret(copy_response, {Format,Cols});
	$t ->
	    <<NParams:16/integer, OidsP/binary>> = Packet,
	    Oids = ts_pgsql_util:oids(OidsP, []),
	    Ret(parameter_description, Oids);
	?PG_NO_DATA ->
	    Ret(no_data, []);

	Any ->
	    Ret(unknown, [Code])
    end.

send_message(Sock, Type, Values) ->
    %%io:format("send_message:~p~n", [{Type, Values}]),
    Packet = encode_message(Type, Values),
    ok = send(Sock, Packet).

%% Add header to a message.
encode(Code, Packet) ->
    Len = size(Packet) + 4,
    <<Code:8/integer, Len:4/integer-unit:8, Packet/binary>>.

%% Encode a message of a given type.
encode_message(pass_plain, Password) ->
		Pass = ts_pgsql_util:pass_plain(Password),
		encode($p, Pass);
encode_message(pass_md5, {User, Password, Salt}) ->
		Pass = ts_pgsql_util:pass_md5(User, Password, Salt),
		encode($p, Pass);
encode_message(terminate, _) ->
    encode($X, <<>>);
encode_message(copydone, _) ->
    encode($c, <<>>);
encode_message(copyfail, Msg) ->
    encode($f, string(Msg));
encode_message(copy, Data) ->
    encode($d, Data );
encode_message(squery, Query) -> % squery as in simple query.
    encode($Q, string(Query));
encode_message(close, {Object, Name}) ->
    Type = case Object of prepared_statement -> $S; portal -> $P end,
    String = string(Name),
    encode($C, <<Type/integer, String/binary>>);
encode_message(describe, {Object, Name}) ->
    ObjectP = case Object of prepared_statement -> $S; portal -> $P end,
    NameP = string(Name),
    encode($D, <<ObjectP:8/integer, NameP/binary>>);
encode_message(flush, _) ->
    encode($H, <<>>);
encode_message(parse, {Name, Query, Oids}) ->
    StringName = string(Name),
    StringQuery = string(Query),
    NOids=length(Oids),
    OidsBin=lists:foldl(fun(X,Acc)-> << Acc/binary ,X:32/integer>> end, << >>, Oids),
    encode($P, <<StringName/binary, StringQuery/binary, NOids:16/integer,OidsBin/binary>>);
encode_message(bind, Bind={NamePortal, NamePrepared,
                           Parameters, ParamsFormats,ResultFormats}) ->
    %%io:format("encode bind: ~p~n", [Bind]),
    PortalP = string(NamePortal),
    PreparedP = string(NamePrepared),
    NParameters = length(Parameters),

    {NParametersFormat, ParamFormatsP} =
        case ParamsFormats of
            none  -> {0,<<>>};
            binary-> {1,<<1:16/integer>>};
            text  -> {1,<<0:16/integer>>};
            auto  ->
                ParamFormatsList = lists:map(
                                     fun (Bin) when is_binary(Bin) -> <<1:16/integer>>;
                                         (Text) -> <<0:16/integer>> end,
                                     Parameters),
                {NParameters, erlang:concat_binary(ParamFormatsList)}
    end,

    ParametersList = lists:map(
                       fun (null) ->
                               Minus = -1,
                               <<Minus:32/integer>>;
                           (Bin) when is_binary(Bin) ->
                               Size = size(Bin),
                               <<Size:32/integer, Bin/binary>>;
                           (Integer) when is_integer(Integer) ->
                               List = integer_to_list(Integer),
                               Bin = list_to_binary(List),
                               Size = size(Bin),
                               <<Size:32/integer, Bin/binary>>;
                           (Text) ->
                               Bin = list_to_binary(Text),
                               Size = size(Bin),
                               <<Size:32/integer, Bin/binary>>
                       end,
                       Parameters),
    ParametersP = erlang:concat_binary(ParametersList),

    NResultFormats = length(ResultFormats),
    ResultFormatsList = lists:map(
                          fun (binary) -> <<1:16/integer>>;
                              (text) ->   <<0:16/integer>> end,
                          ResultFormats),
    ResultFormatsP = erlang:concat_binary(ResultFormatsList),

    %%io:format("encode bind: ~p~n", [{PortalP, PreparedP,
    %%			     NParameters, ParamFormatsP,
    %%			     NParameters, ParametersP,
    %%			     NResultFormats, ResultFormatsP}]),
    encode($B, <<PortalP/binary, PreparedP/binary,
                 NParametersFormat:16/integer, ParamFormatsP/binary,
                 NParameters:16/integer, ParametersP/binary,
                 NResultFormats:16/integer, ResultFormatsP/binary>>);
encode_message(execute, {Portal, Limit}) ->
    String = string(Portal),
    encode($E, <<String/binary, Limit:32/integer>>);
encode_message(sync, _) ->
    encode($S, <<>>).
    

