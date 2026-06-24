import argv
import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

pub fn main() -> Result(a, String) {
  case argv.load().arguments {
    [] | [_] | [_, _, _, ..] ->
      Error(
        "ERROR: Two arguments are required: the path to the Gleam manifest, and the output directory.",
      )
    [manifest, output] -> {
      let text =
        manifest
        |> simplifile.read()
        |> result.map_error(simplifile.describe_error)

      use text <- result.try(text)

      use dyn <- result.try({
        use err <- result.map_error(tom.parse_to_dynamic(text))
        "Failed to parse TOML file\n" <> string.inspect(err)
      })

      use packages <- result.try(result.map_error(
        decode.run(dyn, packages_decoder()),
        string.inspect,
      ))

      use package <- list.map(packages)

      use url <- option.map(to_url(package))
      use request <- result.map(result.map_error(
        request.to(url),
        string.inspect,
      ))
      let request = request.set_header(request, "User-Agent", "nixpkgs")

      use response <- promise.try_await({
        request
        |> fetch.send
        |> fn(p) {
          use prom <- promise.map(p)
          result.map_error(prom, string.inspect)
        }
      })

      use body <- promise.map_try({
        response
        |> fetch.read_bytes_body
        |> fn(p) {
          use prom <- promise.map(p)
          result.map_error(prom, string.inspect)
        }
      })

      simplifile.write_bits(output <> todo, body.body)
      |> result.map_error(simplifile.describe_error)
    }
  }
}

type Package {
  Package(
    name: String,
    version: String,
    build_tools: List(String),
    source: String,
    checksum: String,
  )
}

fn packages_decoder() -> decode.Decoder(List(Package)) {
  use packages <- decode.field(
    "packages",
    decode.list({
      use name <- decode.field("name", decode.string)
      use version <- decode.field("version", decode.string)
      use build_tools <- decode.field("build_tools", decode.list(decode.string))
      use source <- decode.field("source", decode.string)
      use checksum <- decode.field("outer_checksum", decode.string)

      decode.success(Package(name:, version:, build_tools:, source:, checksum:))
    }),
  )

  decode.success(packages)
}

fn to_url(p: Package) -> option.Option(String) {
  let Package(name:, version:, build_tools: _, source:, checksum: _) = p

  case source {
    // From fetchHex:
    // https://repo.hex.pm/tarballs/${pkg}-${version}.tar"
    "hex" ->
      Some({
        "https://repo.hex.pm/tarballs/" <> name
        "-" <> version <> ".tar"
      })
    "git" -> None
    "local" -> None
    other -> panic as { "Unknown package source: " <> other }
  }
}
