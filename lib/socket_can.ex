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

  @doc """
  Subscribe the calling process to receive frames with a specific ID.

  ## Examples

      SocketCAN.subscribe(MyCANBus, 0x123)
  """
  def subscribe(socket_can, frame_id) do
    case Registry.register(socket_can, frame_id, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc """
  Subscribe the calling process to receive all CAN frames.

  ## Examples

      SocketCAN.subscribe(MyCANBus)
      
      receive do
        {:can_frame, frame} -> IO.inspect(frame)
      end
  """
  def subscribe(socket_can) do
    case Registry.register(socket_can, :all_frames, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end
end
