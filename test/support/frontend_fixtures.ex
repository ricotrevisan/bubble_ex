defmodule BubbleEx.FrontendFixtures do
  @moduledoc false

  def clean_scanner do
    BubbleEx.FrontendFixtures.CleanScan
  end

  def leaky_scanner do
    BubbleEx.FrontendFixtures.LeakyScan
  end

  def modern_page do
    %{
      "_id" => "s1app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "pghome",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column", "title" => "Home"},
          "elements" => %{}
        }
      }
    }
  end

  def two_page_app do
    %{
      "_id" => "s1app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "pghome",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column", "title" => "Home"},
          "elements" => %{
            "toAbout" => %{
              "id" => "elToAbout",
              "type" => "Link",
              "properties" => %{
                "text" => "About",
                "destination" => "about",
                "order" => 1
              }
            }
          }
        },
        "about" => %{
          "id" => "pgabout",
          "type" => "Page",
          "name" => "about",
          "properties" => %{"container_layout" => "column", "title" => "About"},
          "elements" => %{
            "heading" => %{
              "id" => "elAbout",
              "type" => "Text",
              "properties" => %{"tag_type" => "h2", "text" => "About us", "order" => 1}
            }
          }
        }
      },
      "element_definitions" => %{
        "cmpNav" => %{
          "id" => "cmpNavInner",
          "name" => "Left Nav",
          "type" => "CustomDefinition",
          "properties" => %{"container_layout" => "column"},
          "elements" => %{
            "label" => %{
              "id" => "elNav",
              "type" => "Text",
              "properties" => %{"text" => "Nav", "tag_type" => "normal"}
            }
          }
        }
      },
      "styles" => %{
        "Text__headline_" => %{
          "id" => "Text__headline_",
          "display" => ".headline",
          "type" => "Text",
          "properties" => %{"font_size" => 32}
        }
      }
    }
  end

  def s1_elements_app do
    %{
      "_id" => "s1app",
      "app_version" => "live",
      "pages" => %{
        "home" => %{
          "id" => "pghome",
          "type" => "Page",
          "name" => "index",
          "properties" => %{"container_layout" => "column", "title" => "Home"},
          "elements" => %{
            "heading" => %{
              "id" => "elH1",
              "type" => "Text",
              "style" => "Text__headline_",
              "properties" => %{"tag_type" => "h1", "text" => "Hello", "order" => 1}
            },
            "cta" => %{
              "id" => "elBtn",
              "type" => "Button",
              "properties" => %{"text" => "Go", "order" => 2}
            },
            "email" => %{
              "id" => "elInput",
              "type" => "Input",
              "properties" => %{
                "format" => "email",
                "placeholder" => "you@example.com",
                "order" => 3
              }
            },
            "dot" => %{
              "id" => "elShape",
              "type" => "Shape",
              "properties" => %{"bgcolor" => "#ccc", "width" => 40, "height" => 40, "order" => 4}
            },
            "docs" => %{
              "id" => "elLink",
              "type" => "Link",
              "properties" => %{
                "text" => "Docs",
                "destination" => "https://example.com",
                "order" => 5
              }
            },
            "plug" => %{
              "id" => "elPlug",
              "type" => "RepeatingGroup",
              "properties" => %{"width" => 200, "height" => 80, "order" => 6}
            }
          }
        }
      },
      "styles" => %{
        "Text__headline_" => %{
          "id" => "Text__headline_",
          "display" => ".headline",
          "type" => "Text",
          "properties" => %{"font_size" => 32}
        }
      }
    }
  end
end

defmodule BubbleEx.FrontendFixtures.CleanScan do
  @moduledoc false
  @behaviour BubbleEx.Secrets

  @impl true
  def scan(_payload, _opts), do: {:ok, []}
end

defmodule BubbleEx.FrontendFixtures.LeakyScan do
  @moduledoc false
  @behaviour BubbleEx.Secrets

  @impl true
  def scan(_payload, _opts) do
    {:ok,
     [
       %{
         detector: "aws_secret",
         raw: "AKIAEXAMPLE",
         redacted: "AKIA…MPLE",
         path: ["settings"],
         verified: true,
         confidence: :high
       }
     ]}
  end
end
