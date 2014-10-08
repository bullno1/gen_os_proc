-module(gen_os_proc).
-behaviour(gen_server).
-export([start_link/1, start_link/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2, format_status/2]).

-record(state, {
	port,
	listener,
	hibernate_timeout,
	buff = []
}).

start_link(Cmd) -> start_link(Cmd, []).

start_link(Cmd, Opts) ->
	gen_server:start_link(?MODULE, {self(), Cmd, Opts}, Opts).

stop(Ref) -> gen_server:call(Ref, stop).

% gen_server

init({Listener, Cmd, Opts}) ->
	{ok, Cwd} = file:get_cwd(),
	PortOpts = [
		{line, 2048},
		{cd, Cwd},
		{args, ["sh", "-c", Cmd]},
		exit_status |
		proplists:get_value(port_opts, Opts, [])
	],
	ProcOpts = proplists:get_value(proc_opts, Opts, []),
	Wrapper = filename:absname(filename:join(code:priv_dir(gen_os_proc), "gen_os_proc")),
	Port = erlang:open_port({spawn_executable, Wrapper}, PortOpts),
	process_flag(trap_exit, true),
	HibernateTimeout = proplists:get_value(hibernate_timeout, ProcOpts, infinity),
	State = #state{
		port = Port,
		listener = Listener,
		hibernate_timeout = HibernateTimeout
	},
	{ok, State, HibernateTimeout}.

terminate(_Reason, #state{port = Port}) ->
	catch erlang:port_close(Port).

handle_call(stop, _From, State) -> {stop, normal, ok, State}.

handle_cast(_Req, State) -> {stop, unexpected, State}.

handle_info({Port, Msg}, #state{port = Port} = State) -> handle_port_msg(Msg, State);

handle_info({'EXIT', Port, _}, #state{hibernate_timeout = Timeout} = State) when is_port(Port) ->
	{noreply, State, Timeout}; %already handled

handle_info(timeout, State) -> {noreply, State, hibernate}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

format_status(_Opt, [_PDict, State]) ->
	FormattedState = lists:zip(record_info(fields, state), tl(tuple_to_list(State))),
	[{data, [{"State", FormattedState}]}].

% private

handle_port_msg({exit_status, Status}, State) -> {stop, {process_terminated, Status}, State};

handle_port_msg({data, {noeol, Data}}, #state{buff = Buff, hibernate_timeout = Timeout} = State) ->
	{noreply, State#state{buff = [Data | Buff]}, Timeout};

handle_port_msg({data, {eol, Data}}, #state{buff = Buff, listener = Listener, hibernate_timeout = Timeout} = State) ->
	Line = lists:flatten(lists:reverse(Buff, Data)),
	Listener ! {line, self(), Line},
	{noreply, State#state{buff = []}, Timeout}.
