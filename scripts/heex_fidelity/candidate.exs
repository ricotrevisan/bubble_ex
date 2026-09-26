# Runs inside the scratch Phoenix project (scripts/heex_fidelity.sh): turns
# one frozen fidelity case's page, rendered by the generated LiveView, into
# a static candidate for test/support/fidelity/run.mjs.
#
#     MIX_ENV=test mix run candidate.exs <bubble_ex root> <case> <out dir>
#
# The page is the LiveView's static render (GET through the endpoint and
# the router, the root layout included); its stylesheet is the project's
# own assets/css/app.css built by the pinned Tailwind CLI (without the
# colocated-hooks import, which has no CSS here). As for the HTML exporter
# (BubbleEx.Frontend.Fidelity), the harness adds the case's pinned Inter
# font face and browser defaults, and serves images from local files.
# Scripts are dropped: the candidate is the initial, static page.

[root, case_id, out] = System.argv()

case_dir = Path.join([root, "test/support/fidelity/cases", case_id])
case_json = case_dir |> Path.join("case.json") |> File.read!() |> Jason.decode!()
surfaces = ".wtf/surfaces.json" |> File.read!() |> Jason.decode!()
page_id = get_in(case_json, ["source", "page_id"])

path =
  case get_in(surfaces, ["pages", page_id, "path"]) do
    path when is_binary(path) -> path
    nil -> raise "case #{case_id}: page #{page_id} was not rendered"
  end

File.rm_rf!(out)
File.mkdir_p!(Path.join(out, "assets"))

conn =
  Phoenix.ConnTest.build_conn()
  |> Phoenix.ConnTest.dispatch(PhxCheckWeb.Endpoint, :get, path, nil)

200 = conn.status

html =
  conn.resp_body
  |> String.replace(~r{<script\b[^>]*>.*?</script>}s, "")
  |> String.replace(~r{href="/assets/css/app\.css[^"]*"}, ~s(href="app.css"))
  |> String.replace(~s(src="/images/bubble/), ~s(src="images/bubble/))
  |> String.replace(~s(srcset="/images/bubble/), ~s(srcset="images/bubble/))

File.write!(Path.join(out, "page.html"), html)

if File.dir?("priv/static/images/bubble") do
  File.mkdir_p!(Path.join(out, "images"))
  File.cp_r!("priv/static/images/bubble", Path.join(out, "images/bubble"))
end

# The project's stylesheet, as `mix tailwind` builds it.
input = "assets/css/heex_fidelity.css"

"assets/css/app.css"
|> File.read!()
|> String.replace(~r/^@import "phoenix-colocated.*\n/m, "")
|> String.replace(~r/^@source "..\/..\/_build.*\n/m, "")
|> then(&File.write!(input, &1))

unless File.exists?(Tailwind.bin_path()), do: Tailwind.install()

{output, 0} =
  System.cmd(Tailwind.bin_path(), ["--input=#{input}", "--output=#{Path.join(out, "built.css")}"],
    stderr_to_stdout: true
  )

_ = output
File.rm!(input)

font = get_in(case_json, ["font", "path"])
File.cp!(Path.join(case_dir, font), Path.join(out, "assets/inter-latin.woff2"))

harness = """
@font-face {
  font-family: "Inter";
  font-style: normal;
  font-weight: 400 800;
  font-display: block;
  src: url("assets/inter-latin.woff2") format("woff2");
}

:root {
  color-scheme: light;
  font-family: Helvetica, Arial, sans-serif;
}

html { scroll-behavior: smooth; }
body { min-width: 320px; }
button, a { cursor: pointer; }

"""

File.write!(Path.join(out, "app.css"), harness <> File.read!(Path.join(out, "built.css")))
IO.puts("candidate #{case_id}: #{path}")
