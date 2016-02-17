defmodule TransducerTest do
  use ExUnit.Case
  doctest Transduce
  import Transduce

  test "stateless transduce works" do
    transducer = filter(&(rem(&1, 2) == 0))
    assert is_function(transducer)
    assert transduce(0..10, transducer) == [0, 2, 4, 6, 8, 10]
  end

  test "stateful transduce works" do
    transducer = take(5)
    assert not is_function(transducer)
    assert transduce(0..10, transducer) == [0, 1, 2, 3, 4]
  end

  test "composed transducer plus stateless optimize for stateless transducers" do
    my_take = take(5) # stateful
    original = compose([my_take, filter(&(&1 > 5))]) # filter is stateless
    composed = compose([original, map(&(&1 + 1))]) # map is stateless
    assert hd(composed.transducers) === my_take
    assert length(composed.transducers) == 2
    # Also doublecheck behavior
    assert transduce(3..10, composed) == [7, 8]
  end

  test "composed transducers with matched stateless optimize for stateless transducers" do
    my_take = take(100) # stateful
    my_step = step(1) # stateful
    first_composed = compose([my_take, filter(&(&1 > 5))]) # filter is stateless
    second_composed = compose([map(&(&1 + 1)), my_step]) # map is stateless
    composed = compose([first_composed, second_composed])
    [first | [second | [third]]] = composed.transducers
    assert first === my_take
    assert is_function(second)
    assert third === my_step
    # Also doublecheck behavior
    assert transduce(3..10, composed) == [7, 9, 11]
  end

  test "basic composition optimizes for stateless transducers" do
    my_take = take(10) # stateful
    composed = compose([filter(&(rem(&1, 2) == 0)), map(&(&1 + 1)), my_take, map(&(&1 * 2)), filter(&(&1 > 10))])
    [first | [second | [third]]] = composed.transducers
    assert is_function(first)
    assert second === my_take
    assert is_function(third)
    # Also doublecheck behavior
    assert transduce(0..100, composed) == [14, 18, 22, 26, 30, 34, 38]
  end
end
