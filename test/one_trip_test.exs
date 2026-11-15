defmodule Postgrex.OneTripTest do
  use ExUnit.Case, async: true
  alias Postgrex.OneTrip

  defmodule TextExtension do
    @behaviour Postgrex.Extension
    def init(_), do: []
    def matching(_), do: [send: "float8send", type: "aclitem"]
    def format(_), do: :text

    def encode(_) do
      quote do
        v when is_binary(v) -> [<<byte_size(v)::signed-32>> | v]
      end
    end

    def decode(_) do
      quote do
        <<len::signed-32, v::binary-size(len)>> -> v
      end
    end
  end

  Postgrex.Types.define(TextTypes, [TextExtension], [])

  setup do
    {:ok, pid} =
      Postgrex.start_link(database: "postgrex_test", backoff_type: :stop, transactions: :strict)

    %{pid: pid}
  end

  defp opts(oids), do: [one_trip: true, param_oids: oids, one_trip_retry_safe: true]

  test "one send replaces two sends on the unnamed wire path", %{pid: p} do
    Postgrex.query!(p, "SELECT 1", [], one_trip: false)

    assert wire_sends(fn -> Postgrex.query!(p, "SELECT $1::int8", [42], one_trip: false) end) == [
             "PDH",
             "BECS"
           ]

    assert wire_sends(fn -> Postgrex.query!(p, "SELECT $1::int8", [42], opts([20])) end) == [
             "PDBECS"
           ]
  end

  defp wire_sends(fun) do
    tracer = spawn(fn -> collect_sends([]) end)
    :erlang.trace_pattern({:gen_tcp, :send, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      receive do: ({:trace_delivered, _, ^ref} -> :ok)
      send(tracer, {:get, self()})
      receive do: ({:sends, sends} -> sends)
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({:gen_tcp, :send, 2}, false, [:local])
      Process.exit(tracer, :kill)
    end
  end

  defp collect_sends(acc) do
    receive do
      {:trace, _, :call, {:gen_tcp, :send, [_, data]}} ->
        collect_sends([wire_tags(IO.iodata_to_binary(data)) | acc])

      {:get, pid} ->
        send(pid, {:sends, Enum.reverse(acc)})
    end
  end

  defp wire_tags(<<tag, size::32, _::binary-size(size - 4), rest::binary>>),
    do: <<tag>> <> wire_tags(rest)

  defp wire_tags(<<>>), do: ""

  test "explicit OIDs, all binary results and ordinary queries interleave", %{pid: p} do
    for _ <- 1..3 do
      assert %{rows: [[42, "hello", true]]} =
               Postgrex.query!(p, "SELECT $1, $2, $3", [42, "hello", true], opts([20, 25, 16]))

      assert %{rows: [[43]]} = Postgrex.query!(p, "SELECT $1::int4", [43], one_trip: false)
    end
  end

  test "all conservative inference types plus unknown NULL", %{pid: p} do
    values = [
      42,
      "hi",
      true,
      1.5,
      Decimal.new("12.25"),
      ~D[2026-01-02],
      ~N[2026-01-02 03:04:05.000000],
      ~U[2026-01-02 03:04:05.000000Z],
      nil
    ]

    sql =
      "SELECT $1::int8, $2::text, $3::bool, $4::float8, $5::numeric, $6::date, $7::timestamp, $8::timestamptz, $9::int4"

    assert {:ok, [20, 25, 16, 701, 1700, 1082, 1114, 1184, 0]} =
             OneTrip.parameter_oids(sql, values, one_trip: true)

    assert %{rows: [^values]} = Postgrex.query!(p, sql, values, one_trip: true)
  end

  test "ambiguous SQL and values fall back without changing resolution", %{pid: p} do
    for {sql, values} <- [
          {"SELECT $1 + 1", [1]},
          {"SELECT $1::int4", [1]},
          {"SELECT $1::uuid", [<<0::128>>]},
          {"SELECT $1::jsonb", [%{"a" => 1}]},
          {"SELECT $1::text[]", [["x"]]},
          {"SELECT length($1::text)", ["hi"]},
          {"SELECT '$1::text'", ["x"]},
          {"SELECT $1::int8 -- comment", [42]},
          {"SELECT $1::int8 FROM generate_series(1,2)", [42]},
          {"SELECT $1::int8", [9_223_372_036_854_775_808]}
        ] do
      assert :fallback = OneTrip.parameter_oids(sql, values, one_trip: true)
    end

    assert %{rows: [["integer"]]} =
             Postgrex.query!(p, "SELECT pg_typeof($1 + 1)::text", [1], one_trip: true)

    assert %{rows: [[true]]} =
             Postgrex.query!(
               p,
               "SELECT $1::uuid = '00000000-0000-0000-0000-000000000000'::uuid",
               [<<0::128>>],
               one_trip: true
             )

    assert %{rows: [[%{"a" => 1}]]} =
             Postgrex.query!(p, "SELECT $1::jsonb", [%{"a" => 1}], one_trip: true)
  end

  test "explicit types require retry safety assertion; zero requires nil" do
    assert :fallback = OneTrip.parameter_oids("SELECT $1", [1], one_trip: true, param_oids: [20])
    assert_raise ArgumentError, fn -> OneTrip.parameter_oids("SELECT $1", [1], opts([0])) end
    assert_raise ArgumentError, fn -> OneTrip.parameter_oids("SELECT $1", [1], opts([])) end
  end

  test "Parse and Execute errors drain to ReadyForQuery", %{pid: p} do
    for sql <- [
          "SELECT nonexistent_column",
          "SELECT 1 / 0",
          "SELECT * FROM absent_one_trip_table"
        ] do
      assert {:error, %Postgrex.Error{}} = Postgrex.query(p, sql, [], opts([]))
      assert %{rows: [[1]]} = Postgrex.query!(p, "SELECT 1", [], opts([]))
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :undefined_function}}} =
             Postgrex.query(
               p,
               "SELECT $1 = '00000000-0000-0000-0000-000000000000'::uuid",
               ["x"],
               opts([25])
             )

    assert %{rows: [[1]]} = Postgrex.query!(p, "SELECT 1", [], opts([]))
  end

  test "encoding fails before sending without losing the connection", %{pid: p} do
    assert_raise DBConnection.EncodeError, fn ->
      Postgrex.query(p, "SELECT $1", ["bad"], opts([20]))
    end

    assert %{rows: [[1]]} = Postgrex.query!(p, "SELECT 1", [], opts([]))
  end

  test "text-only custom result decoder retries using the connection type cache" do
    {:ok, p} = Postgrex.start_link(database: "postgrex_test", types: TextTypes)
    assert %{rows: [["1.25"]]} = Postgrex.query!(p, "SELECT 1.25::float8", [], opts([]))
    assert %{rows: [["2.5"]]} = Postgrex.query!(p, "SELECT 2.5::float8", [], opts([]))

    assert %{rows: [["postgres=r/postgres"]]} =
             Postgrex.query!(p, "SELECT 'postgres=r/postgres'::aclitem", [], opts([]))

    assert %{rows: [[1]]} = Postgrex.query!(p, "SELECT 1", [], opts([]))
  end

  test "transaction result declarations fall back before unsafe binary Bind", %{pid: p} do
    {:ok, custom} = Postgrex.start_link(database: "postgrex_test", types: TextTypes)

    assert {:ok, :ok} =
             Postgrex.transaction(custom, fn conn ->
               assert %{rows: [["postgres=r/postgres"]]} =
                        Postgrex.query!(
                          conn,
                          "SELECT 'postgres=r/postgres'::aclitem",
                          [],
                          opts([]) ++ [one_trip_result_oids: [1033]]
                        )

               assert %{rows: [[1]]} = Postgrex.query!(conn, "SELECT 1", [])
               :ok
             end)

    assert {:ok, :ok} =
             Postgrex.transaction(p, fn conn ->
               assert wire_sends(fn ->
                        Postgrex.query!(conn, "SELECT $1::int8", [42], opts([20]))
                      end) == ["PDH", "BECS"]

               assert wire_sends(fn ->
                        Postgrex.query!(
                          conn,
                          "SELECT $1::int8",
                          [42],
                          opts([20]) ++ [one_trip_result_oids: [20]]
                        )
                      end) == ["PDBECS"]

               :ok
             end)
  end

  test "new enum after bootstrap reloads only after draining", %{pid: p} do
    name = "one_trip_enum_#{System.unique_integer([:positive])}"
    Postgrex.query!(p, "CREATE TYPE #{name} AS ENUM ('ok')", [], one_trip: false)

    try do
      assert %{rows: [["ok"]]} = Postgrex.query!(p, "SELECT 'ok'::#{name}", [], opts([]))
    after
      Postgrex.query!(p, "DROP TYPE #{name}", [], one_trip: false)
    end
  end

  test "transaction error and savepoint fallback", %{pid: p} do
    assert {:ok, :ok} =
             Postgrex.transaction(p, fn conn ->
               assert %{rows: [[42]]} =
                        Postgrex.query!(
                          conn,
                          "SELECT $1",
                          [42],
                          opts([20]) ++ [one_trip_result_oids: [20]]
                        )

               assert {:error, %Postgrex.Error{}} =
                        Postgrex.query(conn, "SELECT 1/0", [], opts([]) ++ [mode: :savepoint])

               assert %{rows: [[43]]} =
                        Postgrex.query!(
                          conn,
                          "SELECT $1",
                          [43],
                          opts([20]) ++ [one_trip_result_oids: [20]]
                        )

               :ok
             end)

    assert {:error, :test} =
             Postgrex.transaction(p, fn conn ->
               assert {:error, %Postgrex.Error{}} =
                        Postgrex.query(
                          conn,
                          "SELECT 1/0",
                          [],
                          opts([]) ++ [one_trip_result_oids: [23]]
                        )

               Postgrex.rollback(conn, :test)
             end)

    assert %{rows: [[1]]} =
             Postgrex.query!(p, "SELECT 1", [], opts([]) ++ [one_trip_result_oids: [23]])
  end

  test "comments and decode mapper", %{pid: p} do
    assert %{rows: [42]} =
             Postgrex.query!(
               p,
               "SELECT $1",
               [42],
               opts([20]) ++
                 [one_trip_result_oids: [20]] ++ [comment: "one trip", decode_mapper: &hd/1]
             )
  end
end
