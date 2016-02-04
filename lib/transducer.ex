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
  def compose(transducer, %ComposedTransducer{}=other) do
    %ComposedTransducer{transducers: transducer.transducers ++ other.transducers}
  end
  def compose(transducer, other) do
    %ComposedTransducer{transducers: transducer.transducers ++ [other]}
  end
end

defmodule Transduce do

  @moduledoc """
  Composable algorithmic transformations.

  Rich Hickey introduced the idea in [this
  post](http://blog.cognitect.com/blog/2014/8/6/transducers-are-coming).
  [This post](http://phuu.net/2014/08/31/csp-and-transducers.html) is a good
  conceptual introduction.
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
  def transduce(enumerable, transducer, accumulator, stateless_reducer, finalizer \\ &(&1))
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
        fn item, {state, accumulator} ->
          if state < count do
            rf.(item, {state+1, accumulator})
          else
            {:halt, {state, accumulator}}
          end
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
      iex> transduce(0..10, [skip(4), take(2)])
      [4, 5]
  """
  def skip(count) do
    %StatefulTransducer{
      initial_state: 0,
      function: fn rf ->
        fn item, {state, accumulator} = acc ->
          if state < count do
            {:cont, {state+1, accumulator}}
          else
            rf.(item, acc)
          end
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
end
