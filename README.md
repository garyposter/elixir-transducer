# Transducer

## Why do you want this?

For Elixir, in my opinion, it's mostly a matter of taste.

Transducers are an idea from the Clojure community that reportedly unify different enumerable patterns there. My library works well enough, but seems to be a *largely* unnecessary abstraction in Elixir. As far as I can tell, it's because the Elixir Enumerable protocol is more flexible than the Clojure Enum protocol. In any case, I currently think that using the [Stream module](http://elixir-lang.org/docs/stable/elixir/Stream.html) gets close enough that the additional abstraction of a transducer will only occasionally give enough value for the cost.

Transducers let you combine reduction operations like `map`, `filter`, `take_while`, `take`, and so on into a single reducing function. As with Stream, but in contrast to Enum, all operations are performed for each item before the next item in the enumerable is processed.  You can compare the two approaches by imagining a spreadsheet table. Each element of your enumerable is at the start of a row, and each transforming function is a column in your spreadsheet. With the Enum module, we fill each column at a time.  With transducers (and the Stream module), we fill each row at a time.  The transducer/Stream approach isn't always necessary, but it can be very useful if you have an enumerable so big that you don't want to have to load it in memory all at once, or if you want to efficiently operate on an incongruent subset of your enumerable.

One difference with the Stream module is that the transducers' reducing functions don't have to produce an enumerable, while Stream module transformations always do. For instance, while you can certainly produce a list with transducers...

    iex> import Transduce, only: [transduce: 2, filter: 1, take: 1]
    iex> transduce(1..100, [filter(&(&1 > 5)), take(5)])
    [6, 7, 8, 9, 10]

...you can also produce another structure:

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

Streams can't do that kind of composition.  That said, maybe I'll see a counterexample someday, but for now the Stream/Enum version of that example isn't really that different, and is slightly faster (unless you compose the transducers beforehand, in which case it performs roughly the same).

    iex> [4, 8, 7, 3, 2, 9, 6, 12, 15] |>
    ...> Stream.filter(&(&1 > 5)) |>
    ...> Stream.take(5) |>
    ...> Enum.reduce(%{}, fn i, acc ->
    ...>   acc
    ...>   |> Map.update(:min, i, &min(&1, i))
    ...>   |> Map.update(:max, i, &max(&1, i))
    ...>   |> Map.update(:count, 1, &(&1+1))
    ...>   |> Map.update(:total, i, &(&1+i))
    ...> end)
    %{count: 5, max: 12, min: 6, total: 42}

Here's a couple more transducer tricks to contemplate.

    iex> import Transduce, only: [transduce: 3, filter: 1, put: 3]
    iex> transduce(
    ...>   [4, 8, 7, 3, 2, 9, 6, 12, 15], [
    ...>     put(:total, 0, &Kernel.+/2),
    ...>     filter(&(rem(&1, 2) == 0)),
    ...>     put(:even_total, 0, &Kernel.+/2)],
    ...>   %{})
    %{even_total: 32, total: 66}

    iex> import Transduce, only: [transduce: 3, filter: 1, put: 4]
    iex> transduce(
    ...>   [4, 8, 7, 3, 2, 9, 6, 12, 15], [
    ...>     put(:even, 0, filter(&(rem(&1, 2) == 0)), &Kernel.+/2),
    ...>     put(:odd, 0, filter(&(rem(&1, 2) == 1)), &Kernel.+/2)
    ...>   ],
    ...>   %{})
    %{even: 32, odd: 34}

That's the kind of thing that the Stream module can't easily emulate.

## What's the status of this library?

This is a casually-maintained alpha.  I'll probably push it to beta soon, which will mean a few more tests.  I'd kind of like to get full specs and try this with Dialyzer before I call it "1.0".

It has some basic docs, the doctests give a modicum of coverage, and it's reasonably efficient, though not quite as fast as a typical Stream/Enum usage in the common cases I've tested.

If you have any feedback for me on the code, I'd appreciate it.  I'm always eager to learn.  File an issue, or reach out to [gary@modernsongs.com](mailto:gary@modernsongs.com).

## How do you use transducers?

For now in this README, I'm just going to show how to use the basic `transduce` function with the default implementation of reducing to a list.

Using a single transducer is simple.

    iex> import Transduce, only: [transduce: 2, step: 1]
    iex> transduce(0..20, step(4))
    [0, 5, 10, 15, 20]

You can compose them with the `compose` function...

    iex> import Transduce, only: [transduce: 2, filter: 1, take: 1, compose: 1]
    iex> transduce(1..100, compose([filter(&(&1 > 5)), take(5)]))
    [6, 7, 8, 9, 10]

