import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path';
import { expect, test } from '@playwright/test';
import { apiCall, newActor, registerViaInvite } from '<workspace>/timetrack-pwa/e2e/helpers';

const BIN = '<workspace>/timetrack-backend/.build/debug/App';
const PWA = '<workspace>/timetrack-pwa/build';
const PORT = 18095, BASE = `http://localhost:${PORT}`, MAIL = 'http://127.0.0.1:18025';

test('e-mail recovery via Mailpit', async ({ browser }) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tt-mail-'));
  const env = { ...process.env, DATABASE_DRIVER: 'sqlite', SQLITE_PATH: path.join(tmp, 'm.sqlite'), AUTO_MIGRATE: 'true',
    PWA_STATIC_DIR: PWA, PUBLIC_BASE_URL: BASE, WEBAUTHN_ORIGIN: BASE, WEBAUTHN_RP_ID: 'localhost',
    SMTP_HOST: '127.0.0.1', SMTP_PORT: '11025', SMTP_TLS: 'off', SMTP_FROM: 'noreply@example.test' };
  const boot = spawnSync(BIN, ['bootstrap-admin'], { env, encoding: 'utf8' });
  const link = boot.stdout.match(/https?:\/\/\S+\/invite\/\S+/)![0];
  const server = spawn(BIN, ['serve', '--hostname', '127.0.0.1', '--port', String(PORT)], { env, stdio: 'ignore' });
  try {
    for (let i = 0; i < 100; i++) { try { if ((await fetch(`${BASE}/ready`)).ok) break; } catch {} await new Promise(r => setTimeout(r, 300)); }
    const a = await newActor(browser);
    await registerViaInvite(a, new URL(link).pathname, 'mail.user', 'Mail User');
    await a.page.getByRole('button', { name: 'Später einrichten' }).click();
    const st = await apiCall(a.page, 'GET', '/api/v1/me/recovery');
    console.log('email available:', st.body.email.available);
    expect(st.body.email.available).toBe(true);

    const getCode = async (subjectPart: RegExp) => {
      for (let i = 0; i < 20; i++) {
        const list = await (await fetch(`${MAIL}/api/v1/messages`)).json();
        const m = list.messages?.[0];
        if (m) {
          const full = await (await fetch(`${MAIL}/api/v1/message/${m.ID}`)).json();
          console.log('mail subject:', full.Subject, '| to:', full.To?.[0]?.Address, '| from:', full.From?.Address);
          const mm = /(?:^|\D)([A-Z0-9]{6,12})(?:\D|$)/.exec(full.Text.replace(/\s+/g, ' ').match(/(?:Code|code)[^A-Za-z0-9]*([A-Z0-9-]{6,})/)?.[0] ?? full.Text);
          console.log('mail text (first 200):', JSON.stringify(full.Text.slice(0, 200)));
          return full.Text as string;
        }
        await new Promise(r => setTimeout(r, 500));
      }
      throw new Error('no mail');
    };
    await fetch(`${MAIL}/api/v1/messages`, { method: 'DELETE' });
    const put = await apiCall(a.page, 'PUT', '/api/v1/me/recovery/email', { email: 'mail.user@example.test' });
    console.log('enable email status:', put.status);
    const text1 = await getCode(/./);
    const code1 = process.env.CODE_RE ? new RegExp(process.env.CODE_RE).exec(text1)![1] : '';
    const ver = await apiCall(a.page, 'POST', '/api/v1/me/recovery/email/verify', { code: code1 });
    console.log('verify status:', ver.status);
    expect(ver.status).toBeLessThan(300);

    await fetch(`${MAIL}/api/v1/messages`, { method: 'DELETE' });
    const anon = await newActor(browser);
    await anon.page.goto('/recover');
    await anon.page.getByLabel('Kontoname').fill('mail.user');
    await anon.page.getByRole('radio', { name: /^E-Mail-Code/ }).check();
    await anon.page.getByRole('button', { name: 'Weiter' }).click();
    const text2 = await getCode(/./);
    const code2 = new RegExp(process.env.CODE_RE!).exec(text2)![1];
    await anon.page.locator('#recover-proof').fill(code2);
    await anon.page.getByRole('button', { name: 'Bestätigen' }).click();
    await anon.page.waitForTimeout(2000);
    console.log('after recovery url:', anon.page.url());
    const sess = await apiCall(anon.page, 'GET', '/api/v1/auth/session');
    console.log('session after recovery:', sess.status, JSON.stringify(sess.body).slice(0, 120));
  } finally { server.kill('SIGTERM'); fs.rmSync(tmp, { recursive: true, force: true }); }
});
