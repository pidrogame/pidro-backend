-- PID-288 defaults. Seeds and the forward migration share this guarded upgrade.
INSERT INTO email_templates
  (id, kind, key, name, subject, preview_text, html_body, variables, inserted_at, updated_at)
VALUES
  (gen_random_uuid(), 'transactional', 'password_reset', 'Password reset',
   'Reset your Pidro password',
   'Choose a new password for Pidro. The link works for one hour.',
   '<h1 class="h1" style="margin:0 0 14px;font-family:''Bree Serif'',Georgia,serif;font-weight:normal;font-size:30px;line-height:1.2;color:#07264c;">Choose a new password</h1>
<p style="margin:0 0 26px;">Hi {{username}}, someone asked to reset the password for your Pidro account. Tap the button and pick a new one.</p>

<table role="presentation" class="btn" cellpadding="0" cellspacing="0" style="margin:0 0 26px;">
<tr><td align="center" style="border-radius:12px;background-color:#e1ad3a;">
<a href="{{reset_url}}" style="display:inline-block;padding:18px 32px;font-family:Nunito,''Helvetica Neue'',Arial,sans-serif;font-size:19px;font-weight:bold;line-height:1.2;color:#1e0e04;text-decoration:none;border-radius:12px;border:1px solid #a86b17;">Choose a new password</a>
</td></tr>
</table>

<p class="muted" style="margin:0 0 6px;font-size:15px;color:#5c6b7d;">The link works for 1 hour. If the button does nothing, copy this address into your browser:</p>
<p style="margin:0 0 26px;font-size:14px;line-height:1.5;word-break:break-all;"><a class="link" href="{{reset_url}}" style="color:#0d5087;">{{reset_url}}</a></p>

<p class="muted" style="margin:0;font-size:15px;color:#5c6b7d;">Didn''t ask for this? Then nothing happens, and your password stays as it is.</p>',
   ARRAY['{{username}}', '{{reset_url}}'], now(), now()),
  (gen_random_uuid(), 'transactional', 'classic_sign_in_code', 'Classic sign-in code',
   'Your Pidro sign-in code',
   'Your code is {{code}}. It works for 15 minutes.',
   '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 22px;">
<tr><td class="codebox" align="center" style="padding:22px 12px;background-color:#eef4fa;border:1px solid #cfdcea;border-radius:14px;font-family:''Bree Serif'',Georgia,serif;font-size:48px;line-height:1.1;letter-spacing:10px;color:#07264c;">{{code}}</td></tr>
</table>

<p style="margin:0 0 22px;">Type this code in Pidro Beta, on the screen that says "Check your email". It is not a new password, so it won''t work in the password box.<br>It works for 15 minutes.<br>If you did not ask for this, ignore this mail.</p>

<p style="margin:0;">Skriv den här koden i Pidro Beta, på sidan där det står "Kolla din e-post". Det är inte ett nytt lösenord, så den fungerar inte i lösenordsrutan.<br>Den gäller i 15 minuter.<br>Om du inte har bett om den kan du strunta i det här mejlet.</p>',
   ARRAY['{{code}}'], now(), now()),
  (gen_random_uuid(), 'transactional', 'classic_help', 'Classic account help',
   'Help finding a Classic account: {{name}}', NULL,
   '<p style="margin:0 0 16px;">Name: {{name}}</p>
<p style="margin:0 0 16px;">Email: {{email}}</p>
<p style="margin:0 0 16px;white-space:pre-wrap;">Details: {{details}}</p>
<p style="margin:0;">{{user_line}}</p>',
   ARRAY['{{name}}', '{{email}}', '{{details}}', '{{user_line}}'], now(), now())
ON CONFLICT (kind, key) DO UPDATE
SET html_body = EXCLUDED.html_body, preview_text = EXCLUDED.preview_text, updated_at = now()
WHERE email_templates.name = EXCLUDED.name
  AND email_templates.subject = EXCLUDED.subject
  AND email_templates.variables = EXCLUDED.variables
  AND email_templates.preview_text IS NULL
  AND email_templates.from_name IS NULL
  AND email_templates.from_email IS NULL
  AND email_templates.reply_to IS NULL
  AND email_templates.html_body = CASE EXCLUDED.key
    WHEN 'password_reset' THEN '<p style="margin:0 0 24px;">Reset your Pidro password:</p>
<p style="margin:0 0 24px;"><a class="email-button" href="{{reset_url}}" style="display:inline-block;padding:16px 20px;background-color:#e1ad3a;color:#1e0e04;border:1px solid #a86b17;border-radius:8px;font-weight:bold;text-decoration:none;font-size:20px;line-height:1.4;">Choose a new password</a></p>
<p style="margin:0 0 24px;font-size:16px;overflow-wrap:anywhere;word-break:break-all;"><a href="{{reset_url}}" style="color:#0d5087;">{{reset_url}}</a></p>
<p style="margin:0;">This link expires in 1 hour.</p>'
    WHEN 'classic_sign_in_code' THEN '<p style="margin:0 0 24px;text-align:center;font-size:44px;font-weight:bold;letter-spacing:6px;line-height:1.4;">{{code}}</p>
<p style="margin:0 0 24px;">It works for 15 minutes</p>
<p style="margin:0;">If you did not ask for this, ignore this mail</p>'
  END;