...or you can just pass a list, as a bit of sugar.

    iex> import Transduce, only: [transduce: 2, filter: 1, take: 1]
    iex> transduce(1..100, [filter(&(&1 > 5)), take(5)])
    [6, 7, 8, 9, 10]

I'm using ranges for all of my examples, but as I showed in the first section of this README, they work with any enumerable (anything that implements the Enumerable protocol).

## How do they work?

Rich Hickey, the creator of the Clojure language, introduced the idea of transducers.  I didn't understand [his blog post](http://blog.cognitect.com/blog/2014/8/6/transducers-are-coming) very well.  [This description, using Javascript, really breaks it down](http://phuu.net/2014/08/31/csp-and-transducers.html), and I recommend reading it if you want to work through it.

That said, I'll try a fast explanation.  Imagine a function that `reduce` could use to multiply every input by 2.  That would normally be just `def reducer(item, accumulator), do: [2 * item | accumulator]`, used with `Enum.reduce(1..4, [], reducer)` (yes, you'd have to reverse that result, but let's ignore that for simplicity).  The `reducer` function multiplied by two, and then pushed the result to the list.  What if you split up those two actions?

With a transducer, you just pass the result of the transformation to the next reducer in a chain.  So, a transducer-based approach would produce that same effect with one inner reducer for pushing to the list, e.g. `def reducing_function(item, accumulator), do: [item | accumulator]`, and a mapping transducer that used it, to effectively produce: `fn item, accumulator -> reducing_function(2 * item, accumulator)`.  That has the same effect as the first function in this paragraph, but it uses a composable pattern.  The outer function called into the inner one, and they both had the same signature.  Another function with the same signature could wrap the outer function and call it, too.  It's composable.

If that didn't make sense, I'm not surprised: it was hubris to try to explain. :-P  Go look at that article I recommended above.  The author does a great job.

## How can you write your own transducers?

You can write two kinds of transducers: stateless and stateful.  A stateless transducer is the most straightforward, since it is just a function.  Consider the `map` transducer.

  ```
  def map(f) do
    fn rf ->
      fn item, accumulator -> rf.(f.(item), accumulator) end
    end
  end
  ```

At its simplest, a transducer takes a reducing function (`rf` above), and then returns another reducing function that wraps the `rf` with its own behavior.  For `map`, it passes the mapped value `f.(item)` to the `rf` for the next step.

This assumes that the `rf` eventually returns a value--e.g., as described in the section above, the reducing function might be `fn item, accumulator -> {:cont, [item | accumulator]} end`.  As shown in that example, the return value is annotated with markers defined by the Enumerable protocol. `{:cont, VALUE}` specifies that the reduction process should continue with the next item in the enumerable input, but VALUE is the new accumulator. `{:halt, VALUE}` specifies that the reduction process should immediately stop and return VALUE as the result.

For an example of using the `:cont` marker, consider the `filter` implementation.

  ```
  def filter(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:cont, accumulator} end
      end
    end
  end
  ```

In that case, if the filter passes the new item from the enumerable, it is passed through to the inner reducing function.  If it doesn't pass, the code returns `:cont` with an unchanged accumulator, indicating that we should move on to the next item in the source enumerable without a new accumulator.

For an example of `:halt`, see the `take_while` implementation.

  ```
  def take_while(f) do
    fn rf ->
      fn item, accumulator ->
        if f.(item) do rf.(item, accumulator) else {:halt, accumulator} end
      end
    end
  end
  ```

Because of the `:halt` flag, the reduction stops and returns the accumulator when the given function no longer returns a true value.

That's pretty much it for stateless transducers.  A stateful transducer looks similar, but, unsurprisingly, has to handle state. Consider the `take` implementation.

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

A `take` transducer is a `StatefulTransducer` struct, which specifies an `initial_state` and a `function`.  The function again takes a reducing function (`rf`) but the wrapping function this time expects that the additional value has the shape `{state, accumulator}`.  The state is private to this function, and will not be in the final accumulator result, but must also be included in the function output, whether it's passed to the wrapped reducing function or returned to the caller with `:halt` or `:cont`.

Composing stateful transducers follows a different pattern internally than stateless transducers, but otherwise, stateful transducers work the same as stateless transducers.

## Thanks

I looked at the [Theriac transducer library](https://github.com/timdeputter/theriac) before writing mine.  I ended up making a lot of different choices, but I definitely learned from that one, and I owe the author a debt of gratitude.

## Installation

  1. Add transducer to your list of dependencies in `mix.exs`:

        def deps do
          [{:transducer, "~> 0.1.0"}]
        end

  2. Ensure transducer is started before your application:

        def application do
          [applications: [:transducer]]
        end
