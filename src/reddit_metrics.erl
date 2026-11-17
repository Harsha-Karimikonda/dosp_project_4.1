%% Per-worker bounded histograms and one-second resource sampling, all in OTP.
-module(reddit_metrics).
-behaviour(gen_server).
-export([start_link/0,window/2,offered/1,record/3,finish/1,sample_start/1,write_json/2,read_json/1]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
window(Start,Stop) -> gen_server:call(?MODULE,{window,Start,Stop}).
offered(Op) -> gen_server:cast(?MODULE,{offered,now_ms(),Op}).
record(Op,Outcome,Latency) -> gen_server:cast(?MODULE,{record,now_ms(),Op,Outcome,Latency}).
finish(Path) -> gen_server:call(?MODULE,{finish,Path},30000).
now_ms() -> erlang:monotonic_time(millisecond).
init([]) -> {ok,#{start=>0,stop=>0,counts=>#{},total_latency=>0,max_latency=>0}}.
handle_call({window,Start,Stop},_,S) ->
  {reply,ok,S#{start:=Start,stop:=Stop,start_wall=>erlang:system_time(millisecond)+Start-now_ms()}};
handle_call({finish,Path},_,S) ->
  Rows=[#{operation=>atom_to_binary(O),outcome=>atom_to_binary(R),upper_ms=>B,count=>N}
        || {{O,R,B},N} <- maps:to_list(maps:get(counts,S))],
  Value=#{histogram=>Rows,total_latency_ms=>maps:get(total_latency,S),max_latency_ms=>maps:get(max_latency,S),
          duration_ms=>maps:get(stop,S)-maps:get(start,S),start_wall_ms=>maps:get(start_wall,S)},
  ok=write_json(Path,Value), {reply,Value,S}.
handle_cast({offered,At,Op},#{start:=A,stop:=B}=S) when At>=A,At<B ->
  {noreply,count({Op,offered,0},S)};
handle_cast({record,At,Op,Result,Latency},#{start:=A,stop:=B}=S) when At>=A,At<B ->
  Next=count({Op,Result,bucket(Latency,1)},S),
  {noreply,Next#{total_latency:=maps:get(total_latency,S)+Latency,max_latency:=max(Latency,maps:get(max_latency,S))}};
handle_cast(_,S) -> {noreply,S}.
handle_info(_,S) -> {noreply,S}.
count(Key,S) -> S#{counts:=maps:update_with(Key,fun(N)->N+1 end,1,maps:get(counts,S))}.
bucket(N,B) when N=<B -> B;
bucket(N,B) -> bucket(N,B*2).
sample_start(Path) -> spawn(fun()->sample_loop(Path) end).
sample_loop(Path) ->
  {Cpu,_}=statistics(runtime),
  Queue=case whereis(reddit_server) of undefined->0; Pid->case process_info(Pid,message_queue_len) of {_,N}->N; _->0 end end,
  Row=#{wall_ms=>erlang:system_time(millisecond),memory_bytes=>erlang:memory(total),cpu_ms=>Cpu,
        mailbox=>Queue,processes=>erlang:system_info(process_count)},
  ok=file:write_file(Path,[json:encode(Row),$\n],[append]),
  receive stop->ok after 1000->sample_loop(Path) end.
write_json(Path,V) -> file:write_file(Path,[json:encode(V),$\n]).
read_json(Path) -> {ok,B}=file:read_file(Path),json:decode(B).
