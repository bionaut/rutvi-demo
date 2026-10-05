defmodule RutviExercise.SynapticSmokeTest do
  use ExUnit.Case, async: false

  defmodule EchoWorkflow do
    use Synaptic.Workflow

    step :echo do
      {:ok, %{smoke_result: context.input}}
    end

    commit()
  end

  test "starts the OTP application and a local workflow" do
    assert is_pid(Process.whereis(RutviExercise.Supervisor))

    run_id = "prep-smoke-#{System.unique_integer([:positive])}"
    assert {:ok, ^run_id} = Synaptic.start(EchoWorkflow, %{input: "ready"}, run_id: run_id)

    assert_eventually(fn ->
      case Synaptic.inspect(run_id) do
        %{status: :completed, context: %{smoke_result: "ready"}} -> true
        _ -> false
      end
    end)

    assert is_list(Synaptic.history(run_id))
  end

  defp assert_eventually(predicate, attempts \\ 50)
  defp assert_eventually(_predicate, 0), do: flunk("workflow did not complete")

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
