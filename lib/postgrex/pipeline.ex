defmodule Postgrex.Pipeline do
  @moduledoc false
  defstruct [:opening, :statement]

  # These are text INPUT representations, never SQL literals. Values still
  # travel as separately length-framed Bind parameters with unknown Parse OIDs.
  def encode_params(params, opts) do
    Enum.reduce_while(params, [], fn value, acc ->
      case encode(value, opts) do
        :fallback -> {:halt, :fallback}
        nil -> {:cont, [<<-1::signed-32>> | acc]}
        text -> {:cont, [[<<byte_size(text)::signed-32>>, text] | acc]}
      end
    end)
    |> case do
      :fallback -> :fallback
      encoded -> {:ok, Enum.reverse(encoded)}
    end
  end

  defp encode(nil, _), do: nil
  defp encode(true, _), do: "true"
  defp encode(false, _), do: "false"
  defp encode(value, _) when is_integer(value), do: Integer.to_string(value)
  defp encode(value, _) when is_float(value), do: Float.to_string(value)
  defp encode(%Decimal{} = value, _), do: Decimal.to_string(value)

  defp encode(%Date{calendar: Calendar.ISO, year: year} = value, _) when year > 0,
    do: Date.to_iso8601(value)

  defp encode(%Time{calendar: Calendar.ISO} = value, _), do: Time.to_iso8601(value)

  defp encode(%NaiveDateTime{calendar: Calendar.ISO, year: year} = value, _) when year > 0,
    do: NaiveDateTime.to_iso8601(value)

  defp encode(%DateTime{calendar: Calendar.ISO, year: year} = value, _) when year > 0,
    do: DateTime.to_iso8601(value)

  defp encode(value, opts) when is_binary(value) do
    # Compiled Selecto params have no text/bytea tag. Even a valid UTF8 binary
    # can be bytea (e.g. "\\x41"). Only an explicit host contract resolves this.
    if opts[:text_binaries] == true and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch,
       do: value,
       else: :fallback
  end

  defp encode(_, _), do: :fallback
end

defimpl DBConnection.Query, for: Postgrex.Pipeline do
  def parse(query, _opts), do: query
  def describe(query, _opts), do: query
  def encode(_query, encoded, _opts), do: encoded

  def decode(_query, {:ok, result}, opts),
    do: {:ok, DBConnection.Query.decode(%Postgrex.Query{}, result, opts)}

  def decode(_query, result, _opts), do: result
end

defimpl String.Chars, for: Postgrex.Pipeline do
  def to_string(query), do: IO.iodata_to_binary(query.statement)
end

# Preserve the failing part across DBConnection's disconnect return, so an
# opening refusal remains distinguishable from a business-statement error.
defmodule Postgrex.PipelineError do
  @moduledoc false
  defexception [:stage, :error]
  def message(%{error: error}), do: Exception.message(error)
end
