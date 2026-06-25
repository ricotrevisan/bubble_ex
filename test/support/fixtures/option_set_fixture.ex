defmodule BubbleEx.OptionSetFixtures do
  @moduledoc false

  def option_set_fixture do
    %{
      "alt_table" => %{
        "%d" => "description",
        "attributes" => %{
          "alt_linked" => %{
            "%d" => "attr_description",
            "%v" => "text"
          },
          "alt_linked_list" => %{
            "%d" => "attr_description",
            "%v" => "text"
          }
        }
      },
      "main" => %{
        "%d" => "description",
        "attributes" => %{
          "text_attr" => %{
            "%d" => "attr_description",
            "%v" => "text"
          },
          "boolean_attr" => %{
            "%d" => "attr_description",
            "%v" => "boolean"
          },
          "text_list_attr" => %{
            "%d" => "attr_description",
            "%v" => "list.text"
          },
          "number_attr" => %{
            "%d" => "attr_description",
            "%v" => "number"
          },
          "image_attr" => %{
            "%d" => "attr_description",
            "%v" => "image"
          },
          "file_attr" => %{
            "%d" => "attr_description",
            "%v" => "file"
          },
          "list_file_attr" => %{
            "%d" => "attr_description",
            "%v" => "list.file"
          },
          "list_option_set_attr" => %{
            "%d" => "attr_description",
            "%v" => "list.option.alt_table"
          },
          "option_set_attr" => %{
            "%d" => "attr_description",
            "%v" => "option.alt_table"
          },
          "list_number_attr" => %{
            "%d" => "attr_description",
            "%v" => "list.number"
          }
        }
      }
    }
  end
end
