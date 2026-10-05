defmodule RutviExercise.Runtime.Schema do
  def validate(_value, schema) when schema in [nil, %{}], do: :ok

  def validate(value, schema) do
    case ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(schema), value) do
      :ok -> :ok
      _ -> {:error, :validation_error}
    end
  rescue
    _ -> {:error, :validation_error}
  end

  def object(properties, required \\ []),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  def string, do: %{"type" => "string", "minLength" => 1}
end
