# Copyright 2016 Gary Poster
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defprotocol Transducer do

  @type accumulator :: any
  @type state :: any
  @type annotated_accumulator :: {:cont, accumulator} | {:halt, accumulator} | {:reduce, term, accumulator}
  @type stateless_reducer :: (term, accumulator -> annotated_accumulator)
  @type stateful_reducer :: (term, {state, accumulator} -> annotated_accumulator)
  @type reducer_function :: stateless_reducer | stateful_reducer

  @spec reducer(any, reducer_function) :: reducer_function
  def reducer(transducer, reducer)

  @spec initial_state(any) :: any
  def initial_state(transducer)

  @spec compose(any, any) :: any
  def compose(transducer, other)
end

defmodule StatefulTransducer do
  defstruct initial_state: nil, function: nil
end

defmodule ComposedTransducer do
  defstruct transducers: []
end

defimpl Transducer, for: Function do
  def reducer(transducer, reducer_function), do: transducer.(reducer_function)
  def initial_state(_), do: :stateless
  def compose(transducer, %StatefulTransducer{}=other) do
    %ComposedTransducer{transducers: [transducer, other]}
  end
  def compose(transducer, %ComposedTransducer{}=other) do
    %ComposedTransducer{transducers: [transducer | other.transducers]}
  end
  def compose(transducer, other), do: fn reducer -> transducer.(other.(reducer)) end
end

defimpl Transducer, for: StatefulTransducer do
  def reducer(transducer, reducer_function) do
    transducer.function.(reducer_function)
  end
  def initial_state(transducer), do: transducer.initial_state
  def compose(transducer, %ComposedTransducer{}=other) do
    %ComposedTransducer{transducers: [transducer | other.transducers]}
  end
  def compose(transducer, other) do
    %ComposedTransducer{transducers: [transducer, other]}
  end
end

defimpl Transducer, for: ComposedTransducer do
  defp short_circuit(transducer) do
    Transducer.reducer(transducer, fn item, acc -> {:reduce, item, acc} end)
  end
  def reducer(transducer, final_reducer) do
    reducers = Enum.map(transducer.transducers, &short_circuit/1) ++ [final_reducer]
    fn item, {states, accumulator} ->
      reduce_composed(item, accumulator, reducers, states, [])
    end
  end
  defp reduce_composed(item, accumulator, [reducer | reducers], [:stateless | states], used_states) do
    case reducer.(item, accumulator) do
      {:reduce, item, accumulator} ->
        reduce_composed(item, accumulator, reducers, states, [:stateless | used_states])
      {:halt, accumulator} ->
        {:halt, {Enum.reverse([:stateless | used_states]) ++ states, accumulator}}
      {:cont, accumulator} ->
        {:cont, {Enum.reverse([:stateless | used_states]) ++ states, accumulator}}
    end
  end
  defp reduce_composed(item, accumulator, [reducer | reducers], [state | states], used_states) do
    case reducer.(item, {state, accumulator}) do
      {:reduce, item, {state, accumulator}} ->
        reduce_composed(item, accumulator, reducers, states, [state | used_states])
      {:halt, {state, accumulator}} ->
        {:halt, {Enum.reverse([state | used_states]) ++ states, accumulator}}
      {:cont, {state, accumulator}} ->
        {:cont, {Enum.reverse([state | used_states]) ++ states, accumulator}}
    end
  end
  defp reduce_composed(item, accumulator, [reducer], [], used_states) do
    reducer.(item, {Enum.reverse(used_states), accumulator})
  end
  def initial_state(transducer) do
    Enum.map(transducer.transducers, &Transducer.initial_state/1)
  end
  def compose(transducer, %ComposedTransducer{transducers: [other | transducers]}) do
    _compose(transducer.transducers, other, [], transducers)
  end
  def compose(transducer, other) do
    _compose(transducer.transducers, other, [], [])
  end
  defp _compose([], nil, acc, [head | tail]) do
    _compose([], nil, [head | acc], tail)
  end
  defp _compose([], nil, acc, []) do
    %ComposedTransducer{transducers: Enum.reverse(acc)}
  end
  defp _compose([next], other, acc, tail) when is_function(next) and is_function(other) do
    _compose([], nil, [Transducer.compose(next, other) | acc], tail)
  end
  defp _compose([next], other, acc, tail) do
    _compose([], nil, [other | [next | acc]], tail)
  end
  defp _compose([next | transducers], other, acc, tail) do
    _compose(transducers, other, [next | acc], tail)
  end
end

