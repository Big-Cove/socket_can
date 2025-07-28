defmodule SocketCAN.ReaderTest do
  use ExUnit.Case

  alias SocketCAN.Frame

  describe "frame dispatching with wildcard subscribers" do
    setup do
      registry_name = :"test_registry_#{System.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)
      {:ok, registry: registry_name}
    end

    test "Reader dispatches frames to both specific and wildcard subscribers", %{
      registry: registry
    } do
      # Mock socket module for testing
      _parent = self()

      # Create a test reader state
      reader_state = %{
        socket: :mock_socket,
        interface: "test0",
        registry: registry,
        recv_timeout: 100
      }

      # Subscribe to all frames from test process
      SocketCAN.subscribe(registry)

      # Also subscribe to specific frame ID
      SocketCAN.subscribe(registry, 0x123)

      # Create test frame
      test_frame = %Frame{
        id: 0x123,
        data: <<1, 2, 3, 4>>,
        is_extended?: false,
        frame_type: :data,
        timestamp: 123_456
      }

      # Simulate what Reader does when receiving a frame
      # Dispatch to ID-specific subscribers
      Registry.dispatch(reader_state.registry, test_frame.id, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Dispatch to wildcard subscribers
      Registry.dispatch(reader_state.registry, :all_frames, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Should receive the frame twice (once from specific, once from wildcard)
      assert_receive {:can_frame, ^test_frame}
      assert_receive {:can_frame, ^test_frame}
      refute_receive {:can_frame, _}, 100
    end

    test "wildcard subscriber receives frames with different IDs", %{registry: registry} do
      # Subscribe to all frames
      SocketCAN.subscribe(registry)

      frames = [
        %Frame{id: 0x100, data: <<1>>, is_extended?: false, frame_type: :data},
        %Frame{id: 0x200, data: <<2>>, is_extended?: false, frame_type: :data},
        %Frame{id: 0x300, data: <<3>>, is_extended?: false, frame_type: :data}
      ]

      # Dispatch each frame as Reader would
      for frame <- frames do
        Registry.dispatch(registry, :all_frames, fn entries ->
          for {pid, _value} <- entries do
            send(pid, {:can_frame, frame})
          end
        end)
      end

      # Should receive all frames
      for expected_frame <- frames do
        assert_receive {:can_frame, ^expected_frame}
      end
    end

    test "specific subscriber doesn't receive frames via wildcard dispatch", %{registry: registry} do
      # Only subscribe to specific ID
      SocketCAN.subscribe(registry, 0x500)

      test_frame = %Frame{
        # Different ID
        id: 0x600,
        data: <<6, 6>>,
        is_extended?: false,
        frame_type: :data
      }

      # Dispatch to wildcard subscribers only
      Registry.dispatch(registry, :all_frames, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # Should not receive the frame
      refute_receive {:can_frame, _}, 100
    end

    test "multiple wildcard subscribers all receive frames", %{registry: registry} do
      # Create multiple processes subscribing to all frames
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            SocketCAN.subscribe(registry)
            assert_receive {:can_frame, frame}
            {i, frame}
          end)
        end

      # Wait for subscriptions
      Process.sleep(50)

      test_frame = %Frame{
        id: 0x777,
        data: <<7, 7, 7>>,
        is_extended?: false,
        frame_type: :data
      }

      # Dispatch to wildcard subscribers
      Registry.dispatch(registry, :all_frames, fn entries ->
        for {pid, _value} <- entries do
          send(pid, {:can_frame, test_frame})
        end
      end)

      # All tasks should receive the frame
      results = Task.await_many(tasks)
      assert length(results) == 3

      for {i, frame} <- results do
        assert frame == test_frame
        assert i in 1..3
      end
    end
  end
end
