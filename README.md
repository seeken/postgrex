# Postgrex

[![Build Status](https://github.com/elixir-ecto/postgrex/workflows/CI/badge.svg)](https://github.com/elixir-ecto/postgrex/actions)

PostgreSQL driver for Elixir.

Documentation: http://hexdocs.pm/postgrex/

## Examples

```iex
iex> {:ok, pid} = Postgrex.start_link(hostname: "localhost", username: "postgres", password: "postgres", database: "postgres")
{:ok, #PID<0.69.0>}

iex> Postgrex.query!(pid, "SELECT user_id, text FROM comments", [])
%Postgrex.Result{command: :select, empty?: false, columns: ["user_id", "text"], rows: [[3,"hey"],[4,"there"]], size: 2}}

iex> Postgrex.query!(pid, "INSERT INTO comments (user_id, text) VALUES (10, 'heya')", [])
%Postgrex.Result{command: :insert, columns: nil, rows: nil, num_rows: 1}
```

## Features

  * Automatic decoding and encoding of Elixir values to and from PostgreSQL's binary format
  * User defined extensions for encoding and decoding any PostgreSQL type
  * Supports transactions, prepared queries and multiple pools via [DBConnection](https://github.com/elixir-ecto/db_connection)
  * Supports PostgreSQL 8.4, 9.0-9.6, and later (hstore is not supported on 8.4)

## Data representation

| PostgreSQL         | Elixir                                                                                                                                      |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `NULL`             | `nil`                                                                                                                                       |
| `bool`             | `true`, `false`                                                                                                                             |
| `char`             | `"é"`                                                                                                                                       |
| `int`              | `42`                                                                                                                                        |
| `float`            | `42.0`                                                                                                                                      |
| `text`             | `"eric"`                                                                                                                                    |
| `bytea`            | `<<42>>`                                                                                                                                    |
| `numeric`          | `#Decimal<42.0>` (1)                                                                                                                        |
| `date`             | `%Date{year: 2013, month: 10, day: 12}`                                                                                                     |
| `time(tz)`         | `%Time{hour: 0, minute: 37, second: 14}` (2)                                                                                                |
| `timestamp`        | `%NaiveDateTime{year: 2013, month: 10, day: 12, hour: 0, minute: 37, second: 14}`                                                           |
| `timestamptz`      | `%DateTime{year: 2013, month: 10, day: 12, hour: 0, minute: 37, second: 14, time_zone: "Etc/UTC"}` (2)                                      |
| `interval`         | `%Postgrex.Interval{months: 14, days: 40, secs: 10920, microsecs: 315}`                                                                     |
| `interval`         | `%Duration{month: 2, day: 5, second: 0, microsecond: {315, 6}}` (3)                                   |
| `array`            | `[1, 2, 3]`                                                                                                                                 |
| `composite type`   | `{42, "title", "content"}`                                                                                                                  |
| `range`            | `%Postgrex.Range{lower: 1, upper: 5}`                                                                                                       |
| `multirange`       | `%Postgrex.Multirange{ranges: [%Postgrex.Range{lower: 1, upper: 5}, %Postgrex.Range{lower: 20, upper: 23}]}`                                |
| `uuid`             | `<<160,238,188,153,156,11,78,248,187,109,107,185,189,56,10,17>>`                                                                            |
| `hstore`           | `%{"foo" => "bar"}`                                                                                                                         |
| `oid types`        | `42`                                                                                                                                        |
| `enum`             | `"ok"` (4)                                                                                                                                  |
| `bit`              | `<< 1::1, 0::1 >>`                                                                                                                          |
| `varbit`           | `<< 1::1, 0::1 >>`                                                                                                                          |
| `tsvector`         | `[%Postgrex.Lexeme{positions: [{1, :A}], word: "a"}]`                                                                                       |

(1) [Decimal](http://github.com/ericmj/decimal)

(2) Timezones will always be normalized to UTC or assumed to be UTC when no information is available, either by PostgreSQL or Postgrex

(3) `%Duration{}` may only be used with Elixir 1.17+. Intervals will only be decoded into a `%Duration{}` struct if the option `interval_decode_type: Duration` is passed to `Postgrex.Types.define/3`.

(4) Enumerated types (enum) are custom named database types with strings as values.

(5) Anonymous composite types are decoded (read) as tuples but they cannot be encoded (written) to the database

Postgrex does not automatically cast between types. For example, you can't pass a string where a date is expected. To add type casting, support new types, or change how any of the types above are encoded/decoded, you can use extensions.

## JSON support

Postgrex comes with JSON support out of the box via the [Jason](https://github.com/michalmuskala/jason) library. To use it, add :jason to your dependencies:

```elixir
{:jason, "~> 1.0"}
```

You can customize it to use another library via the `:json_library` configuration:

```elixir
config :postgrex, :json_library, SomeOtherLib
```

Once you change the value, you have to recompile Postgrex, which can be done by cleaning its current build:

```sh
mix deps.clean postgrex --build
```

## Extensions

Extensions are used to extend Postgrex' built-in type encoding/decoding.

The [extensions](https://github.com/elixir-ecto/postgrex/blob/master/lib/postgrex/extensions/) directory in this project provides implementation for many Postgres' built-in data types. It is also a great example of how to implement your own extensions. For example, you can look at the [`Date`](https://github.com/elixir-ecto/postgrex/blob/master/lib/postgrex/extensions/date.ex) extension as a starting point.

Once you defined your extensions, you should build custom type modules, passing all of your extensions as arguments:

```elixir
Postgrex.Types.define(MyApp.PostgrexTypes, [MyApp.Postgis.Extensions], [])
```

`Postgrex.Types.define/3` must be called on its own file, outside of any module and function, as it only needs to be defined once during compilation.

Once a type module is defined, you must specify it on `start_link`:

```elixir
Postgrex.start_link(types: MyApp.PostgrexTypes)
```

## OID type encoding

PostgreSQL's wire protocol supports encoding types either as text or as binary. Unlike most client libraries Postgrex uses the binary protocol, not the text protocol. This allows for efficient encoding of types (e.g. 4-byte integers are encoded as 4 bytes, not as a string of digits) and automatic support for arrays and composite types.

Unfortunately the PostgreSQL binary protocol transports [OID types](http://www.postgresql.org/docs/current/static/datatype-oid.html#DATATYPE-OID-TABLE) as integers while the text protocol transports them as string of their name, if one exists, and otherwise as integer.

This means you either need to supply oid types as integers or perform an explicit cast (which would be automatic when using the text protocol) in the query.

```elixir
# Fails since $1 is regclass not text.
query("select nextval($1)", ["some_sequence"])

# Perform an explicit cast, this would happen automatically when using a
# client library that uses the text protocol.
query("select nextval($1::text::regclass)", ["some_sequence"])

# Determine the oid once and store it for later usage. This is the most
# efficient way, since PostgreSQL only has to perform the lookup once. Client
# libraries using the text protocol do not support this.
%{rows: [{sequence_oid}]} = query("select $1::text::regclass", ["some_sequence"])
query("select nextval($1)", [sequence_oid])
```

## PgBouncer

PgBouncer versions 1.21.0 and later support named prepared statements. If you are using an older version of PgBouncer with transaction or statement pooling, named prepared queries cannot be used because the bouncer may route requests from the same Postgrex connection to different PostgreSQL backend processes and discards named queries after the transaction closes. To force unnamed prepared queries in such older versions:

```elixir
Postgrex.start_link(prepare: :unnamed)
```

[PgBouncer 1.21.0 release notes](https://www.pgbouncer.org/changelog.html#pgbouncer-121x)

## Experimental one-trip unnamed queries

This fork prototypes an opt-in extended query pipeline. The default is off.
For a statement whose parameter types and repeatability you control:

```elixir
Postgrex.query(conn, "SELECT * FROM widgets WHERE id = $1", [42],
  one_trip: true,
  param_oids: [20],
  one_trip_retry_safe: true
)
```

`param_oids` must be the PostgreSQL types the application intends, not guesses
from Elixir values. For an `int4` key use OID 23, not 20. Supplying OIDs can
change overload resolution, casts, precision and overflow behavior compared
with server inference. Explicit text (25) is not interchangeable with uuid
(2950), jsonb (3802), enum, bytea or unknown literals. OID 0 is permitted only
for `nil`; NULL is sent with its ordinary -1 length framing.

`one_trip_retry_safe: true` asserts that repeating the whole statement has no
observable effects. A SELECT can call volatile functions, advance sequences,
or lock rows, so its spelling alone does not establish repeatability. Without
this assertion, explicitly typed requests use the ordinary path. Do not use
this assertion for writes or effectful SELECTs.

Inside an existing transaction, also supply `one_trip_result_oids`, listing
all expected output types in column order. Keep this declaration in sync with
the SQL and schema. All these types must already have binary decoders in the
connection's type cache; otherwise preparation falls back before sending Bind.
For example, `SELECT id, status FROM widgets WHERE id = $1` with an int4 key
and text status uses `param_oids: [23], one_trip_result_oids: [23, 25]`.
This restriction avoids aborting a transaction on a speculative binary Bind
error. Schema drift invalidating the declaration remains a caller contract
violation; the prototype does not supply automatic savepoint protection.

Without explicit parameter OIDs, inference accepts **only** a whole statement
consisting of `SELECT $1::type, $2::type, ...`, in consecutive parameter order,
with optional surrounding whitespace and a final semicolon. There are no
FROM clauses, expressions, comments, aliases, functions or other SQL syntax.
Every non-null value must map to exactly the cast type:

| Elixir value | PostgreSQL type / OID | Accepted cast spellings |
|---|---|---|
| signed 64-bit integer | int8 / 20 | int8, bigint |
| binary | text / 25 | text |
| boolean | bool / 16 | bool, boolean |
| float | float8 / 701 | float8, double precision |
| Decimal | numeric / 1700 | numeric |
| Date | date / 1082 | date |
| NaiveDateTime | timestamp / 1114 | timestamp |
| DateTime | timestamptz / 1184 | timestamptz |
| nil | unknown / 0 | any of the above, plus int4, integer |

All other inputs and SQL fall back. This includes integer arithmetic, integer
parameters cast to int4, table comparisons, uuid/jsonb comparisons, arrays,
composites, maps, atoms, time values and integers outside the int8 range.
There is deliberately no general SQL inference. The accepted projections
already force the same types on the server and are safe to repeat. Within a
transaction the result declaration rule still applies.

The pipeline sends Parse, Describe, Bind, Execute, Close and Sync in one
socket send. Close retains ordinary unnamed statement cleanup. Bind requests
binary for every result column before RowDescription arrives. Parameter
encoders and result decoders come from this connection's bootstrapped type
cache, including custom type modules. Unknown parameter types fall back before
sending the pipeline. Unknown result types or text-only decoders cause the
pipeline to drain raw replies through ReadyForQuery, then the ordinary path
reloads types and selects its normal per-column formats. The repeatability
contract is necessary because Execute may already have finished. A server
error is drained and returned; only the specific missing binary output
function error in this fallback is retried. Transaction declarations preflight
known text-only/missing decoders instead of speculating on them.

Named cache requests, explicit prepare/execute, streams, COPY and savepoint
mode keep their existing paths. The application setting
`config :postgrex, :one_trip, true` changes the query option's default for
verification; explicit `one_trip: false` overrides it. Enabling it does not
make ineligible SQL use the pipeline.

## Contributing

To contribute you need to compile Postgrex from source and test it:

```
$ git clone https://github.com/elixir-ecto/postgrex.git
$ cd postgrex
$ mix test
```

The tests requires some modifications to your [hba file](http://www.postgresql.org/docs/9.3/static/auth-pg-hba-conf.html). The path to it can be found by running `$ psql -U postgres -c "SHOW hba_file"` in your shell. Put the following above all other configurations (so that they override):

```
local   all             all                     trust
host    all             postgrex_md5_pw         127.0.0.1/32    md5
host    all             postgrex_cleartext_pw   127.0.0.1/32    password
host    all             postgrex_scram_pw       127.0.0.1/32    scram-sha-256
```

The server needs to be restarted for the changes to take effect. Additionally you need to setup a PostgreSQL user with the same username as the local user and give it trust or ident in your hba file. Or you can export $PGUSER and $PGPASSWORD before running tests.

### Testing hstore on 9.0

PostgreSQL versions 9.0 does not have the `CREATE EXTENSION` commands. This means we have to locate the postgres installation and run the `hstore.sql` in `contrib` to install `hstore`. Below is an example command to test 9.0 on OS X with homebrew installed postgres:

```
$ PGVERSION=9.0 PGPATH=/usr/local/share/postgresql9/ mix test
```

## License

Copyright 2013 Eric Meadows-Jönsson

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

### Experimental guarded read pipeline

This fork adds `Postgrex.pipeline_read(conn, opening, sql, params, opts)` for a
trusted caller-owned `BEGIN READ ONLY` opening, one unnamed extended statement,
and `ROLLBACK`. All messages are sent together. It requires an idle connection;
host transactions decline before sending. `sql` is always parsed as a single
extended-protocol statement. Named query caching is not involved.

Parse uses unknown parameter OIDs; Bind uses text input parameters and binary
results. Integers, floats, Decimal, booleans, nil and ISO date/time values have
text encoders. Arrays, maps, tuples, custom structs and ambiguous binaries
return `:fallback` before sending. `text_binaries: true` explicitly asserts that
all binary parameters are text input representations, never bytea or binary
UUIDs. Custom parameter codecs are bypassed. Text and binary input codecs can
accept different Elixir values, so this API is an explicit opt-in contract,
not a transparent replacement for `query/4`.

Successful results use the active connection's binary decoders, including custom
JSONB decoders. Missing/text-only decoders or decoding exceptions return
`{:fallback, reason}` **after draining and rollback**. There is no automatic
replay. READ ONLY and ROLLBACK do not undo session advisory locks, prepared
statements or external effects. Replaying requires a separate repeatability
contract. Errors include their stage (`:opening`, `:query`, `:rollback`); opening
errors take precedence. A failure to reach idle disconnects the connection.

The API is explicit and has no application-wide switch that wraps arbitrary
Postgrex commands in read-only transactions. Existing `query/4`, transactions,
streams, COPY and the earlier `one_trip` option keep their own behavior.
