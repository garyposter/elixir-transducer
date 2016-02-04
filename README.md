# Transducer

## Why do you want this?

Transducers let you combine common enumerable operations like `map`, `filter`, `take_while`, `take`, and so on into a single reducing function. Pipelines of functions that would otherwise send the entire collection through each step (e.g. `enum |> filter(&(&1 > 5)) |> take(5)`) can instead send each element of the collection through all of the functions at once.

Visually, you can compare the two approaches by imagining a spreadsheet table. Each element of your enumerable is at the start of a row, and each transforming function is a column in your spreadsheet. Without transducers, we typically fill each column at a time.  With transducers, we fill each row at a time.  The transducer approach isn't always necessary, but it can be very useful.

Use cases for transducers include the following.

- You have a **big enumerable**, and repeatedly iterating through it is expensive, annoying, or impossible.
- You want to **efficiently operate on only a subset of your enumerable**.  Transducers are especially effective if the composition of the subset is complex (e.g. the example in the first paragraph: you want the first five items that are greater than 5).
- You want to build or use **a composable library of functions** that operate on an enumerable.  For instance, beyond standard enumerable functions, maybe you want to build a library of functions that can collect various statistics on an enumerable.  Written as transducers, they can collect multiple statistics in a single pass.
- Your conception of a problem matches the transducer model.

## What's the status of this library?

This is an alpha.  I am looking for feedback.

I currently have the following goals for the library, in rough prioritization.

- Make it easy to use.
- Make it easy to understand, especially if you've grokked the basic transducer pattern (see the "How do they work" section, below).  In particular, I want transducer functions to look like how they are explained.
- Make it efficient.
- Make it tested and documented.

**Make it easy to use.** I think it's pretty easy to use. I keep contemplating adding some macro sugar for composing transducers: a pipe-like spelling seems particularly nice to me at the moment. Using it more "in anger" will probably inform this and other similar decisions.

**Make it easy to understand.** I'm happy that stateless transducers are simple and compose simply, and that stateful transducers are simple and compose somewhat simply.

**Make it efficient.** It seems pretty efficient already.  I could be a lot more careful about this, but based on a few "best of N runs" test comparing the transducer performance with the enum performance, it seems good.  When the enum is large and transduce can be lazy, transduce kills it, unsurprisingly.  On my machine, here are the results of some casual best-of-20-runs...

- Enum examples
  - `:timer.tc(fn -> 1..20 |> Enum.filter(&(&1 > 5)) |> Enum.take(5) end)`: **62 μs**
  - `:timer.tc(fn -> 1..1000000 |> Enum.filter(&(&1 > 5)) |> Enum.take(5) end)`: **1418820 μs**
- Transduce examples
  - `:timer.tc(fn -> transduce(1..20, [filter(&(&1 > 5)), take(5)]) end)`:
**55 μs**
  - `:timer.tc(fn -> Transduce.transduce(1..1000000, [Transduce.filter(&(&1 > 5)), Transduce.take(5)]) end)`: **66 μs**
  - `:timer.tc(Transduce, :transduce, [1..1000000, [Transduce.filter(&(&1 > 5)), Transduce.take(5)]])`: **33 μs**

Looking at average speed over N runs currently paints a slightly worse picture for Transduce than "best of N", but it still seems reasonably similar for small sets, and wildly better for large sets that

**Make it tested and documented.** I have a decent start on the docs.  My tests are only doctests so far, and I mostly don't have Dialyzer specs.

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

I'm using ranges for all of my examples, but they work with any enumerable (anything that implements the Enumerable protocol).

## How do they work?

Rich Hickey, the creator of the Clojure language, introduced the idea of transducers.  I didn't understand [his blog post](http://blog.cognitect.com/blog/2014/8/6/transducers-are-coming) very well.  [This description, using Javascript, really breaks it down](http://phuu.net/2014/08/31/csp-and-transducers.html), and I recommend reading it if you want to work through it.

That said, I'll try a fast explanation.  Imagine a function that `reduce` could use to multiply every input by 2.  That would normally be just `def reducer(item, accumulator), do: [2 * item | accumulator]`, used with `Enum.reduce(1..4, [], reducer)` (yes, you'd have to reverse that result, but let's ignore that for simplicity).  The `reducer` function multiplied by two, and then pushed the result to the list.  What if you split up those two actions?

With a transducer, you just pass the result of the transformation to the next reducer in a chain.  So, a transducer-based approach would produce that same effect with one inner reducer for pushing to the list, e.g. `def reducing_function(item, accumulator), do: [item | accumulator]`, and a mapping transducer that used it, to effectively produce: `fn item, accumulator -> reducing_function(2 * item, accumulator)`.  That has the same effect as the first function in this paragraph, but it uses a composable pattern.  The outer function called into the inner one, and they both had the same signature.  Another function with the same signature could wrap the outer function and call it, too.  It's composable.

If that didn't make sense, I'm not surprised: it was hubris to try to explain. :-P  Go look at that article I recommended above.  The author does a great job.

## How can you write my own transducers?

For now, I recommend reading the Javascript article I listed above, and then looking at the existing implementations.  You either choose to write a stateless transducer, or a stateful transducer.  The transducers should return functions that use `:cont` or `:halt` when they want to skip or complete early, respectively, following the Enumerable reducer spec.

I'll hope to write more later.

## Thanks

I looked at the [Theriac transducer library](https://github.com/timdeputter/theriac) before writing mine.  I ended up making a lot of different choices, but I definitely learned from that one, and I owe the author a debt of gratitude.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add transducer to your list of dependencies in `mix.exs`:

        def deps do
          [{:transducer, "~> 0.0.1"}]
        end

  2. Ensure transducer is started before your application:

        def application do
          [applications: [:transducer]]
        end
