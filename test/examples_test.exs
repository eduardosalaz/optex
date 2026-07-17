defmodule Optex.ExamplesTest do
  # The examples are documentation that executes; this smoke test keeps them
  # from rotting as the API evolves. Each script is evaluated in-process (the
  # app is already loaded) with its output captured.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  for file <- Path.wildcard("examples/*.exs") do
    test "example #{Path.basename(file)} runs and reaches an optimum" do
      output = capture_io(fn -> Code.eval_file(unquote(file)) end)
      assert output =~ "optimal"
    end
  end
end
