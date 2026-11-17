#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main(Args) ->
  Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
  ok=file:set_cwd(Root),
  ok=filelib:ensure_dir("build/ebin/placeholder"),
  true=code:add_patha(filename:join(Root,"build/ebin")),
  Sources=filelib:wildcard("src/*.erl")++filelib:wildcard("test/*.erl"),
  lists:foreach(fun(Path)->
    case compile:file(Path,[debug_info,warnings_as_errors,report_errors,report_warnings,{outdir,"build/ebin"}]) of
      {ok,_}->ok; Other->io:format(standard_error,"Compilation failed: ~p~n",[Other]),halt(1)
    end
  end,Sources),
  {ok,_}=file:copy("src/reddit.app.src","build/ebin/reddit.app"),
  try reddit_bench:main(Args)
  catch Class:Reason:Stack ->
    io:format(standard_error,"~p: ~p~n~p~n",[Class,Reason,Stack]),halt(1)
  end.
