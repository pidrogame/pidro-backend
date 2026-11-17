defmodule PidroServer.Emails.MailingTest do
  use PidroServer.DataCase, async: false

  import Swoosh.TestAssertions

  alias PidroServer.Accounts.User
  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails
  alias PidroServer.Emails.{EmailSend, EmailSendRecipient, Mailing}

  setup :set_swoosh_global

  defmodule FailingMailer do
    use Swoosh.Adapter

    # Like an SMTP failure, whose details can name the recipient.
    def deliver(email, _config) do
      [{_name, address}] = email.to

      if address =~ "bad" or Application.get_env(:pidro_server, :failing_mailer_all, false),
        do: {:error, {:permanent_failure, ~c"relay.example.com", "550 #{address} refused"}},
        else: Swoosh.Adapters.Test.deliver(email, [])
    end
  end

  defmodule BlockingMailer do
    use Swoosh.Adapter

    def deliver(email, config) do
      [{_name, address}] = email.to
      send(config[:test_pid], {:mail_waiting, self(), address})

      receive do
        :deliver -> Swoosh.Adapters.Test.deliver(email, [])
      end
    end
  end

  setup do
    Repo.delete_all(PidroServer.Emails.EmailTemplate)
    {:ok, template} = Emails.create_template(:campaign)

    on_exit(fn ->
      if pid = Process.whereis(Mailing), do: Process.exit(pid, :kill)
    end)

    %{template: template}
  end

  defp use_mailer(adapter, opts \\ []) do
    mailer_env = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
    Application.put_env(:pidro_server, PidroServer.Mailer, [adapter: adapter] ++ opts)
    on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env) end)
  end

  defp await_mailing do
    case Process.whereis(Mailing) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  defp collect_emails(acc \\ []) do
    receive do
      {:email, email} -> collect_emails([email | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp rows(send_id) do
    Repo.all(
      from r in EmailSendRecipient,
        where: r.send_id == ^send_id,
        select: {r.user_id, r.state},
        order_by: r.id
    )
  end

  defp players(count) do
    for i <- 1..count, do: AccountsFixtures.user_fixture(%{email: "player#{i}@example.com"})
  end

  describe "recipients" do
    test "registered players with a sendable address who did not opt out, and no one else" do
      kept = AccountsFixtures.user_fixture(%{email: "kept@example.com"})
      named = AccountsFixtures.user_fixture(%{email: "named@example.com", display_name: "Aino K"})
      AccountsFixtures.user_fixture(%{email: "guest@example.com", guest: true})
      opted_out = AccountsFixtures.user_fixture(%{email: "off@example.com"})
      {:ok, _user} = Emails.set_update_emails(opted_out, :off)
      unsendable = AccountsFixtures.user_fixture(%{email: "fine@example.com"})

      # A legacy row the SMTP encoder cannot write; the changeset refuses it today.
      Repo.update_all(from(u in User, where: u.id == ^unsendable.id),
        set: [email: "a,b@example.com"]
      )

      {:ok, _no_email} =
        PidroServer.Accounts.Auth.register_user(%{
          username: "no_email",
          password: AccountsFixtures.valid_user_password()
        })

      assert Enum.map(Emails.campaign_recipients(), & &1.id) |> Enum.sort() ==
               Enum.sort([kept.id, named.id])
    end
  end

  describe "unsubscribe token" do
    test "round trips to its own player only; tampered and foreign tokens are refused" do
      aino = AccountsFixtures.user_fixture()
      bo = AccountsFixtures.user_fixture()
      token = token_for(aino)

      assert {:ok, %User{id: id}} = Emails.user_for_unsubscribe_token(token)
      assert id == aino.id
      assert {:ok, %User{id: bo_id}} = token_for(bo) |> Emails.user_for_unsubscribe_token()
      assert bo_id == bo.id

      assert Emails.user_for_unsubscribe_token(tamper(token)) == :error

      # Bo's id in Aino's signed envelope fails the signature.
      [protected, _aino_payload, signature] = String.split(token, ".")
      bo_payload = token_for(bo) |> String.split(".") |> Enum.at(1)

      assert Emails.user_for_unsubscribe_token("#{protected}.#{bo_payload}.#{signature}") ==
               :error

      # Another salt's token for the same id (such as a socket token) is not one.
      other = Phoenix.Token.sign(PidroServerWeb.Endpoint, "user socket", aino.id)
      assert Emails.user_for_unsubscribe_token(other) == :error
      assert Emails.user_for_unsubscribe_token("") == :error

      {:ok, _deleted} = PidroServer.Accounts.Auth.delete_user(aino)
      assert Emails.user_for_unsubscribe_token(token) == :error
    end

    test "turning update emails off twice keeps the first time; on clears it" do
      user = AccountsFixtures.user_fixture()
      {:ok, %User{update_emails_off_at: first}} = Emails.set_update_emails(user, :off)
      assert %DateTime{} = first

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [update_emails_off_at: ~U[2026-01-01 00:00:00Z]]
      )

      assert {:ok, %User{update_emails_off_at: ~U[2026-01-01 00:00:00Z]}} =
               Emails.set_update_emails(user, :off)

      assert {:ok, %User{update_emails_off_at: nil}} = Emails.set_update_emails(user, :on)
      assert {:ok, %User{update_emails_off_at: nil}} = Emails.set_update_emails(user, :on)
    end
  end

  # A middle character: the last one of a signature is partly padding bits.
  defp tamper(token) do
    middle = div(String.length(token), 2)
    swapped = if String.at(token, middle) == "A", do: "B", else: "A"
    String.slice(token, 0, middle) <> swapped <> String.slice(token, (middle + 1)..-1//1)
  end

  defp token_for(user) do
    prefix = PidroServerWeb.Endpoint.url() <> "/unsubscribe/"
    url = Emails.unsubscribe_url(user.id)
    assert String.starts_with?(url, prefix)
    String.replace_prefix(url, prefix, "")
  end

  describe "a send" do
    test "every recipient gets exactly one mail with their own link and both headers; a rerun sends nothing",
         %{template: template} do
      aino = AccountsFixtures.user_fixture(%{email: "aino@example.com", display_name: "Aino K"})
      [p1, p2] = players(2)
      AccountsFixtures.user_fixture(%{email: "guest@example.com", guest: true})

      assert {:ok, %EmailSend{} = send} = Mailing.start(template, "admin@example.com")
      await_mailing()

      emails = collect_emails()
      assert length(emails) == 3

      for user <- [aino, p1, p2] do
        assert [email] = Enum.filter(emails, &(&1.to == [{user.username, user.email}]))
        prefix = PidroServerWeb.Endpoint.url() <> "/unsubscribe/"
        [url | _same] = Regex.run(~r/href="([^"]+)"/, email.html_body, capture: :all_but_first)

        assert {:ok, %User{id: id}} =
                 url |> String.replace_prefix(prefix, "") |> Emails.user_for_unsubscribe_token()

        assert id == user.id
        assert email.text_body =~ "Hi #{User.public_name(user)},"
        assert email.headers["List-Unsubscribe"] == "<#{url}>"
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
        assert email.subject == template.subject
      end

      assert Enum.find(emails, &(&1.to == [{aino.username, aino.email}])).html_body =~
               "Hi Aino K,"

      assert Enum.all?(rows(send.id), &match?({_id, :sent}, &1))

      assert %EmailSend{state: :finished, started_by: "admin@example.com", finished_at: %{}} =
               Repo.get!(EmailSend, send.id)

      # The log keeps what was sent, not what the template says now.
      {:ok, _edited} = Emails.update_template(template, %{subject: "Edited later"})
      assert Repo.get!(EmailSend, send.id).template["subject"] == template.subject

      assert {:ok, _send} = Mailing.resume(send.id)
      await_mailing()
      assert_no_email_sent()
      assert [%{counts: %{sent: 3, pending: 0, failed: 0}}] = Mailing.list_sends(template.id)

      # Deleting an account removes its rows from the log.
      {:ok, _deleted} = PidroServer.Accounts.Auth.delete_user(p2)
      assert [%{counts: %{sent: 2}}] = Mailing.list_sends(template.id)
    end

    test "the text part carries the recipient's own unsubscribe URL, written out, and no one else's",
         %{template: template} do
      users = players(3)
      {:ok, _send} = Mailing.start(template, "admin@example.com")
      await_mailing()
      emails = collect_emails()
      assert length(emails) == 3

      header_urls =
        Map.new(emails, fn email ->
          "<" <> rest = email.headers["List-Unsubscribe"]
          {email.to, String.trim_trailing(rest, ">")}
        end)

      for user <- users do
        email = Enum.find(emails, &(&1.to == [{user.username, user.email}]))
        own_url = header_urls[email.to]

        assert [_ | _] =
                 text_urls = Regex.scan(~r{https?://\S+/unsubscribe/\S+}, email.text_body)

        assert Enum.uniq(List.flatten(text_urls)) == [own_url]

        token =
          String.replace_prefix(own_url, PidroServerWeb.Endpoint.url() <> "/unsubscribe/", "")

        assert {:ok, %User{id: id}} = Emails.user_for_unsubscribe_token(token)
        assert id == user.id

        for {to, other_url} <- header_urls, to != email.to do
          refute email.text_body =~ other_url
        end
      end
    end

    test "a bad address is a failed row and the send goes on", %{template: template} do
      use_mailer(FailingMailer)
      [p1, p2] = players(2)
      bad = AccountsFixtures.user_fixture(%{email: "bad@example.com"})

      {:ok, send} = Mailing.start(template, "admin@example.com")
      log = ExUnit.CaptureLog.capture_log(&await_mailing/0)
      assert log =~ "Mailing email delivery failed"
      refute log =~ "bad@example.com"

      assert Map.new(rows(send.id)) == %{p1.id => :sent, p2.id => :sent, bad.id => :failed}
      assert %EmailSend{state: :finished} = Repo.get!(EmailSend, send.id)
    end

    test "five failures in a row pause the send; Resume sends only the pending rows",
         %{template: template} do
      use_mailer(FailingMailer)
      Application.put_env(:pidro_server, :failing_mailer_all, true)
      on_exit(fn -> Application.delete_env(:pidro_server, :failing_mailer_all) end)
      users = players(7)

      {send, log} =
        ExUnit.CaptureLog.with_log(fn ->
          {:ok, send} = Mailing.start(template, "admin@example.com")
          await_mailing()
          send
        end)

      assert log =~ "Mailing email delivery failed"
      refute log =~ "@example.com"
      assert collect_emails() == []

      paused = Repo.get!(EmailSend, send.id)
      assert paused.state == :paused
      assert paused.paused_reason == "5 failures in a row, the last :permanent_failure"

      states = Map.new(rows(send.id))
      assert states |> Map.values() |> Enum.frequencies() == %{failed: 5, pending: 2}
      pending = Enum.filter(users, &(states[&1.id] == :pending))

      Application.put_env(:pidro_server, :failing_mailer_all, false)
      assert {:ok, _send} = Mailing.resume(send.id)
      await_mailing()

      assert collect_emails() |> Enum.map(& &1.to) |> Enum.sort() ==
               pending |> Enum.map(&[{&1.username, &1.email}]) |> Enum.sort()

      assert %EmailSend{state: :finished, paused_reason: nil} = Repo.get!(EmailSend, send.id)

      assert [%{counts: %{sent: 2, failed: 5, pending: 0, claimed: 0}}] =
               Mailing.list_sends(template.id)
    end

    test "a row left claimed by a crash is neither resent nor counted as sent; a second send cannot start meanwhile",
         %{template: template} do
      use_mailer(BlockingMailer, test_pid: self())
      users = players(3)

      {:ok, send} = Mailing.start(template, "admin@example.com")
      assert_receive {:mail_waiting, sender, address}
      {[claimed], [second, third]} = Enum.split_with(users, &(&1.email == address))
      assert Mailing.running?()

      assert Mailing.start(template, "other@example.com") == {:error, :already_running}
      assert Mailing.resume(send.id) == {:error, :already_running}
      assert Repo.aggregate(EmailSend, :count) == 1

      # The deploy: the delivery process dies with the first mail in the mailer.
      ref = Process.monitor(sender)
      Process.exit(sender, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
      refute Mailing.running?()

      assert Map.new(rows(send.id)) == %{
               claimed.id => :claimed,
               second.id => :pending,
               third.id => :pending
             }

      assert [%{state: :running, counts: %{claimed: 1, sent: 0}}] =
               Mailing.list_sends(template.id)

      use_mailer(Swoosh.Adapters.Test)
      assert {:ok, _send} = Mailing.resume(send.id)
      await_mailing()

      assert collect_emails() |> Enum.map(& &1.to) |> Enum.sort() ==
               Enum.sort([[{second.username, second.email}], [{third.username, third.email}]])

      assert [%{state: :finished, counts: %{claimed: 1, sent: 2, pending: 0}}] =
               Mailing.list_sends(template.id)
    end

    test "a send paused from the other container during a deploy stops this loop; the database allows one running send",
         %{template: template} do
      use_mailer(BlockingMailer, test_pid: self())
      players(3)

      {:ok, send} = Mailing.start(template, "admin@example.com")
      assert_receive {:mail_waiting, sender, _address}

      # The new container's start marks every running send paused.
      Repo.update_all(from(s in EmailSend, where: s.id == ^send.id), set: [state: :paused])

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%EmailSend{template: %{}, started_by: "a", state: :running})
        Repo.insert!(%EmailSend{template: %{}, started_by: "b", state: :running})
      end

      send(sender, :deliver)
      await_mailing()

      assert [_one] = collect_emails()

      assert %{sent: 1, pending: 2} =
               rows(send.id) |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()

      assert %EmailSend{state: :paused} = Repo.get!(EmailSend, send.id)
    end

    test "a player who turns update emails off mid-send is skipped", %{template: template} do
      use_mailer(BlockingMailer, test_pid: self())
      users = players(2)

      {:ok, send} = Mailing.start(template, "admin@example.com")
      assert_receive {:mail_waiting, sender, address}
      {[first], [second]} = Enum.split_with(users, &(&1.email == address))
      {:ok, _user} = Emails.set_update_emails(second, :off)
      send(sender, :deliver)
      await_mailing()

      assert Map.new(rows(send.id)) == %{first.id => :sent, second.id => :skipped}
      assert [[{_name, ^address}]] = Enum.map(collect_emails(), & &1.to)
    end

    test "a template without its unsubscribe link cannot start", %{template: template} do
      {:ok, template} = Emails.update_template(template, %{html_body: "<p>Hi {{first_name}}</p>"})
      players(1)

      assert Mailing.start(template, "admin@example.com") ==
               {:error, {:blocked, "Add {{unsubscribe_url}} to the body first."}}

      assert Repo.aggregate(EmailSend, :count) == 0
      assert_no_email_sent()
    end
  end
end
