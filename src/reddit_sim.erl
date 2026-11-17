-module(reddit_sim).
-export([seed/2,start/1,status/0,release/1,member/3,username/1]).
username(Id) -> <<"u",(integer_to_binary(Id))/binary>>.
community(Rank) -> <<"r",(integer_to_binary(Rank))/binary>>.
member(User,Rank,Total) ->
  ((User-1+Rank*7919) rem Total)<max(1,trunc(Total/math:pow(Rank,1.1))).
seed(Users,Communities) ->
  {ok,done}=call(node(),<<>>,{register,<<"seed">>}),
  Fixtures=[begin
    Name=community(Rank),
    {ok,done}=call(node(),<<"seed">>,{create,Name}),
    {ok,{created,P}}=call(node(),<<"seed">>,{post,Name,<<"Seed post">>,none}),
    {ok,{created,C}}=call(node(),<<"seed">>,{comment,P,none,<<"Seed comment">>}),
    {Name,P,C}
  end || Rank<-lists:seq(1,Communities)],
  persistent_term:put(reddit_fixture,Fixtures),
  #{users=>Users,communities=>Communities}.
call(Node,U,Op) -> reddit_server:request(Node,U,Op,30000).
status() -> persistent_term:get(sim_status,starting).
start(Config) ->
  persistent_term:put(sim_status,starting),
  Parent=self(),
  Pid=spawn(fun()->
    receive go->ok end,
    try coordinator(Config)
    catch Class:Why:Stack -> persistent_term:put(sim_status,{failed,Class,Why,Stack})
    end,
    Parent ! simulator_finished
  end),
  register(sim_coordinator,Pid), Pid ! go, ok.
release(At) -> sim_coordinator ! {release,At},ok.
coordinator(#{engine:=Engine,users:=N,worker:=Worker,workers:=Workers,seed:=Seed,
              warmup_ms:=Warmup,duration_ms:=Duration,interval_ms:=Interval,output:=Out}) ->
  {ok,_}=reddit_metrics:start_link(),
  reddit_metrics:sample_start(filename:join(Out,"worker"++integer_to_list(Worker)++"-resources.jsonl")),
  Fixtures=rpc:call(Engine,persistent_term,get,[reddit_fixture]),
  Parent=self(),
  Clients=[spawn_monitor(fun()->setup(Engine,Id,N,Fixtures,Seed,Interval,Parent) end)
           || Id<-lists:seq(1,N),Id rem Workers=:=Worker],
  await(Clients,ready),
  persistent_term:put(sim_status,ready),
  receive {release,Wall}->timer:sleep(max(0,Wall-erlang:system_time(millisecond))) end,
  Start=erlang:monotonic_time(millisecond)+Warmup, Stop=Start+Duration,
  ok=reddit_metrics:window(Start,Stop),
  [Pid ! {run,Stop} || {Pid,_}<-Clients],
  persistent_term:put(sim_status,running),
  await(Clients,finished),
  Path=filename:join(Out,"worker"++integer_to_list(Worker)++"-metrics.json"),
  _=reddit_metrics:finish(Path),
  persistent_term:put(sim_status,finished).
await(Clients,Kind) -> await_clients(maps:from_list(Clients),Kind).
await_clients(Clients,_) when map_size(Clients)=:=0 -> ok;
await_clients(Clients,Kind) ->
  receive
    {Kind,Pid} ->
      case maps:take(Pid,Clients) of
        {Ref,Rest} ->
          case Kind of finished->demonitor(Ref,[flush]); _->ok end,
          await_clients(Rest,Kind);
        error -> error({unexpected_client,Pid,Kind})
      end;
    {'DOWN',_,process,Pid,Reason} -> error({client_exited_before,Kind,Pid,Reason})
  after 300000 -> error({clients_timeout,Kind,map_size(Clients)})
  end.
