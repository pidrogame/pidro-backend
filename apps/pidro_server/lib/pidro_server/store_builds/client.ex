defmodule PidroServer.StoreBuilds.Client do
  @moduledoc "Reads TestFlight Friends and Play open testing; never publishes a release."

  @asc "https://api.appstoreconnect.apple.com"
  @play "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.oneapps.pidro.beta"
  @token "https://oauth2.googleapis.com/token"

  def connected?(platform, config \\ Application.get_env(:pidro_server, __MODULE__, [])) do
    keys =
      case platform do
        "ios" -> [:asc_key_id, :asc_issuer_id, :asc_private_key]
        "android" -> [:play_service_account_json]
      end

    Enum.all?(keys, &(config[&1] not in [nil, ""]))
  end

  def fetch(platform, config \\ Application.get_env(:pidro_server, __MODULE__, [])) do
    result =
      case platform do
        "ios" -> ios(config)
        "android" -> android(config)
      end

    case result do
      {:ok, %{newest: _, live: _, tracks: _}} -> result
      {:error, _} -> result
      _ -> {:error, "Store returned an unexpected response. Try Refresh."}
    end
  rescue
    # Exceptions can contain private keys, assertions or HTTP bodies. Never expose them.
    _ -> {:error, "Could not read store data. Check credentials and try Refresh."}
  catch
    _, _ -> {:error, "Could not read store data. Try Refresh."}
  end

  defp ios(config) do
    if connected?("ios", config) do
      now = System.os_time(:second)

      token =
        jwt(
          %{"alg" => "ES256", "kid" => config[:asc_key_id], "typ" => "JWT"},
          %{
            "iss" => config[:asc_issuer_id],
            "aud" => "appstoreconnect-v1",
            "iat" => now,
            "exp" => now + 600
          },
          config[:asc_private_key]
        )

      with {:ok, builds} <-
             pages(
               "/v1/builds?filter[app]=6816832730&sort=-uploadedDate&include=buildBetaDetail,preReleaseVersion&limit=200",
               token,
               config
             ),
           {:ok, groups} <- pages("/v1/apps/6816832730/betaGroups?limit=200", token, config),
           {:ok, friends} <- group_builds(groups, "Friends", token, config),
           {:ok, team} <- group_builds(groups, "Team", token, config) do
        {:ok, parse_asc(builds, friends, team)}
      end
    else
      {:error, :not_connected}
    end
  end

  defp group_builds(groups, name, token, config) do
    case Enum.find(groups["data"], fn group ->
           group["attributes"]["name"] == name and
             group["attributes"]["isInternalGroup"] == (name == "Team")
         end) do
      nil -> {:ok, %{"data" => []}}
      group -> pages("/v1/betaGroups/#{group["id"]}/builds?limit=200", token, config)
    end
  end

  # Follow every page: the last externally available build may be older than page one.
  defp pages(path, token, config) do
    url = if String.starts_with?(path, "/"), do: @asc <> path, else: path

    true =
      URI.parse(url).host == "api.appstoreconnect.apple.com" and URI.parse(url).scheme == "https"

    with {:ok, %{"data" => data} = body} <- request(:get, url, token, config) do
      case get_in(body, ["links", "next"]) do
        nil ->
          {:ok, body}

        next ->
          with {:ok, rest} <- pages(next, token, config) do
            {:ok,
             %{
               "data" => data ++ rest["data"],
               "included" => Map.get(body, "included", []) ++ Map.get(rest, "included", [])
             }}
          end
      end
    end
  end

  def parse_asc(body, friends, team) do
    included = Map.new(Map.get(body, "included", []), &{{&1["type"], &1["id"]}, &1["attributes"]})
    friend_ids = MapSet.new(friends["data"], & &1["id"])
    team_ids = MapSet.new(team["data"], & &1["id"])

    builds =
      body["data"]
      |> Enum.map(fn build ->
        attrs = build["attributes"]
        detail = related(build, "buildBetaDetail", included)
        version = related(build, "preReleaseVersion", included)

        %{
          id: build["id"],
          version: version["version"],
          number: attrs["version"],
          uploaded_at: attrs["uploadedDate"],
          since: nil,
          state:
            if(attrs["expired"] == true,
              do: "EXPIRED",
              else: detail["externalBuildState"] || attrs["processingState"]
            ),
          expired: attrs["expired"] == true,
          friends: MapSet.member?(friend_ids, build["id"]),
          team: MapSet.member?(team_ids, build["id"])
        }
      end)
      |> Enum.sort_by(& &1.uploaded_at, :desc)

    %{
      newest: List.first(builds),
      live: Enum.find(builds, &(&1.friends and !&1.expired and &1.state == "IN_BETA_TESTING")),
      tracks: []
    }
  end

  defp related(build, name, included) do
    case get_in(build, ["relationships", name, "data"]) do
      %{"type" => type, "id" => id} -> Map.get(included, {type, id}, %{})
      _ -> %{}
    end
  end

  defp android(config) do
    if connected?("android", config) do
      account = Jason.decode!(config[:play_service_account_json])
      now = System.os_time(:second)

      assertion =
        jwt(
          %{"alg" => "RS256", "typ" => "JWT"},
          %{
            "iss" => account["client_email"],
            "scope" => "https://www.googleapis.com/auth/androidpublisher",
            "aud" => @token,
            "iat" => now,
            "exp" => now + 600
          },
          account["private_key"]
        )

      with {:ok, %{"access_token" => token}} <-
             request(:post, @token, nil, config,
               form: [
                 grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                 assertion: assertion
               ]
             ),
           {:ok, %{"id" => edit}} <- request(:post, @play <> "/edits", token, config, json: %{}) do
        read_edit(edit, token, config)
      end
    else
      {:error, :not_connected}
    end
  end

  defp read_edit(edit, token, config) do
    # request returns errors, including transport exceptions. Delete before parsing,
    # even when the read failed, and never commit this edit.
    result = request(:get, @play <> "/edits/#{edit}/tracks", token, config)

    case request(:delete, @play <> "/edits/#{edit}", token, config) do
      {:ok, _} ->
        with {:ok, body} <- result, do: {:ok, parse_play(body)}

      _ ->
        {:error,
         "Could not delete the temporary Google Play edit. Nothing was committed; try Refresh."}
    end
  end

  def parse_play(%{"tracks" => tracks}) do
    releases =
      for track <- tracks,
          release <- Map.get(track, "releases", []),
          code <- Map.get(release, "versionCodes", []) do
        %{
          id: code,
          number: code,
          version: release_version(release["name"]),
          label: release["name"],
          state: release["status"],
          track: track["track"],
          uploaded_at: nil,
          since: nil
        }
      end
      |> Enum.sort_by(&String.to_integer(&1.number), :desc)

    %{
      newest: Enum.find(releases, &(&1.track in ["beta", "internal"])),
      live: Enum.find(releases, &(&1.track == "beta" and &1.state == "completed")),
      tracks: releases
    }
  end

  defp request(method, url, token, config, extra \\ []) do
    opts = [
      method: method,
      url: url,
      retry: if(method == :delete, do: :transient, else: false),
      max_retries: 2,
      retry_log_level: false,
      redirect: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 10_000]
    ]

    opts = if token, do: Keyword.put(opts, :auth, {:bearer, token}), else: opts

    case Req.request(
           opts
           |> Keyword.merge(extra)
           |> Keyword.merge(Keyword.get(config, :req_options, []))
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Store request failed (HTTP #{status}). Try Refresh."}
      {:error, _} -> {:error, "Store request timed out or could not connect. Try Refresh."}
    end
  rescue
    _ -> {:error, "Store request failed. Try Refresh."}
  catch
    _, _ -> {:error, "Store request failed. Try Refresh."}
  end

  defp jwt(header, claims, pem) do
    [entry] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    message = encode(Jason.encode!(header)) <> "." <> encode(Jason.encode!(claims))
    signature = :public_key.sign(message, :sha256, key)

    signature =
      if header["alg"] == "ES256" do
        {_, r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", signature)
        <<r::unsigned-big-integer-size(256), s::unsigned-big-integer-size(256)>>
      else
        signature
      end

    message <> "." <> encode(signature)
  end

  defp encode(value), do: Base.url_encode64(value, padding: false)

  # Play exposes an editable release name, not versionName. The dashboard
  # requires native-version release names; anything else needs a manual check.
  defp release_version(name) when is_binary(name) do
    case Version.parse(name) do
      {:ok, %Version{pre: [], build: nil}} -> name
      _ -> nil
    end
  end

  defp release_version(_), do: nil
end
