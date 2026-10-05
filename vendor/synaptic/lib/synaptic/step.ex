defmodule Synaptic.Step do
  @moduledoc """
  Metadata structure for compiled workflow steps.
  """

  alias Synaptic.Validation

  defstruct [
    :name,
    input: %{},
    output: %{},
    validation_declared: nil,
    validation: Validation.default_step_validation(),
    suspend?: false,
    resume_schema: %{},
    max_retries: 0,
    type: :sequential,
    scorers: [],
    llm_branches: [],
    jev_branches: [],
    jev_fallback: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          input: map(),
          output: map(),
          validation_declared: keyword() | map() | nil,
          validation: keyword(),
          suspend?: boolean(),
          resume_schema: map(),
          max_retries: non_neg_integer(),
          type: :sequential | :parallel | :async | :llm | :jev,
          scorers: list(),
          llm_branches: list(),
          jev_branches: list(),
          jev_fallback: atom() | nil
        }

  @doc false
  def new(name, opts) do
    validation_declared = Keyword.get(opts, :validation)

    %__MODULE__{
      name: name,
      input: Keyword.get(opts, :input, %{}),
      output: Keyword.get(opts, :output, %{}),
      validation_declared: validation_declared,
      validation: Validation.normalize_step_validation(validation_declared),
      suspend?: Keyword.get(opts, :suspend, false),
      resume_schema: Keyword.get(opts, :resume_schema, %{}),
      max_retries: Keyword.get(opts, :retry, 0),
      type: Keyword.get(opts, :type, :sequential),
      scorers: Keyword.get(opts, :scorers, []),
      llm_branches: Keyword.get(opts, :llm_branches, []),
      jev_branches: Keyword.get(opts, :jev_branches, []),
      jev_fallback: Keyword.get(opts, :jev_fallback)
    }
  end

  @doc false
  def run(%__MODULE__{} = step, workflow_module, context) do
    apply(workflow_module, :__synaptic_handle__, [step.name, context])
  end
end
