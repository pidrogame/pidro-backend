defmodule PidroServerWeb.Schemas.ClassicClaimSchemas do
  @moduledoc false

  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule SignInCodeRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic sign-in code request",
      required: [:login],
      properties: %{
        login: %Schema{type: :string, minLength: 1, description: "Classic username or email"},
        install_id: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          description: "Required without a Bearer token; use the same install when verifying"
        }
      }
    })
  end

  defmodule SignInCodeVerifyRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic sign-in code verification request",
      required: [:login, :code],
      properties:
        Map.put(SignInCodeRequest.schema().properties, :code, %Schema{
          type: :string,
          pattern: "^[0-9]{6}$"
        })
    })
  end

  defmodule SignInCodeResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic sign-in code response",
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:email_hint],
          properties: %{email_hint: %Schema{type: :string, example: "be•••••@example.com"}}
        }
      }
    })
  end

  defmodule ClassicPreview do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic account preview",
      required: [:name, :games_played, :level, :member_since, :name_allowed],
      properties: %{
        name: %Schema{type: :string, nullable: true},
        games_played: %Schema{type: :integer, minimum: 0},
        level: %Schema{type: :integer, minimum: 0},
        member_since: %Schema{
          type: :string,
          nullable: true,
          description: "Null for Classic accounts created before Classic recorded a date"
        },
        name_allowed: %Schema{
          type: :boolean,
          description:
            "Whether the Classic name may be public; false requires account.display_name on the initial claim"
        },
        new_account: %Schema{
          type: :object,
          nullable: true,
          description:
            "On a password verification by a signed-out player or a guest, and an Apple or Facebook verification or sign-in by a signed-out player: the username, and for a password claim the email, the new account takes from Classic. The player cannot change them; each is null when the player must choose it. Email is always null for Apple and Facebook, which need none.",
          required: [:username, :email],
          properties: %{
            username: %Schema{type: :string, nullable: true},
            email: %Schema{type: :string, nullable: true}
          }
        }
      }
    })
  end

  defmodule HelpRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic account help request",
      required: [:name, :email],
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 60},
        email: %Schema{type: :string, format: :email, maxLength: 160},
        details: %Schema{type: :string, maxLength: 600}
      }
    })
  end

  defmodule VerifyRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic ownership verification request",
      properties: %{
        method: %Schema{type: :string, enum: ["password", "apple", "facebook"]},
        login: %Schema{type: :string, description: "Classic username or email"},
        password: %Schema{type: :string},
        identity_token: %Schema{type: :string},
        access_token: %Schema{
          type: :string,
          description: "Facebook Graph credential; mutually exclusive with Limited Login fields"
        },
        authentication_token: %Schema{
          type: :string,
          description: "Facebook Limited Login OIDC JWT; requires nonce"
        },
        nonce: %Schema{
          type: :string,
          description: "Raw nonce supplied to the Facebook Limited Login SDK"
        },
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Required when the request has no Bearer token"
        }
      },
      required: [:method]
    })
  end

  defmodule AlreadyClaimed do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic account already linked",
      description:
        "Present when another player owns the Classic account; names how that player signs in.",
      nullable: true,
      required: [:sign_in_method],
      properties: %{
        sign_in_method: %Schema{
          type: :string,
          enum: ["password", "apple", "facebook"],
          nullable: true
        }
      }
    })
  end

  defmodule VerifyResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic ownership verification response",
      properties: %{
        data: %Schema{
          type: :object,
          required: [:ticket, :expires_at, :classic, :already_claimed],
          properties: %{
            ticket: %Schema{type: :string},
            expires_at: %Schema{type: :string, format: :"date-time"},
            classic: ClassicPreview,
            already_claimed: AlreadyClaimed
          }
        }
      },
      required: [:data]
    })
  end

  defmodule ClassicFoundResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic account found response",
      properties: %{
        data: %Schema{
          type: :object,
          required: [:classic_found, :ticket, :expires_at, :classic, :already_claimed],
          properties: %{
            classic_found: %Schema{type: :boolean, enum: [true]},
            ticket: %Schema{type: :string},
            expires_at: %Schema{type: :string, format: :"date-time"},
            classic: ClassicPreview,
            already_claimed: AlreadyClaimed
          }
        }
      },
      required: [:data]
    })
  end

  defmodule ProviderSignInResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Provider sign-in response",
      oneOf: [
        PidroServerWeb.Schemas.UserSchemas.UserWithTokenResponse,
        ClassicFoundResponse
      ]
    })
  end

  defmodule ClaimRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic claim request",
      properties: %{
        friend_slug: PidroServerWeb.Schemas.UserSchemas.FriendSlug,
        age_band: PidroServerWeb.Schemas.UserSchemas.SubmittedAgeBand,
        terms_version: PidroServerWeb.Schemas.UserSchemas.TermsVersion,
        ticket: %Schema{
          type: :string,
          description: "Opaque ticket returned by Classic verification"
        },
        install_id: %Schema{type: :string, maxLength: 64},
        account: %Schema{
          type: :object,
          description:
            "Required on a fresh install. Password claims need a password, plus username and email where the verify preview's new_account has none; a username or email it offers is taken from Classic and the request's value ignored. Social claims need username where new_account has none, and take an offered one the same way. Authenticated initial claims also use account.display_name when the Classic name is not allowed.",
          properties: %{
            username: %Schema{type: :string, minLength: 3, maxLength: 20},
            email: %Schema{type: :string, format: :email},
            password: %Schema{type: :string, minLength: 8},
            display_name: %Schema{
              type: :string,
              minLength: 2,
              maxLength: 20,
              description:
                "Required on the initial claim when the Classic name is not allowed; optional override otherwise"
            }
          }
        }
      },
      required: [:ticket]
    })
  end

  defmodule AppleRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Apple sign-in request",
      properties: %{
        friend_slug: PidroServerWeb.Schemas.UserSchemas.FriendSlug,
        age_band: PidroServerWeb.Schemas.UserSchemas.SubmittedAgeBand,
        terms_version: PidroServerWeb.Schemas.UserSchemas.TermsVersion,
        identity_token: %Schema{type: :string},
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Required only when a matching Classic account is found"
        }
      },
      required: [:identity_token]
    })
  end

  defmodule FacebookGraphRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Facebook Graph sign-in request",
      additionalProperties: false,
      properties: %{
        friend_slug: PidroServerWeb.Schemas.UserSchemas.FriendSlug,
        age_band: PidroServerWeb.Schemas.UserSchemas.SubmittedAgeBand,
        terms_version: PidroServerWeb.Schemas.UserSchemas.TermsVersion,
        access_token: %Schema{type: :string},
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Required only when a matching Classic account is found"
        }
      },
      required: [:access_token]
    })
  end

  defmodule FacebookLimitedRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Facebook Limited Login sign-in request",
      additionalProperties: false,
      properties: %{
        friend_slug: PidroServerWeb.Schemas.UserSchemas.FriendSlug,
        age_band: PidroServerWeb.Schemas.UserSchemas.SubmittedAgeBand,
        terms_version: PidroServerWeb.Schemas.UserSchemas.TermsVersion,
        authentication_token: %Schema{type: :string},
        nonce: %Schema{type: :string},
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Required only when a matching Classic account is found"
        }
      },
      required: [:authentication_token, :nonce]
    })
  end

  defmodule FacebookRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "Facebook sign-in request",
      oneOf: [FacebookGraphRequest, FacebookLimitedRequest]
    })
  end
end
