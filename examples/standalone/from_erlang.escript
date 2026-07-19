#!/usr/bin/env escript
%% Optex from plain Erlang.
%%
%% Everything below the DSL is ordinary BEAM territory: models are maps,
%% the API is plain functions, solutions are maps, and the NIF neither
%% knows nor cares which language called it. What does NOT carry over is
%% the `model do ... end` DSL (Elixir macros are compile-time), so an
%% Erlang (or Gleam, via @external bindings) caller uses the programmatic
%% Optex.Model API: add_variable/2, add_constraint/5 with terms lists,
%% set_objective/3, then Optex.optimize/2.
%%
%% Run from the repo root after `mix compile`, passing the Elixir lib dir
%% with FORWARD slashes (filelib:wildcard treats backslashes as escapes):
%%
%%     escript examples/standalone/from_erlang.escript "C:/Program Files/Elixir/lib"
%%     escript examples/standalone/from_erlang.escript /usr/lib/elixir/lib
%%
%% (In a real Erlang project you would depend on optex through rebar3's
%% Mix support instead of hand-wiring code paths; this script just proves
%% the runtime story with zero scaffolding.)
main([ElixirLib]) ->
    code:add_paths(filelib:wildcard(ElixirLib ++ "/*/ebin")),
    code:add_paths(filelib:wildcard("_build/dev/lib/*/ebin")),
    application:load(optex),

    M0 = 'Elixir.Optex.Model':new(),
    {_X, M1} = 'Elixir.Optex.Model':add_variable(M0, [{name, x}, {lb, 0.0}, {ub, 4.0}]),
    {_Y, M2} = 'Elixir.Optex.Model':add_variable(M1, [{name, y}, {lb, 0.0}]),
    M3 = 'Elixir.Optex.Model':add_constraint(M2, [{x, 1.0}, {y, 2.0}], le, 7.0, [{name, budget}]),
    M4 = 'Elixir.Optex.Model':set_objective(M3, [{x, 1.0}, {y, 3.0}], max),

    {ok, Sol} = 'Elixir.Optex':optimize(M4, []),

    Values = maps:get(values, Sol),
    io:format("status: ~p~n", [maps:get(status, Sol)]),
    io:format("objective: ~p~n", [maps:get(objective, Sol)]),
    io:format("x = ~p, y = ~p~n", [maps:get(x, Values), maps:get(y, Values)]),
    io:format("dual of budget row: ~p~n", [maps:get(budget, maps:get(duals, Sol))]).
