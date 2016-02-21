defmodule Transducer.Mixfile do
  use Mix.Project

  def project do
    [app: :transducer,
     version: "0.1.0",
     description: description,
     package: package,
     elixir: "~> 1.2",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  defp description do
    """
    Composable algorithmic transformations. Transducers let you combine
    reduction operations like `map`, `filter`, `take_while`, `take`, and so on
    into a single reducing function. As with Stream, but in contrast to Enum,
    all operations are performed for each item before the next item in the
    enumerable is processed. One difference with the Stream module is that the
    transducers' reducing functions don't have to produce an enumerable, while
    Stream module transformations always do.
    """
  end

  defp package do
    [
      maintainers: ["Gary Poster <gary@modernsongs.com>"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => "https://github.com/garyposter/elixir-transducer",
        "Docs" => "http://hexdocs.pm/transducer"
      }
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  def deps do
    [{:earmark, "~> 0.1", only: :dev},
     {:ex_doc, "~> 0.11", only: :dev}]
  end
end
