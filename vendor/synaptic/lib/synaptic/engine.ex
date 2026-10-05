defmodule Synaptic.Engine do
  @moduledoc """
  Internal orchestrator that glues workflow definitions to runtime runners.
  """

  alias Synaptic.{Runner, Security, Validation, Workflow}

  def start(workflow_module, input, opts) do
    definition = Workflow.definition(workflow_module)
    run_id = Keyword.get(opts, :run_id, generate_run_id())
    tenant = Keyword.get(opts, :tenant)

    input =
      if is_binary(tenant) and tenant != "" do
        Map.put(input, :__tenant__, tenant)
      else
        input
      end

    monitor_context =
      opts
      |> Keyword.get(:monitor_context, %{})
      |> Map.new()
      |> Map.put_new(:workflow, workflow_module)
      |> Map.put_new(:run_source, :direct)

    with {:ok, prepared_opts, _report} <- Security.prepare_opts(:workflow, opts),
         {:ok, start_at_step_index} <- validate_start_at_step(prepared_opts, definition),
         :ok <- validate_workflow_input(definition, start_at_step_index, input, prepared_opts) do
      child_spec_opts = [
        workflow: workflow_module,
        definition: definition,
        run_id: run_id,
        context: input,
        monitor_context: monitor_context,
        audit: Keyword.get(prepared_opts, :audit),
        runtime_security: Keyword.get(prepared_opts, :runtime_security),
        validation_defaults: Keyword.get(prepared_opts, :validation_defaults),
        tenant: tenant
      ]

      child_spec_opts =
        if start_at_step_index do
          Keyword.put(child_spec_opts, :start_at_step_index, start_at_step_index)
        else
          child_spec_opts
        end

      child_spec = {Runner, child_spec_opts}

      case DynamicSupervisor.start_child(Synaptic.RuntimeSupervisor, child_spec) do
        {:ok, _pid} ->
          {:ok, run_id}

        {:error, {:already_started, _pid}} ->
          {:error, :already_running}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_workflow_input(definition, start_at_step_index, input, opts) do
    step_index = start_at_step_index || 0

    case Enum.at(definition.steps, step_index) do
      nil ->
        :ok

      step ->
        validation = Validation.effective_step_validation(step, opts)
        Validation.validate_workflow_input(step.name, step.input, validation, input)
    end
  end

  defp validate_start_at_step(opts, definition) do
    case Keyword.get(opts, :start_at_step) do
      nil ->
        {:ok, nil}

      step_name when is_atom(step_name) ->
        case find_step_index(definition.steps, step_name) do
          nil -> {:error, :invalid_step}
          index -> {:ok, index}
        end

      _ ->
        {:error, :invalid_step}
    end
  end

  defp find_step_index(steps, step_name) do
    steps
    |> Enum.with_index()
    |> Enum.find_value(fn {%{name: name}, index} ->
      if name == step_name, do: index
    end)
  end

  def resume(run_id, payload) do
    Runner.resume(run_id, payload)
  end

  def inspect(run_id, timeout \\ 5000) do
    Runner.snapshot(run_id, timeout)
  end

  def history(run_id) do
    Runner.history(run_id)
  end

  def stop(run_id, reason) do
    Runner.stop(run_id, reason)
  end

  def purge(run_id) do
    Runner.purge(run_id)
  end

  def workflow_definition(module), do: Workflow.definition(module)

  def generate_run_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
