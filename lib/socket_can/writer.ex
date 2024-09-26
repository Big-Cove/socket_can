defmodule SocketCAN.Writer do
  use GenServer

  require Logger

  @valid_opts [:name, :interface, :max_retries, :registry, :wait_for]

  def start_link(opts) do
    name = opts[:name] || raise ArgumentError, "option :name is required"
    opts[:interface] || raise ArgumentError, "option :interface is required"

    for key <- Keyword.keys(opts) do
      if key not in @valid_opts do
        raise ArgumentError, "unknown option: #{inspect(key)}"
      end
    end

    if opts[:wait_for] == :vintage_net do
      Code.ensure_loaded?(VintageNet) ||
        raise RuntimeError,
              ":wait_for value of :vintage_net requires the VintageNet module to be loaded"
    end

    opts = Keyword.put_new(opts, :max_retries, 5)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{socket: nil, interface: opts[:interface], max_retries: opts[:max_retries] - 1}

    {:ok, state, {:continue, {:wait_for, opts[:wait_for]}}}
  end

  @impl true
  def handle_continue({:wait_for, time_ms}, state) when is_integer(time_ms) do
    Process.sleep(time_ms)

    {:noreply, state, {:continue, {:open_socket, state.interface, state.max_retries}}}
  end

  @impl true
  def handle_continue({:wait_for, :vintage_net}, state) do
    if VintageNet.get(["interface", state.interface, "connection"]) == :lan do
      {:noreply, state, {:continue, {:open_socket, state.interface, state.max_retries}}}
    else
      VintageNet.subscribe(["interface", state.interface, "connection"])
      {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:open_socket, interface, retries}, state) do
    case {SocketCAN.Socket.open(interface, write_only: true), retries} do
      {{:ok, socket}, _retries} ->
        {:noreply, put_in(state.socket, socket)}

      {{:error, :enodev}, retries} when retries > 0 ->
        Logger.warning("Device #{interface} not found: retrying #{retries} more time(s)")
        Process.sleep(1000)
        {:noreply, state, {:continue, {:open_socket, interface, retries - 1}}}

      {{:error, :enodev}, retries} when retries == 0 ->
        Logger.error("Unable to open SocketCAN device #{interface}")
        {:shutdown, state}
    end
  end

  @impl true
  def handle_info(
        {VintageNet, ["interface", _interface, "connection"], _old_value, :lan, _metadata},
        state
      ) do
    VintageNet.unsubscribe(["interface", state.interface, "connection"])

    {:noreply, state, {:continue, {:open_socket, state.interface, state.max_retries}}}
  end

  @impl true
  def handle_call({:send, frame, _opts}, _from, state) when is_binary(frame) do
    :ok = :socket.send(state.socket, frame)
    {:reply, :ok, state}
  end
end