setup(Engine,Id,N,Fixtures,Seed,Interval,Parent) ->
  rand:seed(exsss,{Seed*100003+Id,Id+17,Seed+101}),
  U=username(Id), {ok,done}=call(Engine,U,{register,U}),
  Mine=[F || {F,Rank}<-lists:zip(Fixtures,lists:seq(1,length(Fixtures))),member(Id,Rank,N)],
  [begin {ok,done}=call(Engine,U,{join,Name}) end || {Name,_,_}<-Mine],
  {ok,{created,Message}}=call(Engine,<<"seed">>,{send_message,U,<<"Seed direct message">>}),
  {_,P,_}=hd(Mine),
  Parent ! {ready,self()},
  receive {run,Stop}->
    timer:sleep(rand:uniform(Interval)-1),
    loop(#{engine=>Engine,user=>U,total=>N,fixtures=>Mine,last_post=>P,message=>Message,interval=>Interval,seed_comments=>maps:from_list([{Name,SC} || {Name,_,SC}<-Mine])},
         Stop,now_ms()+5000+random(10000))
  end,
  Parent ! {finished,self()}.
now_ms() -> erlang:monotonic_time(millisecond).
random(Max) -> rand:uniform(Max)-1.
request(C,Name,Op) ->
  Before=now_ms(), reddit_metrics:offered(Name),
  R=reddit_server:request(maps:get(engine,C),maps:get(user,C),Op,3000),
  Result=case R of {ok,_}->ok; {error,timeout}->timeout; _->error end,
  reddit_metrics:record(Name,Result,now_ms()-Before), R.
loop(C,Stop,Disconnect) ->
  Now=now_ms(),
  if Now>=Stop -> ok;
     Now>=Disconnect ->
       _=request(C,disconnect,{online,false}),
       timer:sleep(min(2000+random(3000),max(0,Stop-now_ms()))),
       _=request(C,reconnect,{online,true}),
       loop(C,Stop,now_ms()+5000+random(10000));
     true ->
       Next=action(C),timer:sleep(min(maps:get(interval,C),max(0,Stop-now_ms()))),
       loop(Next,Stop,Disconnect)
  end.
action(#{fixtures:=Fixtures}=C) ->
  {Community,P,Comment}=lists:nth(random(length(Fixtures))+1,Fixtures),
  case random(100) of
    N when N<30 ->
      case request(C,feed,{feed,none,20}) of
        {ok,{posts,[#{id:=Id}|_]}} -> C#{last_post:=Id}; _->C
      end;
    N when N<55 ->
      {Name,Original}=case random(10) of 0->{repost,maps:get(last_post,C)}; _->{post,none} end,
      _=request(C,Name,{post,Community,<<"Simulated text post">>,Original}), C;
    N when N<75 ->
      {Name,Parent}=case random(2) of 0->{nested_comment,Comment}; _->{comment,none} end,
      case request(C,Name,{comment,P,Parent,<<"Simulated comment">>}) of
        {ok,{created,Id}} -> C#{fixtures:=lists:keyreplace(Community,1,Fixtures,{Community,P,Id})}; _->C
      end;
    N when N<90 ->
      Target=case random(2) of 0->{post,P}; _->{comment,maps:get(Community,maps:get(seed_comments,C))} end,
      _=request(C,vote,{vote,Target,random(3)-1}), C;
    N when N<95 ->
      case random(3) of
        0 -> _=request(C,send_message,{send_message,username(random(maps:get(total,C))+1),<<"Hello">>}),C;
        1 -> _=request(C,reply_message,{reply_message,maps:get(message,C),<<"Reply">>}),C;
        2 -> case request(C,inbox,{inbox,none,20}) of
          {ok,{messages,[#{id:=Id}|_]}} -> C#{message:=Id}; _->C
        end
      end;
    _ ->
      _=request(C,leave,{leave,Community}),_=request(C,join,{join,Community}),
      %% Joining again restores the client's known membership set.
      C
  end.
