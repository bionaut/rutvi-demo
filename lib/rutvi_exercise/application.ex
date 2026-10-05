defmodule RutviExercise.Application do
  use Application

  def start(_type, _args) do
    children = [
      RutviExercise.Store,
      {Task.Supervisor, name: RutviExercise.Workers},
      {Task.Supervisor, name: RutviExercise.Evaluators},
      {Task.Supervisor, name: RutviExercise.External},
      {Task.Supervisor, name: RutviExercise.DomainWorkers},
      {Task.Supervisor, name: RutviExercise.ControlWorkers},
      RutviExercise.Runtime.Bootstrap,
      RutviExercise.Runtime.Dispatcher,
      {RutviExercise.HTTP.Server, []}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: RutviExercise.Supervisor)
  end
end
