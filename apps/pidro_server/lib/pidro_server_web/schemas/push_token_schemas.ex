defmodule PidroServerWeb.Schemas.PushTokenSchemas do
  @moduledoc "Wire contract for registering a phone for push (PID-392)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule Request do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "PushTokenRequest",
      type: :object,
      required: [:token, :platform],
      properties: %{
        token: %Schema{
          type: :string,
          description: "ExponentPushToken[...] or ExpoPushToken[...]",
          example: "ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]"
        },
        platform: %Schema{type: :string, enum: ["ios", "android"]},
        install_id: %Schema{type: :string, maxLength: 64, nullable: true},
        app_version: %Schema{type: :string, maxLength: 32, nullable: true, example: "3.3.0"},
        app_build: %Schema{
          type: :string,
          pattern: "^[0-9]{1,10}$",
          nullable: true,
          description: "iOS build number or Android version code",
          example: "15"
        }
      }
    })
  end

  defmodule Response do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "PushTokenResponse",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:token, :platform, :install_id, :app_version],
          properties: %{
            token: %Schema{type: :string},
            platform: %Schema{type: :string, enum: ["ios", "android"]},
            install_id: %Schema{type: :string, nullable: true},
            app_version: %Schema{type: :string, nullable: true},
            app_build: %Schema{type: :string, nullable: true}
          }
        }
      }
    })
  end
end
