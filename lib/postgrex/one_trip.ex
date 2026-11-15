defmodule Postgrex.OneTrip do
  @moduledoc false

  # Deliberately not a SQL parser: inference accepts ONLY this entire grammar.
  # Explicit casts constrain exactly the same type with or without Parse OIDs.
  @casts %{
    "int4" => 23,
    "integer" => 23,
    "int8" => 20,
    "bigint" => 20,
    "text" => 25,
    "bool" => 16,
    "boolean" => 16,
    "float8" => 701,
    "double precision" => 701,
    "numeric" => 1700,
    "date" => 1082,
    "timestamp" => 1114,
    "timestamptz" => 1184
  }

  def parameter_oids(statement, params, opts) do
    enabled = Keyword.get(opts, :one_trip, Application.get_env(:postgrex, :one_trip, false))

    cond do
      not enabled or opts[:mode] == :savepoint or opts[:postgrex_copy] ->
        :fallback

      oids = opts[:param_oids] ->
        validate_oids!(oids, params)
        # Retrying after Execute is safe only with a caller assertion.
        if opts[:one_trip_retry_safe], do: {:ok, oids}, else: :fallback

      true ->
        infer(IO.iodata_to_binary(statement), params)
    end
  end

  defp validate_oids!(oids, params) do
    unless is_list(oids) and length(oids) == length(params) and
             Enum.all?(Enum.zip(oids, params), fn {oid, value} ->
               is_integer(oid) and oid >= 0 and oid <= 4_294_967_295 and
                 (oid != 0 or is_nil(value))
             end) do
      raise ArgumentError, ":param_oids must match params; OID 0 is allowed only for nil"
    end
  end

  defp infer(statement, params) do
    with [_, projection] <- Regex.run(~r/\A\s*SELECT\s+(.+?)\s*;?\s*\z/is, statement),
         parts = String.split(projection, ","),
         true <- length(parts) == length(params) and params != [] do
      parts
      |> Enum.zip(params)
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {{part, value}, index}, acc ->
        with [_, number, cast] <- Regex.run(~r/\A\s*\$(\d+)\s*::\s*([a-z0-9 ]+?)\s*\z/i, part),
             true <- String.to_integer(number) == index,
             oid when not is_nil(oid) <- @casts[String.downcase(cast)],
             inferred when inferred == oid or inferred == 0 <- infer_value(value) do
          {:cont, [inferred | acc]}
        else
          _ -> {:halt, :fallback}
        end
      end)
      |> case do
        :fallback -> :fallback
        oids -> {:ok, Enum.reverse(oids)}
      end
    else
      _ -> :fallback
    end
  end

  defp infer_value(nil), do: 0

  defp infer_value(v)
       when is_integer(v) and v >= -9_223_372_036_854_775_808 and v <= 9_223_372_036_854_775_807,
       do: 20

  defp infer_value(v) when is_binary(v), do: 25
  defp infer_value(v) when is_boolean(v), do: 16
  defp infer_value(v) when is_float(v), do: 701
  defp infer_value(%Decimal{}), do: 1700
  defp infer_value(%Date{}), do: 1082
  defp infer_value(%NaiveDateTime{}), do: 1114
  defp infer_value(%DateTime{}), do: 1184
  defp infer_value(_), do: :ambiguous
end
