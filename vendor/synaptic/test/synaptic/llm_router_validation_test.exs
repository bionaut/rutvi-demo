defmodule Synaptic.LLMRouterValidationTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    def chat(_, _) do
      {:ok, Process.get(:route_response)}
    end
  end

  @branches [{"first", :first}, {"second", :route2}]

  test "invalid numeric choices never select an in-range branch" do
    for choice <- [0, -1, -2, 3, 1.5, 2.0, "0", "-1", "1 and 2"] do
      Process.put(:route_response, %{"choice" => choice})
      assert {:error, _} = Synaptic.LLMRouter.evaluate(%{}, @branches, %{}, adapter: Adapter)
    end
  end

  test "structured and bare responses preserve exact named targets and valid indices" do
    for {response, expected} <- [
          {%{"choice" => 1}, :first},
          {%{"target" => "route2"}, :route2},
          {"route2", :route2},
          {"1", :first},
          {~s({"target":"route2"}), :route2},
          {~s({"choice":2}), :route2},
          {%{"choice" => "route2"}, :route2}
        ] do
      Process.put(:route_response, response)
      assert {:ok, ^expected} = Synaptic.LLMRouter.evaluate(%{}, @branches, %{}, adapter: Adapter)
    end
  end

  test "unknown targets and empty branches are rejected" do
    Process.put(:route_response, %{"target" => "unknown"})
    assert {:error, _} = Synaptic.LLMRouter.evaluate(%{}, @branches, %{}, adapter: Adapter)

    assert {:error, :invalid_branches} =
             Synaptic.LLMRouter.evaluate(%{}, [], %{}, adapter: Adapter)
  end

  test "model runtime options reach the adapter while workflow timeout remains a step option" do
    opts = [
      model: "test",
      adapter: Adapter,
      reasoning_effort: "low",
      receive_timeout: 3000,
      max_retries: 0,
      timeout: 4000
    ]

    {llm_opts, step_opts} = Synaptic.Workflow.__split_llm_router_opts__(opts)
    assert llm_opts == Keyword.delete(opts, :timeout)
    assert step_opts == [timeout: 4000]
  end
end
