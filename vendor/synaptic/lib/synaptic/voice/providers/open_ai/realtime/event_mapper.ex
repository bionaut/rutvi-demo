defmodule Synaptic.Voice.Providers.OpenAI.Realtime.EventMapper do
  @moduledoc false

  @spec normalize_event(map()) :: {:ok, %{event: atom(), data: map()}} | {:ignore, term()}
  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.delta",
        "delta" => text
      })
      when is_binary(text) do
    {:ok, %{event: :input_partial_text, data: %{text: text}}}
  end

  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => text,
        "item_id" => item_id
      })
      when is_binary(text) and is_binary(item_id) do
    {:ok, %{event: :input_final_text, data: %{text: text, item_id: item_id}}}
  end

  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => text
      })
      when is_binary(text) do
    {:ok, %{event: :input_final_text, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "input_audio_buffer.speech_stopped"} = payload) do
    {:ok,
     %{
       event: :input_speech_stopped,
       data:
         compact(%{
           item_id: payload["item_id"],
           audio_end_ms: payload["audio_end_ms"]
         })
     }}
  end

  def normalize_event(%{"type" => "response.audio_transcript.delta", "delta" => text})
      when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.output_audio_transcript.delta", "delta" => text})
      when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => type})
      when type in [
             "response.audio_transcript.done",
             "response.output_audio_transcript.done"
           ] do
    {:ignore, :assistant_transcript_done}
  end

  def normalize_event(%{"type" => "response.text.delta", "delta" => text}) when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.output_text.delta", "delta" => text})
      when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.created"} = payload) do
    {:ok, %{event: :assistant_response_started, data: response_data(payload)}}
  end

  def normalize_event(%{"type" => "response.done"} = payload) do
    {:ok, %{event: :assistant_response_done, data: response_data(payload)}}
  end

  def normalize_event(%{"type" => "input_audio_buffer.speech_started"}) do
    {:ok, %{event: :duplex_interruption, data: %{reason: :speech_started}}}
  end

  def normalize_event(%{
        "type" => "error",
        "error" => %{"code" => "response_cancel_not_active"}
      }) do
    {:ignore, :response_cancel_not_active}
  end

  def normalize_event(%{"type" => "error", "error" => error}) do
    {:ok, %{event: :session_error, data: %{source: :provider, reason: error}}}
  end

  def normalize_event(%{"type" => type}), do: {:ignore, {:unhandled, type}}
  def normalize_event(other), do: {:ignore, {:unhandled, other}}

  defp response_data(%{"response" => response}) when is_map(response) do
    compact(%{
      response_id: response["id"],
      source: response_source(get_in(response, ["metadata", "synaptic_response_source"]))
    })
  end

  defp response_data(_payload), do: %{}

  defp response_source("backchannel"), do: :backchannel
  defp response_source("busy_ack"), do: :busy_ack
  defp response_source("queue_confirmation"), do: :queue_confirmation
  defp response_source("workflow"), do: :workflow
  defp response_source("capability"), do: :capability
  defp response_source("capability_error"), do: :capability_error
  defp response_source("capability_confirmation"), do: :capability_confirmation
  defp response_source(_source), do: nil

  defp compact(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
