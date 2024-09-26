defmodule SocketCAN.Frame do
  @moduledoc """
  The type for a standard 11-bit frame
  """

  @eff_flag 0x80000000
  @rtr_flag 0x40000000
  @err_flag 0x20000000

  @sff_mask 0x000007FF
  @eff_mask 0x1FFFFFFF

  @frame_types [:data, :remote, :error]

  import Bitwise, only: [&&&: 2, |||: 2]

  # TODO: add support for CAN-FD with `:is_fd?` struct field
  # TODO: should `:frame_type` be named just `:type`?
  @enforce_keys [:id]
  defstruct [:id, :timestamp, is_extended?: false, frame_type: :data, data: ""]

  defp standard_id(id) when is_integer(id) and id >= 0, do: id &&& @sff_mask
  defp extended_id(id) when is_integer(id) and id >= 0, do: (id &&& @eff_mask) ||| @eff_flag

  def to_binary!(frame) do
    case to_binary(frame) do
      {:ok, frame_binary} -> frame_binary
      {:error, reason} -> raise RuntimeError, "invalid frame: #{reason}"
    end
  end

  def to_binary(frame) do
    # TODO: check the frame is valid here
    can_id =
      cond do
        frame.is_extended? -> extended_id(frame.id)
        true -> standard_id(frame.id)
      end

    can_id =
      case frame.frame_type do
        :data -> can_id
        :remote -> can_id ||| @rtr_flag
        :error -> can_id ||| @err_flag
      end

    data_length = :erlang.byte_size(frame.data)
    pad = 0

    frame_binary =
      <<can_id::integer-32-little, data_length, pad::integer-24-little, frame.data::binary,
        pad::integer-size(8 * (8 - data_length))>>

    {:ok, frame_binary}
  end

  def from_binary!(frame_binary) do
    case from_binary(frame_binary) do
      {:ok, frame} -> frame
      {:error, reason} -> raise RuntimeError, "invalid frame: #{reason}"
    end
  end

  def from_binary(binary, opts \\ []) when is_binary(binary) do
    put_timestamp = Keyword.get(opts, :put_timestamp)

    # TODO: check that the binary length is correct, return {:error, reason} if not
    <<can_id::integer-32-little, data_length, _pad::integer-24-little, data::binary>> = binary

    is_extended? = (can_id &&& @eff_flag) > 0

    frame_id =
      cond do
        is_extended? -> can_id &&& @eff_mask
        true -> can_id &&& @sff_mask
      end

    frame_type =
      cond do
        (can_id &&& @rtr_flag) > 0 -> :remote
        (can_id &&& @err_flag) > 0 -> :error
        true -> :data
      end

    <<data_trimmed::binary-size(data_length), _pad::binary>> = data

    frame =
      %__MODULE__{
        id: frame_id,
        is_extended?: is_extended?,
        frame_type: frame_type,
        data: data_trimmed,
        timestamp: put_timestamp && NaiveDateTime.utc_now()
      }

    {:ok, frame}
  end
end
