zrjg
===

Random JSON Generator implemented in Zig.
This project is inspired by the Rust-based [rjg](https://github.com/sile/rjg) and provides similar functionality in a Zig implementation.

```console

// Generate integer arrays.
$ rjg --count 3 '[0, {"$int": {"min": 1, "max": 8}}, 9]'
[0,1,9]
[0,3,9]
[0,8,9]

// Generate objects with user-defined variables.
$ rjg --count 3 \
      -v key='{"$str": ["key_", "$alpha", "$alpha", "$digit"]}' \
      -v val='{"$option": "$u16"}' \
      '{"put": {"key": "$key", "value": "$val"}}'
{"put":{"key":"key_dX2","value":5873}}
{"put":{"key":"key_Hh8","value":55205}}
{"put":{"key":"key_Dq4","value":null}}

// Print help.
$ rjg -h
Random JSON generator

Usage: rjg [OPTIONS] <JSON_TEMPLATE>

Arguments:
  <JSON_TEMPLATE>  JSON template used to generate values

Options:
    -h, --help                    Print help
    -c, --count <COUNT>           Number of JSON values to generate [default: 1]
    -v, --variable <VARIABLE>...  User-defined variables
    -p, --prefix <PREFIX>         Prefix for variable and generator names [default: $]
    -f, --file <FILE>             File to output
    <TEMPLATE>...                 Json template used to generate values

```

Rules
-----

- Literal JSON values within a JSON template are outputted exactly as they are
- Non-literal JSON values are classified as follows:
  - **Variables**: JSON strings starting with the `$` prefix
  - **Generators**: Single-member objects with a key starting with the `$` prefix
  - NOTE:
    - The prefix can be changed using `--prefix` option.
    - Both variables and generators cannot be used as object names.
- **Variables**:
  - Variables can be [pre-defined](#pre-defined-variables) or user-defined (the latter are defined via `--variable` option)
  - The value of a variable is evaluated to a JSON value when generating a JSON value
- **Generators**:
  - [Generators](#generators) produce a random JSON value based on their content

Generators
----------

### `int`

`int` generator produces a JSON integer between `min` and `max`.

```
{"$int": {"min": INTEGER, "max": INTEGER}}
```

#### `int` examples

```console
$ rjg --count 3 '{"$int": {"min": -5, "max": 5}}'
-5
-4
0
```

### `str`

`str` generator procudes a JSON string by concating the values with in the given array.
Note that `null` values are filtered out from the result.

```
{"$str": [VALUE, ...]}
```

#### `str` examples

```console
$ rjg --count 3 '{"$str": ["$digit", " + ", "$digit"]}'
"8 + 2"
"0 + 3"
"1 + 9"

$ rjg --count 3 '{"$str": [{"$option": "_"}, "$alpha", "$alpha", "$digit"]}'
"im9"
"_Xw6"
"_Rv8"

$ rjg --count 3 '{"$str": {"$arr": {"len": 8, "val": "$digit"}}}'
"53820416"
"64606941"
"65477569"
```

### `arr`

`arr` generator produces a JSON array based on the provided length and value.
Unlike other generators, `arr` postpones the evaluation of `val` until each individual array item is generated.

```
{"$arr": {"len": INTEGER, "val": VALUE}}
```

#### `arr` examples

```console
$ rjg --count 3 '{"$arr": {"len": 3, "val": "$digit"}}'
[3,8,5]
[7,8,5]
[1,1,4]

$ rjg --count 3 '{"$arr": {"len": "$digit", "val": "$digit"}}'
[6,6,9]
[3,7,0]
[7,1,8,5,0]
```

### `obj`

`obj` generator produces a JSON object from an array of objects that specify a name and value.
Note that `null` values in the array are ignored when producing the resulting object.

```
{"$obj": [{"name": STRING, "val": VALUE} | null, ...]}
```

#### `obj` examples

```console
$ rjg --count 3 '{"$obj": [{"name":"foo", "val":"$u8"}, {"$option":{"name":"bar", "val":"$i8"}}]}'
{"foo":174,"bar":48}
{"foo":90}
{"foo":213}

$ rjg --count 3 -v key='{"$str": ["$alpha", "$alpha"]}' '{"$obj": [{"name":"$key", "val":"$u8"}]}'
{"bi":199}
{"dP":34}
{"lC":142}
```

### `oneof`

`oneof` generator selects a JSON value from the given array.

```
{"$oneof": [VALUE, ...]}
```

#### `oneof` examples

```console
$ rjg --count 3 '{"$oneof": ["foo", "bar", "baz"]}'
"bar"
"baz"
"bar"
```

### `option`

`option` is syntactic sugar for `oneof`.
That is, `{"$option": VALUE}` is equivalent with `{"$oneof": [VALUE, null]}`.

Pre-defined variables
---------------------

### `i`

`i` represents the current iteration count.

```console
$ rjg --count 3 '"$i"'
0
1
2
```

### `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `i64`, `digit`

Integer variables.
Each integer variable represents a JSON integer within the pre-defined range.

```console
$ rjg --count 3 '"$u8"'
110
21
198

$ rjg --count 3 '"$i32"'
-1725197084
8790253
1149821987
```

### `bool`

`bool` represents `true` or `false`.

```console
$ rjg --count 3 '"$bool"'
true
false
false
```

### `alpha`

`alpha` represents a JSON string containing an alphabetic character from the ASCII character set.

```console
$ rjg --count 3 '"$alpha"'
"e"
"t"
"I"
```
