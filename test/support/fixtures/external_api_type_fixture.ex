defmodule BubbleEx.Test.ExternalApiTypeFixture do
  @moduledoc false

  @address "api.apiconnector2.atlas.address.Address"
  @event "api.apiconnector2.atlas.events.Event"
  @geo "api.apiconnector2.compass.geo.Geo"

  def app do
    %{
      "_id" => "synthetic-external-api-types",
      "user_types" => %{
        "parcel" => %{
          "%d" => "Parcel",
          "%f3" => %{
            "destination" => %{"%d" => "Destination", "%v" => @address},
            "history" => %{"%d" => "History", "%v" => "list." <> @event},
            "unresolved" => %{
              "%d" => "Unresolved",
              "%v" => "api.apiconnector2.atlas.address.Unknown"
            },
            "malformed" => %{"%d" => "Malformed", "%v" => "api."},
            "deleted" => %{"%d" => "Deleted", "%v" => @event, "%del" => true}
          }
        }
      },
      "settings" => %{
        "client_safe" => %{
          "apiconnector2" => %{
            "atlas" => %{
              "address" =>
                call(@address, %{
                  @address =>
                    definition("Address", %{
                      "street" => field("Street", ["street"], "text"),
                      "tags" => field("Tags", ["tags"], "list.text"),
                      "geo" => field(nil, ["geo"], @geo),
                      "events" => field("Events", ["events"], "list." <> @event),
                      "_ignore" => field("Ignored", ["ignored"], "text")
                    })
                }),
              "events" =>
                call(@event, %{
                  @event =>
                    definition("Event", %{
                      "at" => field("At", ["at"], "date_unix"),
                      "children" => field("Children", ["children"], "list." <> @event)
                    })
                })
            },
            "compass" => %{
              "geo" =>
                call(@geo, %{
                  @geo =>
                    definition("Geo", %{
                      "latitude" => field("Latitude", ["latitude"], "number"),
                      "captured" => field("Captured", ["captured"], "date")
                    })
                })
            }
          }
        }
      }
    }
  end

  defp call(ret_value, types), do: %{"ret_value" => ret_value, "types" => Jason.encode!(types)}
  defp definition(caption, fields), do: %{"caption" => caption, "fields" => fields}

  defp field(caption, path, descriptor),
    do: %{"caption" => caption, "path" => path, "ret_btype" => descriptor}
end
