defmodule SocketCANTest do
  use ExUnit.Case
  doctest SocketCAN

  test "greets the world" do
    assert SocketCAN.hello() == :world
  end
end
