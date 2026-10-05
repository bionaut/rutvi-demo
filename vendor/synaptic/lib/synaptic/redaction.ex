defmodule Synaptic.Redaction do
  @moduledoc false

  @types [:email, :phone, :ssn, :payment_card, :auth_token]

  @email_regex ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  @ssn_regex ~r/\b\d{3}-?\d{2}-?\d{4}\b/
  @phone_regex ~r/(?<!\w)(?:\+?\d[\d\-\.\(\) ]{8,}\d)(?!\w)/
  @card_regex ~r/(?<!\w)(?:\d[ -]*?){13,19}(?!\w)/

  @default_preview_chars 160

  def scrub(term, opts \\ []) do
    types = normalize_types(Keyword.get(opts, :types, @types))

    do_scrub(term, types)
  end

  def summary(term, opts \\ []) do
    types = detect(term, opts)
    preview_chars = Keyword.get(opts, :preview_chars, @default_preview_chars)

    cond do
      types != [] ->
        "[sensitive content redacted: " <>
          (types |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")) <> "]"

      true ->
        term
        |> scrub(opts)
        |> preview_text(preview_chars)
    end
  end

  def detect(term, opts \\ []) do
    requested_types = normalize_types(Keyword.get(opts, :types, @types))

    term
    |> collect_strings()
    |> Enum.reduce(MapSet.new(), fn string, acc ->
      Enum.reduce(requested_types, acc, fn type, set ->
        if sensitive_match?(type, string) do
          MapSet.put(set, type)
        else
          set
        end
      end)
    end)
    |> MapSet.to_list()
  end

  defp do_scrub(%module{} = term, types) do
    term
    |> Map.from_struct()
    |> do_scrub(types)
    |> then(&struct(module, &1))
  end

  defp do_scrub(term, types) when is_map(term) do
    Map.new(term, fn {key, value} -> {key, do_scrub(value, types)} end)
  end

  defp do_scrub(term, types) when is_list(term) do
    Enum.map(term, &do_scrub(&1, types))
  end

  defp do_scrub(term, types) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&do_scrub(&1, types))
    |> List.to_tuple()
  end

  defp do_scrub(term, types) when is_binary(term) do
    Enum.reduce(types, term, fn type, acc ->
      scrub_string(acc, type)
    end)
  end

  defp do_scrub(term, _types), do: term

  defp scrub_string(value, :address), do: value

  defp scrub_string(value, type) do
    regex = detector_regex(type)

    regex
    |> Regex.scan(value, return: :index)
    |> Enum.flat_map(fn
      [{start, length} | _rest] ->
        match = binary_part(value, start, length)

        if sensitive_match?(type, match) do
          [{start, length, redacted_value(type, match)}]
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(fn {start, length, _replacement} -> {start, length} end)
    |> Enum.reverse()
    |> Enum.reduce(value, fn {start, length, replacement}, acc ->
      prefix = binary_part(acc, 0, start)
      suffix = binary_part(acc, start + length, byte_size(acc) - start - length)
      prefix <> replacement <> suffix
    end)
  end

  defp collect_strings(term) when is_binary(term), do: [term]

  defp collect_strings(term) when is_map(term) do
    Enum.flat_map(term, fn {_key, value} -> collect_strings(value) end)
  end

  defp collect_strings(term) when is_list(term) do
    Enum.flat_map(term, &collect_strings/1)
  end

  defp collect_strings(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.flat_map(&collect_strings/1)
  end

  defp collect_strings(_term), do: []

  defp sensitive_match?(:phone, value) do
    digits = String.replace(value, ~r/\D/u, "")
    String.length(digits) >= 10 and String.length(digits) <= 15
  end

  defp sensitive_match?(:payment_card, value) do
    digits = String.replace(value, ~r/\D/u, "")
    String.length(digits) in 13..19 and luhn_valid?(digits)
  end

  defp sensitive_match?(type, value) do
    Regex.match?(detector_regex(type), value)
  end

  defp detector_regex(:email), do: @email_regex
  defp detector_regex(:ssn), do: @ssn_regex
  defp detector_regex(:phone), do: @phone_regex
  defp detector_regex(:payment_card), do: @card_regex
  defp detector_regex(:auth_token), do: auth_token_regex()

  defp auth_token_regex do
    ~r/\b(?:sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z\-_]{20,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+)\b/
  end

  defp redacted_value(:email, value) do
    case String.split(value, "@", parts: 2) do
      [local, domain] ->
        prefix =
          case String.graphemes(local) do
            [first | _] -> first <> "***"
            _ -> "***"
          end

        prefix <> "@" <> domain

      _ ->
        "[REDACTED_EMAIL]"
    end
  end

  defp redacted_value(:phone, value) do
    digits = String.replace(value, ~r/\D/u, "")

    if String.length(digits) >= 4 do
      "***-***-" <> String.slice(digits, -4, 4)
    else
      "[REDACTED_PHONE]"
    end
  end

  defp redacted_value(:ssn, value) do
    digits = String.replace(value, ~r/\D/u, "")

    if String.length(digits) == 9 do
      "***-**-" <> String.slice(digits, -4, 4)
    else
      "[REDACTED_SSN]"
    end
  end

  defp redacted_value(:payment_card, value) do
    digits = String.replace(value, ~r/\D/u, "")

    if String.length(digits) >= 4 do
      "**** **** **** " <> String.slice(digits, -4, 4)
    else
      "[REDACTED_PAYMENT_CARD]"
    end
  end

  defp redacted_value(:auth_token, value) do
    prefix = String.slice(value, 0, 4) || ""
    suffix = String.slice(value, -4, 4) || ""
    prefix <> "...#{suffix}"
  end

  defp preview_text(term, preview_chars) when is_binary(term) do
    if byte_size(term) <= preview_chars do
      term
    else
      binary_part(term, 0, preview_chars) <> "... [truncated]"
    end
  end

  defp preview_text(term, preview_chars) do
    term
    |> inspect()
    |> preview_text(preview_chars)
  end

  defp normalize_types(types) when is_list(types) do
    types
    |> Enum.flat_map(&normalize_types/1)
    |> Enum.uniq()
  end

  defp normalize_types(type) when type in @types, do: [type]

  defp normalize_types(type) when is_binary(type) do
    case String.downcase(type) do
      "email" -> [:email]
      "phone" -> [:phone]
      "ssn" -> [:ssn]
      "payment_card" -> [:payment_card]
      "auth_token" -> [:auth_token]
      _ -> []
    end
  end

  defp normalize_types(_type), do: []

  defp luhn_valid?(digits) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, index}, acc ->
      value = String.to_integer(digit)

      adjusted =
        if rem(index, 2) == 1 do
          doubled = value * 2
          if doubled > 9, do: doubled - 9, else: doubled
        else
          value
        end

      acc + adjusted
    end)
    |> rem(10)
    |> Kernel.==(0)
  end
end
