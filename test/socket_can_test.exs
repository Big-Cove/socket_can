defmodule SocketCANTest do
  use ExUnit.Case
  doctest SocketCAN

  describe "subscribe/2" do
    test "subscribes to specific frame ID" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe to frame ID 0x123
      assert :ok = SocketCAN.subscribe(registry_name, 0x123)

      # Verify registration
      current_pid = self()
      assert [{^current_pid, nil}] = Registry.lookup(registry_name, 0x123)
    end

    test "allows multiple processes to subscribe to same frame ID" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe from current process
      assert :ok = SocketCAN.subscribe(registry_name, 0x100)

      # Spawn another process and subscribe
      parent = self()

      pid =
        spawn(fn ->
          SocketCAN.subscribe(registry_name, 0x100)
          send(parent, :subscribed)

          # Keep process alive for the test
          receive do
            :done -> :ok
          end
        end)

      # Wait for subscription
      assert_receive :subscribed

      # Verify both processes are registered
      subscribers = Registry.lookup(registry_name, 0x100)
      assert length(subscribers) == 2

      # Clean up
      send(pid, :done)
    end
  end

  describe "subscribe/1" do
    test "subscribes to all frames" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe to all frames
      assert :ok = SocketCAN.subscribe(registry_name)

      # Verify registration under :all_frames key
      current_pid = self()
      assert [{^current_pid, nil}] = Registry.lookup(registry_name, :all_frames)
    end

    test "allows subscribing to both all frames and specific IDs" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe to all frames
      assert :ok = SocketCAN.subscribe(registry_name)

      # Also subscribe to specific frame
      assert :ok = SocketCAN.subscribe(registry_name, 0x200)

      # Verify both registrations
      current_pid = self()
      assert [{^current_pid, nil}] = Registry.lookup(registry_name, :all_frames)
      assert [{^current_pid, nil}] = Registry.lookup(registry_name, 0x200)
    end
  end

  describe "frame dispatching" do
    test "wildcard subscribers receive all frames" do
      # This test simulates what the Reader does
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe to all frames
      SocketCAN.subscribe(registry_name)

      # Simulate frame dispatch (what Reader does)
      test_frame = %SocketCAN.Frame{
        id: 0x123,
        data: <<1, 2, 3, 4>>,
        is_extended?: false,
        frame_type: :data
      }

      # Dispatch to wildcard subscribers
      Registry.dispatch(registry_name, :all_frames, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Verify frame received
      assert_receive {:can_frame, ^test_frame}
    end

    test "specific subscribers only receive matching frames" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Subscribe to specific ID
      SocketCAN.subscribe(registry_name, 0x100)

      # Simulate dispatching different frame IDs
      frame_100 = %SocketCAN.Frame{id: 0x100, data: <<1>>, is_extended?: false, frame_type: :data}
      frame_200 = %SocketCAN.Frame{id: 0x200, data: <<2>>, is_extended?: false, frame_type: :data}

      # Dispatch frame with ID 0x100
      Registry.dispatch(registry_name, 0x100, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, frame_100})
        end
      end)

      # Dispatch frame with ID 0x200 (should not be received)
      Registry.dispatch(registry_name, 0x200, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, frame_200})
        end
      end)

      # Should only receive frame_100
      assert_receive {:can_frame, ^frame_100}
      refute_receive {:can_frame, ^frame_200}, 100
    end

    test "wildcard and specific subscribers both receive frames" do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      # Process 1: Subscribe to all frames
      task1 =
        Task.async(fn ->
          SocketCAN.subscribe(registry_name)
          assert_receive {:can_frame, frame}
          {:wildcard, frame}
        end)

      # Process 2: Subscribe to specific ID
      task2 =
        Task.async(fn ->
          SocketCAN.subscribe(registry_name, 0x300)
          assert_receive {:can_frame, frame}
          {:specific, frame}
        end)

      # Give tasks time to subscribe
      Process.sleep(50)

      # Simulate frame dispatch (as Reader would do)
      test_frame = %SocketCAN.Frame{
        id: 0x300,
        data: <<3, 3, 3>>,
        is_extended?: false,
        frame_type: :data
      }

      # Dispatch to specific ID subscribers
      Registry.dispatch(registry_name, 0x300, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Dispatch to wildcard subscribers
      Registry.dispatch(registry_name, :all_frames, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Both tasks should receive the frame
      assert {:wildcard, ^test_frame} = Task.await(task1)
      assert {:specific, ^test_frame} = Task.await(task2)
    end
  end
end
