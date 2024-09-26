defmodule SocketCAN.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    name =
      opts[:name] ||
        raise ArgumentError, "the :name option is required when starting SocketCAN"

    opts[:interface] ||
      raise ArgumentError, "the :interface option is required when starting SocketCAN"

    opts = Keyword.put_new(opts, :wait_for, 1000)

    sup_name = Module.concat(name, "Supervisor")
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  @impl true
  def init(opts) do
    name = opts[:name]
    writer_name = Module.concat(name, Writer)
    reader_name = Module.concat(name, Reader)

    shared_opts = [interface: opts[:interface], registry: name, wait_for: opts[:wait_for]]

    children = [
      {Registry, name: name, keys: :duplicate},
      {SocketCAN.Writer, Keyword.put(shared_opts, :name, writer_name)},
      {SocketCAN.Reader, Keyword.put(shared_opts, :name, reader_name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
