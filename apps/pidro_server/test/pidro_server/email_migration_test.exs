defmodule PidroServer.EmailMigrationTest do
  use PidroServer.DataCase, async: false

  import Swoosh.TestAssertions

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails

  @code_mail """
  012345

  Type this code in Pidro Beta, on the screen that says "Check your email". It is not a new password, so it won't work in the password box.
  It works for 15 minutes.
  If you did not ask for this, ignore this mail.

  Skriv den här koden i Pidro Beta, på sidan där det står "Kolla din e-post". Det är inte ett nytt lösenord, så den fungerar inte i lösenordsrutan.
  Den gäller i 15 minuter.
  Om du inte har bett om den kan du strunta i det här mejlet.
  """

  setup :set_swoosh_global

  setup do
    Repo.delete_all(PidroServer.Emails.EmailTemplate)
    :ok
  end

  test "sample data covers every variable group and renders every seeded template" do
    sample = Emails.sample_variables()

    for group <- Emails.variable_groups(), variable <- group.variables do
      key = String.trim(variable.key, "{{") |> String.trim("}}")
      assert is_binary(sample[key]) and sample[key] != ""
    end

    seed_templates()

    for template <- Emails.list_templates() do
      assert {:ok, rendered} = Emails.render_template(template, sample)
      refute rendered.html_body =~ "{{"
      refute rendered.subject =~ "{{"
    end
  end

  test "placeholder warnings distinguish unknown, unused and clean declarations" do
    {:ok, template} = Emails.create_template(:transactional)

    template = %{
      template
      | subject: "Hi {{ username }}",
        preview_text: "{{code}}",
        html_body: "<p>{{typo}}</p>",
        variables: ["{{username}}", "code", "{{unused}}"]
    }

    assert Emails.placeholder_warnings(template) == %{unknown: ["typo"], unused: ["unused"]}

    assert Emails.placeholder_warnings(%{template | variables: ["username", "code", "typo"]}) ==
             %{unknown: [], unused: []}
  end

  test "clearing variable declarations persists an empty list; omitting them preserves it" do
    {:ok, template} = Emails.create_template(:transactional)
    {:ok, unchanged} = Emails.update_template(template, %{subject: "Hi"})
    assert unchanged.variables == template.variables

    for blank <- ["", "  \n "] do
      {:ok, updated} = Emails.update_template(template, %{variables_text: blank})
      assert Emails.get_template!(updated.id).variables == []
      assert Emails.placeholder_warnings(updated) == %{unknown: ["username"], unused: []}
    end
  end

  test "test sends validate a single recipient before consuming quota and match production headers" do
    seed_templates()
    template = Emails.get_transactional_template(:classic_sign_in_code)
    admin_id = Ecto.UUID.generate()

    for invalid <- [
          nil,
          ["one@example.com"],
          "",
          "not-an-email",
          "a,b@example.com",
          "a@example.com\nb@example.com"
        ] do
      assert {:error, _} = Emails.send_test_email(template, invalid, admin_id)
      assert_no_email_sent()
    end

    for _ <- 1..5 do
      assert {:ok, _} = Emails.send_test_email(template, " aino@example.com ", admin_id)

      assert_email_sent(fn email ->
        production =
          Emails.transactional_email(:classic_sign_in_code, "aino@example.com", %{code: "028641"})

        assert email == production
      end)
    end

    assert {:error, {:rate_limited, retry_after}} =
             Emails.send_test_email(template, "other@example.com", admin_id)

    assert retry_after in 1..600_000
    assert_no_email_sent()

    {:ok, campaign} = Emails.create_template(:campaign)
    assert {:ok, _} = Emails.send_test_email(campaign, "aino@example.com", Ecto.UUID.generate())

    assert_email_sent(fn email ->
      assert email.from == {"Pidro", "hello@pidro.online"}
      refute email.html_body =~ "Pidro, the card game from Ostrobothnia"
      true
    end)
  end

  test "transactional layout wraps once without double escaping; text has no chrome" do
    {:ok, template} = Emails.create_template(:transactional)
    {:ok, rendered} = Emails.render_template(template, %{username: "<Aino & O'Neil>"})

    assert rendered.html_body =~ "<!DOCTYPE html>"
    assert rendered.html_body =~ "<p>Hi &lt;Aino &amp; O&#39;Neil&gt;,</p>"
    refute rendered.html_body =~ "&amp;lt;"
    assert rendered.html_body =~ "Pidro, the card game from Ostrobothnia"
    assert rendered.html_body =~ "color-scheme"
    assert rendered.text_body == "Hi <Aino & O'Neil>,\n\nWrite the email body here."

    {:ok, campaign} = Emails.render_template(%{template | kind: :campaign}, %{username: "Aino"})
    assert campaign.html_body == "<p>Hi Aino,</p>\n<p>Write the email body here.</p>\n"
  end

  test "transactional mails use the Pidro email logo, never the Phoenix SVG" do
    seed_templates()

    for template <- Emails.list_templates() do
      assert {:ok, rendered} = Emails.render_template(template, Emails.sample_variables())
      assert rendered.html_body =~ "/images/logo-email.png"
      refute rendered.html_body =~ "logo.svg"
    end
  end

  test "the hidden preheader contains escaped rendered preview text, not body or plain text" do
    seed_templates()
    template = Emails.get_transactional_template(:classic_sign_in_code)
    assert {:ok, rendered} = Emails.render_template(template, %{code: "012345"})

    assert rendered.html_body =~
             ~s(<div style="display:none;max-height:0;overflow:hidden;opacity:0;">Your code is 012345. It works for 15 minutes.</div>)

    refute rendered.text_body =~ "Your code is"
    assert rendered.text_body == String.trim_trailing(@code_mail)

    template = %{template | preview_text: "For {{username}}: <private>"}

    assert {:ok, rendered} =
             Emails.render_template(template, %{code: "012345", username: "<Aino & O'Neil>"})

    assert rendered.html_body =~ "For &lt;Aino &amp; O&#39;Neil&gt;: &lt;private&gt;</div>"
    refute rendered.html_body =~ "&amp;lt;"
  end

  test "upgrading old defaults matches fresh seeds and preserves every admin-editable field" do
    seed_templates()

    content_fields =
      ~w(name subject preview_text html_body variables from_name from_email reply_to)a

    expected = Map.new(Emails.list_templates(), &{&1.key, Map.take(&1, content_fields)})
    Repo.delete_all(PidroServer.Emails.EmailTemplate)
    seed_templates("transactional_email_templates_v1.sql")
    old = Emails.list_templates()
    seed_templates()

    for template <- old do
      upgraded = Emails.get_template!(template.id)
      assert Map.take(upgraded, content_fields) == expected[template.key]
    end

    unchanged = Emails.list_templates()
    seed_templates()
    assert Emails.list_templates() == unchanged

    for {field, value} <- [
          name: "Edited name",
          subject: "Edited subject",
          preview_text: "Edited preview",
          html_body: "<p>Edited body</p>",
          variables_text: "{{code}}\n{{username}}",
          from_name: "Edited sender",
          from_email: "sender@example.com",
          reply_to: "reply@example.com"
        ] do
      Repo.delete_all(PidroServer.Emails.EmailTemplate)
      seed_templates("transactional_email_templates_v1.sql")

      edited_templates =
        for template <- Emails.list_templates() do
          {:ok, edited} = Emails.update_template(template, %{field => value})
          Emails.get_template!(edited.id)
        end

      seed_templates()

      for edited <- edited_templates do
        assert Emails.get_template!(edited.id) == edited
      end
    end
  end

  for {key, variables, expected} <- [
        {:password_reset,
         %{
           username: "Aino",
           reset_url: "https://play.pidro.online/reset-password?token=abc&from=mail"
         }, "The link works for 1 hour."},
        {:classic_sign_in_code, %{code: "012345"}, String.trim_trailing(@code_mail)},
        {:classic_help, %{name: "Aino", email: "aino@example.com", details: nil, user_line: ""},
         "Name: Aino\n\nEmail: aino@example.com\n\nDetails:"}
      ] do
    test "seeded #{key} renders with exactly its call-site variables and survives admin failures" do
      seed_templates()
      key = unquote(key)
      variables = unquote(Macro.escape(variables))
      template = Emails.get_transactional_template(key)
      assert {:ok, rendered} = Emails.render_template(template, variables)
      assert rendered.text_body =~ unquote(expected)
      refute rendered.text_body =~ "Pidro, the card game from Ostrobothnia"
      refute rendered.html_body =~ "{{"

      email = Emails.transactional_email(key, "aino@example.com", variables)
      assert email.html_body == rendered.html_body
      assert email.text_body == rendered.text_body

      {:ok, template} = Emails.update_template(template, %{subject: "Changed {{typo}}"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          fallback = Emails.transactional_email(key, "aino@example.com", variables)
          refute fallback.subject =~ "Changed"

          refute fallback.html_body &&
                   fallback.html_body =~ "Pidro, the card game from Ostrobothnia"

          send(self(), {:fallback, fallback})
        end)

      assert log =~ "using fallback: :missing_variables"
      refute log =~ "aino@example.com"
      assert_receive {:fallback, fallback}

      Emails.delete_template(template)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Emails.transactional_email(key, "aino@example.com", variables) == fallback
        end)

      assert log =~ ":template_not_found"
    end
  end

  test "seed reruns preserve an admin's content and reply-to" do
    seed_templates()
    template = Emails.get_transactional_template(:classic_sign_in_code)

    {:ok, edited} =
      Emails.update_template(template, %{
        subject: "Your code: {{code}}",
        html_body: "<p>Code {{code}}</p>",
        reply_to: "admin@example.com"
      })

    seed_templates()
    assert Emails.get_template!(template.id) == edited
    assert Emails.template_summary() == %{total: 3, transactional: 3, campaigns: 0}

    email =
      Emails.transactional_email(:classic_sign_in_code, "aino@example.com", %{code: "012345"})

    assert email.subject == "Your code: 012345"
    assert email.text_body == "Code 012345"
    assert email.reply_to == {"", "admin@example.com"}
  end

  test "lookup exceptions fall back without exposing mail contents" do
    Repo.query!("ALTER TABLE email_templates RENAME TO unavailable_email_templates")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        email =
          Emails.transactional_email(:classic_sign_in_code, "aino@example.com", %{code: "012345"})

        assert email.text_body == @code_mail

        assert email.html_body == nil
      end)

    assert log =~ "using fallback: Postgrex.Error"
    refute log =~ "012345"
    refute log =~ "aino@example.com"
  end

  test "configured sender and default reply-to do not come from template sender fields" do
    seed_templates()
    original = Map.new(["MAIL_FROM_ADDRESS", "MAIL_REPLY_TO"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- original do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.put_env("MAIL_FROM_ADDRESS", "mail@example.com")
    System.put_env("MAIL_REPLY_TO", "help@example.com")
    template = Emails.get_transactional_template(:classic_sign_in_code)
    Emails.update_template(template, %{from_email: "other@example.com", from_name: "Other"})

    email =
      Emails.transactional_email(:classic_sign_in_code, "aino@example.com", %{code: "012345"})

    assert email.from == {"Pidro", "mail@example.com"}
    assert email.reply_to == {"", "help@example.com"}
    assert email.html_body =~ "mailto:help@example.com"
  end

  test "subscriber_summary counts exportable contacts" do
    AccountsFixtures.user_fixture(%{username: "mail_registered", email: "registered@example.com"})

    AccountsFixtures.user_fixture(%{
      username: "mail_guest",
      email: "guest@example.com",
      guest: true
    })

    {:ok, _user} =
      Auth.register_user(%{
        username: "mail_without_email",
        password: AccountsFixtures.valid_user_password()
      })

    summary = Emails.subscriber_summary()

    assert summary.total_users == 3
    assert summary.contacts_with_email == 2
    assert summary.registered_contacts == 1
    assert summary.guest_contacts == 1
    assert summary.missing_email == 1
  end

  test "export_contacts_csv includes Keila headers and escapes fields" do
    AccountsFixtures.user_fixture(%{
      username: ~s(Name, "Pilot"),
      email: "pilot@example.com"
    })

    csv = Emails.export_contacts_csv()

    assert csv =~
             "email,username,first_name,last_name,subscribed,guest,created_at,updated_at,source"

    assert csv =~ "pilot@example.com"
    assert csv =~ ~s("Name, ""Pilot""")
    assert csv =~ ",true,false,"
    assert csv =~ "pidro_server"
  end

  test "creates and updates email templates in the database" do
    {:ok, template} = Emails.create_template(:transactional)

    assert template.kind == :transactional
    assert template.key =~ "transactional_email_"
    assert template.name == "Untitled transactional email"
    refute Map.has_key?(template, :sends)
    refute Map.has_key?(template, :opens)

    {:ok, updated} =
      Emails.update_template(template, %{
        "key" => "welcome_email",
        "name" => "Welcome email",
        "subject" => "Welcome to Pidro",
        "html_body" => "<p>Hi {{username}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert updated.name == "Welcome email"
    assert updated.key == "welcome_email"
    assert updated.subject == "Welcome to Pidro"
    assert updated.variables == ["{{username}}", "{{support_email}}"]
    assert Emails.get_transactional_template(:welcome_email).id == updated.id
    assert Emails.template_summary().transactional == 1

    assert {:ok, _deleted} = Emails.delete_template(updated)
    assert Emails.get_template(updated.id) == nil
    assert Emails.template_summary().transactional == 0
  end

  test "renders and delivers a transactional email by key" do
    user =
      AccountsFixtures.user_fixture(%{
        username: "mail_delivery_player",
        email: "mail-delivery@example.com"
      })

    {:ok, template} = Emails.create_template(:transactional)

    {:ok, _template} =
      Emails.update_template(template, %{
        "key" => "welcome_email",
        "name" => "Welcome email",
        "subject" => "Welcome {{username}}",
        "preview_text" => "Start playing, {{username}}",
        "from_name" => "Pidro",
        "from_email" => "noreply@pidro.online",
        "reply_to" => "support@pidro.net",
        "html_body" => "<p>Hi {{username}}</p><p>Ask {{support_email}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert {:ok, _metadata} =
             Emails.deliver_transactional(:welcome_email, user, %{
               username: "<Pilot>",
               support_email: "support@pidro.net"
             })

    assert_email_sent(fn email ->
      assert email.subject == "Welcome <Pilot>"
      assert email.to == [{"mail_delivery_player", "mail-delivery@example.com"}]
      assert email.from == {"Pidro", "noreply@pidro.online"}
      assert email.reply_to == {"", "support@pidro.net"}
      assert email.html_body =~ "Hi &lt;Pilot&gt;"
      assert email.text_body =~ "Hi <Pilot>"
      true
    end)
  end

  test "returns missing variable errors before sending transactional email" do
    {:ok, template} = Emails.create_template(:transactional)

    {:ok, template} =
      Emails.update_template(template, %{
        "key" => "account_deletion",
        "subject" => "Account deletion for {{username}}",
        "html_body" => "<p>Ask {{support_email}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert {:error, {:missing_variables, ["support_email"]}} =
             Emails.render_template(template, %{username: "Pilot"})

    assert {:error, {:missing_variables, ["support_email"]}} =
             Emails.deliver_transactional("account_deletion", "pilot@example.com", %{
               username: "Pilot"
             })
  end

  defp seed_templates(file \\ "transactional_email_templates.sql") do
    :pidro_server
    |> Application.app_dir("priv/repo/#{file}")
    |> File.read!()
    |> Repo.query!()
  end
end
