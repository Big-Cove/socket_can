defmodule SocketCanTest do
  use ExUnit.Case
  doctest SocketCan

  test "greets the world" do
    assert SocketCan.hello() == :world
  end
end
