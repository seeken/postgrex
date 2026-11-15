defmodule Postgrex.PipelineTest do
  use ExUnit.Case, async: true

  defmodule RaisingFloat do
    @behaviour Postgrex.Extension
    def init(_), do: nil
    def matching(_), do: [send: "float8send"]
    def format(_), do: :binary

    def encode(_) do
      quote do
        value when is_float(value) -> <<8::signed-32, value::float-64>>
      end
    end

    def fail(_), do: raise("deliberate decoder failure")

    def decode(_) do
      quote do
        <<8::signed-32, value::float-64>> -> Postgrex.PipelineTest.RaisingFloat.fail(value)
      end
    end
  end

  Postgrex.Types.define(PipelineRaisingTypes, [RaisingFloat], [])

  defmodule TextFloat do
    @behaviour Postgrex.Extension
    def init(_), do: nil
    def matching(_), do: [send: "float8send"]
    def format(_), do: :text

    def encode(_) do
      quote do
        value when is_binary(value) -> [<<byte_size(value)::signed-32>>, value]
      end
    end

    def decode(_) do
      quote do
        <<size::signed-32, value::binary-size(size)>> -> value
      end
    end
  end

  Postgrex.Types.define(PipelineTextTypes, [TextFloat], [])

  setup do
    {:ok, pid} = Postgrex.start_link(opts())
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{pid: pid}
  end

  defp opts do
    [
      database: "postgrex_test",
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      transactions: :strict
    ]
  end

  defp wave(pid, sql, params \\ [], opts \\ []),
    do: Postgrex.pipeline_read(pid, "BEGIN READ ONLY", sql, params, opts)

  defp idle(pid) do
    assert DBConnection.status(pid) == :idle
    assert {:ok, %{rows: [[1]]}} = Postgrex.query(pid, "SELECT 1", [])
  end

  test "unknown OIDs preserve inferred arithmetic and overloads", %{pid: pid} do
    sql = "SELECT $1 + 1 AS n, pg_typeof($1)::text"
    assert {:ok, fast} = wave(pid, sql, [2])
    assert {:ok, old} = Postgrex.query(pid, sql, [2], one_trip: false)
    assert fast.rows == old.rows
    assert fast.rows == [[3, "integer"]]
    idle(pid)
  end

  test "scalar text representations match the existing codecs", %{pid: pid} do
    params = [
      42,
      1.2345678901234567,
      Decimal.new("123456.00100"),
      true,
      "café'\\test",
      ~D[2026-11-14],
      ~T[12:34:56.123456],
      ~N[2026-11-14 12:34:56.123456],
      ~U[2026-11-14 12:34:56.123456Z],
      nil
    ]

    sql =
      "SELECT $1::int8, $2::float8, $3::numeric, $4::bool, $5::text, $6::date, $7::time, $8::timestamp, $9::timestamptz, $10::text"

    assert {:ok, fast} = wave(pid, sql, params, text_binaries: true)
    assert {:ok, old} = Postgrex.query(pid, sql, params, one_trip: false)
    assert fast.rows == old.rows
    assert fast.columns == old.columns
    idle(pid)
  end

  test "ambiguous binaries and unsupported values decline before sending", %{pid: pid} do
    for value <- [
          "\\x41",
          <<0, 255>>,
          [1, 2],
          %{a: 1},
          {1, 2},
          %Postgrex.INET{address: {127, 0, 0, 1}}
        ] do
      assert :fallback = wave(pid, "SELECT $1", [value])
      idle(pid)
    end
  end

  test "host transactions decline and stay intact", %{pid: pid} do
    for opts <- [[mode: :savepoint], [postgrex_copy: true], [comment: "trace"]] do
      assert :fallback = wave(pid, "SELECT 1", [], opts)
      idle(pid)
    end

    assert {:ok, :done} =
             Postgrex.transaction(pid, fn conn ->
               assert :fallback = wave(conn, "SELECT 1")
               assert DBConnection.status(conn) == :transaction
               :done
             end)

    idle(pid)
  end

  test "Parse, Bind and Execute errors drain all three parts", %{pid: pid} do
    for {sql, params, opts} <- [
          {"SELECT (", [], []},
          {"SELECT 1; SELECT 2", [], []},
          {"SELECT $1::int4", ["bad"], [text_binaries: true]},
          {"SELECT 1/0", [], []}
        ] do
      assert {:error, :query, %Postgrex.Error{}} = wave(pid, sql, params, opts)
      idle(pid)
    end
  end

  test "opening error wins over the aborted business error", %{pid: pid} do
    assert {:error, :opening, %Postgrex.Error{postgres: %{code: :division_by_zero}}} =
             Postgrex.pipeline_read(pid, "BEGIN READ ONLY; SELECT 1/0", "SELECT 2", [])

    idle(pid)
  end

  test "read only enforcement and server cancellation leave idle", %{pid: pid} do
    assert {:error, :query, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} =
             wave(pid, "CREATE TABLE never_created(id int)")

    assert {:error, :query, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
             Postgrex.pipeline_read(
               pid,
               "BEGIN READ ONLY; SET LOCAL statement_timeout='20ms'",
               "SELECT pg_sleep(1)",
               []
             )

    idle(pid)
  end

  test "unknown result types drain before returning a replay decision", %{pid: pid} do
    type = "pipeline_enum_#{System.unique_integer([:positive])}"
    Postgrex.query!(pid, "CREATE TYPE #{type} AS ENUM ('one')", [])

    try do
      assert {:fallback, :unknown_result} = wave(pid, "SELECT 'one'::#{type}")
      idle(pid)
      assert %{rows: [["one"]]} = Postgrex.query!(pid, "SELECT 'one'::#{type}", [])
    after
      Postgrex.query!(pid, "DROP TYPE #{type}", [])
    end
  end

  test "text-only result codecs drain before declining" do
    {:ok, pid} = Postgrex.start_link(Keyword.put(opts(), :types, PipelineTextTypes))
    assert {:fallback, :text_result} = wave(pid, "SELECT 1.5::float8")
    idle(pid)
    assert %{rows: [["1.5"]]} = Postgrex.query!(pid, "SELECT 1.5::float8", [])
    GenServer.stop(pid)
  end

  test "decoder exceptions drain before declining" do
    {:ok, pid} = Postgrex.start_link(Keyword.put(opts(), :types, PipelineRaisingTypes))
    assert {:fallback, :decode} = wave(pid, "SELECT 1.5::float8")
    idle(pid)
    GenServer.stop(pid)
  end

  test "READ ONLY rollback is not a replay-safety guarantee", %{pid: pid} do
    # The lock remains held after this wave, including when a result type forces
    # a fallback. Replaying would increment its session lock count a second time.
    key = System.unique_integer([:positive])
    assert {:ok, _} = wave(pid, "SELECT pg_advisory_lock(#{key})")
    assert %{rows: [[true]]} = Postgrex.query!(pid, "SELECT pg_advisory_unlock(#{key})", [])
    assert %{rows: [[false]]} = Postgrex.query!(pid, "SELECT pg_advisory_unlock(#{key})", [])
    idle(pid)
  end

  test "failed rollback disconnect preserves the original failing part" do
    for {stage, opening, business, expected_code} <- [
          {:rollback, command("BEGIN") <> ready(?T), command("SELECT 0") <> ready(?T), "42601"},
          {:query, command("BEGIN") <> ready(?T), error("22012", "business") <> ready(?E),
           "22012"},
          {:opening, error("P0001", "opening") <> ready(?E),
           error("25P02", "aborted") <> ready(?E), "P0001"}
        ] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      owner = self()

      worker =
        spawn_link(fn ->
          {:ok, server} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(server, 0, 1000)

          :ok =
            :gen_tcp.send(server, opening <> business <> error("42601", "rollback") <> ready(?E))

          send(owner, {:sent, self()})
          :gen_tcp.recv(server, 0, 1000)
          :gen_tcp.close(server)
        end)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      state = %Postgrex.Protocol{
        sock: {:gen_tcp, socket},
        buffer: <<>>,
        postgres: :idle,
        transactions: :strict,
        connection_id: 1
      }

      query = %Postgrex.Pipeline{opening: "BEGIN READ ONLY", statement: "SELECT 1"}

      assert {:disconnect,
              %Postgrex.PipelineError{
                stage: ^stage,
                error: %Postgrex.Error{postgres: %{pg_code: ^expected_code}}
              }, state} =
               Postgrex.Protocol.handle_execute(query, [], [], state)

      assert state.postgres == :error
      assert_receive {:sent, ^worker}
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end
  end

  defp frame(type, payload), do: <<type, byte_size(payload) + 4::32, payload::binary>>
  defp command(tag), do: frame(?C, tag <> <<0>>)
  defp ready(state), do: frame(?Z, <<state>>)

  defp error(code, message),
    do: frame(?E, <<?S, "ERROR", 0, ?C, code::binary, 0, ?M, message::binary, 0, 0>>)
end
