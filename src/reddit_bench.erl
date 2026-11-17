%% Builds/launches genuine OS processes through OTP peer; no external runner.
-module(reddit_bench).
-export([main/1,run/1,aggregate/2,percentile/2]).

main(["build"]) -> io:format("Compiled pure Erlang/OTP project.~n");
main(["test"]) -> ok=eunit:test(reddit_tests,[verbose]);
main(["demo"|Rest]) -> demo(options(Rest));
main(["simulate"|Rest]) -> _=run(options(Rest)),ok;
main(["benchmark"|Rest]) -> benchmark(options(Rest));
main(["report"|Rest]) -> reddit_report:generate(options(Rest));
main(["package"|Rest]) -> package(options(Rest));
main(_) -> io:format("Usage: escript scripts/project4.escript build|test|demo|simulate|benchmark|report|package [--key value]~n"
 "Options: --users 100 --workers 2 --communities 100 --warmup 10 --duration 30~n"
 "         --seed 42 --interval 1000 --schedulers 2 --budget 900 --output PATH~n"),error(invalid_arguments).

options(Args) ->
  Defaults=#{users=>100,workers=>2,communities=>100,warmup=>10,duration=>30,seed=>42,
             interval=>1000,schedulers=>2,budget=>900},
  C=parse(Args,Defaults),
  [begin V=maps:get(K,C),true=is_integer(V) andalso V>0 end || K<-[users,workers,communities,duration,interval,schedulers,budget]],
  true=maps:get(warmup,C)>=0,true=maps:get(workers,C)=<maps:get(users,C),C.