defmodule Transduce do

  @moduledoc """
  Composable algorithmic transformations.

  Rich Hickey introduced the idea in [this
  post](http://blog.cognitect.com/blog/2014/8/6/transducers-are-coming).
  [This post](http://phuu.net/2014/08/31/csp-and-transducers.html) is a good
  conceptual introduction.

  The input is always an enumerable.  The output can be an enumerable...

      iex> import Transduce, only: [transduce: 2, filter: 1, take: 1]
      iex> transduce(1..100, [filter(&(&1 > 5)), take(5)])
      [6, 7, 8, 9, 10]

...or can also produce another structure:

      iex> import Transduce, only: [transduce: 3, filter: 1, take: 1, put: 3]
      iex> transduce(
      ...>   [4, 8, 7, 3, 2, 9, 6, 12, 15], [
      ...>     filter(&(&1 > 5)),
      ...>     take(5),
      ...>     put(:min, nil, &min/2),
      ...>     put(:max, 0, &max/2),
      ...>     put(:count, 0, fn _, a -> a+1 end),
      ...>     put(:total, 0, &Kernel.+/2)],
      ...>   %{})
      %{count: 5, max: 12, min: 6, total: 42}

  You can write two kinds of transducers: stateless and stateful.  A stateless
  transducer is the most straightforward, since it is just a function.  Consider
  the `map` transducer.

  ```
  def map(f) do
    fn rf ->
      fn item, accumulator -> rf.(f.(item), accumulator) end
    end
  end
  ```

  At its simplest, a transducer takes a reducing function (`rf` above), and
  then returns another reducing function that wraps the `rf` with its own
  behavior.  For `map`, it passes the mapped value to the `rf` for the next
  step.  This works if the rf eventually returns a value.

  The return value is annotated, as defined by the Enumerable protocol.
  `{:cont, VALUE}` specifies that the reduction process should continue with
  the next item in the enumerable input, but VALUE is the new accumulator.
  `{:halt, VALUE}` specifies that the reduction process should stop,
  short-circuiting, and return VALUE as the result.

  For example, consider the `filter` implementation.

  ```
  def filter(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:cont, accumulator} end
      end
    end
  end
  ```

  In that case, if the filter passes the new item from the enumerable, it is
  passed through to the inner reducing function.  If it doesn't pass, the
  code returns `:cont` with an unchanged accumulator, indicating that we should
  move on to the next item in the source enumerable without a new accumulator.
  For an example of `:halt`, see the `take_while` implementation.

  A stateful transducer looks similar, but has some additional features.
  Consider the `take` implementation.

  ```
  def take(count) do
    %StatefulTransducer{
      initial_state: 0,
      function: fn rf ->
        fn
          item, {state, accumulator} when state < count ->
            rf.(item, {state+1, accumulator})
          item, {state, accumulator} -> {:halt, {state, accumulator}}
        end
      end
    }
  end
  ```

  A take transducer returns a StatefulTransducer struct, which specifies an
  `initial_state` and a `function`.  The function again takes a reducing
  function (`rf`) but the wrapping function this time expects that the
  accumulator has the shape `{state, accumulator}`.  The state is private to
  this function, and will not be in the final accumulator result, but must also
  be included in the function output, whether it's passed to the wrapped
  reducing function or returned to the caller with `:halt` or `:cont`.
  """

  @doc ~S"""
  Transduce a given enumerable to generate a list.

  ## Examples

      iex> import Transduce, only: [transduce: 2, take: 1, compose: 1, filter: 1]
      iex> transduce([2,3,5,7,11], take(3))
      [2, 3, 5]
      iex> transduce(0..20, compose([filter(&(rem(&1, 2) == 0)), take(5)]))
      [0, 2, 4, 6, 8]
      iex> transduce(0..20, [filter(&(rem(&1, 3) == 0)), take(6)])
      [0, 3, 6, 9, 12, 15]
  """
  def transduce(enumerable, transducer) do
    transduce(enumerable, transducer, [], &({:cont, [&1 | &2]}), &:lists.reverse/1)
  end

  @spec transduce(any, any, any, Transducer.stateless_reducer, any) :: any
  def transduce(enumerable, transducer, accumulator, stateless_reducer \\ fn _, acc -> {:cont, acc} end, finalizer \\ &(&1))
  def transduce(enumerable, transducer, accumulator, stateless_reducer, finalizer) when is_function(transducer) do
    {_, result} = Enumerable.reduce(
      enumerable, {:cont, accumulator}, transducer.(stateless_reducer))
    finalizer.(result)
  end
  def transduce(enumerable, transducers, accumulator, stateless_reducer, finalizer) when is_list(transducers) do
    transduce(enumerable, compose(transducers), accumulator, stateless_reducer, finalizer)
  end

  def transduce(enumerable, transducer, accumulator, stateless_reducer, finalizer) do
    final_reducer = fn element, {state, accumulator} ->
       {atom, accumulator} = stateless_reducer.(element, accumulator)
       {atom, {state, accumulator}}
    end
    {_, {_state, result}} = Enumerable.reduce(
      enumerable,
      {:cont, {Transducer.initial_state(transducer), accumulator}},
      Transducer.reducer(transducer, final_reducer))
    finalizer.(result)
  end

  @doc ~S"""
  Compose multiple transducers into one.

  ## Examples

      iex> import Transduce, only: [transduce: 2, compose: 1, map: 1, filter: 1]
      iex> transduce([2,3,5,7,11,13,17,19,23], compose([map(&(&1+1)), filter(&(rem(&1,3)==0))]))
      [3, 6, 12, 18, 24]

  Stateless transducers compose into functions.

      iex> import Transduce, only: [compose: 1, map: 1]
      iex> tr = compose([map(&(&1*2)), map(&(&1+2))])
      iex> tr.(fn item, acc -> {item, acc} end).(5, 42)
      {12, 42}

  If any other kind of transducer enters the mix, it becomes a
  ComposedTransducer.

      iex> import Transduce, only: [compose: 1, map: 1, take: 1]
      iex> tr = compose([map(&(&1*2)), take(5)])
      iex> length(tr.transducers)
      2

  Composed transducers can themselves be composed.

      iex> import Transduce, only: [transduce: 2, compose: 1, map: 1, filter: 1, take: 1]
      iex> tr1 = compose([filter(&(rem(&1, 3)==0)), map(&(&1*2))])
      iex> tr2 = compose([map(&(&1+1)), take(5)])
      iex> transduce(0..20, compose([tr1, tr2]))
      [1, 7, 13, 19, 25]
  """
  def compose([first | rest] = _transducers) do
    _compose(first, rest)
  end

  def _compose(current, [next1, next2 | rest])
    when not is_function(current) and is_function(next1) and is_function(next2) do
    _compose(current, [Transducer.compose(next1, next2) | rest])
  end
  def _compose(current, [next | rest]) do
    _compose(Transducer.compose(current, next), rest)
  end
  def _compose(current, []), do: current

  @doc ~S"""
  Apply a function to each item it receives.

  ## Examples

      iex> import Transduce, only: [transduce: 2, map: 1]
      iex> transduce(0..4, map(&(-&1)))
      [0, -1, -2, -3, -4]
  """
  def map(f) do
    fn rf ->
      fn item, accumulator -> rf.(f.(item), accumulator) end
    end
  end

  @doc ~S"""
  Only include items if the filter function returns true.

  ## Examples

      iex> import Transduce, only: [transduce: 2, filter: 1]
      iex> transduce(0..5, filter(&(rem(&1,2)==0)))
      [0, 2, 4]
  """
  def filter(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:cont, accumulator} end
      end
    end
  end

  @doc ~S"""
  Exclude items if the remove function returns true.

  ## Examples

      iex> import Transduce, only: [transduce: 2, remove: 1]
      iex> transduce(0..5, remove(&(rem(&1,2)==0)))
      [1, 3, 5]
  """
  def remove(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do {:cont, accumulator} else rf.(item, accumulator) end
      end
    end
  end

  @doc ~S"""
  Only iterate while the function returns true.

  ## Examples

      iex> import Transduce, only: [transduce: 2, take_while: 1]
      iex> transduce([0, 1, 2, 10, 11, 4], take_while(&(&1 < 10)))
      [0, 1, 2]
  """
  def take_while(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:halt, accumulator} end
      end
    end
  end

  @doc ~S"""
  Take the first N items from the enumerable and then stop iteration.

  ## Examples

      iex> import Transduce, only: [transduce: 2, take: 1, filter: 1]
      iex> transduce(0..200, take(5))
      [0, 1, 2, 3, 4]
      iex> transduce(0..200, [filter(&(rem(&1, 5)==0)), take(5)])
      [0, 5, 10, 15, 20]
  """
  def take(count) do
    %StatefulTransducer{
      initial_state: 0,
      function: fn rf ->
        fn
          item, {state, accumulator} when state < count ->
            rf.(item, {state+1, accumulator})
          _, {state, accumulator} -> {:halt, {state, accumulator}}
        end
      end
    }
  end

  @doc ~S"""
  Skip the first N items from the enumerable and then iterate.

  ## Examples

      iex> import Transduce, only: [transduce: 2, skip: 1, take: 1]
      iex> transduce(0..10, skip(8))
      [8, 9, 10]
      iex> transduce(0..20, [skip(4), take(2)])
      [4, 5]
  """
  def skip(count) do
    %StatefulTransducer{
      initial_state: 0,
      function: fn rf ->
        fn
          _, {state, accumulator} when state < count ->
            {:cont, {state + 1, accumulator}}
          item, {state, accumulator} -> rf.(item, {state + 1, accumulator})
        end
      end
    }
  end

  @doc ~S"""
  Call the function with each value and the result of the previous call,
  beginning with the initial_value.

  ## Examples

      iex> import Transduce, only: [transduce: 2, scan: 2]
      iex> transduce(1..5, scan(0, &(&1 + &2)))
      [1, 3, 6, 10, 15]
  """
  def scan(initial_value, f) do
    %StatefulTransducer{
      initial_state: initial_value,
      function: fn rf ->
        fn item, {state, accumulator} ->
          new = f.(item, state)
          rf.(new, {new, accumulator})
        end
      end
    }
  end

  @doc ~S"""
  Step over N items in the enumerable, taking 1 between each set.  Called with
  two arguments, you specify how many to take (take_count, skip_count).

  ## Examples

      iex> import Transduce, only: [transduce: 2, step: 1, step: 2]
      iex> transduce(0..10, step(2))
      [0, 3, 6, 9]
      iex> transduce(0..15, step(2, 3))
      [0, 1, 5, 6, 10, 11, 15]
  """
  def step(skip_count), do: step(1, skip_count)
  def step(take_count, skip_count) do
    total = take_count + skip_count
    %StatefulTransducer{
      initial_state: 0,
      function: fn rf ->
        fn item, {state, accumulator} ->
          position = rem(state, total)
          if position < take_count do
            rf.(item, {position+1, accumulator})
          else
            {:cont, {position+1, accumulator}}
          end
        end
      end
    }
  end

  @doc ~S"""
  For each item in the enumerable, transform it and the previous result with the
  given reducer and then stash the resulting value in the accumulator, which
  must be a map.

  ## Examples

      iex> import Transduce, only: [transduce: 3, put: 3]
      iex> transduce([6,3,8,2,4,9,5,0,1,7], [put(:min, nil, &min/2), put(:max, 0, &max/2)], %{})
      %{max: 9, min: 0}

      iex> import Transduce, only: [transduce: 3, filter: 1, put: 3]
      iex> transduce(
      ...>   1..20, [
      ...>     put(:total, 0, &Kernel.+/2),
      ...>     put(:count, 0, fn _, ct -> ct + 1 end),
      ...>     filter(fn v -> rem(v, 2) == 0 end),
      ...>     put(:even, 0, &Kernel.+/2)
      ...>   ],
      ...>   %{})
      %{count: 20, even: 110, total: 210}
  """
  def put(key, initial_value, reducer) do
    fn rf ->
      fn item, acc ->
        rf.(item, Map.put(acc, key, reducer.(item, Map.get(acc, key, initial_value))))
      end
    end
  end

  @doc ~S"""
  For each item in the enumerable, transform it with the given transducer(s) and
  then stash the resulting value in the accumulator, which must be a map.

  ## Examples

      iex> import Transduce, only: [transduce: 3, filter: 1, tput: 2, scan: 2]
      iex> transduce(
      ...>   1..20, [
      ...>     tput(:total, scan(0, &Kernel.+/2)),
      ...>     tput(:even, [filter(fn v -> rem(v, 2) == 0 end), scan(0, &Kernel.+/2)]),
      ...>     tput(:odd, [filter(fn v -> rem(v, 2) == 1 end), scan(0, &Kernel.+/2)])
      ...>   ],
      ...>   %{})
      %{even: 110, odd: 100, total: 210}
  """
  def tput(key, transducers) when is_list(transducers) do
    tput(key, compose(transducers))
  end
  def tput(key, transducer) when is_function(transducer) do
    reducer = Transducer.reducer(
      transducer,
      fn item, accumulator -> {:cont, Map.put(accumulator, key, item)} end)
    %StatefulTransducer{
      initial_state: :cont,
      function: fn rf ->
        fn
          item, {:halt, accumulator} -> rf.(item, accumulator)
          item, {:cont, accumulator} -> rf.(item, reducer.(item, accumulator))
        end
      end
    }
  end
  def tput(key, transducer) do
    reducer = Transducer.reducer(
      transducer,
      fn item, {state, accumulator} -> {:cont, {state, Map.put(accumulator, key, item)}} end)
    %StatefulTransducer{
      initial_state: {:cont, Transducer.initial_state(transducer)},
      function: fn rf ->
        fn
          item, {{:halt, _}, _}=accumulator -> rf.(item, accumulator)
          item, {{:cont, state}, accumulator} ->
            {disposition, {new_state, new_accumulator}} = reducer.(item, {state, accumulator})
            rf.(item, {{disposition, new_state}, new_accumulator})
        end
      end
    }
  end
end
