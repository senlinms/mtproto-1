defmodule MTProto.Packet do
  @moduledoc """
  Module for dealing with packets - encode, decode, ecnrypt, decrypt.
  """

  alias TL.{Utils, Serializer}
  alias MTProto.{Crypto, Math}

  defmodule Meta do
    defstruct [:message_id, :msg_seqno]
  end

  # TODO
  @doc """
  """
  def encode(request, %{auth_state: :encrypted} = state, message_id) do
    packet = Serializer.encode(request)
    state = append_request_with_id(state, request, message_id, content_related?(request))
    {msg_seqno, msg_seqno_state} = make_msg_seqno(state.msg_seqno, content_related?(request))

    packet_with_meta =
      <<state.server_salt :: binary-size(8),
        state.session_id :: binary-size(8),
        message_id :: little-size(64),
        msg_seqno :: little-size(32),
        byte_size(packet) :: little-size(32),
        packet :: binary>>

    packet_with_meta = Utils.padding(16, packet_with_meta)

    encrypted_packet = Crypto.encrypt_packet(packet_with_meta,
      state.auth_key, state.auth_key_hash)

    packet = encode_packet_size(encrypted_packet)

    {packet, %{state|msg_seqno: msg_seqno_state}}
  end

  @doc """
  Encodes packet as "bare", without encryption and empty auth_key,
  used for authorizaion only.
  """
  @spec encode_bare(binary, non_neg_integer) :: binary
  def encode_bare(packet, message_id) do
    auth_key_id = 0

    packet_with_meta =
      <<auth_key_id :: little-size(64),
        message_id :: little-size(64),
        byte_size(packet) :: little-size(32),
        packet :: binary>>

    encode_packet_size(packet_with_meta)
  end


  def encode_packet_size(packet) do
    size = trunc(Float.ceil(byte_size(packet) / 4))

    if size < 127 do
      <<size :: 8, packet :: binary>>
    else
      <<0x7f, size :: little-size(24), packet :: binary>>
    end
  end

  @doc """
  Tries to extract packet by it size, returns :more when packet is incomplete, otherwise :ok
  """
  @spec decode(binary) :: {:more, pos_integer, binary} :: {:ok, binary, binary}
  def decode(<<0x7f, size :: little-size(24), packet :: binary>> = packet_with_size) when byte_size(packet) < size * 4 do
    {:more, size * 4, packet_with_size}
  end
  def decode(<<0x7f, size :: little-size(24), rest :: binary>>) do
    size = size * 4
    <<packet :: binary-size(size), rest :: binary>> = rest
    {:ok, packet, rest}
  end
  def decode(<<size :: 8, packet :: binary>> = packet_with_size) when byte_size(packet) < size * 4 do
    {:more, size * 4, packet_with_size}
  end
  def decode(<<size :: 8, rest :: binary>>) do
    size = size * 4
    <<packet :: binary-size(size), rest :: binary>> = rest
    {:ok, packet, rest}
  end

  @spec decode_packet(binary, %MTProto.State{}) ::
    {:ok, struct | binary, %Meta{}, %MTProto.State{}}

  def decode_packet(<<error_reason :: little-signed-integer-size(32)>>, _state) do
    {:error, error_reason}
  end
  def decode_packet(packet_with_meta, %{auth_state: :encrypted} = state) do
    decrypted_packet = Crypto.decrypt_packet(packet_with_meta,
      state.auth_key)

    <<_server_salt :: binary-size(8),
      _session_id :: binary-size(8),
      message_id :: little-size(64),
      msg_seqno :: little-size(32),
      packet_size :: little-size(32),
      packet :: binary-size(packet_size),
      _rest :: binary>> = decrypted_packet

    state =
      if Math.band1(msg_seqno) == 1 do
        %{state|msg_ids_to_ack: [message_id|state.msg_ids_to_ack]}
      else
        state
      end

    case Serializer.decode(packet) do
      {:ok, packet} -> {:ok, packet, %Meta{message_id: message_id, msg_seqno: msg_seqno}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end
  def decode_packet(<<_auth_key_id :: 64, message_id :: little-size(64),
                      packet_size :: little-size(32), packet :: binary-size(packet_size)>>, state) do
    {:ok, packet, %Meta{message_id: message_id}, state}
  end

  def append_request_with_id(state, request, message_id, true) do
    %{state|msg_ids: Map.put(state.msg_ids, message_id, request)}
  end
  def append_request_with_id(state, _request, _message_id, false) do
    state
  end

  def make_msg_seqno(current_seqno, true) do
    {current_seqno * 2 + 1, current_seqno + 1}
  end
  def make_msg_seqno(current_seqno, false) do
    {current_seqno * 2, current_seqno}
  end

  def content_related?(%TL.MTProto.Ping{}), do: false
  def content_related?(%TL.MTProto.Msgs.Ack{}), do: false
  def content_related?(_), do: true
end