parse([],C) -> C;
parse(["--resume"|Rest],C) -> parse(Rest,C#{resume=>true});
parse(["--output",V|Rest],C) -> parse(Rest,C#{output=>filename:absname(V)});
parse(["--members",V|Rest],C) -> parse(Rest,C#{members=>filename:absname(V)});
parse(["--input",V|Rest],C) -> parse(Rest,C#{input=>filename:absname(V)});
parse([[ $-,$- | Key],V|Rest],C) ->
  Keys=#{"users"=>users,"workers"=>workers,"communities"=>communities,"warmup"=>warmup,
         "duration"=>duration,"seed"=>seed,"interval"=>interval,"schedulers"=>schedulers,"budget"=>budget},
  case maps:find(Key,Keys) of {ok,K}->parse(Rest,C#{K=>list_to_integer(V)});error->error({unknown_option,Key}) end;
parse(Args,_) -> error({invalid_options,Args}).
unique() -> integer_to_list(erlang:system_time(microsecond))++"_"++integer_to_list(erlang:unique_integer([positive])).
output(C,Prefix) -> maps:get(output,C,filename:absname(filename:join("results",Prefix++unique()))).
make_out(Out) ->
  ok=filelib:ensure_dir(filename:join(filename:dirname(Out),"placeholder")),
  case file:make_dir(Out) of ok->ok;{error,eexist}->error({output_already_exists,Out}); E->error(E) end.
start_peer(Role,Tag,Cookie,C) ->
  Ebin=filename:absname("build/ebin"),
  Args=["+S",integer_to_list(maps:get(schedulers,C))++":"++integer_to_list(maps:get(schedulers,C)),
        "-setcookie",Cookie,"-kernel","inet_dist_use_interface","{127,0,0,1}","-connect_all","false","-pa",Ebin],
  {ok,Peer,Node}=peer:start_link(#{name=>list_to_atom("p4_"++Role++"_"++Tag),host=>"127.0.0.1",
      longnames=>true,connection=>standard_io,args=>Args,wait_boot=>30000}),
  put(peers,[Peer|get(peers)]),{Peer,Node}.
cleanup() -> [try peer:stop(P) catch _:_ -> ok end || P<-get(peers)],erase(peers),ok.
call(P,M,F,A) -> peer:call(P,M,F,A,300000).
start_engine(Peer,Out) ->
  {ok,[reddit]}=call(Peer,application,ensure_all_started,[reddit]),
  _=call(Peer,reddit_metrics,sample_start,[filename:join(Out,"engine-resources.jsonl")]),ok.
stats(Peer,Node,Out,Name) ->
  {ok,V}=call(Peer,reddit_server,request,[Node,<<>>,inspect,10000]),
  ok=reddit_metrics:write_json(filename:join(Out,Name),V),V.

run(C) ->
  Out=output(C,"run-"),make_out(Out),put(peers,[]),Tag=unique(),Cookie="local_"++Tag,
  io:format("Setup: ~B users; ~B independent client OS processes; ~s~n",[maps:get(users,C),maps:get(workers,C),Out]),
  try
    {Engine,Node}=start_peer("engine",Tag,Cookie,C),start_engine(Engine,Out),
    InitialPid=call(Engine,erlang,whereis,[reddit_server]),
    _=call(Engine,reddit_sim,seed,[maps:get(users,C),maps:get(communities,C)]),
    Workers=[begin
      {P,N}=start_peer("client"++integer_to_list(I),Tag,Cookie,C),
      Config=#{engine=>Node,users=>maps:get(users,C),worker=>I,workers=>maps:get(workers,C),
               seed=>maps:get(seed,C),warmup_ms=>1000*maps:get(warmup,C),duration_ms=>1000*maps:get(duration,C),
               interval_ms=>maps:get(interval,C),output=>Out},
      ok=call(P,reddit_sim,start,[Config]),{I,P,N}
    end || I<-lists:seq(0,maps:get(workers,C)-1)],
    wait_workers(Workers,ready,erlang:monotonic_time(millisecond)+300000),
    _=stats(Engine,Node,Out,"initial.json"),
    At=erlang:system_time(millisecond)+1500,
    [ok=call(P,reddit_sim,release,[At]) || {_,P,_}<-Workers],
    io:format("Running: ~Bs warmup + ~Bs measurement~n",[maps:get(warmup,C),maps:get(duration,C)]),
    Deadline=erlang:monotonic_time(millisecond)+1000*(maps:get(warmup,C)+maps:get(duration,C)+30),
    wait_workers(Workers,finished,Deadline),
    InitialPid=call(Engine,erlang,whereis,[reddit_server]),
    _=stats(Engine,Node,Out,"final.json"),
    Summary=aggregate(Out,C),
    ok=reddit_metrics:write_json(filename:join(Out,"summary.json"),Summary),
    io:format("Done: ~.1f successful requests/s; p95 <= ~p ms; ~p~n",
      [maps:get(success_throughput_per_s,Summary),maps:get(p95_ms,Summary),maps:get(outcomes,Summary)]),
    Summary
  after cleanup() end.
wait_workers(Workers,Expected,Deadline) ->
  States=[call(P,reddit_sim,status,[]) || {_,P,_}<-Workers],
  case [S || S<-States,is_tuple(S)] of []->ok;Fail->error({simulator_failed,Fail}) end,
  case lists:all(fun(S)->S=:=Expected end,States) of
    true->ok;
    false->
      case erlang:monotonic_time(millisecond)>Deadline of true->error({simulator_timeout,Expected,States});false->ok end,
      timer:sleep(200),wait_workers(Workers,Expected,Deadline)
  end.

demo(C) ->
  Out=output(C,"demo-"),make_out(Out),put(peers,[]),Tag=unique(),Cookie="local_"++Tag,
  try
    {Engine,Node}=start_peer("engine",Tag,Cookie,C),start_engine(Engine,Out),
    {Client,_}=start_peer("demo",Tag,Cookie,C),
    ok=call(Client,reddit_tests,remote_demo,[Node]),
    _=stats(Engine,Node,Out,"final.json"),
    ok=peer:stop(Engine),put(peers,[Client]),
    {error,unavailable}=call(Client,reddit_server,request,[Node,<<"alice">>,{feed,none,20},1000]),
    ok=reddit_metrics:write_json(filename:join(Out,"result.json"),#{passed=>true,
        scenarios=>[<<"features across OS processes">>,<<"concurrent votes">>,<<"offline delivery">>,
                    <<"request timeout">>,<<"engine OS process unavailable">>]}),
    io:format("PASS: distributed feature demo, concurrent votes, offline/reconnect, timeout, stopped engine.~n")
  after cleanup() end.

aggregate(Out,C) ->
  Metrics=[reddit_metrics:read_json(P) || P<-filelib:wildcard(filename:join(Out,"worker*-metrics.json"))],
  Rows=lists:append([maps:get(<<"histogram">>,M) || M<-Metrics]),
  Offered=lists:sum([maps:get(<<"count">>,R) || R<-Rows,maps:get(<<"outcome">>,R)=:= <<"offered">>]),
  Completed=[R || R<-Rows,maps:get(<<"outcome">>,R)=/= <<"offered">>],
  {Histogram,Outcomes,Operations}=lists:foldl(fun(R,{H,O,Ops})->
    Op=maps:get(<<"operation">>,R),Outcome=maps:get(<<"outcome">>,R),N=maps:get(<<"count">>,R),B=maps:get(<<"upper_ms">>,R),
    Current=maps:get(Op,Ops,#{hist=>#{},outcomes=>#{}}),
    Next=Current#{hist:=add(B,N,maps:get(hist,Current)),outcomes:=add(Outcome,N,maps:get(outcomes,Current))},
    {add(B,N,H),add(Outcome,N,O),maps:put(Op,Next,Ops)}
  end,{#{},#{},#{}},Completed),
  OpSummary=maps:map(fun(Op,#{hist:=H,outcomes:=O})->
    #{outcomes=>O,p50_ms=>percentile(H,0.50),p95_ms=>percentile(H,0.95),p99_ms=>percentile(H,0.99),
      offered=>lists:sum([maps:get(<<"count">>,R) || R<-Rows,maps:get(<<"operation">>,R)=:=Op,maps:get(<<"outcome">>,R)=:= <<"offered">>])}
  end,Operations),
  Start=lists:min([maps:get(<<"start_wall_ms">>,M)||M<-Metrics]),
  Stop=lists:max([maps:get(<<"start_wall_ms">>,M)+maps:get(<<"duration_ms">>,M)||M<-Metrics]),
  Resources=resources(Out,Start,Stop),
  Total=lists:sum(maps:values(Outcomes)),Ok=maps:get(<<"ok">>,Outcomes,0),Timeouts=maps:get(<<"timeout">>,Outcomes,0),
  Before=reddit_metrics:read_json(filename:join(Out,"initial.json")),After=reddit_metrics:read_json(filename:join(Out,"final.json")),
  Members=maps:get(<<"memberships">>,Before),Counts0=maps:get(<<"post_counts">>,Before),Counts=maps:get(<<"post_counts">>,After),
  Exact=lists:all(fun(Rank)->
    Name= <<"r",(integer_to_binary(Rank))/binary>>,
    maps:get(Name,Members)=:=max(1,trunc(maps:get(users,C)/math:pow(Rank,1.1)))+1
  end,lists:seq(1,maps:get(communities,C))),
  Correlation=correlation([{maps:get(Name,Members),N-maps:get(Name,Counts0,0)} || {Name,N}<-maps:to_list(Counts)]),
  P95=percentile(Histogram,0.95), SuccessRate=ratio(Ok,Total),TimeoutRate=ratio(Timeouts,Total),
  Queue=maps:get(mailbox_samples,maps:get(<<"engine">>,Resources,#{}),[]),
  Growth=growth(Queue),
  #{users=>maps:get(users,C),workers=>maps:get(workers,C),communities=>maps:get(communities,C),
    seed=>maps:get(seed,C),duration_s=>maps:get(duration,C),warmup_s=>maps:get(warmup,C),interval_ms=>maps:get(interval,C),
    schedulers_per_node=>maps:get(schedulers,C),offered_requests=>Offered,offered_per_s=>Offered/maps:get(duration,C),
    observed_completions=>Total,outcomes=>Outcomes,completion_throughput_per_s=>Total/maps:get(duration,C),
    success_throughput_per_s=>Ok/maps:get(duration,C),success_rate=>SuccessRate,timeout_rate=>TimeoutRate,
    p50_ms=>percentile(Histogram,0.50),p95_ms=>P95,p99_ms=>percentile(Histogram,0.99),operations=>OpSummary,
    resources=>Resources,membership_zipf_exact=>Exact,membership_post_correlation=>Correlation,
    new_reposts=>maps:get(<<"reposts">>,After)-maps:get(<<"reposts">>,Before),
    final_online=>maps:get(<<"online">>,After),sustained_mailbox_growth=>Growth,
    slo_pass=>Total>0 andalso SuccessRate>=0.99 andalso TimeoutRate<0.01 andalso is_number(P95) andalso P95<1000 andalso not Growth,
    architecture=>list_to_binary(erlang:system_info(system_architecture)),logical_cpus=>erlang:system_info(logical_processors_available),
    otp_release=>list_to_binary(erlang:system_info(otp_release)),
    notes=>[<<"Percentiles are upper bounds from power-of-two millisecond histograms.">>,
      <<"Offered uses request-start time; completions use response time, so window boundaries can differ.">>,
      <<"Resource samples occur once per second inside the measurement window; CPU spans first to last sample.">>,
      <<"Closed-loop online users wait for responses then sleep; offline users pause.">>,
      <<"Membership counts include one seed account; post counts include warmup activity.">>] }.
add(K,N,M) -> maps:update_with(K,fun(X)->X+N end,N,M).
ratio(_,0) -> 0.0;
ratio(A,B) -> A/B.
percentile(Hist,Q) ->
  Total=lists:sum(maps:values(Hist)),
  case Total of 0->null; _->percentile_rows(lists:sort(maps:to_list(Hist)),ceil(Total*Q),0) end.
percentile_rows([{B,N}|Rest],Target,Acc) ->
  case Acc+N>=Target of true->B;false->percentile_rows(Rest,Target,Acc+N) end.
resources(Out,Start,Stop) ->
  maps:from_list([begin
    {ok,B}=file:read_file(Path),
    Samples=[json:decode(Line)||Line<-binary:split(B,<<"\n">>,[global]),Line=/= <<>>],
    Window=[S||S<-Samples,maps:get(<<"wall_ms">>,S)>=Start,maps:get(<<"wall_ms">>,S)<Stop],
    Stats=case Window of []->#{}; _->
      A=hd(Window),Z=lists:last(Window),
      #{peak_memory_bytes=>lists:max([maps:get(<<"memory_bytes">>,S)||S<-Window]),
        peak_mailbox=>lists:max([maps:get(<<"mailbox">>,S)||S<-Window]),
        mailbox_samples=>[maps:get(<<"mailbox">>,S)||S<-Window],samples=>length(Window),
        cpu_ms=>maps:get(<<"cpu_ms">>,Z)-maps:get(<<"cpu_ms">>,A),
        elapsed_ms=>maps:get(<<"wall_ms">>,Z)-maps:get(<<"wall_ms">>,A)} end,
    Name=filename:basename(Path,"-resources.jsonl"),{list_to_binary(Name),Stats}
  end || Path<-filelib:wildcard(filename:join(Out,"*-resources.jsonl"))]).
growth(Q) when length(Q)<6 -> false;
growth(Q) ->
  Last=lists:nthtail(length(Q)-6,Q),
  lists:last(Last)>100 andalso increasing(Last).
increasing([_]) -> true;
increasing([A,B|Rest]) -> B>A andalso increasing([B|Rest]).
correlation(Pairs) ->
  N=length(Pairs), MX=lists:sum([X||{X,_}<-Pairs])/N,MY=lists:sum([Y||{_,Y}<-Pairs])/N,
  Den=math:sqrt(lists:sum([math:pow(X-MX,2)||{X,_}<-Pairs])*lists:sum([math:pow(Y-MY,2)||{_,Y}<-Pairs])),
  case Den == 0 of true->null; false->lists:sum([(X-MX)*(Y-MY)||{X,Y}<-Pairs])/Den end.

benchmark(C) ->
  Out=maps:get(output,C,filename:absname("results/benchmark")),
  Resume=maps:get(resume,C,false),
  Existing=case Resume of
    false->make_out(Out),[];
    true->[maps:from_list([{binary_to_existing_atom(K,utf8),V} || {K,V}<-maps:to_list(R)])
           ||R<-reddit_metrics:read_json(filename:join(Out,"results.json"))]
  end,
  NowWall=erlang:system_time(millisecond),
  PriorStart=case Resume of
    false->NowWall;
    true->lists:min([begin
      {ok,B}=file:read_file(P),[Line|_]=binary:split(B,<<"\n">>,[global]),
      maps:get(<<"wall_ms">>,json:decode(Line))
    end ||P<-filelib:wildcard(filename:join([Out,"*","engine-resources.jsonl"]))])
  end,
  Start=erlang:monotonic_time(second)-(NowWall-PriorStart) div 1000,
  Jobs=[{N,R}||{N,Reps}<-[{100,3},{1000,3},{10000,3},{20000,1},{50000,1}],R<-lists:seq(1,Reps)],
  Pending=[{N,R}||{N,R}<-Jobs,not lists:any(fun(E)->maps:get(users,E)=:=N andalso maps:get(seed,E)=:=41+R end,Existing)],
  {Results,Failures,Reason}=sweep(Pending,C,Out,Start,lists:reverse(Existing),[]),
  ok=reddit_metrics:write_json(filename:join(Out,"results.json"),Results),
  MaxTested=lists:max([0|[maps:get(users,R)||R<-Results]++[maps:get(users,F)||F<-Failures]]),
  Summary=#{runs=>length(Results),elapsed_s=>erlang:monotonic_time(second)-Start,budget_s=>maps:get(budget,C),
      stop_reason=>Reason,failures=>Failures,largest_tested=>MaxTested,
      largest_passing=>lists:max([0|[maps:get(users,R)||R<-Results,maps:get(slo_pass,R)]])},
  ok=reddit_metrics:write_json(filename:join(Out,"sweep.json"),Summary),
  io:format("Sweep complete: ~p~n",[Summary]),
  case Failures of []->ok;_->error(benchmark_run_failed) end.
sweep([],_,_,_,Results,Failures) -> {lists:reverse(Results),Failures,<<"All configured populations tested; no larger population claimed.">>};
sweep([{N,R}|Rest],C,Out,Start,Results,Failures) ->
  case erlang:monotonic_time(second)-Start>maps:get(budget,C)-70 of
    true->{lists:reverse(Results),Failures,<<"Wall-clock budget reached.">>};
    false->
      RunOut=filename:join(Out,"u"++integer_to_list(N)++"-r"++integer_to_list(R)),
      case maps:get(resume,C,false) andalso filelib:is_dir(RunOut) of
        true ->
          Archive=filename:absname(filename:join(["build","interrupted",filename:basename(RunOut)++"-"++unique()])),
          ok=filelib:ensure_dir(filename:join(filename:dirname(Archive),"placeholder")),
          ok=file:rename(RunOut,Archive),
          io:format("Preserved interrupted evidence at ~s~n",[Archive]);
        false -> ok
      end,
      try run(C#{users=>N,seed=>41+R,output=>RunOut}) of
        Result ->
          Next=[Result|Results],
          ok=reddit_metrics:write_json(filename:join(Out,"results.json"),lists:reverse(Next)),
          case maps:get(slo_pass,Result) of
            true->sweep(Rest,C,Out,Start,Next,Failures);
            false->{lists:reverse(Next),Failures,<<"Completion, timeout, latency or sustained mailbox-growth criterion failed.">>}
          end
      catch Class:Why:Stack ->
        Failure=#{users=>N,repetition=>R,error=>list_to_binary(io_lib:format("~p:~p ~p",[Class,Why,Stack]))},
        {lists:reverse(Results),[Failure|Failures],<<"Run failure; see failure evidence.">>}
      end
  end.
package(C) ->
  Out=maps:get(output,C,filename:absname("project4.zip")),
  Files=["README.md","SUBMISSION_COMMENT.txt",".gitignore"]++filelib:wildcard("src/*")++
        filelib:wildcard("test/*")++filelib:wildcard("scripts/*.escript")++filelib:wildcard("config/*")++
        filelib:fold_files("results",".*",true,fun(P,Acc)->[P|Acc] end,[]),
  true=lists:all(fun(P)->not lists:member(filename:extension(P),[".pdf",".py",".pyc",".gleam"]) end,Files),
  {ok,_}=zip:create(Out,Files,[]),io:format("Created ~s (~B files; report PDF excluded).~n",[Out,length(Files)]).
