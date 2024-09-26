defmodule SocketCAN do
  @moduledoc """
  Documentation for `SocketCAN`.
  """

  defdelegate child_spec(opts), to: SocketCAN.Supervisor

  def send_frame(socket_can, %SocketCAN.Frame{} = frame, opts \\ []) do
    timeout = opts[:timeout] || 1000

    writer = Module.concat(socket_can, Writer)

    with {:ok, frame_binary} <- SocketCAN.Frame.to_binary(frame) do
      GenServer.call(writer, {:send, frame_binary, opts}, timeout)
    end
  end

  def subscribe(socket_can, frame_id) do
    Registry.register(socket_can, frame_id, nil)
    :ok
  end
end
