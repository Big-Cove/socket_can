defmodule SocketCAN.Writer do
  @moduledoc """
  GenServer responsible for writing CAN frames to a SocketCAN interface.

  ## Overview

  The Writer is a critical component of the SocketCAN library's OTP supervision tree. It handles
  all outbound CAN frame transmission through a Linux SocketCAN interface. The module is designed
  to be fault-tolerant and efficient, with special handling for common error conditions.

  ### Architecture

  - Part of a `:rest_for_one` supervision strategy (started after Registry, before Reader)
  - Maintains a persistent socket connection to the CAN interface
  - Provides synchronous API that returns immediately to callers
  - Handles interface availability with configurable retry logic
  - Supports VintageNet integration for embedded Linux systems

  ### Key Features

  1. **Interface Management** - Automatically retries when CAN interface is not available
  2. **Write-only Socket** - Optimized socket configuration for transmission only
  3. **Error Recovery** - Graceful handling of transmission errors
  4. **VintageNet Support** - Can wait for network interfaces to come up on embedded systems

  ## Queue Implementation

  This module implements a smart queue to handle the `:enobufs` (buffer full) error that can occur
  when the CAN transmit buffer is full. Without proper handling, this error would crash the writer
  process and potentially the entire NMEA 2000 stack.

  ### Why Two Data Structures?

  The queue implementation uses two complementary data structures:

  1. **`queue` (Map)** - Stores the actual frame data
     - Key: CAN ID (first 4 bytes of the frame)
     - Value: The complete binary frame
     - Provides O(1) lookup for deduplication

  2. **`queue_order` (Erlang :queue)** - Maintains frame ordering
     - Stores only CAN IDs in FIFO order
     - Ensures frames are sent in the order they were queued

  ### Deduplication Strategy

  When a new frame arrives with a CAN ID that already exists in the queue:
  1. The old frame is removed from both the queue Map and the order queue
  2. The new frame is added to the end of the queue
  
  This ensures that:
  - Only the most recent data for each CAN ID is sent
  - Temporal ordering is preserved (newer frames are sent after older ones)
  - Frequently updated values (like heading, position) don't flood the queue

  ### Queue Size Limiting

  The queue has a configurable maximum size (default: 100 frames) to prevent unbounded memory growth.
  When the queue is full, the oldest frame is dropped and a warning is logged.

  ### Error Handling

  - `:enobufs` errors result in frames being queued for later transmission
  - Other errors are returned immediately to the caller
  - Queued frames are sent asynchronously when the buffer becomes available
  - Failed queued frames are logged and discarded (no retry for queued frames)

  ## Options

  - `:name` - Required. The registered name for the GenServer
  - `:interface` - Required. The CAN interface name (e.g., "can0")
  - `:max_retries` - Maximum retries for opening the socket (default: 5)
  - `:max_queue_size` - Maximum number of frames to queue (default: 100)
  - `:wait_for` - Optional delay or `:vintage_net` to wait for interface
  """
  use GenServer

  require Logger

  @valid_opts [:name, :interface, :max_retries, :registry, :wait_for, :max_queue_size]

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
    opts = Keyword.put_new(opts, :max_queue_size, 100)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      socket: nil,
      interface: opts[:interface],
      max_retries: opts[:max_retries] - 1,
      max_queue_size: opts[:max_queue_size],
      queue: %{},
      queue_order: :queue.new(),
      draining: false
    }

    {:ok, state, {:continue, {:wait_for, opts[:wait_for]}}}
  end

  @impl true
  def handle_continue({:wait_for, nil}, state) do
    {:noreply, state, {:continue, {:open_socket, state.interface, state.max_retries}}}
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
  def handle_info(:drain_queue, state) do
    case :queue.out(state.queue_order) do
      {{:value, can_id}, new_queue_order} ->
        case Map.get(state.queue, can_id) do
          frame when is_binary(frame) ->
            case :socket.send(state.socket, frame) do
              :ok ->
                # Success - continue draining
                new_queue = Map.delete(state.queue, can_id)
                send(self(), :drain_queue)
                {:noreply, %{state | queue: new_queue, queue_order: new_queue_order}}

              {:error, :enobufs} ->
                # Still full - retry later with exponential backoff
                Process.send_after(self(), :drain_queue, 10)
                {:noreply, state}

              {:error, reason} ->
                # Other error - log and continue draining
                Logger.warning("Failed to send queued CAN frame: #{inspect(reason)}")
                new_queue = Map.delete(state.queue, can_id)
                send(self(), :drain_queue)
                {:noreply, %{state | queue: new_queue, queue_order: new_queue_order}}
            end

          nil ->
            # Frame was replaced/removed, continue draining
            send(self(), :drain_queue)
            {:noreply, %{state | queue_order: new_queue_order}}
        end

      {:empty, _} ->
        # Queue is empty, stop draining
        {:noreply, %{state | draining: false}}
    end
  end

  @impl true
  def handle_call({:send, frame, _opts}, _from, state) when is_binary(frame) do
    case :socket.send(state.socket, frame) do
      :ok ->
        {:reply, :ok, state}

      {:error, :enobufs} ->
        # Extract CAN ID from frame for deduplication
        <<can_id::integer-32-little, _rest::binary>> = frame
        
        # Smart queue: if frame with same CAN ID exists, remove it first
        {new_queue_order, new_queue} = 
          if Map.has_key?(state.queue, can_id) do
            # Remove the old frame from queue order
            filtered_queue_order = :queue.filter(fn id -> id != can_id end, state.queue_order)
            # Delete from map
            updated_queue = Map.delete(state.queue, can_id)
            {filtered_queue_order, updated_queue}
          else
            {state.queue_order, state.queue}
          end
        
        # Check if we need to drop oldest frame due to queue size limit
        {final_queue_order, final_queue} = 
          if :queue.len(new_queue_order) >= state.max_queue_size do
            # Drop the oldest frame
            {{:value, oldest_can_id}, trimmed_queue_order} = :queue.out(new_queue_order)
            trimmed_queue = Map.delete(new_queue, oldest_can_id)
            Logger.warning("CAN queue full (#{state.max_queue_size} frames), dropping oldest frame with ID: 0x#{Integer.to_string(oldest_can_id, 16)}")
            {trimmed_queue_order, trimmed_queue}
          else
            {new_queue_order, new_queue}
          end
        
        # Now add the new frame to the end of the queue
        final_queue_order_with_new = :queue.in(can_id, final_queue_order)
        final_queue_with_new = Map.put(final_queue, can_id, frame)
        new_state = %{state | queue: final_queue_with_new, queue_order: final_queue_order_with_new}

        # Start draining if not already
        final_state = if not state.draining do
          send(self(), :drain_queue)
          %{new_state | draining: true}
        else
          new_state
        end

        # Reply immediately with :ok since we've queued it
        {:reply, :ok, final_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end
end
