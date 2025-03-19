defmodule Mix.Tasks.Sentry.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs sentry. Requires igniter to be installed."
  end

  def example do
    "mix sentry.install --dsn <your_dsn>"
  end

  def long_doc do
    """
    #{short_doc()}

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--dsn` - Your sentry `dsn`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Sentry.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :sentry,
        adds_deps: [{:jason, "~> 1.2"}, {:hackney, "~> 1.8"}],
        example: __MODULE__.Docs.example(),
        schema: [dsn: :string],
        # Default values for the options in the `schema`
        defaults: [dsn: "<your_dsn>"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)

      mix_env_code =
        quote do
          Mix.env()
        end

      cwd_code =
        quote do
          [File.cwd!()]
        end

      # Do your work here and return an updated igniter
      igniter
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:dsn],
        igniter.args.options[:dsn]
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:environment_name],
        {:code, mix_env_code}
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:enable_source_code_context],
        true
      )
      |> Igniter.Project.Config.configure(
        "prod.exs",
        app_name,
        [:root_source_code_paths],
        {:code, cwd_code}
      )
      |> configure_phoenix()
      |> add_logger_handler()
      |> Igniter.add_notice("""
      Sentry: 

        Add a call to mix sentry.package_source_code in your release script to 
        make sure the stacktraces you receive are complete.
      """)
    end

    defp add_logger_handler(igniter) do
      app_module = Igniter.Project.Application.app_module(igniter)

      Igniter.Project.Module.find_and_update_module(igniter, app_module, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Function.move_to_def(zipper, :start, 2),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
          code =
            """
            :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
              config: %{metadata: [:file, :line]}
            })
            """

          {:ok, Igniter.Code.Common.add_code(zipper, code, placement: :prepend)}
        end
      end)
      |> case do
        {:ok, igniter} -> igniter
        _ -> igniter
      end
    end

    defp configure_phoenix(igniter) do
      {igniter, routers} =
        Igniter.Libs.Phoenix.list_routers(igniter)

      {igniter, endpoints} =
        Enum.reduce(routers, {igniter, []}, fn router, {igniter, endpoints} ->
          {igniter, new_endpoints} = Igniter.Libs.Phoenix.endpoints_for_router(igniter, router)
          {igniter, endpoints ++ new_endpoints}
        end)

      Enum.reduce(endpoints, igniter, fn endpoint, igniter ->
        igniter
        |> setup_endpoint(endpoint)
      end)
    end

    defp setup_endpoint(igniter, endpoint) do
      Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
        zipper
        |> Igniter.Code.Common.within(&add_plug_capture/1)
        |> Igniter.Code.Common.within(&add_plug_context/1)
        |> then(&{:ok, &1})
      end)
    end

    defp add_plug_capture(zipper) do
      with {:ok, zipper} <- Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
        Igniter.Code.Common.add_code(zipper, "use Sentry.PlugCapture", placement: :before)
      else
        _ ->
          {:ok, zipper}
      end
    end

    defp add_plug_context(zipper) do
      with {:ok, zipper} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :plug,
               [2, 1],
               &Igniter.Code.Function.argument_equals?(&1, 0, Plug.Parsers)
             ) do
        Igniter.Code.Common.add_code(zipper, "plug Sentry.PlugContext", placement: :after)
      else
        _ ->
          {:ok, zipper}
      end
    end
  end
else
  defmodule Mix.Tasks.Sentry.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'sentry.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
