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
  Transduce a given enumerable.  By default, generate a list.

  ## Examples

      iex> Transducer.transduce([2,3,5,7,11], Transducer.take(2))
      [2, 3]
  """

  # @spec transduce(t, stateful_transducer)

  def transduce(enumerable, transducers) when is_list(transducers) do
    transduce(enumerable, compose(transducers))
  end
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

  def compose([first | rest] = _transducers) do
    _compose(first, rest)
  end

  def _compose(current, [next | rest]) do
    _compose(Transducer.compose(current, next), rest)
  end
  def _compose(current, []), do: current

  def map(f) do
    fn rf ->
      fn item, accumulator -> rf.(f.(item), accumulator) end
    end
  end

  def filter(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:cont, accumulator} end
      end
    end
  end

  def remove(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do {:cont, accumulator} else rf.(item, accumulator) end
      end
    end
  end

  def take_while(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:halt, accumulator} end
      end
    end
  end

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
