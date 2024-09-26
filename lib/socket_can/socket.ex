defmodule SocketCAN.Socket do
  @pf_can 29
  @can_raw 1

  @sol_can_raw 101
  @can_filter 1
  @can_loopback 3

  def open(interface, opts \\ []) do
    with {:ok, socket} <- :socket.open(@pf_can, :raw, @can_raw),
         {:ok, ifindex} <- :socket.ioctl(socket, :gifindex, String.to_charlist(interface)) do
      addr = <<0::size(16)-little, ifindex::size(32)-little, 0::size(128)>>
      :ok = :socket.bind(socket, %{:family => @pf_can, :addr => addr})

      # disable the local loopback of sent frames
      # https://docs.kernel.org/networking/can.html#raw-socket-option-can-raw-loopback
      :ok = :socket.setopt_native(socket, {@sol_can_raw, @can_loopback}, false)

      # disable the reception of frames
      # https://docs.kernel.org/networking/can.html#raw-socket-option-can-raw-filter
      if opts[:write_only] do
        :ok = :socket.setopt_native(socket, {@sol_can_raw, @can_filter}, <<>>)
      end

      {:ok, socket}
    end
  end
end
